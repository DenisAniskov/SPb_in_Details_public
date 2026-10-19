import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/puddle_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/recommendation_context.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';

import 'context_recommendation_fixtures.dart';
import 'live_navigation_test.dart' show MockNavigationLocationService;
import 'off_route_reroute_test.dart' show FakeRouteService, FixClock;

// --------------------------------------------------------------------------
// Phase C7.4 — the provider, integrated with the REAL C7.1/C7.2/C7.3
// providers (ТЗ §9: «Проверь движок отдельно и интеграцию с настоящими
// провайдерами»).
//
// Two properties are the point of this file:
//
// * the panel is DERIVED: it must track every invalidation the existing
//   providers already implement, and it must never add an assessment of its
//   own (no service is called unless the user pressed a button);
// * nothing is ever merged across routes, sessions or evaluation instants —
//   the identity evidence the providers publish is what makes that checkable.
// --------------------------------------------------------------------------

final _t1400 = DateTime(2026, 7, 1, 14);
final _t1405 = DateTime(2026, 7, 1, 14, 5);
final _t1600 = DateTime(2026, 7, 1, 16);
final _t1300 = DateTime(2026, 7, 1, 13);

const _p0 = GeoCoord(59.9300, 30.3100);
const _p1 = GeoCoord(59.9345, 30.3100);
const _p2 = GeoCoord(59.9390, 30.3100);

PedestrianRouteModel _walkRoute({WalkKind walkKind = WalkKind.normal}) {
  const legs = [
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'POI 1',
      distanceMeters: 500,
      durationSeconds: 360,
      geometryPoints: [_p0, _p1],
      visitMinutes: 15,
    ),
    RouteLegModel(
      fromTitle: 'POI 1',
      toTitle: 'Финиш',
      distanceMeters: 500,
      durationSeconds: 360,
      geometryPoints: [_p1, _p2],
    ),
  ];
  return PedestrianRouteModel(
    distanceMeters: 1000,
    durationSeconds: 720,
    geometryPoints: const [_p0, _p1, _p2],
    steps: const [],
    legs: legs,
    placesCount: 2,
    walkKind: walkKind,
  );
}

const _comparison = RouteComparison(
  normalWalkingSeconds: 600,
  scenicWalkingSeconds: 780,
  normalDistanceMeters: 800,
  scenicDistanceMeters: 950,
  stopCount: 2,
  benefitLines: ['Проходит по набережной реки Мойки'],
);

class _FakeMapKit extends MapKitService {
  _FakeMapKit(this.route);

  final PedestrianRouteModel route;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async => route;
}

class _RecordingShadeService implements BaseShadeAnalysisService {
  int calls = 0;
  final List<DateTime> departures = [];
  final List<List<RouteLegModel>> legs = [];
  ShadeAnalysisFailure? failure;
  ShadeAnalysisModel Function()? response;

  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async {
    calls++;
    departures.add(departure);
    this.legs.add(List.of(legs));
    final failure = this.failure;
    if (failure != null) throw failure;
    return (response ?? shadeFixture)();
  }
}

class _RecordingPuddleService implements BasePuddleAnalysisService {
  final List<DateTime> departures = [];
  Object? failure;
  PuddleAnalysisModel Function()? response;

  @override
  Future<PuddleAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    departures.add(departure);
    final failure = this.failure;
    if (failure != null) throw failure;
    return (response ?? puddleHighFixture)();
  }
}

class _RecordingPollenService implements BasePollenAnalysisService {
  final List<DateTime> departures = [];
  Object? failure;
  Completer<PollenAnalysisModel>? pending;
  PollenAnalysisModel Function()? response;

  @override
  Future<PollenAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    departures.add(departure);
    final pending = this.pending;
    if (pending != null) return pending.future;
    final failure = this.failure;
    if (failure != null) throw failure;
    return (response ?? pollenConcentrationsFixture)();
  }
}

