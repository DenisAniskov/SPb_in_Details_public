import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_navigator_spb/services/voice/android_speech_recognition_service.dart';
import 'package:smart_navigator_spb/services/voice/speech_recognition_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_engine_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_engine_settings.dart';
import 'package:smart_navigator_spb/services/voice/voice_search_controller.dart';

class _MemoryStore implements VoiceEngineSettingsStore {
  _MemoryStore() : settings = VoiceEngineSettings.defaults;
  VoiceEngineSettings settings;
  int saves = 0;

  @override
  Future<VoiceEngineSettings> load() async => settings;

  @override
  Future<void> save(VoiceEngineSettings value) async {
    settings = value;
    saves++;
  }
}

AndroidSpeechAvailability _availability({
  bool supported = true,
  SpeechPermission permission = SpeechPermission.granted,
}) => AndroidSpeechAvailability(supported: supported, permission: permission);

class _FakeAndroid extends AndroidSpeechRecognitionService {
  _FakeAndroid(this.availability)
    : super(events: const Stream<Object?>.empty());

  AndroidSpeechAvailability availability;
  final StreamController<String> partials =
      StreamController<String>.broadcast();
  SpeechRecognitionException? startError;
  SpeechRecognitionException? stopError;
  SpeechRecognitionResult result = const SpeechRecognitionResult(
    text: 'Исаакиевский собор',
    audioDurationMs: 1600,
    latencyMs: 900,
    engine: 'android-system',
    model: 'ru-RU',
    timings: {'firstPartialMs': 300, 'finalMs': 900},
  );
  int startCalls = 0, stopCalls = 0, cancelCalls = 0;
  int permissionCalls = 0;

  @override
  Future<AndroidSpeechAvailability> inspectAvailability() async => availability;

  @override
  Future<SpeechRecognitionStatus> status() async {
    if (!availability.supported) {
      return const SpeechRecognitionStatus.unavailable(
        'Системное распознавание речи недоступно.',
      );
    }
    return SpeechRecognitionStatus(
      supported: true,
      modelReady: true,
      permission: availability.permission,
      engine: 'android-system',
      model: 'ru-RU',
    );
  }

  @override
  Future<SpeechPermission> requestPermission() async {
    permissionCalls++;
    return availability.permission;
  }

  @override
  Future<void> startRecording() async {
    startCalls++;
    if (startError != null) throw startError!;
  }

  @override
  Future<SpeechRecognitionResult> stopAndRecognize() async {
    stopCalls++;
    if (stopError != null) throw stopError!;
    return result;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Stream<String> get partialTranscripts => partials.stream;

  @override
  Future<void> dispose() async {
    await partials.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidSpeechRecognitionService platform contract', () {
    const channel = MethodChannel(
      AndroidSpeechRecognitionService.methodChannelName,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late StreamController<Object?> events;
    late int stopCalls;
    late int cancelCalls;
    late int nextSession;
    String? requestedEngine;

    setUp(() {
      events = StreamController<Object?>.broadcast();
      stopCalls = 0;
      cancelCalls = 0;
      nextSession = 6;
      requestedEngine = null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'start':
            requestedEngine = (call.arguments as Map)['engine'] as String?;
            nextSession++;
            return {'session': nextSession, 'engine': 'android-system'};
          case 'stop':
            stopCalls++;
            return true;
          case 'cancel':
            cancelCalls++;
            return null;
          case 'status':
            return {'supported': true, 'permission': 'granted'};
        }
        return null;
      });
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await events.close();
    });

    Future<AndroidSpeechRecognitionService> startService() async {
      final service = AndroidSpeechRecognitionService(
        channel: channel,
        events: events.stream,
      );
      addTearDown(service.dispose);
      await service.startRecording();
      return service;
    }

    test('only the ordinary system recognizer is requested', () async {
      await startService();
      expect(requestedEngine, 'online');
    });

    test('partial and final results are delivered once with timings', () async {
      final service = await startService();
      final partials = <String>[];
      final sub = service.partialTranscripts.listen(partials.add);
      addTearDown(sub.cancel);

      events.add({'session': 7, 'type': 'partial', 'text': 'Исаак'});
      await pumpEventQueue();
      expect(partials, ['Исаак']);

      events.add({
        'session': 7,
        'type': 'final',
        'text': 'Исаакиевский собор',
        'engine': 'android-system',
        'timings': {'firstPartialMs': 320, 'finalMs': 910, 'speechMs': 1500},
      });
      await pumpEventQueue();

      final result = await service.stopAndRecognize();
      expect(result.text, 'Исаакиевский собор');
      expect(result.engine, 'android-system');
      expect(result.timings['firstPartialMs'], 320);
      expect(result.audioDurationMs, 1500);
      // The recognizer had already delivered its final result; no extra stop.
      expect(stopCalls, 0);
    });

