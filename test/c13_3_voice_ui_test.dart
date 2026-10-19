import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/services/voice/android_speech_recognition_service.dart';
import 'package:smart_navigator_spb/services/voice/speech_recognition_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_engine_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_engine_settings.dart';
import 'package:smart_navigator_spb/services/voice/voice_search_controller.dart';
import 'package:smart_navigator_spb/ui/screens/guest_settings_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/voice_search_sheet.dart';

class _MemoryStorage implements GuestKeyValueStore {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }
}

class _Catalogue extends PlacesRepository {
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async => const [];

  @override
  Future<List<CategoryModel>> getCategories() async => const [];
}

class _MemoryStore implements VoiceEngineSettingsStore {
  VoiceEngineSettings settings = VoiceEngineSettings.defaults;
  int saves = 0;

  @override
  Future<VoiceEngineSettings> load() async => settings;

  @override
  Future<void> save(VoiceEngineSettings value) async {
    settings = value;
    saves++;
  }
}

class _FakeAndroid extends AndroidSpeechRecognitionService {
  _FakeAndroid({
    this.availability = const AndroidSpeechAvailability(
      supported: true,
      permission: SpeechPermission.granted,
    ),
  }) : super(events: const Stream<Object?>.empty());

  AndroidSpeechAvailability availability;
  final StreamController<String> partials =
      StreamController<String>.broadcast();
  SpeechRecognitionException? startError;
  SpeechRecognitionResult result = const SpeechRecognitionResult(
    text: 'Исаакиевский собор',
    audioDurationMs: 1600,
    latencyMs: 900,
    engine: 'android-system',
    model: 'ru-RU',
  );
  int startCalls = 0;
  int cancelCalls = 0;

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
  Future<SpeechPermission> requestPermission() async => availability.permission;

  @override
  Future<void> startRecording() async {
    startCalls++;
    if (startError != null) throw startError!;
  }

  @override
  Future<SpeechRecognitionResult> stopAndRecognize() async => result;

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

Future<GuestExperienceProvider> _guest() async {
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: _MemoryStorage()),
    repository: _Catalogue(),
    catalogScope: 'https://catalog.example/api/v1',
  );
  addTearDown(guest.dispose);
  await guest.initialize();
  await guest.completeOnboarding();
  return guest;
}

Future<VoiceSearchController> _voice({
  _MemoryStore? store,
  _FakeAndroid? android,
}) async {
  final controller = VoiceSearchController(
    service: VoiceSearchEngineService(
      android: android ?? _FakeAndroid(),
      store: store ?? _MemoryStore(),
    ),
  );
  addTearDown(controller.dispose);
  await controller.initializeEngineSettings();
  return controller;
}

Future<void> _mountSettings(
  WidgetTester tester,
  GuestExperienceProvider guest,
  VoiceSearchController voice, {
  Size size = const Size(360, 640),
  bool dark = false,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
        ChangeNotifierProvider<VoiceSearchController>.value(value: voice),
      ],
      child: MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const GuestSettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text('Голосовой поиск'),
    220,
    maxScrolls: 60,
  );
  await tester.pumpAndSettle();
}

