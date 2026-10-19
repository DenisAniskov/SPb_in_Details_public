import 'dart:async';

import 'package:flutter/services.dart';
import 'package:smart_navigator_spb/services/voice/speech_recognition_service.dart';

class AndroidSpeechAvailability {
  const AndroidSpeechAvailability({
    required this.supported,
    required this.permission,
    this.error,
  });

  const AndroidSpeechAvailability.unavailable(this.error)
    : supported = false,
      permission = SpeechPermission.denied;

  final bool supported;
  final SpeechPermission permission;
  final String? error;
}

/// Platform implementation of the Android SpeechRecognizer. The platform
/// service owns the microphone and may perform on-device or network
/// recognition; this class never receives or stores audio bytes.
///
/// The app always uses the ordinary system recognizer. Android decides where
/// the work happens, so the client neither selects an on-device engine nor
/// manages offline language packs.
class AndroidSpeechRecognitionService
    implements SpeechRecognitionService, PartialTranscriptSource {
  AndroidSpeechRecognitionService({
    MethodChannel? channel,
    EventChannel? eventChannel,
    Stream<Object?>? events,
    // Test seam: production always uses the platform event channel.
    // ignore: prefer_initializing_formals
  }) : _channel = channel ?? const MethodChannel(methodChannelName),
       _eventChannel = eventChannel ?? const EventChannel(eventChannelName),
       _injectedEvents = events;

  static const String methodChannelName = 'smartnavigator/android_stt';
  static const String eventChannelName = 'smartnavigator/android_stt_events';
  static const Duration stopTimeout = Duration(seconds: 12);

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final Stream<Object?>? _injectedEvents;

  List<String> biasStrings = const [];

  final StreamController<String> _partialController =
      StreamController<String>.broadcast();

  StreamSubscription<Object?>? _eventSubscription;
  Completer<SpeechRecognitionResult>? _pending;
  SpeechRecognitionResult? _finalResult;
  SpeechRecognitionException? _error;
  int _session = 0;
  bool _disposed = false;

  @override
  Stream<String> get partialTranscripts => _partialController.stream;

  void _ensureEvents() {
    if (_eventSubscription != null || _disposed) return;
    _eventSubscription =
        (_injectedEvents ?? _eventChannel.receiveBroadcastStream()).listen(
          _onEvent,
          onError: (Object _) {
            // A missing event channel is reported by method calls; the UI keeps
            // manual search available.
          },
        );
  }

  @override
  Future<SpeechRecognitionStatus> status() async {
    final availability = await inspectAvailability();
    if (!availability.supported) {
      return SpeechRecognitionStatus.unavailable(
        availability.error ??
            'Системное распознавание речи недоступно на этом устройстве.',
      );
    }
    return SpeechRecognitionStatus(
      supported: true,
      modelReady: true,
      permission: availability.permission,
      engine: 'android-system',
      model: 'ru-RU',
      maxDurationSeconds: 30,
    );
  }

  Future<AndroidSpeechAvailability> inspectAvailability() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('status');
      if (raw == null) {
        return const AndroidSpeechAvailability.unavailable(
          'Системное распознавание речи недоступно.',
        );
      }
      final supported = raw['supported'] == true;
      final permission = _permission(raw['permission']);
      if (!supported) {
        return AndroidSpeechAvailability(
          supported: false,
          permission: permission,
          error: 'Системное распознавание речи недоступно на этом устройстве.',
        );
      }
      return AndroidSpeechAvailability(supported: true, permission: permission);
    } on MissingPluginException {
      return const AndroidSpeechAvailability.unavailable(
        'Системное распознавание доступно только в Android-сборке.',
      );
    } on PlatformException catch (error) {
      return AndroidSpeechAvailability.unavailable(
        error.message ?? 'Не удалось проверить системное распознавание.',
      );
    }
  }

  @override
  Future<SpeechPermission> requestPermission() async {
    try {
      final outcome = await _channel.invokeMethod<String>('requestPermission');
      return _permission(outcome);
    } on PlatformException {
      return SpeechPermission.denied;
    } on MissingPluginException {
      return SpeechPermission.denied;
    }
  }

  @override
  Future<void> startRecording() async {
    if (_disposed) {
      throw const SpeechRecognitionException(
        SpeechFailureCode.busy,
        'Распознавание недоступно.',
      );
    }
    _ensureEvents();
    // No event may be accepted until the native start returns its session id.
    _session = -1;
    _finalResult = null;
    _error = null;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('start', {
        // The native bridge reads this as the ordinary system recognizer.
        // There is no separate on-device path in the application anymore.
        'engine': 'online',
        'bias': biasStrings.take(24).toList(growable: false),
      });
      final session = raw?['session'];
      _session = session is int && session > 0 ? session : 0;
    } on PlatformException catch (error) {
      throw _exception(error);
    } on MissingPluginException {
      throw const SpeechRecognitionException(
        SpeechFailureCode.modelUnavailable,
        'Системное распознавание доступно только в Android-сборке.',
      );
    }
  }

  @override
  Future<SpeechRecognitionResult> stopAndRecognize() async {
    if (_disposed || _session <= 0) {
      throw const SpeechRecognitionException(
        SpeechFailureCode.cancelled,
        'Распознавание отменено.',
      );
    }
    final delivery = _pending ??= Completer<SpeechRecognitionResult>();
    final ready = _finalResult;
    if (ready != null) {
      _pending = null;
      return ready;
    }
    final failure = _error;
    if (failure != null) {
      _pending = null;
      throw failure;
    }
    try {
      await _channel.invokeMethod<Object?>('stop');
    } on PlatformException catch (error) {
      _pending = null;
      throw _exception(error);
    } on MissingPluginException {
      _pending = null;
      throw const SpeechRecognitionException(
        SpeechFailureCode.modelUnavailable,
        'Системное распознавание доступно только в Android-сборке.',
      );
    }
    try {
      return await delivery.future.timeout(stopTimeout);
    } on TimeoutException {
      _pending = null;
      await cancel();
      throw const SpeechRecognitionException(
        SpeechFailureCode.timeout,
        'Системное распознавание не ответило вовремя. Попробуйте ещё раз.',
      );
    } finally {
      if (identical(_pending, delivery)) _pending = null;
    }
  }

  void _onEvent(Object? raw) {
    if (_disposed || raw is! Map || _session <= 0) return;
    final session = raw['session'];
    if (session is int && session != _session) return;
    final type = raw['type'];
    if (type == 'partial') {
      final text = raw['text'];
      if (text is String && text.trim().isNotEmpty) {
        _partialController.add(text.trim());
      }
      return;
    }
    if (type == 'final') {
      final text = raw['text'];
      if (text is! String || text.trim().isEmpty) {
        _deliverError(
          const SpeechRecognitionException(
            SpeechFailureCode.emptySpeech,
            'Не удалось расслышать речь.',
          ),
        );
        return;
      }
      final timings = _timings(raw['timings']);
      final result = SpeechRecognitionResult(
        text: text.trim(),
        audioDurationMs: timings['speechMs'] ?? timings['finalMs'] ?? 0,
        latencyMs: timings['finalMs'] ?? 0,
        engine: raw['engine'] as String? ?? 'android-system',
        model: 'ru-RU',
        timings: timings,
      );
      _finalResult = result;
      final pending = _pending;
      _pending = null;
      if (pending != null && !pending.isCompleted) pending.complete(result);
      return;
    }
    if (type == 'error') {
      _deliverError(
        SpeechRecognitionException(
          _failureCode(raw['code']),
          raw['message'] as String? ?? 'Не удалось распознать речь.',
        ),
      );
    }
  }

  void _deliverError(SpeechRecognitionException error) {
    _error = error;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  @override
  Future<void> cancel() async {
    if (_disposed) return;
    _session = 0;
    _finalResult = null;
    _error = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        const SpeechRecognitionException(
          SpeechFailureCode.cancelled,
          'Голосовой ввод отменён.',
        ),
      );
    }
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException {
      // Cancellation is best effort; late events are ignored by session.
    } on MissingPluginException {
      // Nothing to cancel without the platform bridge.
    }
  }

  @override
  Future<void> openPermissionSettings() async {
    try {
      await _channel.invokeMethod<void>('openPermissionSettings');
    } on PlatformException {
      // Manual search remains available.
    } on MissingPluginException {
      // Manual search remains available.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _partialController.close();
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (_) {
      // The engine may already be detached.
    }
  }

  static SpeechPermission _permission(Object? value) => switch (value) {
    'granted' => SpeechPermission.granted,
    'permanentlyDenied' => SpeechPermission.permanentlyDenied,
    _ => SpeechPermission.denied,
  };

  static SpeechFailureCode _failureCode(Object? value) => switch (value) {
    'permissionDenied' => SpeechFailureCode.permissionDenied,
    'permissionPermanentlyDenied' =>
      SpeechFailureCode.permissionPermanentlyDenied,
    'modelUnavailable' => SpeechFailureCode.modelUnavailable,
    'emptySpeech' => SpeechFailureCode.emptySpeech,
    'timeout' => SpeechFailureCode.timeout,
    'cancelled' => SpeechFailureCode.cancelled,
    'busy' => SpeechFailureCode.busy,
    'microphoneUnavailable' => SpeechFailureCode.microphoneUnavailable,
    'network' => SpeechFailureCode.network,
    'languageUnavailable' => SpeechFailureCode.languageUnavailable,
    _ => SpeechFailureCode.recognitionFailed,
  };

  static SpeechRecognitionException _exception(PlatformException error) =>
      SpeechRecognitionException(
        _failureCode(error.code),
        error.message ?? 'Не удалось распознать речь.',
      );

  static Map<String, int> _timings(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, int>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is String && value is int && value >= 0) {
        result[key] = value;
      }
    }
    return Map.unmodifiable(result);
  }
}