    test('late events from an older session are ignored', () async {
      final service = await startService();
      events.add({'session': 6, 'type': 'partial', 'text': 'Старый запрос'});
      await pumpEventQueue();
      var partial = '';
      final sub = service.partialTranscripts.listen((value) => partial = value);
      addTearDown(sub.cancel);
      events.add({'session': 7, 'type': 'partial', 'text': 'Новый'});
      await pumpEventQueue();
      expect(partial, 'Новый');
    });

    test('cancel discards pending text and prevents a late final', () async {
      final service = await startService();
      await service.cancel();
      expect(cancelCalls, 1);
      expect(
        () => service.stopAndRecognize(),
        throwsA(
          isA<SpeechRecognitionException>().having(
            (e) => e.code,
            'code',
            SpeechFailureCode.cancelled,
          ),
        ),
      );
      events.add({
        'session': 7,
        'type': 'final',
        'text': 'Поздний текст',
        'timings': {'finalMs': 10},
      });
      await pumpEventQueue();
      // A new session must not inherit the abandoned text.
      await service.startRecording();
      events.add({
        'session': 7,
        'type': 'final',
        'text': 'Поздний текст',
        'timings': {'finalMs': 10},
      });
      await pumpEventQueue();
      events.add({
        'session': 8,
        'type': 'final',
        'text': 'Новый запрос',
        'timings': {'finalMs': 20},
      });
      await pumpEventQueue();
      final result = await service.stopAndRecognize();
      expect(result.text, 'Новый запрос');
    });

    test('five consecutive sessions stay isolated', () async {
      final service = await startService();
      for (var index = 0; index < 5; index++) {
        // The first session was opened by startService (id 7).
        if (index > 0) await service.startRecording();
        final session = 7 + index;
        events.add({
          'session': session,
          'type': 'final',
          'text': 'Запрос $index',
          'timings': {'finalMs': 100 + index},
        });
        await pumpEventQueue();
        final result = await service.stopAndRecognize();
        expect(result.text, 'Запрос $index');
        if (index < 4) await service.cancel();
      }
    });

    test('native error codes stay typed and carry Russian messages', () async {
      final service = await startService();
      events.add({
        'session': 7,
        'type': 'error',
        'code': 'network',
        'message': 'Нет связи с системной службой распознавания.',
      });
      await pumpEventQueue();
      await expectLater(
        service.stopAndRecognize(),
        throwsA(
          isA<SpeechRecognitionException>()
              .having((e) => e.code, 'code', SpeechFailureCode.network)
              .having((e) => e.message, 'message', contains('связи')),
        ),
      );
    });

