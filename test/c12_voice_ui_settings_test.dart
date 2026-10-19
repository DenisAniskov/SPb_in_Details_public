import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/tts_provider.dart';
import 'package:smart_navigator_spb/services/pedestrian_guidance_service.dart';
import 'package:smart_navigator_spb/services/voice/tts_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_settings.dart';
import 'package:smart_navigator_spb/ui/screens/guest_settings_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';

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

class _FakeTts implements TtsService {
  TtsAvailability availability = const TtsAvailability(
    available: true,
    voices: [
      TtsVoice(name: 'ru-alpha', locale: 'ru-RU'),
      TtsVoice(name: 'ru-beta', locale: 'ru-RU'),
    ],
  );
  final List<String> spoken = [];
  int stops = 0;

  @override
  Future<TtsAvailability> initialize() async => availability;

  @override
  Future<void> speak(
    String text, {
    required double rate,
    String? voiceName,
    String? voiceLocale,
  }) async {
    spoken.add(text);
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

  @override
  Future<VoiceSettings> load() async => settings;

  @override
  Future<void> save(VoiceSettings settings) async {
    this.settings = settings;
  }
}

class _ActiveNavigation extends NavigationProvider {
  _ActiveNavigation(this.fakeState);

  final LiveNavigationState fakeState;

  @override
  LiveNavigationState get state => fakeState;

  @override
  PedestrianGuidanceModel get guidance =>
      const PedestrianGuidanceService().guidanceFor(fakeState);

  @override
  NavigationStatus get status => fakeState.status;

  @override
  bool get isActive => fakeState.isActive;

  @override
  bool get locksPlanning => true;
}

const _a = GeoCoord(60.0, 30.0);
const _b = GeoCoord(60.0005, 30.0);

LiveNavigationState _activeState() {
  const route = PedestrianRouteModel(
    distanceMeters: 55.6,
    durationSeconds: 60,
    geometryPoints: [_a, _b],
    steps: [],
    placesCount: 1,
    legs: [
      RouteLegModel(
        fromTitle: 'Старт',
        toTitle: 'Финиш',
        distanceMeters: 55.6,
        durationSeconds: 60,
        geometryPoints: [_a, _b],
        maneuvers: [
          PedestrianManeuverModel(
            kind: PedestrianManeuverKind.right,
            segmentIndex: 0,
            segmentPosition: 0.5,
            offsetMeters: 55.6,
          ),
        ],
      ),
    ],
  );
  return LiveNavigationState(
    status: NavigationStatus.active,
    route: route,
    currentLegIndex: 0,
    currentManeuverIndex: 0,
    currentLocation: UserLocationSnapshot(
      coordinate: _a,
      timestamp: DateTime.now(),
    ),
    projectedPoint: _a,
    progressOnCurrentLegMeters: 0,
    remainingDistanceOnCurrentLegMeters: 55.6,
    totalProgressMeters: 0,
    totalRemainingMeters: 55.6,
  );
}

Future<(GuestExperienceProvider, NavigationProvider, TtsProvider)>
_settingsHost(WidgetTester tester, {TtsAvailability? availability}) async {
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: _MemoryStorage()),
    repository: _Catalogue(),
    catalogScope: 'https://catalog.example/api/v1',
  );
  addTearDown(guest.dispose);
  await guest.initialize();
  await guest.completeOnboarding();
  final navigation = NavigationProvider();
  addTearDown(navigation.dispose);
  final service = _FakeTts();
  if (availability != null) service.availability = availability;
  final provider = TtsProvider(
    service: service,
    store: _FakeStore(),
    navigation: navigation,
  );
  addTearDown(provider.dispose);
  await provider.initialize();
  return (guest, navigation, provider);
}

void main() {
  testWidgets('voice settings are off by default and persist the switch', (
    tester,
  ) async {
    final host = await _settingsHost(tester);
    final guest = host.$1;
    final navigation = host.$2;
    final tts = host.$3;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
          ChangeNotifierProvider<NavigationProvider>.value(value: navigation),
          ChangeNotifierProvider<TtsProvider>.value(value: tts),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const GuestSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Голосовые подсказки'),
      200,
      maxScrolls: 30,
    );
    expect(tts.enabled, isFalse);
    expect(find.text('Озвучивать навигацию'), findsOneWidget);

    await tester.tap(find.text('Озвучивать навигацию'));
    await tester.pumpAndSettle();

    expect(tts.enabled, isTrue);
    expect(find.text('Прослушать пример'), findsOneWidget);
    expect(find.text('Скорость речи: 100%'), findsOneWidget);

    await tester.tap(find.text('Прослушать пример'));
    await tester.pumpAndSettle();
    expect(host.$3.voices, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an unavailable Russian engine is explained and cannot be enabled',
    (tester) async {
      final host = await _settingsHost(
        tester,
        availability: const TtsAvailability(
          available: false,
          message: 'Русский голос не установлен. Текстовая навигация работает.',
        ),
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GuestExperienceProvider>.value(
              value: host.$1,
            ),
            ChangeNotifierProvider<NavigationProvider>.value(value: host.$2),
            ChangeNotifierProvider<TtsProvider>.value(value: host.$3),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const GuestSettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Голосовые подсказки'),
        200,
        maxScrolls: 30,
      );

      expect(find.textContaining('Русский голос не найден'), findsOneWidget);
      expect(host.$3.enabled, isFalse);
      expect(await host.$3.setEnabled(true), isFalse);
      expect(host.$3.errorMessage, contains('Русский голос'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the navigation sheet exposes a sound toggle', (tester) async {
    final navigation = _ActiveNavigation(_activeState());
    addTearDown(navigation.dispose);
    final service = _FakeTts();
    final store = _FakeStore();
    final tts = TtsProvider(
      service: service,
      store: store,
      navigation: navigation,
    );
    addTearDown(tts.dispose);
    await tts.initialize();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<NavigationProvider>.value(value: navigation),
          ChangeNotifierProvider<TtsProvider>.value(value: tts),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: LiveNavigationSheet(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('navigation_voice_toggle'));
    expect(toggle, findsOneWidget);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);

    await tester.tap(toggle);
    await tester.pump();
    expect(tts.enabled, isTrue);
    expect(store.settings.enabled, isTrue);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(service.spoken, isNotEmpty);

    await tester.tap(toggle);
    await tester.pump();
    expect(tts.enabled, isFalse);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation voice toggle fits 320x480 with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigation = _ActiveNavigation(_activeState());
    addTearDown(navigation.dispose);
    final tts = TtsProvider(
      service: _FakeTts(),
      store: _FakeStore(),
      navigation: navigation,
    );
    addTearDown(tts.dispose);
    await tts.initialize();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<NavigationProvider>.value(value: navigation),
          ChangeNotifierProvider<TtsProvider>.value(value: tts),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: LiveNavigationSheet(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('navigation_voice_toggle'));
    expect(toggle, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('voice settings fit 320x480 dark with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = await _settingsHost(tester);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GuestExperienceProvider>.value(value: host.$1),
          ChangeNotifierProvider<NavigationProvider>.value(value: host.$2),
          ChangeNotifierProvider<TtsProvider>.value(value: host.$3),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const GuestSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Озвучивать навигацию'),
      220,
      maxScrolls: 60,
    );
    await tester.ensureVisible(find.text('Озвучивать навигацию'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Озвучивать навигацию'));
    await tester.pumpAndSettle();
    expect(host.$3.enabled, isTrue);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('Прослушать пример'),
      220,
      maxScrolls: 40,
    );
    expect(tester.takeException(), isNull);
  });
}
