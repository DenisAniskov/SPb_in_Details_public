import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/guest_onboarding_screen.dart';
import 'package:smart_navigator_spb/ui/screens/guest_settings_screen.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/guest_launch_gate.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';

import 'smart_walk_audit_test.dart' show NativeRouteAdapter;

const _place = PlaceModel(
  id: 701,
  catalogKey: 'c11-2-1-onboarding-place',
  title: 'Тестовый сад',
  shortDescription: 'Описание тестового сада',
  category: PlaceCategoryEnum.nature,
  latitude: 59.94,
  longitude: 30.31,
  address: 'Тестовый адрес',
);

class _MemoryStorage implements GuestKeyValueStore {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }
}

class _ThrowingGuest extends GuestExperienceProvider {
  _ThrowingGuest()
    : super(
        store: JsonGuestLocalStore(storage: _MemoryStorage()),
        repository: _Catalogue(),
        catalogScope: 'https://catalog.example/api/v1',
      );

  @override
  Future<void> completeOnboarding() async {
    throw StateError('simulated local storage failure');
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

class _Host {
  _Host(this.guest, this.routing);

  final GuestExperienceProvider guest;
  final RoutingProvider routing;
}

Future<_Host> _mountMap(
  WidgetTester tester, {
  Size size = const Size(360, 640),
  bool dark = false,
  double textScale = 1,
  bool completed = false,
  RoutingProvider? routing,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  MapKitService.isMapKitInitialized = false;

  final repository = _Catalogue();
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: _MemoryStorage()),
    repository: repository,
    catalogScope: 'https://catalog.example/api/v1',
  );
  addTearDown(guest.dispose);
  await guest.initialize();
  if (completed) await guest.completeOnboarding();
  final routing0 =
      routing ?? RoutingProvider(mapKitService: NativeRouteAdapter());
  final places = PlacesProvider(repository: repository);
  addTearDown(routing0.dispose);
  addTearDown(places.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<PlacesRepository>.value(value: repository),
        ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
        ChangeNotifierProvider<PlacesProvider>.value(value: places),
        ChangeNotifierProvider<RoutingProvider>.value(value: routing0),
      ],
      child: MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: GuestLaunchGate(homeBuilder: (_) => const MainMapScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Host(guest, routing0);
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: scrollable,
      maxScrolls: 30,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapLabel(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Дополнительные действия'));
  await tester.pumpAndSettle();
  await _tapLabel(tester, 'Настройки');
  expect(find.byType(GuestSettingsScreen), findsOneWidget);
}

Future<void> _openRepeatedIntroduction(WidgetTester tester) async {
  await _tapLabel(tester, 'Повторить знакомство');
  expect(find.byType(GuestOnboardingScreen), findsOneWidget);
}

Future<void> _closeWizard(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Закрыть мастер'));
  await tester.pumpAndSettle();
  expect(find.byType(SmartWalkWizardSheet), findsNothing);
}

PedestrianRouteModel _singleLegRoute() {
  const points = [GeoCoord(59.93, 30.31), GeoCoord(59.94, 30.32)];
  return const PedestrianRouteModel(
    distanceMeters: 100,
    durationSeconds: 120,
    geometryPoints: points,
    steps: [],
    placesCount: 1,
    legs: [
      RouteLegModel(
        fromTitle: 'Старт',
        toTitle: 'Финиш',
        distanceMeters: 100,
        durationSeconds: 120,
        geometryPoints: points,
      ),
    ],
  );
}

void main() {
  group('C11.2.1 first launch', () {
    testWidgets('start walk opens the existing wizard exactly once', (
      tester,
    ) async {
      await _mountMap(tester);
      await _tapLabel(tester, 'Подобрать прогулку');

      expect(find.byType(GuestOnboardingScreen), findsNothing);
      expect(find.byType(MainMapScreen), findsOneWidget);
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);

      await _closeWizard(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SmartWalkWizardSheet), findsNothing);
    });

    testWidgets('show map opens the map without a wizard', (tester) async {
      await _mountMap(tester);
      await _tapLabel(tester, 'Перейти к карте');

      expect(find.byType(GuestOnboardingScreen), findsNothing);
      expect(find.byType(MainMapScreen), findsOneWidget);
      expect(find.byType(SmartWalkWizardSheet), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SmartWalkWizardSheet), findsNothing);
    });
  });

