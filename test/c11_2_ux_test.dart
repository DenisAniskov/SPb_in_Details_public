import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/historical_content_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/guest_onboarding_screen.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/environmental_report_card.dart';
import 'package:smart_navigator_spb/ui/widgets/guest_launch_gate.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';

import 'guided_walk_test_helpers.dart';
import 'historical_content_test.dart'
    show HistoryRepository, NoopMapKit, otherPlace, stopPlace, wrap;
import 'smart_walk_audit_test.dart'
    show
        NativeRouteAdapter,
        PendingRepository,
        mountWizard,
        proposal,
        tapVisible;

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

class _HangingHistory extends PlacesRepository {
  @override
  Future<PlaceModel?> getPlaceDetail(int placeId) async => stopPlace;

  @override
  Future<HistoricalContent?> getPlaceHistory(int placeId) =>
      Completer<HistoricalContent?>().future;
}

class _Host {
  _Host(this.guest, this.routing, this.places);

  final GuestExperienceProvider guest;
  final RoutingProvider routing;
  final PlacesProvider places;
}

GuestExperienceProvider _guest(_MemoryStorage storage, PlacesRepository repo) {
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: storage),
    repository: repo,
    catalogScope: 'https://catalog.example/api/v1',
  );
  addTearDown(guest.dispose);
  return guest;
}

