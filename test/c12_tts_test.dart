import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/tts_provider.dart';
import 'package:smart_navigator_spb/services/voice/tts_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_settings.dart';

class _FakeTts implements TtsService {
  TtsAvailability availability = const TtsAvailability(
    available: true,
    voices: [
      TtsVoice(name: 'ru-alpha', locale: 'ru-RU'),
      TtsVoice(name: 'ru-beta', locale: 'ru-RU'),
    ],
  );
  final List<String> spoken = [];
  final List<double> rates = [];
  final List<String?> voiceNames = [];
  int stops = 0;
  int initializes = 0;

  @override
  Future<TtsAvailability> initialize() async {
    initializes++;
    return availability;
  }

  @override
  Future<void> speak(
    String text, {
    required double rate,
    String? voiceName,
    String? voiceLocale,
  }) async {
    spoken.add(text);
    rates.add(rate);
    voiceNames.add(voiceName);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {}
}

class _FakeStore implements VoiceSettingsStore {
  VoiceSettings settings = VoiceSettings.defaults;
  bool failLoad = false;
  bool failSave = false;
  int saves = 0;

  @override
  Future<VoiceSettings> load() async {
    if (failLoad) throw StateError('read failed');
    return settings;
  }

  @override
  Future<void> save(VoiceSettings settings) async {
    saves++;
    if (failSave) throw StateError('write failed');
    this.settings = settings;
  }
}

class _FakeFlutterTts extends FlutterTts {
  final List<String> spoken = [];
  bool? lastFocus;
  double? lastRate;
  String? lastLanguage;
  Map<String, String>? lastVoice;
  bool languageAvailable = true;

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;

  @override
  Future<dynamic> setQueueMode(int queueMode) async => 1;

  @override
  Future<dynamic> setPitch(double pitch) async => 1;

  @override
  Future<dynamic> setLanguage(String language) async {
    lastLanguage = language;
    return 1;
  }

  @override
  Future<dynamic> isLanguageAvailable(String language) async =>
      languageAvailable;

  @override
  Future<dynamic> get getVoices async => [
    {'name': 'ru-alpha', 'locale': 'ru-RU'},
    {'name': 'ru-beta', 'locale': 'ru-RU'},
    {'name': 'en-us', 'locale': 'en-US'},
  ];

  @override
  Future<dynamic> stop() async => 1;

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    lastVoice = voice;
    return 1;
  }

