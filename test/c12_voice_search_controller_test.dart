import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/services/voice/speech_recognition_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_query_normalizer.dart';
import 'package:smart_navigator_spb/services/voice/voice_search_controller.dart';

class _FakeSpeech implements SpeechRecognitionService {
  SpeechRecognitionStatus statusResult = const SpeechRecognitionStatus(
    supported: true,
    modelReady: true,
    permission: SpeechPermission.granted,
  );
  SpeechPermission permissionResult = SpeechPermission.granted;
  SpeechRecognitionResult result = const SpeechRecognitionResult(
    text: 'Исаакиевский собор',
    audioDurationMs: 1800,
    latencyMs: 900,
    engine: 'android-on-device',
    model: 'ru-RU',
  );
  Object? startError;
  Object? stopError;
  Completer<SpeechRecognitionResult>? stopCompleter;

  int statusCalls = 0;
  int permissionCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  bool settingsOpened = false;

  @override
  Future<SpeechRecognitionStatus> status() async {
    statusCalls++;
    return statusResult;
  }

  @override
  Future<SpeechPermission> requestPermission() async {
    permissionCalls++;
    return permissionResult;
  }

  @override
  Future<void> startRecording() async {
    startCalls++;
    if (startError != null) throw startError!;
  }

  @override
  Future<SpeechRecognitionResult> stopAndRecognize() {
    stopCalls++;
    if (stopError != null) return Future.error(stopError!);
    return stopCompleter?.future ?? Future.value(result);
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> openPermissionSettings() async {
    settingsOpened = true;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late _FakeSpeech speech;
  late VoiceSearchController controller;

  setUp(() {
    speech = _FakeSpeech();
    controller = VoiceSearchController(service: speech);
  });

  tearDown(() {
    controller.dispose();
  });

  test('start requests permission only when it is not granted', () async {
    speech.statusResult = const SpeechRecognitionStatus(
      supported: true,
      modelReady: true,
      permission: SpeechPermission.denied,
    );
    speech.permissionResult = SpeechPermission.granted;
    final states = <VoiceSearchState>[];
    controller.addListener(() => states.add(controller.state));

    await controller.start();

    expect(speech.permissionCalls, 1);
    expect(speech.startCalls, 1);
    expect(controller.state, VoiceSearchState.recording);
    expect(states, [
      VoiceSearchState.requestingPermission,
      VoiceSearchState.recording,
    ]);
  });

  test('an already granted permission skips the permission dialog', () async {
    speech.permissionResult = SpeechPermission.denied;

    await controller.start();

    expect(speech.permissionCalls, 0);
    expect(controller.state, VoiceSearchState.recording);
  });

  test('permission denial keeps manual search available', () async {
    speech.statusResult = const SpeechRecognitionStatus(
      supported: true,
      modelReady: true,
      permission: SpeechPermission.denied,
    );
    speech.permissionResult = SpeechPermission.denied;

    await controller.start();

    expect(controller.state, VoiceSearchState.permissionDenied);
    expect(controller.errorMessage, contains('вручную'));
    expect(speech.startCalls, 0);
  });

  test('permanent denial offers application settings', () async {
    speech.statusResult = const SpeechRecognitionStatus(
      supported: true,
      modelReady: true,
      permission: SpeechPermission.denied,
    );
    speech.permissionResult = SpeechPermission.permanentlyDenied;

    await controller.start();

    expect(controller.state, VoiceSearchState.permissionPermanentlyDenied);
    await controller.openPermissionSettings();
    expect(speech.settingsOpened, isTrue);
  });

  test(
    'a missing Russian package is reported without asking for the microphone',
    () async {
      speech.statusResult = const SpeechRecognitionStatus(
        supported: true,
        modelReady: false,
        modelMissing: true,
        permission: SpeechPermission.granted,
        error: 'Русский языковой пакет не установлен.',
      );

      await controller.start();

      expect(controller.state, VoiceSearchState.modelUnavailable);
      expect(controller.errorMessage, contains('пакет'));
      expect(speech.startCalls, 0);
    },
  );

  test('stop recognizes, normalizes and exposes the transcript', () async {
    speech.result = const SpeechRecognitionResult(
      text: 'Найди Исаакиевский собор',
      audioDurationMs: 1800,
      latencyMs: 900,
      engine: 'android-on-device',
      model: 'ru-RU',
    );
    await controller.start();

    await controller.stop();

    expect(speech.stopCalls, 1);
    expect(controller.state, VoiceSearchState.transcriptReady);
    expect(controller.transcript, 'Исаакиевский собор');
    expect(controller.lastResult?.latencyMs, 900);
  });

  test('empty audio becomes emptySpeech and never reaches search', () async {
    speech.result = const SpeechRecognitionResult(
      text: '   ',
      audioDurationMs: 400,
      latencyMs: 200,
      engine: 'android-on-device',
      model: 'ru-RU',
    );
    await controller.start();

    await controller.stop();

    expect(controller.state, VoiceSearchState.emptySpeech);
    expect(controller.transcript, isEmpty);
    expect(controller.confirm(), isNull);
  });

  test('a recognition failure is recoverable', () async {
    speech.stopError = const SpeechRecognitionException(
      SpeechFailureCode.recognitionFailed,
      'Не удалось распознать речь.',
    );
    await controller.start();

    await controller.stop();

    expect(controller.state, VoiceSearchState.recognitionFailed);
    expect(controller.canRetry, isTrue);
  });

  test('cancel during recording discards the audio', () async {
    await controller.start();

    await controller.cancel();

    expect(controller.state, VoiceSearchState.cancelled);
    expect(speech.cancelCalls, 1);
    expect(controller.transcript, isEmpty);
  });

  test('a late result after cancel never changes the transcript', () async {
    final pending = Completer<SpeechRecognitionResult>();
    speech.stopCompleter = pending;
    await controller.start();
    final stopping = controller.stop();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, VoiceSearchState.recognizing);

    await controller.cancel();
    pending.complete(
      const SpeechRecognitionResult(
        text: 'Казанский собор',
        audioDurationMs: 1200,
        latencyMs: 700,
        engine: 'android-on-device',
        model: 'ru-RU',
      ),
    );
    await stopping;
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, VoiceSearchState.cancelled);
    expect(controller.transcript, isEmpty);
    expect(controller.lastResult, isNull);
  });