Future<_Host> _mountGate(
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
  final guest = _guest(_MemoryStorage(), repository);
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
  return _Host(guest, routing0, places);
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

Future<void> _tapVisible(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
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
  group('C11.2 first launch', () {
    testWidgets(
      'both actions finish onboarding and only one opens Smart Walk',
      (tester) async {
        // "Перейти к карте" is deliberately plain: no wizard, no extra action.
        await _mountGate(tester);
        await _tapVisible(tester, 'Перейти к карте');
        expect(find.byType(MainMapScreen), findsOneWidget);
        expect(find.byType(SmartWalkWizardSheet), findsNothing);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();

        // "Подобрать прогулку" records one transient intent, which the ready
        // map consumes once and never reopens.
        await _mountGate(tester);
        await _tapVisible(tester, 'Подобрать прогулку');
        expect(find.byType(MainMapScreen), findsOneWidget);
        expect(find.byType(SmartWalkWizardSheet), findsOneWidget);

        await tester.tap(find.byTooltip('Закрыть мастер'));
        await tester.pumpAndSettle();
        expect(find.byType(SmartWalkWizardSheet), findsNothing);
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(SmartWalkWizardSheet), findsNothing);
      },
    );

    testWidgets(
      'reopening the introduction returns an explicit action, not the '
      'first-launch callback',
      (tester) async {
        final repository = _Catalogue();
        final guest = _guest(_MemoryStorage(), repository);
        await guest.initialize();
        await guest.completeOnboarding();
        var started = 0;
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
                                builder: (_) => GuestOnboardingScreen(
                                  onStartWalk: () => started++,
                                ),
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
        await _tapVisible(tester, 'Подобрать прогулку');
        expect(find.byType(GuestOnboardingScreen), findsNothing);
        expect(find.text('Открыть знакомство'), findsOneWidget);
        expect(chosen, OnboardingAction.startSmartWalk);
        expect(started, 0);
        expect(guest.onboardingCompleted, isTrue);
      },
    );
  });

  group('C11.2 Smart Walk entry and proposal', () {
    testWidgets('the map exposes a labelled, accessible Smart Walk action', (
      tester,
    ) async {
      final host = await _mountGate(tester, completed: true);
      expect(find.text('Умная прогулка'), findsOneWidget);
      expect(
        find.byTooltip('Умная прогулка: подбор маршрута по вашим интересам'),
        findsOneWidget,
      );
      final button = find.ancestor(
        of: find.text('Умная прогулка'),
        matching: find.byType(OutlinedButton),
      );
      expect(button, findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      final semantics = tester.getSemantics(button);
      expect(semantics.label, contains('Умная прогулка'));
      expect(host.routing.navigationLocked, isFalse);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
    });

    testWidgets('opening the wizard does not change the built walk', (
      tester,
    ) async {
      final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
      routing.setProposedWalkForScenicTest(
        scenic: false,
        comparison: null,
        walkKind: WalkKind.normal,
        route: _singleLegRoute(),
      );
      final walk = routing.walkPlaces;
      final route = routing.currentRoute;
      await _mountGate(tester, completed: true, routing: routing);
      final entry = find.ancestor(
        of: find.text('Умная прогулка'),
        matching: find.byType(OutlinedButton),
      );
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть мастер'));
      await tester.pumpAndSettle();
      expect(routing.walkPlaces, walk);
      expect(identical(routing.currentRoute, route), isTrue);
      expect(routing.navigationLocked, isFalse);
    });

    testWidgets('proposal CTA keeps the existing build path and busy text', (
      tester,
    ) async {
      final repository = PendingRepository();
      final native = NativeRouteAdapter()..wait = true;
      final routing = RoutingProvider(mapKitService: native);
      await mountWizard(tester, repository, routing);
      await guidedToInterests(tester);
      await tapVisible(tester, find.text('Сформировать прогулку'));
      repository.pending.single.complete(proposal());
      await tester.pumpAndSettle();

      expect(find.text('Построить прогулку'), findsOneWidget);
      expect(
        find.textContaining('Проверим настоящий пешеходный маршрут'),
        findsOneWidget,
      );
      expect(find.text('Проверить маршрут'), findsNothing);

      await tapVisible(tester, find.text('Построить прогулку'));
      await tester.pump();
      expect(find.text('Строим пешеходный маршрут…'), findsWidgets);
      expect(native.calls, isNotEmpty);

      for (final pending in native.pending) {
        pending.complete(_singleLegRoute());
      }
      await tester.pumpAndSettle();
    });

    testWidgets('map fits 320x480 and 360x640 with large text in both themes', (
      tester,
    ) async {
      for (final dark in [false, true]) {
        for (final size in [const Size(320, 480), const Size(360, 640)]) {
          await _mountGate(
            tester,
            size: size,
            dark: dark,
            textScale: 1.6,
            completed: true,
          );
          expect(find.text('Умная прогулка'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        }
      }
    });
  });

  group('C11.2 history states and affordance', () {
    testWidgets('confirmed history exposes a CTA that scrolls to the card', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      addTearDown(routing.dispose);
      await tester.pumpWidget(
        wrap(
          repository: HistoryRepository(),
          routing: routing,
          builder: (_) => const PlaceDetailScreen(place: stopPlace),
        ),
      );
      await tester.pumpAndSettle();
      final cta = find.text('Читать историю места');
      expect(cta, findsOneWidget);
      final button = find.ancestor(
        of: cta,
        matching: find.byType(OutlinedButton),
      );
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSemantics(button).label,
        contains('Читать историю места'),
      );
      await tester.ensureVisible(cta);
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final before = scrollable.position.pixels;
      await tester.tap(cta);
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(before));
      expect(find.text('Краткая история'), findsOneWidget);
    });

    testWidgets('pending history shows loading, not a fake absence', (
      tester,
    ) async {
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      addTearDown(routing.dispose);
      await tester.pumpWidget(
        wrap(
          repository: _HangingHistory(),
          routing: routing,
          builder: (_) => const PlaceDetailScreen(place: stopPlace),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('Загружаем историческую справку…'), findsOneWidget);
      expect(
        find.text('Историческая справка пока не подготовлена.'),
        findsNothing,
      );
      expect(find.text('Краткая история'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('absent history is stated as not prepared, not as an error', (
      tester,
    ) async {
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      addTearDown(routing.dispose);
      await tester.pumpWidget(
        wrap(
          repository: HistoryRepository(),
          routing: routing,
          builder: (_) => const PlaceDetailScreen(place: otherPlace),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Историческая справка пока не подготовлена.'),
        findsOneWidget,
      );
      expect(
        find.text('Не удалось загрузить историческую справку'),
        findsNothing,
      );
      expect(find.text('Читать историю места'), findsNothing);
    });
  });

  group('C11.2 environmental wording helpers', () {
    test('coverage states the uncovered share instead of generalising', () {
      expect(environmentalCoverageSentence(0.64), contains('64%'));
      expect(environmentalCoverageSentence(0.64), contains('36%'));
      expect(environmentalCoverageSentence(1), contains('весь маршрут'));
      expect(environmentalCoverageSentence(0), contains('нет'));
    });

    test('a puddle answer without data is never called dry', () {
      final analysis = PuddleAnalysisModel(
        status: PuddleStatus.outsideCoverage,
        method: 'test',
        methodVersion: 'test',
        risk: PuddleRisk.unknown,
        riskIndex: null,
        routeLengthMeters: 1000,
        knownMeters: 0,
        unknownMeters: 1000,
        lowMeters: 0,
        moderateMeters: 0,
        highMeters: 0,
        coverageShare: 0,
        confidence: 'unavailable',
        periodStart: DateTime(2026, 7, 1, 14),
        periodEnd: DateTime(2026, 7, 1, 15),
        timezoneName: 'MSK',
        datasetVersion: null,
        datasetSource: '',
        datasetLicense: '',
        weather: const PuddleWeatherSource(
          provider: '',
          kind: '',
          license: '',
          available: false,
        ),
        reasons: const [],
        limitations: const [],
      );
      expect(puddleHumanVerdict(analysis), contains('не значит'));
      expect(puddleHumanVerdict(analysis), contains('сухой'));
      expect(puddleCoverageNote(analysis), contains('не означает'));
      final details = puddleTechnicalDetails(analysis);
      expect(details, isNotEmpty);
      expect(details.first, contains('100%'));
      expect(details.join(' '), contains('100% маршрута'));
    });
  });
}