Future<void> _mountSheet(
  WidgetTester tester,
  VoiceSearchController voice, {
  Size size = const Size(360, 640),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ChangeNotifierProvider<VoiceSearchController>.value(
      value: voice,
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(body: VoiceSearchSheet()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('settings expose one system recognizer and consent management', (
    tester,
  ) async {
    final store = _MemoryStore();
    final voice = await _voice(store: store);
    await _mountSettings(tester, await _guest(), voice);

    expect(find.text('Голосовой поиск'), findsOneWidget);
    expect(
      find.textContaining('используется системная служба Android'),
      findsWidgets,
    );
    expect(find.text('Согласие не получено'), findsOneWidget);
    expect(find.text('Разрешить голосовой поиск'), findsOneWidget);
    expect(find.text('Системное распознавание доступно'), findsOneWidget);
    expect(find.textContaining('Встроенный Android'), findsNothing);
    expect(find.textContaining('Системный распознаватель'), findsNothing);
    expect(
      find.textContaining('Загрузить русский языковой пакет'),
      findsNothing,
    );
    expect(find.byType(RadioListTile<Object>), findsNothing);
    expect(store.settings.onlineConsent, isFalse);
    expect(voice.engineSnapshot?.needsConsent, isTrue);

    await tester.ensureVisible(find.text('Разрешить голосовой поиск'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Разрешить голосовой поиск'));
    await tester.pumpAndSettle();
    expect(find.text('Разрешить голосовой поиск?'), findsOneWidget);
    expect(find.textContaining('передавать аудио поставщику'), findsWidgets);

    await tester.tap(find.text('Не разрешать'));
    await tester.pumpAndSettle();
    expect(store.settings.onlineConsent, isFalse);

    await tester.ensureVisible(find.text('Разрешить голосовой поиск'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Разрешить голосовой поиск'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Согласен'));
    await tester.pumpAndSettle();

    expect(store.settings.onlineConsent, isTrue);
    expect(find.text('Согласие на распознавание получено'), findsOneWidget);
    expect(find.text('Отозвать согласие'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('revoking consent persists and blocks the next session', (
    tester,
  ) async {
    final store = _MemoryStore()
      ..settings = const VoiceEngineSettings(onlineConsent: true);
    final android = _FakeAndroid();
    final voice = await _voice(store: store, android: android);
    await _mountSettings(tester, await _guest(), voice);

    await tester.scrollUntilVisible(
      find.text('Отозвать согласие'),
      250,
      maxScrolls: 30,
    );
    await tester.ensureVisible(find.text('Отозвать согласие'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отозвать согласие'));
    await tester.pumpAndSettle();
    expect(find.textContaining('микрофон будет остановлен'), findsOneWidget);
    await tester.tap(find.text('Отозвать'));
    await tester.pumpAndSettle();

    expect(store.settings.onlineConsent, isFalse);
    expect(voice.engineSnapshot?.needsConsent, isTrue);

    await voice.start();
    expect(voice.state, VoiceSearchState.consentRequired);
    expect(android.startCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the first voice use asks for consent before the microphone', (
    tester,
  ) async {
    final store = _MemoryStore();
    final android = _FakeAndroid();
    final voice = await _voice(store: store, android: android);

    await voice.start();
    expect(voice.state, VoiceSearchState.consentRequired);
    expect(android.startCalls, 0);
    await _mountSheet(tester, voice);

    expect(find.text('Согласен и продолжить'), findsOneWidget);
    expect(find.text('Найти вручную'), findsOneWidget);
    expect(find.textContaining('может использовать интернет'), findsWidgets);
    expect(find.textContaining('Встроенный Android'), findsNothing);
    expect(find.text('Слушать'), findsNothing);

    await tester.tap(find.text('Согласен и продолжить'));
    await tester.pumpAndSettle();

    expect(store.settings.onlineConsent, isTrue);
    expect(android.startCalls, 1);
    expect(voice.state, VoiceSearchState.recording);
    expect(find.text('Слушаю…'), findsOneWidget);
    expect(find.text('Готово'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await voice.cancel();
    await tester.pump();
  });

  testWidgets('an unavailable recognizer keeps manual search and no pack UI', (
    tester,
  ) async {
    final android = _FakeAndroid(
      availability: const AndroidSpeechAvailability(
        supported: false,
        permission: SpeechPermission.granted,
        error: 'Системное распознавание речи недоступно.',
      ),
    );
    final store = _MemoryStore()
      ..settings = const VoiceEngineSettings(onlineConsent: true);
    final voice = await _voice(store: store, android: android);
    await voice.start();
    expect(voice.state, VoiceSearchState.modelUnavailable);
    await _mountSheet(tester, voice);

    expect(find.textContaining('недоступно'), findsWidgets);
    expect(find.text('Найти вручную'), findsOneWidget);
    expect(find.text('Настройки распознавания'), findsNothing);
    expect(find.textContaining('языковой пакет'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('partial words are visible and the system privacy is explained', (
    tester,
  ) async {
    final android = _FakeAndroid();
    final store = _MemoryStore()
      ..settings = const VoiceEngineSettings(onlineConsent: true);
    final voice = await _voice(store: store, android: android);
    await voice.start();
    expect(voice.state, VoiceSearchState.recording);
    await _mountSheet(tester, voice);

    expect(find.text('Слушаю…'), findsOneWidget);
    expect(
      find.textContaining('Системная служба Android вправе передать аудио'),
      findsOneWidget,
    );
    expect(find.textContaining('встроенный движок'), findsNothing);

    android.partials.add('Исаак');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Исаак'), findsOneWidget);
    android.partials.add('Исаакиевский собор');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Исаакиевский собор'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await voice.cancel();
    await tester.pump();
  });

  testWidgets('voice settings and consent sheet fit small screens at 1.6x', (
    tester,
  ) async {
    final voice = await _voice();
    await _mountSettings(
      tester,
      await _guest(),
      voice,
      size: const Size(320, 480),
      dark: true,
      textScale: 1.6,
    );
    expect(find.text('Голосовой поиск'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Разрешить голосовой поиск'),
      160,
      maxScrolls: 30,
    );
    expect(find.text('Разрешить голосовой поиск'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await voice.start();
    await _mountSheet(
      tester,
      voice,
      size: const Size(320, 480),
      textScale: 1.6,
    );
    expect(find.text('Согласен и продолжить'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