  test('a new recording starts after cancelling a long recognition', () async {
    final first = Completer<SpeechRecognitionResult>();
    speech.stopCompleter = first;
    await controller.start();
    final firstStop = controller.stop();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, VoiceSearchState.recognizing);

    await controller.cancel();
    expect(controller.state, VoiceSearchState.cancelled);

    // The same controller must record again without recreating the app or the
    // native engine; the older inference is still running at this point.
    final second = Completer<SpeechRecognitionResult>();
    speech.stopCompleter = second;
    await controller.start();
    expect(controller.state, VoiceSearchState.recording);
    expect(speech.startCalls, 2);

    final secondStop = controller.stop();
    await Future<void>.delayed(Duration.zero);
    second.complete(
      const SpeechRecognitionResult(
        text: 'Казанский собор',
        audioDurationMs: 1300,
        latencyMs: 800,
        engine: 'android-on-device',
        model: 'ru-RU',
        timings: {'inference': 640, 'total': 800},
      ),
    );
    await secondStop;

    expect(controller.state, VoiceSearchState.transcriptReady);
    expect(controller.transcript, 'Казанский собор');
    expect(controller.lastResult?.timings['inference'], 640);

    // The abandoned first inference finishing late must stay invisible.
    first.complete(
      const SpeechRecognitionResult(
        text: 'Исаакиевский собор',
        audioDurationMs: 2200,
        latencyMs: 1500,
        engine: 'android-on-device',
        model: 'ru-RU',
      ),
    );
    await firstStop;
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, VoiceSearchState.transcriptReady);
    expect(controller.transcript, 'Казанский собор');
    expect(controller.lastResult?.latencyMs, 800);
  });

  test('two starts in the same frame record only once', () async {
    await Future.wait([controller.start(), controller.start()]);

    expect(speech.startCalls, 1);
    expect(controller.state, VoiceSearchState.recording);
  });

  test(
    'the recording limit stops the microphone and reports timeout',
    () async {
      controller.dispose();
      controller = VoiceSearchController(
        service: speech,
        maxRecordingDuration: const Duration(milliseconds: 40),
      );
      // The disposed controller above cancels once; count only this session.
      speech.cancelCalls = 0;
      await controller.start();

      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(controller.state, VoiceSearchState.timeout);
      expect(speech.cancelCalls, 1);
      expect(controller.errorMessage, contains('лимиту'));
    },
  );

  test('Russian landmark names pass through unchanged', () async {
    for (final name in [
      'Исаакиевский собор',
      'Дворцовая площадь',
      'Петропавловская крепость',
      'Летний сад',
    ]) {
      speech.result = SpeechRecognitionResult(
        text: name,
        audioDurationMs: 1000,
        latencyMs: 500,
        engine: 'android-on-device',
        model: 'ru-RU',
      );
      await controller.start();
      await controller.stop();
      expect(controller.transcript, name);
      controller.reset();
    }
  });

  test('the recognized text can be corrected before confirmation', () async {
    await controller.start();
    await controller.stop();

    controller.updateTranscript('Казанский собор');
    final query = controller.confirm();

    expect(query, 'Казанский собор');
    expect(controller.state, VoiceSearchState.idle);
  });

  test('too short and too long corrections are rejected', () async {
    await controller.start();
    await controller.stop();

    controller.updateTranscript('я');
    expect(controller.confirm(), isNull);
    expect(controller.state, VoiceSearchState.transcriptReady);
    expect(controller.errorMessage, contains('короткий'));

    controller.updateTranscript(
      'x' * (VoiceSearchController.maxQueryLength + 1),
    );
    expect(controller.confirm(), isNull);
    expect(controller.errorMessage, contains('150'));
  });

  test('confirm is unavailable before a transcript exists', () {
    expect(controller.confirm(), isNull);
    expect(controller.canConfirm, isFalse);
  });

  _normalizerTests();
}

void _normalizerTests() {
  group('VoiceQueryNormalizer', () {
    test('strips an explicit search lead-in', () {
      expect(
        VoiceQueryNormalizer.normalize('Найди Исаакиевский собор'),
        'Исаакиевский собор',
      );
    });

    test('handles polite and nested lead-ins without inventing text', () {
      expect(
        VoiceQueryNormalizer.normalize(
          'Пожалуйста, подскажи, где находится Летний сад',
        ),
        'Летний сад',
      );
    });

    test('collapses whitespace and keeps bare landmark names', () {
      expect(
        VoiceQueryNormalizer.normalize('  Дворцовая   площадь '),
        'Дворцовая площадь',
      );
    });

    test('does not strip ordinary words that merely start like a command', () {
      expect(
        VoiceQueryNormalizer.normalize('Найдёнов переулок'),
        'Найдёнов переулок',
      );
    });
  });
}