void main() {
  late FixClock fixClock;
  late MockNavigationLocationService mockLocation;
  late _RecordingShadeService shadeService;
  late _RecordingPuddleService puddleService;
  late _RecordingPollenService pollenService;
  late FakeRouteService routeService;
  late RoutingProvider routing;
  late NavigationProvider nav;
  late PuddleAssessmentProvider puddle;
  late PollenAssessmentProvider pollen;
  late ContextRecommendationProvider panel;

  /// The panel's wall clock (injectable by design): a real walk is the only
  /// context where it decides anything, and tests must be able to move it.
  late DateTime panelNow;
  VirtualShadeClock? clock;

  /// Rebuilds the whole stack; [withClock] mounts the simulator's shared
  /// virtual timeline exactly like `main.dart` does in simulator builds.
  /// [now] replaces the shared wall clock (the mutable [panelNow] by default)
  /// and [gate] replaces the context gate — a deliberately tiny live-walk
  /// window lets a test observe a REAL timer instead of mocking more clocks.
  void build({
    bool withClock = false,
    WalkKind walkKind = WalkKind.normal,
    RecommendationContextGate? gate,
    DateTime Function()? now,
  }) {
    panelNow = _t1400;
    final wallClock = now ?? () => panelNow;
    fixClock = FixClock();
    mockLocation = MockNavigationLocationService();
    shadeService = _RecordingShadeService();
    puddleService = _RecordingPuddleService();
    pollenService = _RecordingPollenService();
    routeService = FakeRouteService();
    routing =
        RoutingProvider(
          mapKitService: _FakeMapKit(_walkRoute()),
          shadeAnalysisService: shadeService,
        )..setProposedWalkForScenicTest(
          scenic: false,
          comparison: null,
          walkKind: walkKind,
          route: _walkRoute(walkKind: walkKind),
        );
    nav = NavigationProvider(
      locationService: mockLocation,
      routingProvider: routing,
      routeService: routeService,
    );
    clock = withClock ? VirtualShadeClock() : null;
    if (clock != null) routing.attachShadeClock(clock);
    // The whole stack shares ONE injectable wall clock: the factor providers
    // stamp their assessments with it and the panel ages them against it.
    puddle = PuddleAssessmentProvider(
      puddleService,
      routing: routing,
      navigation: nav,
      clock: clock,
      now: wallClock,
    );
    pollen = PollenAssessmentProvider(
      pollenService,
      routing: routing,
      navigation: nav,
      clock: clock,
      now: wallClock,
    );
    panel = ContextRecommendationProvider(
      routing: routing,
      navigation: nav,
      puddle: puddle,
      pollen: pollen,
      clock: clock,
      gate: gate,
      now: wallClock,
    );
  }

  setUp(build);

  tearDown(() {
    panel.dispose();
    pollen.dispose();
    puddle.dispose();
    clock?.dispose();
    nav.dispose();
    routing.dispose();
    mockLocation.close();
  });

  List<String> ids() => panel.recommendations.map((entry) => entry.id).toList();

  RecommendationSourceReport reportFor(RecommendationFactor factor) =>
      panel.context.sources.firstWhere((report) => report.factor == factor);

  Future<void> startWalk() async {
    mockLocation.currentPositionResult = UserLocationSnapshot(
      coordinate: _p0,
      timestamp: fixClock.next(),
    );
    await nav.startNavigation(routing.currentRoute!);
  }

  void injectFix(double latitude) {
    nav.injectLocationForTesting(
      UserLocationSnapshot(
        coordinate: GeoCoord(latitude, 30.3100),
        timestamp: fixClock.next(),
      ),
    );
  }

  /// Two consistent fixes, because accepted forward progress beyond the jump
  /// limit needs confirmation (one erroneous fix may never latch progress).
  /// This is exactly the sequence the real GPS stream produces after a start.
  void walkTo(double latitude) {
    for (var i = 0; i < 2; ++i) {
      injectFix(latitude);
    }
  }

  group('the panel never invents a factor (ТЗ §7, §9.1)', () {
    test('nothing assessed: no recommendations and no service is called', () {
      expect(panel.recommendations, isEmpty);
      expect(panel.context.sources.map((report) => report.factor).toList(), [
        RecommendationFactor.shade,
        RecommendationFactor.puddle,
        RecommendationFactor.pollen,
      ]);
      expect(
        panel.context.sources.every(
          (report) =>
              report.availability ==
              RecommendationSourceAvailability.notAssessed,
        ),
        isTrue,
      );
      // Reading the panel is not a trigger (ТЗ §9.17).
      for (var i = 0; i < 5; ++i) {
        expect(panel.recommendations, isEmpty);
      }
      expect(shadeService.calls, 0);
      expect(puddleService.departures, isEmpty);
      expect(pollenService.departures, isEmpty);
      expect(routeService.calls, 0);
    });

    test('only shade was assessed: only shade is reported', () async {
      await routing.assessShade(departure: _t1400);
      expect(ids(), ['shade.estimate']);
      expect(
        reportFor(RecommendationFactor.puddle).availability,
        RecommendationSourceAvailability.notAssessed,
      );
      expect(
        reportFor(RecommendationFactor.pollen).availability,
        RecommendationSourceAvailability.notAssessed,
      );
      // The other two factors were NOT assessed behind the user's back.
      expect(puddleService.departures, isEmpty);
      expect(pollenService.departures, isEmpty);
    });

    test('only a scenic comparison: the trade-off is factual (ТЗ §9.2)', () {
      build(walkKind: WalkKind.scenic);
      routing.setProposedWalkForScenicTest(
        scenic: true,
        comparison: _comparison,
        walkKind: WalkKind.scenic,
        route: _walkRoute(walkKind: WalkKind.scenic),
      );
      expect(ids(), ['scenic.comparison']);
      final entry = panel.recommendations.single;
      expect(entry.title, 'Живописный маршрут построен: +3 мин ходьбы');
      expect(
        entry.facts.map((fact) => fact.display),
        containsAll(['10 мин ходьбы', '13 мин ходьбы', '+3 мин, +150 м']),
      );
      expect(
        entry.facts.map((fact) => fact.value),
        contains('Проходит по набережной реки Мойки'),
      );
      expect(
        reportFor(RecommendationFactor.shade).availability,
        RecommendationSourceAvailability.notAssessed,
      );
    });

    test('all factors fail: the panel stays empty and says why', () async {
      shadeService.failure = const ShadeAnalysisFailure(
        ShadeAnalysisFailureKind.serviceUnavailable,
        'Оценка тени недоступна. Обычная навигация работает.',
      );
      puddleService.failure = const PuddleAnalysisFailure(
        PuddleAnalysisFailureKind.serviceUnavailable,
        'Оценка мокрых участков сейчас недоступна. Обычная навигация работает.',
      );
      pollenService.failure = const PollenAnalysisFailure(
        PollenAnalysisFailureKind.serviceUnavailable,
        'Оценка пыльцы сейчас недоступна. Обычная навигация работает.',
      );
      await routing.assessShade(departure: _t1400);
      await puddle.assess();
      await pollen.assess();

      expect(panel.recommendations, isEmpty);
      for (final factor in [
        RecommendationFactor.shade,
        RecommendationFactor.puddle,
        RecommendationFactor.pollen,
      ]) {
        final report = reportFor(factor);
        expect(report.availability, RecommendationSourceAvailability.failed);
        expect(report.message, contains('Обычная навигация работает'));
      }
      // The walk is untouched by any of it.
      expect(routing.hasRoute, isTrue);
      expect(routing.navigationLocked, isFalse);
    });

    test('an off pollen source is a source state, not clean air', () async {
      pollenService.response = pollenSourceOffFixture;
      await pollen.assess();
      final entry = panel.recommendations.single;
      expect(entry.id, 'pollen.no_values');
      expect(entry.explanation, contains('означает отсутствие данных'));
      expect(entry.facts.where((fact) => fact.unit == 'grains/m³'), isEmpty);
    });
  });

  group('the factors keep their own meaning (ТЗ §9.3, §9.5, §9.6)', () {
    test(
      'puddle high sections and modelled pollen zeros, side by side',
      () async {
        await puddle.assess();
        await pollen.assess();
        expect(ids(), ['puddle.high_sections', 'pollen.concentrations']);

        final puddleEntry = panel.recommendations.first;
        expect(
          puddleEntry.title,
          contains('520 м с высоким относительным риском'),
        );
        expect(
          puddleEntry.explanation,
          contains('не откалибрована на местности'),
        );
        expect(
          puddleEntry.explanation,
          contains('классификация меняется'),
          reason: 'расхождение вариантов параметров входит в вывод',
        );

        final pollenEntry = panel.recommendations.last;
        expect(
          pollenEntry.explanation,
          contains('Ноль — подтверждённое моделью'),
        );
        expect(
          pollenEntry.facts.where((fact) => fact.unit == 'grains/m³'),
          hasLength(6),
          reason: 'виды по отдельности, без общего индекса',
        );
        // No factor is combined with another anywhere in the set.
        expect(
          pollenEntry.facts.map((fact) => fact.label),
          isNot(contains('Всего')),
        );
      },
    );

    test(
      'the withheld pollen panel restores no concentration (ТЗ §9.6)',
      () async {
        pollenService.response = pollenWithheldFixture;
        await pollen.assess();
        final entry = panel.recommendations.single;
        expect(entry.id, 'pollen.withheld');
        expect(entry.availability, RecommendationAvailability.withheld);
        expect(entry.facts.where((fact) => fact.unit == 'grains/m³'), isEmpty);
        expect(
          entry.facts.map((fact) => fact.display),
          contains('50% времени ходьбы'),
        );
        // The provider's own evidence is what keeps it truthful.
        expect(pollen.analysis!.hasWithheldNumbers, isTrue);
        expect(pollen.analysis!.knownMeters, 0);
      },
    );
  });

  group('walk scope and session safety (ТЗ §6, §9.10–§9.12)', () {
    test('mid-walk only the remaining path is admitted', () async {
      await routing.assessShade(departure: _t1400);
      expect(ids(), ['shade.estimate']);

      await startWalk();
      expect(routing.navigationLocked, isTrue);
      walkTo(59.9322);
      final remaining = nav.buildRemainingRoute()!;
      expect(
        remaining.geometryPoints.first.latitude,
        closeTo(59.9322, 1e-6),
        reason: 'остаток пути начинается там, где стоит гуляющий',
      );
      await puddle.assess();

      expect(panel.context.scope, RecommendationScope.remainingPath);
      expect(ids(), [
        'puddle.high_sections',
      ], reason: 'оценка всей прогулки не применима к пути впереди');
      final shadeReport = reportFor(RecommendationFactor.shade);
      expect(shadeReport.rejection, RecommendationRejection.scopeMismatch);
      expect(shadeReport.message, contains('«Вся прогулка»'));
      // The plan estimate itself is untouched and still available to its card.
      expect(routing.shadeAnalysis, isNotNull);
      expect(nav.isActive, isTrue);
    });

    test('a reroute drops every remaining-path recommendation', () async {
      await startWalk();
      walkTo(59.9322);
      await puddle.assess();
      expect(ids(), ['puddle.high_sections']);

      // Three consecutive off-route fixes over more than the sustain window.
      for (var i = 0; i < 3; ++i) {
        nav.injectLocationForTesting(
          UserLocationSnapshot(
            coordinate: const GeoCoord(59.9322, 30.3140),
            timestamp: fixClock.next(const Duration(seconds: 3)),
          ),
        );
      }
      expect(nav.state.isOffRoute, isTrue);
      routeService.result = _walkRoute();
      await nav.rerouteToNextStop();
      expect(nav.state.isRerouting, isFalse);
      expect(nav.status, NavigationStatus.active);

      expect(
        puddle.analysis,
        isNull,
        reason: 'провайдер оценки сбрасывает результат при перестроении',
      );
      expect(ids(), isEmpty);
      expect(
        reportFor(RecommendationFactor.puddle).availability,
        RecommendationSourceAvailability.notAssessed,
      );
    });

    test('finishing the walk returns to the whole-walk question', () async {
      await routing.assessShade(departure: _t1400);
      await startWalk();
      walkTo(59.9322);
      await puddle.assess();
      expect(panel.context.scope, RecommendationScope.remainingPath);

      nav.stopNavigation();

      expect(panel.context.scope, RecommendationScope.wholeWalk);
      expect(routing.navigationLocked, isFalse);
      expect(ids(), [
        'shade.estimate',
      ], reason: 'плановая оценка снова применима, оценка остатка пути — нет');
    });

    test('changing the walk invalidates every factor at once', () async {
      await routing.assessShade(departure: _t1400);
      await puddle.assess();
      await pollen.assess();
      expect(ids(), hasLength(3));

      routing.addPlaceToWalk(
        const PlaceModel(
          id: 42,
          title: 'Новое место',
          shortDescription: 'Описание',
          category: PlaceCategoryEnum.historyArchitecture,
          latitude: 59.94,
          longitude: 30.31,
          address: 'Санкт-Петербург',
          recommendedVisitMinutes: 30,
        ),
      );

      expect(ids(), isEmpty);
      expect(routing.shadeAnalysis, isNull);
      expect(puddle.analysis, isNull);
      expect(pollen.analysis, isNull);
    });

    test('a virtual time change invalidates the dependent estimates', () async {
      build(withClock: true);
      await routing.assessShade(departure: _t1400);
      expect(ids(), ['shade.estimate']);
      expect(panel.context.referenceInstant, _t1400);

      // Any other card's time change arms the SAME shared clock.
      clock!.arm(_t1400.add(const Duration(hours: 3)));

      expect(
        panel.context.referenceInstant,
        _t1400.add(const Duration(hours: 3)),
      );
      expect(ids(), isEmpty);
      final report = reportFor(RecommendationFactor.shade);
      expect(report.rejection, RecommendationRejection.timeMismatch);
      expect(report.message, contains('пересчитайте её'));
    });

    test(
      'an assessment for another rule is not reused across routes',
      () async {
        await puddle.assess();
        expect(puddle.assessedRoute, isNotNull);
        // The seeding helper replaces the route WITHOUT notifying, so the only
        // thing standing between the panel and a stale fact is the identity
        // evidence C7.4 verifies itself.
        routing.setProposedWalkForScenicTest(
          scenic: true,
          comparison: _comparison,
          walkKind: WalkKind.scenic,
          route: _walkRoute(walkKind: WalkKind.scenic),
        );
        expect(ids(), [
          'scenic.comparison',
        ], reason: 'оценка, сделанная для другого маршрута, не показывается');
        final report = reportFor(RecommendationFactor.puddle);
        expect(report.rejection, RecommendationRejection.routeMismatch);
      },
    );
  });

  group('state safety (ТЗ §9.13, §9.15, §9.16)', () {
    test('a late in-flight result never reaches the recommendations', () async {
      pollenService.pending = Completer<PollenAnalysisModel>();
      final inFlight = pollen.assess();

      expect(ids(), isEmpty);
      expect(
        reportFor(RecommendationFactor.pollen).availability,
        RecommendationSourceAvailability.inProgress,
      );

      // The walk is rebuilt while the request is still running.
      await routing.buildRouteToExternalPoint(
        const ExternalMapPoint(
          title: 'Новая цель',
          latitude: 59.9500,
          longitude: 30.3300,
        ),
      );
      pollenService.pending!.complete(pollenConcentrationsFixture());
      await inFlight;

      expect(pollen.analysis, isNull);
      expect(pollen.failure, isNull);
      expect(ids(), isEmpty);
      expect(
        ids().where((id) => id.startsWith('pollen')),
        isEmpty,
        reason: 'опоздавший ответ не попадает в рекомендации нового маршрута',
      );
    });

    test('switching the preference changes nothing but the panel', () async {
      await routing.assessShade(departure: _t1400);
      await puddle.assess();
      final route = routing.currentRoute;
      final duration = route!.durationSeconds;
      final placeIds = routing.walkPlaces.map((place) => place.id).toList();
      final shade = routing.shadeAnalysis;

      panel.setPreference(RecommendationPreference.scenic);
      panel.setPreference(RecommendationPreference.shade);

      expect(identical(routing.currentRoute, route), isTrue);
      expect(routing.currentRoute!.durationSeconds, duration);
      expect(routing.walkPlaces.map((place) => place.id).toList(), placeIds);
      expect(routing.navigationLocked, isFalse);
      expect(identical(routing.shadeAnalysis, shade), isTrue);
      expect(puddle.analysis, isNotNull);
      // Order follows the documented policy; the set is unchanged otherwise.
      expect(panel.recommendations.map((entry) => entry.factor).toList(), [
        RecommendationFactor.shade,
        RecommendationFactor.puddle,
      ]);
    });

    test('the same context always yields the same list', () async {
      await routing.assessShade(departure: _t1400);
      await puddle.assess();
      await pollen.assess();
      final first = panel.recommendations;
      final second = panel.recommendations;
      expect(first, equals(second));
      expect(first.map((entry) => entry.id).toList(), ids());
    });
  });

  // --------------------------------------------------------------------------
  // C7.4.1 — the three review findings, integrated with the REAL providers:
  // the virtual timeline, a walker moving along unchanged geometry, and a
  // reroute in flight.
  // --------------------------------------------------------------------------
  group('virtual time is authoritative in both directions (C7.4.1 #1)', () {
    test(
      'seeking the simulator back drops the estimate, forward keeps it',
      () async {
        build(withClock: true);
        await routing.assessShade(departure: _t1600);
        expect(ids(), ['shade.estimate']);
        expect(panel.context.referenceInstant, _t1600);

        // Backward: the estimate was made for a virtual instant that no longer
        // is "now". Before the fix the later estimate stayed as the reference
        // and was presented as current.
        clock!.arm(_t1300);
        expect(panel.context.referenceInstant, _t1300);
        expect(ids(), isEmpty);
        expect(
          reportFor(RecommendationFactor.shade).rejection,
          RecommendationRejection.timeMismatch,
        );

        // Forward again, into the same walk window: admissible once more.
        clock!.arm(_t1600.add(const Duration(minutes: 6)));
        expect(
          panel.context.referenceInstant,
          _t1600.add(const Duration(minutes: 6)),
        );
        expect(ids(), [
          'shade.estimate',
        ], reason: '6 мин — то же время прогулки');
        expect(shadeService.calls, 1, reason: 'ничего не пересчитывалось само');
      },
    );
  });

  group('moving along the route invalidates the tail (C7.4.1 #2)', () {
    test(
      'a walker who moved on loses the tail, and recompute restores it',
      () async {
        await startWalk();
        walkTo(59.9322); // ≈ 245 м
        await puddle.assess();
        expect(ids(), ['puddle.high_sections']);
        final version = routing.navigationRouteVersion;

        walkTo(59.9340); // ≈ +200 м по ТОЙ ЖЕ геометрии сессии
        expect(nav.state.isRerouting, isFalse);
        expect(
          routing.navigationRouteVersion,
          version,
          reason: 'геометрия не перестраивалась — версия и не должна меняться',
        );
        expect(nav.state.currentLegIndex, 0);

        expect(ids(), isEmpty);
        final report = reportFor(RecommendationFactor.puddle);
        expect(report.rejection, RecommendationRejection.progressAdvanced);
        expect(report.message, contains('продвинулись по этому же маршруту'));
        expect(report.message, contains('примерно на 200 м'));
        expect(report.message, contains('порог — 150 м'));
        expect(
          puddle.analysis,
          isNotNull,
          reason:
              'оценка не удаляется: её карточка и пересчёт продолжают работать',
        );

        await panel.recompute(RecommendationFactor.puddle);
        expect(ids(), [
          'puddle.high_sections',
        ], reason: 'пересчёт для текущего места');
        expect(puddleService.departures, hasLength(2));
        expect(
          routeService.calls,
          0,
          reason: 'ни одного нового MapKit-запроса',
        );
      },
    );

    test('completing a leg invalidates the estimate made on the previous one', () async {
      await startWalk();
      walkTo(59.9322);
      await puddle.assess();
      expect(ids(), ['puddle.high_sections']);

      // Arrival needs two validated fixes near the endpoint; the progress jump
      // to the leg's end needs a confirming fix of its own.
      injectFix(59.9345);
      injectFix(59.9345);
      injectFix(59.9345);
      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);

      expect(panel.context.scope, RecommendationScope.remainingPath);
      expect(ids(), isEmpty);
      expect(
        reportFor(RecommendationFactor.puddle).rejection,
        RecommendationRejection.progressAdvanced,
      );
      expect(routeService.calls, 0);
    });

    test('GPS jitter never invalidates a tail estimate', () async {
      await startWalk();
      walkTo(59.9322);
      await puddle.assess();
      expect(ids(), ['puddle.high_sections']);

      // ≈ 33 м forward and ≈ 22 м back — noise, not a new place on the route.
      injectFix(59.9325);
      injectFix(59.9323);

      expect(ids(), ['puddle.high_sections']);
      expect(
        panel.context.sources.map((report) => report.factor),
        isNot(contains(RecommendationFactor.puddle)),
      );
    });

    test('a late response is excluded once the walker has moved on', () async {
      await startWalk();
      walkTo(59.9322);
      pollenService.pending = Completer<PollenAnalysisModel>();
      final inFlight = pollen.assess();
      expect(
        reportFor(RecommendationFactor.pollen).availability,
        RecommendationSourceAvailability.inProgress,
      );

      walkTo(59.9340); // the request is still running
      pollenService.pending!.complete(pollenConcentrationsFixture());
      await inFlight;

      expect(pollen.analysis, isNotNull, reason: 'ответ получен и опубликован');
      expect(
        ids(),
        isEmpty,
        reason: 'но он описывает остаток, который начинался 200 м назад',
      );
      expect(
        reportFor(RecommendationFactor.pollen).rejection,
        RecommendationRejection.progressAdvanced,
      );
      expect(routeService.calls, 0);
    });
  });

  group('freshness in a real walk (C7.4.1 #2)', () {
    test('an aged estimate is replaced by an explicit recompute', () async {
      await startWalk();
      walkTo(59.9322);
      await puddle.assess();
      expect(ids(), ['puddle.high_sections']);

      panelNow = _t1400.add(const Duration(minutes: 16));
      expect(ids(), isEmpty);
      final report = reportFor(RecommendationFactor.puddle);
      expect(report.rejection, RecommendationRejection.assessmentAged);
      expect(report.message, contains('не менее 15 мин назад'));

      await panel.recompute(RecommendationFactor.puddle);
      expect(ids(), [
        'puddle.high_sections',
      ], reason: 'пересчёт на текущий момент');
      expect(routeService.calls, 0);
    });

    test('an expired forecast deadline is its own, named reason', () async {
      puddleService.response = () =>
          PuddleAnalysisModelWithWeatherValidity(puddleHighFixture(), _t1405);
      await startWalk();
      walkTo(59.9322);
      await puddle.assess();
      expect(ids(), ['puddle.high_sections']);

      panelNow = _t1400.add(const Duration(minutes: 10));
      expect(ids(), isEmpty);
      final report = reportFor(RecommendationFactor.puddle);
      expect(report.rejection, RecommendationRejection.sourceExpired);
      expect(report.message, contains('актуален до 01.07.2026 14:05'));
      expect(
        report.message,
        isNot(contains('оценка сделана')),
        reason:
            'истёкшая валидность источника — отдельная причина, не старение',
      );
    });

    test('planning is not aged against the wall clock', () async {
      // Both factors are assessed for the same deliberately chosen instant.
      panelNow = _t1600;
      await routing.assessShade(departure: _t1600);
      await puddle.assess();
      expect(ids(), hasLength(2));

      // Two days later, still the plan for the chosen time: nothing is stale,
      // because the walk has not started.
      panelNow = _t1600.add(const Duration(days: 2));
      expect(ids(), hasLength(2));
      expect(
        panel.context.sources.map((report) => report.factor),
        isNot(
          anyOf(
            contains(RecommendationFactor.shade),
            contains(RecommendationFactor.puddle),
          ),
        ),
      );
    });

    test('the simulator switches freshness to the virtual timeline', () async {
      build(withClock: true);
      await startWalk();
      walkTo(59.9322);
      await puddle.assess();
      expect(ids(), ['puddle.high_sections']);

      // The wall clock moved far past the assessment, but the virtual walk is
      // still exactly where it was: the virtual timeline governs.
      panelNow = _t1400.add(const Duration(hours: 5));
      expect(ids(), ['puddle.high_sections']);
    });
  });

  // --------------------------------------------------------------------------
  // C7.4.2 #2 — a fact that goes stale because TIME passed must reach an open
  // panel even when nothing at all happens: a stationary walker, no GPS fix,
  // no provider event, no user gesture.
  // --------------------------------------------------------------------------
  group('time alone wakes the panel up (C7.4.2 #2)', () {
    test(
      'a wake-up is armed exactly while a real walk has a live fact',
      () async {
        expect(
          panel.hasPendingLiveExpiryWakeUp,
          isFalse,
          reason: 'прогулки нет — стареть нечему',
        );

        await routing.assessShade(departure: _t1400);
        expect(
          panel.hasPendingLiveExpiryWakeUp,
          isFalse,
          reason: 'планирование не старится сознательно: будить нечего',
        );

        await startWalk();
        await puddle.assess();
        expect(ids(), ['puddle.high_sections']);
        expect(
          panel.hasPendingLiveExpiryWakeUp,
          isTrue,
          reason: 'живая прогулка с допущенным фактом — есть что будить',
        );

        nav.stopNavigation();
        expect(
          panel.hasPendingLiveExpiryWakeUp,
          isFalse,
          reason: 'вместе с прогулкой снимается и пробуждение',
        );
      },
    );

    test('a disposed panel leaves no wake-up behind', () async {
      await startWalk();
      await puddle.assess();
      expect(panel.hasPendingLiveExpiryWakeUp, isTrue);

      // A second instance over the same providers, disposed on its own: the
      // wake-up belongs to the instance and must go with it.
      final local = ContextRecommendationProvider(
        routing: routing,
        navigation: nav,
        puddle: puddle,
        pollen: pollen,
        clock: clock,
        now: () => panelNow,
      );
      expect(
        local.hasPendingLiveExpiryWakeUp,
        isTrue,
        reason: 'тот же живой факт — то же пробуждение',
      );
      local.dispose();
      expect(
        local.hasPendingLiveExpiryWakeUp,
        isFalse,
        reason: 'после dispose таймеров не остаётся',
      );
      expect(panel.hasPendingLiveExpiryWakeUp, isTrue);
    });

    test(
      'the simulator arms no wake-up: the virtual timeline decides',
      () async {
        build(withClock: true);
        await startWalk();
        await puddle.assess();
        expect(ids(), ['puddle.high_sections']);
        expect(
          panel.hasPendingLiveExpiryWakeUp,
          isFalse,
          reason: 'при взведённых часах настенное время ничего не решает',
        );
      },
    );

    test('time alone notifies the panel, with no event from any source', () async {
      // The production mechanism on a deliberately tiny window: a real walk, a
      // real Timer and the real event loop — and, after the assessment, no GPS
      // fix, no provider event and no user gesture at all.
      final stopwatch = Stopwatch()..start();
      build(
        gate: const RecommendationContextGate(maxLiveAge: Duration(seconds: 1)),
        now: () => _t1400.add(stopwatch.elapsed),
      );
      await startWalk();
      await puddle.assess();
      expect(ids(), ['puddle.high_sections']);
      final puddleCalls = puddleService.departures.length;
      final shadeCalls = shadeService.calls;
      var notifications = 0;
      panel.addListener(() => notifications++);

      await Future<void>.delayed(const Duration(milliseconds: 2500));

      expect(
        notifications,
        greaterThan(0),
        reason: 'панель обновилась сама: событий навигации не было',
      );
      expect(ids(), isEmpty);
      expect(
        reportFor(RecommendationFactor.puddle).rejection,
        RecommendationRejection.assessmentAged,
      );
      expect(
        puddleService.departures.length,
        puddleCalls,
        reason: 'пробуждение не запускает оценку',
      );
      expect(shadeService.calls, shadeCalls);
      expect(routeService.calls, 0, reason: 'ни одного нового MapKit-запроса');
    });
  });

  group('a reroute in flight (C7.4.1 #3)', () {
    test(
      'nothing is presented while the session rebuilds, and after it',
      () async {
        await startWalk();
        walkTo(59.9322);
        await panel.recompute(RecommendationFactor.shade);
        expect(ids(), ['shade.estimate']);

        // Step off the route: three sustained fixes confirm it.
        for (var i = 0; i < 3; ++i) {
          nav.injectLocationForTesting(
            UserLocationSnapshot(
              coordinate: const GeoCoord(59.9322, 30.3140),
              timestamp: fixClock.next(const Duration(seconds: 3)),
            ),
          );
        }
        expect(nav.state.isOffRoute, isTrue);
        expect(ids(), [
          'shade.estimate',
        ], reason: 'сход с маршрута сам по себе ничего не перестраивает');

        // Hold the rebuild in flight: this is the window the fix closes.
        routeService.pending = Completer<PedestrianRouteModel>();
        final inFlight = nav.rerouteToNextStop();
        expect(nav.state.isRerouting, isTrue);

        expect(
          routing.shadeAnalysis,
          isNotNull,
          reason:
              'провайдер сбрасывает оценку только при завершении перестроения',
        );
        expect(ids(), isEmpty);
        final report = reportFor(RecommendationFactor.shade);
        expect(report.availability, RecommendationSourceAvailability.rejected);
        expect(report.rejection, RecommendationRejection.sessionRebuilding);
        expect(report.message, contains('идёт перестроение маршрута'));

        routeService.pending!.complete(_walkRoute());
        await inFlight;
        expect(nav.state.isRerouting, isFalse);

        // The rebuilt geometry invalidated the old estimate outright; the panel
        // is back to normal and a fresh estimate is a deliberate press again.
        expect(routing.shadeAnalysis, isNull);
        expect(
          reportFor(RecommendationFactor.shade).availability,
          RecommendationSourceAvailability.notAssessed,
        );
        await panel.recompute(RecommendationFactor.shade);
        expect(ids(), ['shade.estimate']);
        expect(nav.isActive, isTrue);
        expect(routing.navigationLocked, isTrue);
      },
    );
  });

  group('the only action is an explicit user gesture (ТЗ §8)', () {
    test('recompute re-runs exactly the factor the user pressed', () async {
      await panel.recompute(RecommendationFactor.shade);
      expect(shadeService.calls, 1);
      expect(puddleService.departures, isEmpty);
      expect(pollenService.departures, isEmpty);
      expect(routeService.calls, 0, reason: 'движок не запускает роутер');

      await panel.recompute(RecommendationFactor.pollen);
      expect(pollenService.departures, hasLength(1));
      expect(puddleService.departures, isEmpty);

      // The scenic factor has no action at all: C7.4 creates no candidates.
      await panel.recompute(RecommendationFactor.scenic);
      expect(routeService.calls, 0);
    });

    test(
      'mid-walk the shade re-run asks for the remaining path only',
      () async {
        await startWalk();
        walkTo(59.9322);
        final remaining = nav.buildRemainingRoute()!;
        shadeService.legs.clear();

        await panel.recompute(RecommendationFactor.shade);

        expect(shadeService.calls, 1);
        expect(
          shadeService.legs.single.first.geometryPoints.first.latitude,
          closeTo(remaining.geometryPoints.first.latitude, 1e-9),
        );
        expect(
          shadeService.legs.single.first.geometryPoints.first.latitude,
          isNot(closeTo(_p0.latitude, 1e-9)),
          reason: 'пересчёт не описывает уже пройденное',
        );
        expect(nav.isActive, isTrue);
        expect(routing.navigationLocked, isTrue);
      },
    );

    test('a failed recompute leaves the walk and the lock alone', () async {
      await startWalk();
      walkTo(59.9322);
      shadeService.failure = const ShadeAnalysisFailure(
        ShadeAnalysisFailureKind.serviceUnavailable,
        'Оценка тени недоступна.',
      );
      await panel.recompute(RecommendationFactor.shade);

      expect(routing.shadeFailure, isNotNull);
      expect(nav.isActive, isTrue);
      expect(routing.navigationLocked, isTrue);
      expect(identical(nav.state.route, routing.navigationRoute), isTrue);
      expect(
        reportFor(RecommendationFactor.shade).availability,
        RecommendationSourceAvailability.failed,
      );
      expect(ids(), isEmpty);
    });
  });
}
