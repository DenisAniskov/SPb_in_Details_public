import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:smart_navigator_spb/services/voice/speech_recognition_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_engine_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_query_normalizer.dart';

/// Explicit states of the voice-search interaction. The machine only advances
/// on user actions or on a completed native operation; a late platform result
/// after cancellation is ignored by generation tracking.
enum VoiceSearchState {
  idle,
  requestingPermission,
  recording,
  recognizing,
  transcriptReady,
  permissionDenied,
  permissionPermanentlyDenied,
  modelUnavailable,
  recognitionFailed,
  emptySpeech,
  timeout,
  cancelled,
  consentRequired,
}

class VoiceSearchController extends ChangeNotifier {
  VoiceSearchController({
    required SpeechRecognitionService service,
    this.maxRecordingDuration = const Duration(seconds: 30),
    // Public dependency names are part of the injection contract.
    // ignore: prefer_initializing_formals
  }) : _service = service;

  static const int maxQueryLength = 150;

  final SpeechRecognitionService _service;
  final Duration maxRecordingDuration;

  VoiceSearchState _state = VoiceSearchState.idle;
  String _transcript = '';
  String _errorMessage = '';
  SpeechRecognitionResult? _lastResult;
  Timer? _timer;
  StreamSubscription<String>? _partialSubscription;
  String _partialTranscript = '';
  VoiceEngineSnapshot? _engineSnapshot;
  int _generation = 0;
  bool _disposed = false;

  VoiceSearchState get state => _state;
  String get transcript => _transcript;
  String get errorMessage => _errorMessage;
  SpeechRecognitionResult? get lastResult => _lastResult;

  /// Interim words from the system recognizer. Never used as a search query;
  /// the final transcript remains the only applied text.
  String get partialTranscript => _partialTranscript;
  VoiceEngineSnapshot? get engineSnapshot => _engineSnapshot;
  String get engineLabel =>
      _engineSnapshot?.engineLabel ?? 'Системное распознавание Android';

  bool get isBusy =>
      _state == VoiceSearchState.requestingPermission ||
      _state == VoiceSearchState.recording ||
      _state == VoiceSearchState.recognizing;

  bool get isRecording => _state == VoiceSearchState.recording;
  bool get canConfirm =>
      _state == VoiceSearchState.transcriptReady &&
      _transcript.trim().isNotEmpty;

  bool get canRetry => switch (_state) {
    VoiceSearchState.permissionDenied ||
    VoiceSearchState.permissionPermanentlyDenied ||
    VoiceSearchState.modelUnavailable ||
    VoiceSearchState.recognitionFailed ||
    VoiceSearchState.emptySpeech ||
    VoiceSearchState.timeout ||
    VoiceSearchState.cancelled ||
    VoiceSearchState.idle => true,
    _ => false,
  };

  /// Loads saved consent and system-recognizer availability for the settings
  /// screen. Called once at app startup; safe to repeat.
  Future<void> initializeEngineSettings() async {
    final access = _service is VoiceEnginePreferencesAccess
        ? _service as VoiceEnginePreferencesAccess
        : null;
    if (access == null || _disposed) return;
    try {
      final snapshot = await access.refreshEngines();
      if (_disposed) return;
      _engineSnapshot = snapshot;
      notifyListeners();
    } catch (_) {
      // Manual search remains available; the sheet will report the failure.
    }
  }