    test('permission outcome distinguishes permanent denial', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return call.method == 'requestPermission' ? 'permanentlyDenied' : null;
      });
      final service = AndroidSpeechRecognitionService(
        channel: channel,
        events: events.stream,
      );
      addTearDown(service.dispose);
      expect(
        await service.requestPermission(),
        SpeechPermission.permanentlyDenied,
      );
    });

    test(
      'availability reports the system service without language packs',
      () async {
        final service = AndroidSpeechRecognitionService(
          channel: channel,
          events: events.stream,
        );
        addTearDown(service.dispose);
        final availability = await service.inspectAvailability();
        expect(availability.supported, isTrue);
        expect(availability.permission, SpeechPermission.granted);

        final status = await service.status();
        expect(status.supported, isTrue);
        expect(status.modelReady, isTrue);
        expect(status.modelMissing, isFalse);
        expect(status.engine, 'android-system');
      },
    );

    test('an unavailable system service is reported honestly', () async {
      final service = AndroidSpeechRecognitionService(
        channel: const MethodChannel('smartnavigator/missing_stt'),
        events: events.stream,
      );
      addTearDown(service.dispose);
      final status = await service.status();
      expect(status.supported, isFalse);
      expect(status.error, contains('Android'));
    });
  });

  group('VoiceSearchEngineService consent and single engine', () {
    late _FakeAndroid android;
    late _MemoryStore store;
    late VoiceSearchEngineService service;

    setUp(() {
      android = _FakeAndroid(_availability());
      store = _MemoryStore();
      service = VoiceSearchEngineService(android: android, store: store);
    });

    tearDown(() async {
      await service.dispose();
    });

    test('the default is one system recognizer without consent', () async {
      final snapshot = await service.refreshEngines();
      expect(snapshot.supported, isTrue);
      expect(snapshot.onlineConsent, isFalse);
      expect(snapshot.needsConsent, isTrue);
      expect(snapshot.engineLabel, 'Системное распознавание Android');
    });

    test('recognition cannot start before consent', () async {
      await expectLater(
        service.startRecording(),
        throwsA(
          isA<SpeechRecognitionException>().having(
            (e) => e.code,
            'code',
            SpeechFailureCode.consentRequired,
          ),
        ),
      );
      expect(android.startCalls, 0);
    });

    test('granting consent unlocks the same system service', () async {
      await service.setOnlineConsent(true);
      expect(store.settings.onlineConsent, isTrue);
      expect(service.engineSnapshot!.needsConsent, isFalse);

      final status = await service.status();
      expect(status.supported, isTrue);
      expect(status.engine, 'android-system');

      await service.startRecording();
      expect(android.startCalls, 1);
    });

    test('revoking consent is persisted and blocks new sessions', () async {
      await service.setOnlineConsent(true);
      await service.setOnlineConsent(false);
      expect(store.settings.onlineConsent, isFalse);
      expect(service.engineSnapshot!.needsConsent, isTrue);
      await expectLater(
        service.startRecording(),
        throwsA(
          isA<SpeechRecognitionException>().having(
            (e) => e.code,
            'code',
            SpeechFailureCode.consentRequired,
          ),
        ),
      );
      expect(android.startCalls, 0);
    });

    test('an unavailable recognizer is reported before recording', () async {
      android.availability = _availability(supported: false);
      await service.setOnlineConsent(true);
      expect(service.engineSnapshot!.supported, isFalse);
      await expectLater(
        service.startRecording(),
        throwsA(
          isA<SpeechRecognitionException>().having(
            (e) => e.code,
            'code',
            SpeechFailureCode.modelUnavailable,
          ),
        ),
      );
      expect(android.startCalls, 0);
    });

    test('partial words still come from the Android service', () async {
      await service.status();
      final partials = <String>[];
      final sub = service.partialTranscripts.listen(partials.add);
      addTearDown(sub.cancel);
      android.partials.add('Исаак');
      await pumpEventQueue();
      expect(partials, ['Исаак']);
    });
  });

  group('VoiceSearchController consent integration', () {
    late _FakeAndroid android;
    late _MemoryStore store;
    late VoiceSearchEngineService engine;
    late VoiceSearchController controller;

    setUp(() {
      android = _FakeAndroid(_availability());
      store = _MemoryStore();
      engine = VoiceSearchEngineService(android: android, store: store);
      controller = VoiceSearchController(service: engine);
    });

    tearDown(() {
      controller.dispose();
      engine.dispose();
    });

    test(
      'the first attempt shows consent and does not touch the microphone',
      () async {
        await controller.initializeEngineSettings();
        await controller.start();
        expect(controller.state, VoiceSearchState.consentRequired);
        expect(controller.errorMessage, contains('согласие'));
        expect(android.startCalls, 0);
        expect(android.permissionCalls, 0);

        expect(await controller.setOnlineConsent(true), isTrue);
        await controller.start();
        expect(controller.state, VoiceSearchState.recording);
        expect(android.startCalls, 1);
      },
    );

    test('a denied microphone still leaves text search available', () async {
      android.availability = _availability(permission: SpeechPermission.denied);
      store.settings = const VoiceEngineSettings(onlineConsent: true);
      await controller.start();
      expect(controller.state, VoiceSearchState.permissionDenied);
      expect(controller.errorMessage, contains('вручную'));
      expect(android.startCalls, 0);
    });

    test(
      'revoking consent stops an active session and blocks the next',
      () async {
        store.settings = const VoiceEngineSettings(onlineConsent: true);
        await controller.start();
        expect(controller.state, VoiceSearchState.recording);
        expect(android.startCalls, 1);

        expect(await controller.setOnlineConsent(false), isTrue);
        expect(android.cancelCalls, greaterThan(0));
        expect(store.settings.onlineConsent, isFalse);
        expect(controller.state, VoiceSearchState.cancelled);

        await controller.start();
        expect(controller.state, VoiceSearchState.consentRequired);
        expect(android.startCalls, 1);
      },
    );

    test(
      'an unavailable recognizer reports no model and no microphone',
      () async {
        android.availability = _availability(supported: false);
        store.settings = const VoiceEngineSettings(onlineConsent: true);
        await controller.start();
        expect(controller.state, VoiceSearchState.modelUnavailable);
        expect(android.startCalls, 0);
        expect(android.permissionCalls, 0);
      },
    );

    test(
      'partial words are shown while only the final text is applied',
      () async {
        store.settings = const VoiceEngineSettings(onlineConsent: true);
        await controller.initializeEngineSettings();
        await controller.start();
        expect(controller.state, VoiceSearchState.recording);
        expect(controller.engineLabel, 'Системное распознавание Android');

        android.partials.add('Исаак');
        await pumpEventQueue();
        expect(controller.partialTranscript, 'Исаак');
        expect(controller.transcript, isEmpty);

        await controller.stop();
        expect(controller.state, VoiceSearchState.transcriptReady);
        expect(controller.transcript, 'Исаакиевский собор');
        expect(controller.partialTranscript, isEmpty);
        expect(controller.lastResult?.timings['firstPartialMs'], 300);
      },
    );
  });

  group('VoiceEngineSettings consent migration and storage', () {
    test('defaults contain no consent and the canonical version', () {
      expect(VoiceEngineSettings.defaults.onlineConsent, isFalse);
      expect(VoiceEngineSettings.defaults.toJson()['version'], 3);
      expect(
        VoiceEngineSettings.defaults.toJson().containsKey('choice'),
        isFalse,
      );
    });

    test('an offline selection is never treated as network consent', () {
      for (final version in [1, 2]) {
        final parsed = VoiceEngineSettings.fromJson({
          'version': version,
          'choice': 'android_on_device',
          'onlineConsent': false,
        });
        expect(parsed.onlineConsent, isFalse, reason: 'version $version');
      }
    });

    test('former system consent survives the migration', () {
      final parsed = VoiceEngineSettings.fromJson({
        'version': 2,
        'choice': 'android_system_online',
        'onlineConsent': true,
      });
      expect(parsed.onlineConsent, isTrue);
    });

    test('system selection without consent stays unconsented', () {
      final parsed = VoiceEngineSettings.fromJson({
        'version': 2,
        'choice': 'android_system_online',
        'onlineConsent': false,
      });
      expect(parsed.onlineConsent, isFalse);
    });

    test('unknown and corrupt records return the safe default', () {
      expect(VoiceEngineSettings.fromJson('broken').onlineConsent, isFalse);
      expect(
        VoiceEngineSettings.fromJson({'version': 99, 'onlineConsent': true})
            .onlineConsent,
        isFalse,
      );
    });

    test('a legacy record is rewritten without touching other keys', () async {
      SharedPreferences.setMockInitialValues({
        SharedPreferencesVoiceEngineSettingsStore.storageKey: jsonEncode({
          'version': 2,
          'choice': 'android_system_online',
          'onlineConsent': true,
        }),
        'smartnavigator.guest': '{"keep":true}',
      });
      final store = SharedPreferencesVoiceEngineSettingsStore();
      final settings = await store.load();
      expect(settings.onlineConsent, isTrue);

      final preferences = await SharedPreferences.getInstance();
      final rewritten = jsonDecode(
        preferences.getString(
          SharedPreferencesVoiceEngineSettingsStore.storageKey,
        )!,
      ) as Map;
      expect(rewritten['version'], 3);
      expect(rewritten['onlineConsent'], true);
      expect(rewritten.containsKey('choice'), isFalse);
      expect(preferences.getString('smartnavigator.guest'), '{"keep":true}');
    });

    test('consent survives a reload and removal is persisted', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPreferencesVoiceEngineSettingsStore();
      await store.save(const VoiceEngineSettings(onlineConsent: true));
      expect((await store.load()).onlineConsent, isTrue);

      await store.save(const VoiceEngineSettings(onlineConsent: false));
      expect((await store.load()).onlineConsent, isFalse);
    });
  });
}
