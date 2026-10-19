import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/suggest_item_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/data/repositories/search_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/voice/speech_recognition_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_search_controller.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';

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

class _SearchRepository extends SearchRepository {
  final List<String> queries = [];

  @override
  Future<List<SuggestItemModel>> getSuggestions(
    String query, {
    int limit = 7,
  }) async {
    queries.add(query);
    return const [];
  }
}

class _FakeSpeech implements SpeechRecognitionService {
  SpeechRecognitionStatus statusResult = const SpeechRecognitionStatus(
    supported: true,
    modelReady: true,
    permission: SpeechPermission.granted,
  );
  SpeechPermission permissionResult = SpeechPermission.granted;
  SpeechRecognitionResult result = const SpeechRecognitionResult(
    text: 'Найди Казанский собор',
    audioDurationMs: 1600,
    latencyMs: 700,
    engine: 'android-on-device',
    model: 'ru-RU',
  );
  Completer<SpeechRecognitionResult>? pendingStop;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;

  @override
  Future<SpeechRecognitionStatus> status() async => statusResult;

  @override
  Future<SpeechPermission> requestPermission() async => permissionResult;

  @override
  Future<void> startRecording() async {
    startCalls++;
  }

  @override
  Future<SpeechRecognitionResult> stopAndRecognize() {
    stopCalls++;
    return pendingStop?.future ?? Future.value(result);
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> openPermissionSettings() async {}

  @override
  Future<void> dispose() async {}
}

class _Host {
  _Host(this.voice, this.places, this.search, this.routing, this.speech);

  final VoiceSearchController voice;
  final PlacesProvider places;
  final SearchProvider search;
  final RoutingProvider routing;
  final _FakeSpeech speech;
}

Future<_Host> _mountMap(
  WidgetTester tester, {
  Size size = const Size(360, 640),
  bool dark = false,
  double textScale = 1,
  _FakeSpeech? speech,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  MapKitService.isMapKitInitialized = false;

  final fakeSpeech = speech ?? _FakeSpeech();
  final repository = _Catalogue();
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: _MemoryStorage()),
    repository: repository,
    catalogScope: 'https://catalog.example/api/v1',
  );
  addTearDown(guest.dispose);
  await guest.initialize();
  await guest.completeOnboarding();
  final places = PlacesProvider(repository: repository);
  final search = SearchProvider(repository: _SearchRepository());
  final routing = RoutingProvider();
  final voice = VoiceSearchController(service: fakeSpeech);
  addTearDown(places.dispose);
  addTearDown(search.dispose);
  addTearDown(routing.dispose);
  addTearDown(voice.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<PlacesRepository>.value(value: repository),
        ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
        ChangeNotifierProvider<PlacesProvider>.value(value: places),
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
        ChangeNotifierProvider<SearchProvider>.value(value: search),
        ChangeNotifierProvider<VoiceSearchController>.value(value: voice),
      ],
      child: MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const MainMapScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Host(voice, places, search, routing, fakeSpeech);
}

Future<void> _openMicrophone(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Голосовой поиск'));
  await tester.pumpAndSettle();
  expect(find.textContaining('Слушаю'), findsOneWidget);
}

Future<void> _finishRecording(WidgetTester tester) async {
  final done = find.text('Готово');
  final screenHeight =
      tester.view.physicalSize.height / tester.view.devicePixelRatio;
  expect(
    tester.getCenter(done).dy,
    lessThanOrEqualTo(screenHeight),
    reason: 'the stop action must be visible without scrolling',
  );
  await tester.tap(done);
  await tester.pump();
  // C13.2: the UI switches to recognizing before the native call returns.
  expect(find.textContaining('Распознаём речь'), findsOneWidget);
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pumpAndSettle();
  // A successful transcript closes the sheet and fills normal search; there
  // is no mandatory second confirmation.
  expect(find.text('Голосовой поиск'), findsNothing);
  expect(find.text('Казанский собор'), findsOneWidget);
}

void main() {
  testWidgets('confirmed voice query feeds the existing search only', (
    tester,
  ) async {
    final host = await _mountMap(tester);
    await _openMicrophone(tester);

    await _finishRecording(tester);

    expect(host.speech.stopCalls, 1);
    expect(host.places.searchQuery, 'Казанский собор');
    expect(host.search.searchQuery, 'Казанский собор');
    expect(find.text('Казанский собор'), findsOneWidget);
    expect(find.byType(SmartWalkWizardSheet), findsNothing);
    expect(find.byType(LiveNavigationSheet), findsNothing);
    expect(host.routing.navigationLocked, isFalse);
    expect(host.routing.currentRoute, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission denial leaves manual search available', (
    tester,
  ) async {
    final speech = _FakeSpeech()
      ..statusResult = const SpeechRecognitionStatus(
        supported: true,
        modelReady: true,
        permission: SpeechPermission.denied,
      )
      ..permissionResult = SpeechPermission.denied;
    final host = await _mountMap(tester, speech: speech);

    await tester.tap(find.byTooltip('Голосовой поиск'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Микрофон недоступен'), findsOneWidget);
    expect(find.text('Найти вручную'), findsOneWidget);

    await tester.tap(find.text('Найти вручную'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Микрофон недоступен'), findsNothing);
    expect(host.places.searchQuery, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling during recognition never writes a late transcript', (
    tester,
  ) async {
    final speech = _FakeSpeech()
      ..pendingStop = Completer<SpeechRecognitionResult>();
    final host = await _mountMap(tester, speech: speech);
    await _openMicrophone(tester);
    final done = find.text('Готово');
    await tester.ensureVisible(done);
    await tester.pump();
    await tester.tap(done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Распознаём речь'), findsOneWidget);

    await tester.tap(find.text('Отмена'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    speech.pendingStop!.complete(
      const SpeechRecognitionResult(
        text: 'Исаакиевский собор',
        audioDurationMs: 1200,
        latencyMs: 600,
        engine: 'android-on-device',
        model: 'ru-RU',
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(host.places.searchQuery, isEmpty);
    expect(find.text('Исаакиевский собор'), findsNothing);
    expect(host.speech.cancelCalls, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('backgrounding the app stops an active microphone', (
    tester,
  ) async {
    final host = await _mountMap(tester);
    await _openMicrophone(tester);
    expect(host.voice.state, VoiceSearchState.recording);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(host.speech.cancelCalls, greaterThan(0));
    expect(host.voice.state, VoiceSearchState.cancelled);
    expect(tester.takeException(), isNull);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  });

  for (final config in [
    (const Size(320, 480), false),
    (const Size(320, 480), true),
    (const Size(360, 640), false),
    (const Size(360, 640), true),
  ]) {
    testWidgets(
      'voice sheet fits ${config.$1.width.toInt()}x${config.$1.height.toInt()} '
      '${config.$2 ? 'dark' : 'light'} with large text',
      (tester) async {
        await _mountMap(
          tester,
          size: config.$1,
          dark: config.$2,
          textScale: 1.6,
        );
        await _openMicrophone(tester);
        expect(tester.takeException(), isNull);

        await _finishRecording(tester);
        final screenHeight =
            tester.view.physicalSize.height / tester.view.devicePixelRatio;
        expect(
          tester.getCenter(find.text('Казанский собор')).dy,
          lessThanOrEqualTo(screenHeight),
          reason: 'the applied query must stay visible without overflow',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