  group('C11.2.1 completion failure', () {
    testWidgets('an unexpected completion error still returns once', (
      tester,
    ) async {
      final guest = _ThrowingGuest();
      addTearDown(guest.dispose);
      OnboardingAction? chosen;
      await tester.pumpWidget(
        ChangeNotifierProvider<GuestExperienceProvider>.value(
          value: guest,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () async {
                      chosen = await Navigator.of(context)
                          .push<OnboardingAction>(
                            MaterialPageRoute<OnboardingAction>(
                              builder: (_) => const GuestOnboardingScreen(),
                            ),
                          );
                    },
                    child: const Text('Открыть знакомство'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть знакомство'));
      await tester.pumpAndSettle();

      await _tapLabel(tester, 'Перейти к карте');

      expect(find.byType(GuestOnboardingScreen), findsNothing);
      expect(chosen, OnboardingAction.showMap);
      expect(tester.takeException(), isNull);
    });
  });

  group('C11.2.1 repeated introduction from settings', () {
    testWidgets('start walk closes both screens and opens one wizard', (
      tester,
    ) async {
      final host = await _mountMap(tester, completed: true);
      await _openSettings(tester);
      await _openRepeatedIntroduction(tester);

      await _tapLabel(tester, 'Подобрать прогулку');

      expect(find.byType(GuestOnboardingScreen), findsNothing);
      expect(find.byType(GuestSettingsScreen), findsNothing);
      expect(find.byType(MainMapScreen), findsOneWidget);
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
      expect(host.routing.navigationLocked, isFalse);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
    });

    testWidgets('show map closes both screens without a wizard', (
      tester,
    ) async {
      await _mountMap(tester, completed: true);
      await _openSettings(tester);
      await _openRepeatedIntroduction(tester);

      await _tapLabel(tester, 'Перейти к карте');

      expect(find.byType(GuestOnboardingScreen), findsNothing);
      expect(find.byType(GuestSettingsScreen), findsNothing);
      expect(find.byType(MainMapScreen), findsOneWidget);
      expect(find.byType(SmartWalkWizardSheet), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SmartWalkWizardSheet), findsNothing);
    });

    testWidgets('Back returns to settings and never starts Smart Walk', (
      tester,
    ) async {
      await _mountMap(tester, completed: true);
      await _openSettings(tester);
      await _openRepeatedIntroduction(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(GuestOnboardingScreen), findsNothing);
      expect(find.byType(GuestSettingsScreen), findsOneWidget);
      expect(find.byType(SmartWalkWizardSheet), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SmartWalkWizardSheet), findsNothing);
    });

    testWidgets('a double activation opens only one wizard', (tester) async {
      await _mountMap(tester, completed: true);
      await _openSettings(tester);
      await _openRepeatedIntroduction(tester);

      final start = find.text('Подобрать прогулку');
      await _reveal(tester, start);
      final button = find.ancestor(
        of: start,
        matching: find.byType(FilledButton),
      );
      final onPressed = tester.widget<FilledButton>(button).onPressed!;

      // Two activations in the same frame: the button guard must accept only
      // one transition and therefore produce only one wizard route.
      onPressed();
      onPressed();
      await tester.pumpAndSettle();

      expect(find.byType(GuestOnboardingScreen), findsNothing);
      expect(find.byType(GuestSettingsScreen), findsNothing);
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
    });

    testWidgets('closing the wizard does not reopen it', (tester) async {
      await _mountMap(tester, completed: true);
      await _openSettings(tester);
      await _openRepeatedIntroduction(tester);
      await _tapLabel(tester, 'Подобрать прогулку');
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);

      await _closeWizard(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(SmartWalkWizardSheet), findsNothing);
      expect(find.byType(MainMapScreen), findsOneWidget);
    });

    testWidgets('the existing built walk and route are preserved', (
      tester,
    ) async {
      final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
      routing.setProposedWalkForScenicTest(
        scenic: false,
        comparison: null,
        walkKind: WalkKind.normal,
        route: _singleLegRoute(),
      );
      final routeBefore = routing.currentRoute;
      final placesBefore = routing.walkPlaces;
      await _mountMap(tester, completed: true, routing: routing);
      await _openSettings(tester);
      await _openRepeatedIntroduction(tester);

      await _tapLabel(tester, 'Подобрать прогулку');
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
      await _closeWizard(tester);

      expect(identical(routing.currentRoute, routeBefore), isTrue);
      expect(routing.walkPlaces, placesBefore);
      expect(routing.navigationLocked, isFalse);
    });

    testWidgets('saved favorites are unchanged', (tester) async {
      final host = await _mountMap(tester, completed: true);
      await host.guest.addFavorite(_place);
      await tester.pumpAndSettle();
      final favoritesBefore = host.guest.favorites;
      expect(favoritesBefore, hasLength(1));
      expect(host.guest.isFavorite(_place), isTrue);

      await _openSettings(tester);
      await _openRepeatedIntroduction(tester);
      await _tapLabel(tester, 'Подобрать прогулку');
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
      await _closeWizard(tester);

      expect(host.guest.favorites, favoritesBefore);
      expect(host.guest.isFavorite(_place), isTrue);
      expect(host.guest.onboardingCompleted, isTrue);
    });

    testWidgets('a navigation lock appearing in flight cancels the wizard', (
      tester,
    ) async {
      final host = await _mountMap(tester, completed: true);
      await _openSettings(tester);
      await _openRepeatedIntroduction(tester);

      // The lock appears after the introduction was opened but before its
      // result reaches the map. The map must re-check it and do nothing.
      host.routing.setNavigationLocked(true);
      await tester.pumpAndSettle();

      await _tapLabel(tester, 'Подобрать прогулку');

      expect(find.byType(GuestSettingsScreen), findsNothing);
      expect(find.byType(GuestOnboardingScreen), findsNothing);
      expect(find.byType(MainMapScreen), findsOneWidget);
      expect(find.byType(SmartWalkWizardSheet), findsNothing);
      expect(host.routing.navigationLocked, isTrue);
    });

    testWidgets('the result transition leaves no navigator errors', (
      tester,
    ) async {
      await _mountMap(tester, completed: true);
      await _openSettings(tester);
      await _openRepeatedIntroduction(tester);

      await _tapLabel(tester, 'Подобрать прогулку');
      expect(find.byType(MainMapScreen), findsOneWidget);
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _closeWizard(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });
  });

  for (final dark in [false, true]) {
    for (final size in [const Size(320, 480), const Size(360, 640)]) {
      testWidgets('repeated introduction fits ${size.width.toInt()}x'
          '${size.height.toInt()} dark=$dark with large text', (tester) async {
        await _mountMap(
          tester,
          size: size,
          dark: dark,
          textScale: 1.6,
          completed: true,
        );
        await _openSettings(tester);
        expect(tester.takeException(), isNull, reason: 'settings');

        await _openRepeatedIntroduction(tester);
        expect(tester.takeException(), isNull, reason: 'introduction');

        await _tapLabel(tester, 'Подобрать прогулку');
        expect(find.byType(MainMapScreen), findsOneWidget);
        expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'wizard');
        await _closeWizard(tester);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }
}