  @override
  Future<dynamic> setSpeechRate(double rate) async {
    lastRate = rate;
    return 1;
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spoken.add(text);
    lastFocus = focus;
    return 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceSettings', () {
    test('voice output is off by default', () {
      expect(VoiceSettings.defaults.enabled, isFalse);
      expect(VoiceSettings.defaults.rate, 0.5);
    });

    test('invalid stored values fall back to the safe default', () {
      expect(VoiceSettings.fromJson(null), VoiceSettings.defaults);
      expect(
        VoiceSettings.fromJson({'version': 1, 'enabled': 'yes', 'rate': 1}),
        VoiceSettings.defaults,
      );
    });

    test('rate is clamped to the supported range', () {
      final settings = VoiceSettings.fromJson({
        'version': 1,
        'enabled': true,
        'rate': 5.0,
        'voiceName': null,
        'voiceLocale': null,
      });
      expect(settings.rate, VoiceSettings.maxRate);
    });

    test(
      'the separate preferences key round-trips without guest data',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = SharedPreferencesVoiceSettingsStore();
        const settings = VoiceSettings(
          enabled: true,
          rate: 0.62,
          voiceName: 'ru-alpha',
          voiceLocale: 'ru-RU',
        );

        await store.save(settings);
        final loaded = await store.load();

        expect(loaded.enabled, isTrue);
        expect(loaded.rate, 0.62);
        expect(loaded.voiceName, 'ru-alpha');
        expect(loaded.voiceLocale, 'ru-RU');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('smartnavigator.guest'), isFalse);
        expect(
          prefs.containsKey(SharedPreferencesVoiceSettingsStore.storageKey),
          isTrue,
        );
      },
    );

    test('a corrupted voice value does not break reading', () async {
      SharedPreferences.setMockInitialValues({
        SharedPreferencesVoiceSettingsStore.storageKey: 'not-json',
      });
      final loaded = await SharedPreferencesVoiceSettingsStore().load();
      expect(loaded.enabled, isFalse);
    });
  });

  group('FlutterTtsService', () {
    test('initialization exposes only Russian system voices', () async {
      final engine = _FakeFlutterTts();
      final availability = await FlutterTtsService(engine: engine).initialize();

      expect(availability.available, isTrue);
      expect(availability.voices, hasLength(2));
      expect(
        availability.voices.every((voice) => voice.locale == 'ru-RU'),
        isTrue,
      );
    });

    test('speech requests audio focus and the configured rate', () async {
      final engine = _FakeFlutterTts();
      final service = FlutterTtsService(engine: engine);
      await service.initialize();

      await service.speak('Поверните налево', rate: 0.6);

      expect(engine.lastFocus, isTrue);
      expect(engine.lastRate, 0.6);
      expect(engine.lastLanguage, 'ru-RU');
      expect(engine.spoken.single, 'Поверните налево');
    });

    test('a selected system voice is applied', () async {
      final engine = _FakeFlutterTts();
      final service = FlutterTtsService(engine: engine);
      await service.initialize();

      await service.speak(
        'Поверните направо',
        rate: 0.5,
        voiceName: 'ru-beta',
        voiceLocale: 'ru-RU',
      );

      expect(engine.lastVoice, {'name': 'ru-beta', 'locale': 'ru-RU'});
    });

    test('an unavailable Russian engine fails safely', () async {
      final engine = _FakeFlutterTts()..languageAvailable = false;
      final service = FlutterTtsService(engine: engine);
      final availability = await service.initialize();

      expect(availability.available, isFalse);
      expect(availability.message, contains('Русский голос'));
      await expectLater(
        service.speak('Текст', rate: 0.5),
        throwsA(isA<TtsException>()),
      );
    });
  });

  group('TtsProvider', () {
    late _FakeTts service;
    late _FakeStore store;
    late NavigationProvider navigation;
    late TtsProvider provider;

    setUp(() {
      service = _FakeTts();
      store = _FakeStore();
      navigation = NavigationProvider();
      provider = TtsProvider(
        service: service,
        store: store,
        navigation: navigation,
      );
    });

    tearDown(() {
      provider.dispose();
      navigation.dispose();
    });

    test('starts ready, available and switched off', () async {
      await provider.initialize();

      expect(provider.ready, isTrue);
      expect(provider.available, isTrue);
      expect(provider.enabled, isFalse);
      expect(provider.voices, hasLength(2));
      expect(service.initializes, 1);
    });

    test('enabling speech persists the choice', () async {
      await provider.initialize();

      final enabled = await provider.setEnabled(true);

      expect(enabled, isTrue);
      expect(provider.enabled, isTrue);
      expect(store.settings.enabled, isTrue);
      expect(store.saves, 1);
    });

    test('a missing Russian voice refuses to enable speech', () async {
      service.availability = const TtsAvailability(
        available: false,
        message: 'Русский голос не установлен.',
      );
      await provider.initialize();

      final enabled = await provider.setEnabled(true);

      expect(enabled, isFalse);
      expect(provider.enabled, isFalse);
      expect(provider.errorMessage, contains('Русский голос'));
    });

    test(
      'a removed saved voice falls back to the default Russian voice',
      () async {
        store.settings = const VoiceSettings(
          enabled: true,
          voiceName: 'deleted-voice',
          voiceLocale: 'ru-RU',
        );
        await provider.initialize();

        expect(provider.selectedVoice, isNull);
        expect(provider.voiceNotice, contains('больше не установлен'));
        expect(store.settings.voiceName, isNull);
      },
    );

    test('rate and voice changes are persisted', () async {
      await provider.initialize();
      await provider.setRate(0.9);
      await provider.selectVoice(
        const TtsVoice(name: 'ru-beta', locale: 'ru-RU'),
      );

      expect(provider.rate, VoiceSettings.maxRate);
      expect(provider.selectedVoice?.name, 'ru-beta');
      expect(store.settings.rate, VoiceSettings.maxRate);
      expect(store.settings.voiceName, 'ru-beta');
    });

    test('the test phrase uses the selected settings', () async {
      await provider.initialize();
      await provider.setEnabled(true);
      await provider.selectVoice(
        const TtsVoice(name: 'ru-alpha', locale: 'ru-RU'),
      );
      service.spoken.clear();

      final spoken = await provider.speakTest();

      expect(spoken, isTrue);
      expect(service.spoken.single, contains('поверните налево'));
      expect(service.voiceNames.single, 'ru-alpha');
    });

    test(
      'a storage write failure keeps the session setting and explains it',
      () async {
        store.failSave = true;
        await provider.initialize();

        await provider.setEnabled(true);

        expect(provider.enabled, isTrue);
        expect(provider.errorMessage, contains('не сохранились'));
      },
    );

    test('a storage read failure leaves speech off', () async {
      store.failLoad = true;
      await provider.initialize();

      expect(provider.enabled, isFalse);
      expect(provider.errorMessage, contains('Не удалось'));
    });
  });
}