  /// Persists consent and, when revoking, stops an active recognition first.
  /// No new session can start after the controller has observed a refused
  /// consent, regardless of what happens to the separate settings screen.
  Future<bool> setOnlineConsent(bool granted) async {
    final access = _service is VoiceEnginePreferencesAccess
        ? _service as VoiceEnginePreferencesAccess
        : null;
    if (access == null || _disposed) return false;
    if (!granted) {
      // Stop the microphone before recording "no", so an active session never
      // continues while consent is being withdrawn.
      await cancel();
      if (_disposed) return false;
    }
    try {
      await access.setOnlineConsent(granted);
      _engineSnapshot = access.engineSnapshot;
      if (_disposed) return false;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Optional recognition hint for engines that support biasing.
  void setBiasStrings(Iterable<String> values) {
    final service = _service;
    if (service is VoiceSearchEngineService) {
      service.setBiasStrings(values);
    }
  }

  Future<void> start() async {
    if (_disposed || isBusy) return;
    final generation = ++_generation;
    _timer?.cancel();
    _transcript = '';
    _partialTranscript = '';
    _lastResult = null;
    _errorMessage = '';
    _setState(VoiceSearchState.requestingPermission);

    try {
      final access = _service is VoiceEnginePreferencesAccess
          ? _service as VoiceEnginePreferencesAccess
          : null;
      if (access != null) {
        final snapshot = await access.refreshEngines();
        if (!_isCurrent(generation)) return;
        _engineSnapshot = snapshot;
        notifyListeners();
        if (snapshot.needsConsent) {
          _fail(
            VoiceSearchState.consentRequired,
            'Для голосового поиска нужно согласие на системное '
            'распознавание. Служба Android в зависимости от устройства '
            'может использовать интернет и передавать аудио поставщику. '
            'Текстовый поиск работает и без согласия.',
          );
          return;
        }
        if (!snapshot.supported) {
          _fail(
            VoiceSearchState.modelUnavailable,
            snapshot.reason ??
                'Голосовое распознавание недоступно. '
                    'Можно найти место вручную.',
          );
          return;
        }
      }
      final status = await _service.status();
      if (!_isCurrent(generation)) return;
      if (!status.supported) {
        _fail(
          VoiceSearchState.modelUnavailable,
          status.error ?? 'Голосовой поиск недоступен на этом устройстве.',
        );
        return;
      }
      if (status.modelMissing) {
        _fail(
          VoiceSearchState.modelUnavailable,
          status.error ??
              'Системное распознавание русского языка сейчас недоступно. '
                  'Можно найти место вручную.',
        );
        return;
      }

      var permission = status.permission;
      if (permission != SpeechPermission.granted) {
        permission = await _service.requestPermission();
        if (!_isCurrent(generation)) return;
      }
      if (permission == SpeechPermission.permanentlyDenied) {
        _fail(
          VoiceSearchState.permissionPermanentlyDenied,
          'Микрофон отключён в настройках приложения. '
          'Его можно включить в настройках или найти место вручную.',
        );
        return;
      }
      if (permission != SpeechPermission.granted) {
        _fail(
          VoiceSearchState.permissionDenied,
          'Микрофон недоступен. Можно найти место вручную.',
        );
        return;
      }

      await _service.startRecording();
      if (!_isCurrent(generation)) {
        unawaited(_service.cancel());
        return;
      }
      _setState(VoiceSearchState.recording);
      _subscribePartials(generation);
      _timer = Timer(maxRecordingDuration, () => _expire(generation));
    } on SpeechRecognitionException catch (error) {
      if (!_isCurrent(generation)) return;
      _fail(_stateForFailure(error.code), error.message);
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _fail(
        VoiceSearchState.recognitionFailed,
        'Не удалось запустить голосовой ввод. '
        'Можно найти место вручную.',
      );
    }
  }

  Future<void> stop() async {
    if (_disposed || _state != VoiceSearchState.recording) return;
    final generation = _generation;
    _timer?.cancel();
    _timer = null;
    _unsubscribePartials(clear: true);
    _setState(VoiceSearchState.recognizing);
    // Let the «Распознаём речь…» frame reach the screen before the platform
    // call. The native bridge no longer blocks the platform thread, but this
    // makes the immediate state change deterministic. The timeout and the
    // guard keep headless controller tests working without a scheduler.
    await _waitForRecognizingFrame();
    if (!_isCurrent(generation)) return;
    try {
      final result = await _service.stopAndRecognize();
      if (!_isCurrent(generation)) return;
      final text = VoiceQueryNormalizer.normalize(result.text);
      if (text.isEmpty) {
        _fail(
          VoiceSearchState.emptySpeech,
          'Не удалось расслышать речь. Попробуйте ещё раз '
          'или введите запрос вручную.',
        );
        return;
      }
      // Aggregate timings only; the transcript never enters logs.
      debugPrint(
        'STT timings: audio=${result.audioDurationMs}ms '
        'total=${result.latencyMs}ms ${result.timings}',
      );
      _lastResult = result;
      _transcript = text;
      _errorMessage = '';
      _setState(VoiceSearchState.transcriptReady);
    } on SpeechRecognitionException catch (error) {
      if (!_isCurrent(generation)) return;
      _fail(_stateForFailure(error.code), error.message);
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _fail(
        VoiceSearchState.recognitionFailed,
        'Не удалось распознать речь. Попробуйте ещё раз '
        'или найдите место вручную.',
      );
    }
  }

  Future<void> cancel() async {
    if (_disposed) return;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _unsubscribePartials(clear: true);
    if (isBusy) {
      await _service.cancel();
    }
    if (_disposed) return;
    _setState(VoiceSearchState.cancelled);
  }

  /// Applies a user correction to the recognized text before confirmation.
  void updateTranscript(String value) {
    if (_disposed || _state != VoiceSearchState.transcriptReady) return;
    _transcript = value;
    _errorMessage = '';
    notifyListeners();
  }

  /// Returns the normalized query exactly once. Routing is never started from
  /// here: the caller hands the text to the existing search pipeline.
  String? confirm() {
    if (_disposed || !canConfirm) return null;
    final query = VoiceQueryNormalizer.normalize(_transcript);
    if (query.length < 2) {
      _errorMessage = 'Запрос слишком короткий. Назовите место точнее.';
      notifyListeners();
      return null;
    }
    if (query.length > maxQueryLength) {
      _errorMessage = 'Запрос длиннее $maxQueryLength символов. Сократите его.';
      notifyListeners();
      return null;
    }
    _transcript = query;
    _timer?.cancel();
    _timer = null;
    _setState(VoiceSearchState.idle);
    return query;
  }

  Future<void> openPermissionSettings() => _service.openPermissionSettings();

  /// Returns the machine to idle after the sheet closes or a query is applied.
  void reset() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _unsubscribePartials(clear: true);
    ++_generation;
    _transcript = '';
    _errorMessage = '';
    _lastResult = null;
    _setState(VoiceSearchState.idle);
  }

  void _subscribePartials(int generation) {
    _partialSubscription?.cancel();
    _partialSubscription = null;
    final source = _service is PartialTranscriptSource
        ? _service as PartialTranscriptSource
        : null;
    if (source == null) return;
    _partialSubscription = source.partialTranscripts.listen((text) {
      if (!_isCurrent(generation) || _state != VoiceSearchState.recording) {
        return;
      }
      final value = text.trim();
      if (value.isEmpty || value == _partialTranscript) return;
      _partialTranscript = value;
      notifyListeners();
    });
  }

  void _unsubscribePartials({required bool clear}) {
    _partialSubscription?.cancel();
    _partialSubscription = null;
    if (clear) _partialTranscript = '';
  }

  Future<void> _waitForRecognizingFrame() async {
    try {
      await Future.any<void>([
        SchedulerBinding.instance.endOfFrame,
        Future<void>.delayed(const Duration(milliseconds: 80)),
      ]);
    } catch (_) {
      // No initialized binding (plain unit test): the state is already set.
    }
  }

  Future<void> _expire(int generation) async {
    if (!_isCurrent(generation) || _state != VoiceSearchState.recording) return;
    ++_generation;
    _timer = null;
    _unsubscribePartials(clear: true);
    await _service.cancel();
    if (_disposed) return;
    _fail(
      VoiceSearchState.timeout,
      'Запись остановлена по лимиту '
      '${maxRecordingDuration.inSeconds} секунд. Попробуйте ещё раз.',
    );
  }

  void _fail(VoiceSearchState state, String message) {
    _errorMessage = message;
    _setState(state);
  }

  void _setState(VoiceSearchState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  VoiceSearchState _stateForFailure(SpeechFailureCode code) => switch (code) {
    SpeechFailureCode.permissionDenied => VoiceSearchState.permissionDenied,
    SpeechFailureCode.permissionPermanentlyDenied =>
      VoiceSearchState.permissionPermanentlyDenied,
    SpeechFailureCode.consentRequired => VoiceSearchState.consentRequired,
    SpeechFailureCode.modelUnavailable => VoiceSearchState.modelUnavailable,
    SpeechFailureCode.emptySpeech => VoiceSearchState.emptySpeech,
    SpeechFailureCode.timeout => VoiceSearchState.timeout,
    SpeechFailureCode.cancelled => VoiceSearchState.cancelled,
    SpeechFailureCode.languageUnavailable => VoiceSearchState.modelUnavailable,
    SpeechFailureCode.busy ||
    SpeechFailureCode.network ||
    SpeechFailureCode.microphoneUnavailable ||
    SpeechFailureCode.recognitionFailed => VoiceSearchState.recognitionFailed,
  };

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _unsubscribePartials(clear: true);
    unawaited(_service.cancel());
    unawaited(_service.dispose());
    super.dispose();
  }
}
