import 'dart:async';

import 'package:smart_navigator_spb/services/voice/android_speech_recognition_service.dart';
import 'package:smart_navigator_spb/services/voice/speech_recognition_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_engine_settings.dart';

/// Consent and availability of the single Android system recognizer.
///
/// The former on-device/online engine choice is gone: the app always asks
/// Android for system recognition, and the only user decision is whether that
/// service may process speech, including a possible network transfer.
class VoiceEngineSnapshot {
  const VoiceEngineSnapshot({
    required this.settings,
    required this.supported,
    required this.permission,
    this.reason,
  });

  final VoiceEngineSettings settings;
  final bool supported;
  final SpeechPermission permission;
  final String? reason;

  bool get onlineConsent => settings.onlineConsent;
  bool get needsConsent => !settings.onlineConsent;
  String get engineLabel => 'Системное распознавание Android';
}

/// Consent and availability surface used by the voice controller and the
/// settings screen.
abstract interface class VoiceEnginePreferencesAccess {
  VoiceEngineSnapshot? get engineSnapshot;
  Future<VoiceEngineSnapshot> refreshEngines();
  Future<void> setOnlineConsent(bool granted);
  Future<void> openPermissionSettings();
}

/// Wraps the one system recognizer with the local consent requirement.
///
/// Recognition never starts without stored consent, and the microphone
/// permission is still requested separately by Android on first use.
class VoiceSearchEngineService
    implements
        SpeechRecognitionService,
        PartialTranscriptSource,
        VoiceEnginePreferencesAccess {
  VoiceSearchEngineService({
    required AndroidSpeechRecognitionService android,
    required VoiceEngineSettingsStore store,
    // Public dependency names are part of the injection contract.
    // ignore: prefer_initializing_formals
  }) : _android = android,
       // ignore: prefer_initializing_formals
       _store = store;

  final AndroidSpeechRecognitionService _android;
  final VoiceEngineSettingsStore _store;

  VoiceEngineSnapshot? _snapshot;

  @override
  VoiceEngineSnapshot? get engineSnapshot => _snapshot;

  @override
  Stream<String> get partialTranscripts => _android.partialTranscripts;

  void setBiasStrings(Iterable<String> values) {
    _android.biasStrings = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .take(24)
        .toList(growable: false);
  }

  @override
  Future<VoiceEngineSnapshot> refreshEngines() async {
    final settings = await _store.load();
    final availability = await _android.inspectAvailability();
    final reason = availability.supported
        ? null
        : availability.error ??
              'Системное распознавание речи недоступно на этом устройстве.';
    _snapshot = VoiceEngineSnapshot(
      settings: settings,
      supported: availability.supported,
      permission: availability.permission,
      reason: reason,
    );
    return _snapshot!;
  }

  @override
  Future<SpeechRecognitionStatus> status() async {
    final snapshot = await refreshEngines();
    if (snapshot.needsConsent) {
      return const SpeechRecognitionStatus.unavailable(
        'Для голосового поиска нужно согласие на системное распознавание.',
      );
    }
    if (!snapshot.supported) {
      return SpeechRecognitionStatus.unavailable(
        snapshot.reason ??
            'Голосовое распознавание недоступно. '
                'Можно найти место вручную.',
      );
    }
    return _android.status();
  }

  @override
  Future<SpeechPermission> requestPermission() => _android.requestPermission();

  @override
  Future<void> startRecording() async {
    final snapshot = _snapshot ?? await refreshEngines();
    if (snapshot.needsConsent) {
      throw const SpeechRecognitionException(
        SpeechFailureCode.consentRequired,
        'Для голосового поиска нужно согласие на системное распознавание.',
      );
    }
    if (!snapshot.supported) {
      throw SpeechRecognitionException(
        SpeechFailureCode.modelUnavailable,
        snapshot.reason ?? 'Голосовое распознавание недоступно.',
      );
    }
    // A launch-time language or network failure is surfaced to the user.
    // There is no silent engine switch, and no audio leaves the Android
    // speech service through this application.
    await _android.startRecording();
  }

  @override
  Future<SpeechRecognitionResult> stopAndRecognize() =>
      _android.stopAndRecognize();

  @override
  Future<void> cancel() async {
    await _android.cancel();
  }

  @override
  Future<void> openPermissionSettings() => _android.openPermissionSettings();

  @override
  Future<void> setOnlineConsent(bool granted) async {
    final current = _snapshot?.settings ?? await _store.load();
    await _store.save(current.copyWith(onlineConsent: granted));
    await refreshEngines();
  }

  @override
  Future<void> dispose() async {
    await _android.dispose();
  }
}

/// Convenience used by bootstrap code: the Android SpeechRecognizer engine.
VoiceSearchEngineService createProductionVoiceEngineService() {
  return VoiceSearchEngineService(
    android: AndroidSpeechRecognitionService(),
    store: SharedPreferencesVoiceEngineSettingsStore(),
  );
}
