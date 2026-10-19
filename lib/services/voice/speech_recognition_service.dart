/// Outcome of the Android RECORD_AUDIO permission request.
enum SpeechPermission { granted, denied, permanentlyDenied }

/// Everything the UI needs before opening the microphone.
///
/// [modelMissing] means the Android speech service cannot currently provide
/// Russian recognition. The system service and its language data are managed
/// by Android; the app never bundles a model.
class SpeechRecognitionStatus {
  const SpeechRecognitionStatus({
    required this.supported,
    required this.modelReady,
    required this.permission,
    this.modelMissing = false,
    this.engine = 'android-system',
    this.model = 'ru-RU',
    this.maxDurationSeconds = 30,
    this.error,
  });

  const SpeechRecognitionStatus.unavailable(this.error)
    : supported = false,
      modelReady = false,
      permission = SpeechPermission.denied,
      modelMissing = true,
      engine = 'android',
      model = 'ru-RU',
      maxDurationSeconds = 30;

  final bool supported;
  final bool modelReady;
  final bool modelMissing;
  final SpeechPermission permission;
  final String engine;
  final String model;
  final int maxDurationSeconds;
  final String? error;
}

enum SpeechFailureCode {
  permissionDenied,
  permissionPermanentlyDenied,
  consentRequired,
  modelUnavailable,
  emptySpeech,
  timeout,
  cancelled,
  busy,
  microphoneUnavailable,
  recognitionFailed,
  network,
  languageUnavailable,
}

class SpeechRecognitionException implements Exception {
  const SpeechRecognitionException(this.code, this.message);

  final SpeechFailureCode code;
  final String message;

  @override
  String toString() => message;
}

class SpeechRecognitionResult {
  const SpeechRecognitionResult({
    required this.text,
    required this.audioDurationMs,
    required this.latencyMs,
    required this.engine,
    required this.model,
    this.timings = const {},
  });

  final String text;
  final int audioDurationMs;
  final int latencyMs;
  final String engine;
  final String model;

  /// Aggregate native timings only (ready, first partial, end of speech,
  /// final, total). Never contains audio or text.
  final Map<String, int> timings;
}

/// Platform boundary for Android SpeechRecognizer. The platform service owns
/// the microphone; implementations never receive, buffer or persist audio.
abstract interface class SpeechRecognitionService {
  Future<SpeechRecognitionStatus> status();
  Future<SpeechPermission> requestPermission();
  Future<void> startRecording();
  Future<SpeechRecognitionResult> stopAndRecognize();
  Future<void> cancel();
  Future<void> openPermissionSettings();
  Future<void> dispose();
}

/// Service whose engine emits live interim words. The voice controller shows
/// them but never sends them to search; only the final normalized transcript
/// is applied.
abstract interface class PartialTranscriptSource {
  Stream<String> get partialTranscripts;
}
