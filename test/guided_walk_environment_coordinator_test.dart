import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/quiet_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/puddle_analysis_service.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/simulated_location_source.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/controllers/guided_walk_environment_coordinator.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';

import 'context_recommendation_fixtures.dart';
import 'live_navigation_test.dart' show MockNavigationLocationService;
import 'off_route_reroute_test.dart' show FakeRouteService;
import 'smart_walk_audit_test.dart' show poi;

PedestrianRouteModel _route() => const PedestrianRouteModel(
  distanceMeters: 1000,
  durationSeconds: 600,
  placesCount: 1,
  geometryPoints: [GeoCoord(59.93, 30.31), GeoCoord(59.94, 30.32)],
  steps: [],
  legs: [
    RouteLegModel(
      fromTitle: 'Дворцовая площадь',
      toTitle: 'Музей',
      distanceMeters: 1000,
      durationSeconds: 600,
      geometryPoints: [GeoCoord(59.93, 30.31), GeoCoord(59.94, 30.32)],
    ),
  ],
);

class _Shade implements BaseShadeAnalysisService {
  _Shade(this.events);
  final List<String> events;
  final departures = <DateTime>[];
  final routes = <List<RouteLegModel>>[];
  Completer<ShadeAnalysisModel>? pending;
  Object? error;
  ShadeAnalysisModel result = shadeFixture();
  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async {
    events.add('shade');
    departures.add(departure);
    routes.add(legs);
    if (error != null) throw error!;
    return pending?.future ?? result;
  }
}

class _Puddle implements BasePuddleAnalysisService {
  _Puddle(this.events);
  final List<String> events;
  final departures = <DateTime>[];
  final routes = <List<RouteLegModel>>[];
  Completer<PuddleAnalysisModel>? pending;
  Object? error;
  PuddleAnalysisModel result = puddleHighFixture();
  @override
  Future<PuddleAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    events.add('puddle');
    departures.add(departure);
    routes.add(legs);
    if (error != null) throw error!;
    return pending?.future ?? result;
  }
}

class _Pollen implements BasePollenAnalysisService {
  _Pollen(this.events);
  final List<String> events;
  final departures = <DateTime>[];
  final routes = <List<RouteLegModel>>[];
  Completer<PollenAnalysisModel>? pending;
  Object? error;
  PollenAnalysisModel result = pollenConcentrationsFixture();
  @override
  Future<PollenAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeLegs = true,
  }) async {
    events.add('pollen');
    departures.add(departure);
    routes.add(legs);
    if (error != null) throw error!;
    return pending?.future ?? result;
  }
}

class _Quiet implements BaseQuietAnalysisService {
  _Quiet(this.events);
  final List<String> events;
  final assessedAt = <DateTime>[];
  final routes = <List<RouteLegModel>>[];
  Completer<QuietAnalysisModel>? pending;
  Object? error;
  QuietAnalysisModel result = QuietAnalysisModel(
    status: QuietStatus.available,
    estimate: true,
    confidence: 'low',
    method: 'relative_road_noise_exposure_proxy',
    methodVersion: 'c11_1',
    evaluatedAt: fixtureInstant,
    temporalModel: 'static_osm_network',
    trafficTimeModeled: false,
    routeLengthMeters: 1000,
    knownMeters: 1000,
    unknownMeters: 0,
    coverageShare: 1,
    roadNoiseExposureIndex: 0.3,
    lowExposureShare: 0.6,
    majorRoadAdjacentShare: 0.1,
    meanNearestRoadDistanceM: 50,
    maxRoadClassNearby: 'secondary',
    legs: null,
    reasons: const [],
    limitations: const ['Не дБ.'],
    assumptions: const ['Прокси.'],
    sourceProvenance: const {'license': 'ODbL-1.0'},
    datasetVersion: 'c11_quiet_spb_central_v1',
    datasetSha256: 'a' * 64,
  );

  @override
  Future<QuietAnalysisModel> analyzeWalk({
    required DateTime assessedAt,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeLegs = false,
  }) async {
    events.add('quiet');
    this.assessedAt.add(assessedAt);
    routes.add(legs);
    if (error != null) throw error!;
    return pending?.future ?? result;
  }
}

class _WalkMapKit extends MapKitService {
  int walkCalls = 0;
  int pointCalls = 0;
  @override
  Future<PedestrianRouteModel> calculateBoundedWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
    required NativeWalkRequestBudget requestBudget,
  }) async {
    walkCalls++;
    requestBudget.consume();
    return _route();
  }

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    pointCalls++;
    throw StateError('An environmental assessment must not request a route');
  }
}

class _ElapsedSimulation extends SimulationController {
  _ElapsedSimulation({required super.source, required super.nav});
  @override
  Duration get simulatedElapsed => const Duration(minutes: 7);
}

class _Harness {
  _Harness({
    this.clock,
    Duration timeout = const Duration(seconds: 1),
    bool factors = true,
    bool quietFactor = false,
    RoutingProvider? suppliedRouting,
  }) {
    routing =
        suppliedRouting ??
        RoutingProvider(shadeAnalysisService: shade, mapKitService: walkNative);
    if (suppliedRouting == null) install(_route());
    routing.attachShadeClock(clock);
    nav = NavigationProvider(
      locationService: location,
      routingProvider: routing,
      routeService: native,
    );
    puddle = PuddleAssessmentProvider(
      wet,
      routing: routing,
      navigation: nav,
      clock: clock,
    );
    pollen = PollenAssessmentProvider(
      grains,
      routing: routing,
      navigation: nav,
      clock: clock,
    );
    if (quietFactor) {
      quiet = QuietAssessmentProvider(
        silence,
        routing: routing,
        navigation: nav,
        clock: clock,
      );
    }
    recommendations = ContextRecommendationProvider(
      routing: routing,
      navigation: nav,
      puddle: factors ? puddle : null,
      pollen: factors ? pollen : null,
      clock: clock,
    );
    coordinator = GuidedWalkEnvironmentCoordinator(
      routing: routing,
      navigation: nav,
      recommendations: recommendations,
      puddle: factors ? puddle : null,
      pollen: factors ? pollen : null,
      quiet: quietFactor ? quiet : null,
      clock: clock,
      timeout: timeout,
      now: () => fixtureInstant,
    );
  }
  final VirtualShadeClock? clock;
  final events = <String>[];
  late final shade = _Shade(events);
  late final wet = _Puddle(events);
  late final grains = _Pollen(events);
  late final silence = _Quiet(events);
  final native = FakeRouteService();
  final walkNative = _WalkMapKit();
  final location = MockNavigationLocationService();
  late final RoutingProvider routing;
  late final NavigationProvider nav;
  late final PuddleAssessmentProvider puddle;
  late final PollenAssessmentProvider pollen;
  QuietAssessmentProvider? quiet;
  late final ContextRecommendationProvider recommendations;
  late final GuidedWalkEnvironmentCoordinator coordinator;
  void install(PedestrianRouteModel route) {
    routing.setProposedWalkForScenicTest(
      scenic: false,
      comparison: null,
      walkKind: WalkKind.normal,
      route: route,
    );
    routing.cancelStartSelection();
  }

  void dispose() {
    coordinator.dispose();
    recommendations.dispose();
    puddle.dispose();
    pollen.dispose();
    quiet?.dispose();
    nav.dispose();
    routing.dispose();
    location.close();
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'three providers run sequentially for one native snapshot and time',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.routing.setProposedWalk([poi(1)], timeBudgetMinutes: 120);
      await h.routing.buildWalkRoute();
      final original = h.routing.currentRoute;
      final phases = <GuidedWalkEnvironmentPhase>[];
      h.coordinator.addListener(() => phases.add(h.coordinator.phase));
      await h.coordinator.assess();
      expect(h.events, ['shade', 'puddle', 'pollen']);
      expect(
        phases,
        containsAllInOrder([
          GuidedWalkEnvironmentPhase.shade,
          GuidedWalkEnvironmentPhase.puddle,
          GuidedWalkEnvironmentPhase.pollen,
          GuidedWalkEnvironmentPhase.preparingReport,
          GuidedWalkEnvironmentPhase.complete,
        ]),
      );
      final report = h.coordinator.report!;
      expect(report.route, same(original));
      expect(report.evaluatedFor, fixtureInstant);
      expect(report.shade.status, GuidedWalkEnvironmentalStatus.available);
      expect(report.puddle.status, GuidedWalkEnvironmentalStatus.partial);
      expect(report.pollen.status, GuidedWalkEnvironmentalStatus.available);
      expect(report.recommendations, isNotEmpty);
      for (final times in [
        h.shade.departures,
        h.wet.departures,
        h.grains.departures,
      ]) {
        expect(times, [fixtureInstant]);
      }
      for (final routes in [h.shade.routes, h.wet.routes, h.grains.routes]) {
        expect(routes.single, same(original!.legs));
      }
      expect(h.routing.currentRoute, same(original));
      expect(
        h.native.calls,
        0,
        reason: 'environmental checks do not start navigation routing',
      );
      expect(
        h.walkNative.walkCalls,
        1,
        reason: 'only the initial preview is routed',
      );
      expect(
        h.walkNative.pointCalls,
        0,
        reason: 'shade does not explore alternatives',
      );
      expect(h.nav.locksPlanning, isFalse);
      expect(h.routing.shadeOverlayEnabled, isFalse);
      expect(h.puddle.scope, PuddleAssessmentScope.wholeWalk);
      expect(h.pollen.scope, PollenAssessmentScope.wholeWalk);
    },
  );

  test(
    'a fourth quiet factor runs after pollen on the one route and instant',
    () async {
      final h = _Harness(quietFactor: true);
      addTearDown(h.dispose);
      await h.coordinator.assess();

      expect(h.events, ['shade', 'puddle', 'pollen', 'quiet']);
      final report = h.coordinator.report!;
      expect(report.quiet.status, GuidedWalkEnvironmentalStatus.available);
      expect(report.quiet.data!.roadNoiseExposureIndex, 0.3);
      expect(report.quiet.evaluatedFor, fixtureInstant);
      expect(h.silence.assessedAt.single, fixtureInstant);
      expect(h.silence.routes.single, isNotEmpty);
      // The other three factors and the native route are untouched.
      expect(report.shade.data, isNotNull);
      expect(report.puddle.data, isNotNull);
      expect(report.pollen.data, isNotNull);
      expect(h.coordinator.phase, GuidedWalkEnvironmentPhase.complete);
    },
  );

  test(
    'duplicate presses and reopening a finished analysis make no calls',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.shade.pending = Completer();
      final first = h.coordinator.assess();
      final second = h.coordinator.assess();
      await _flush();
      expect(h.events, ['shade']);
      h.shade.pending!.complete(shadeFixture());
      await Future.wait([first, second]);
      await h.coordinator.assess();
      expect(h.events, ['shade', 'puddle', 'pollen']);
    },
  );

  test(
    'independent provider failures preserve shade and the native route',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.wet.error = StateError('offline');
      h.grains.error = StateError('offline');
      await h.coordinator.assess();
      expect(h.coordinator.report!.shade.hasEstimate, isTrue);
      expect(
        h.coordinator.report!.puddle.status,
        GuidedWalkEnvironmentalStatus.failed,
      );
      expect(
        h.coordinator.report!.pollen.status,
        GuidedWalkEnvironmentalStatus.failed,
      );
      expect(h.events, ['shade', 'puddle', 'pollen']);
      expect(h.routing.hasRoute, isTrue);
    },
  );

  test('all failures finish and never turn absence into zero', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.shade.error = StateError('offline');
    h.wet.error = StateError('offline');
    h.grains.error = StateError('offline');
    await h.coordinator.assess();
    final report = h.coordinator.report!;
    expect(report.shade.data, isNull);
    expect(report.puddle.data, isNull);
    expect(report.pollen.data, isNull);
    expect(h.routing.isAssessingShade, isFalse);
    expect(h.coordinator.isRunning, isFalse);
    expect(report.coverageWarning, isNull);
  });

  test('missing optional providers yield honest unavailable results', () async {
    final h = _Harness(factors: false);
    addTearDown(h.dispose);
    await h.coordinator.assess();
    expect(h.events, ['shade']);
    expect(
      h.coordinator.report!.puddle.status,
      GuidedWalkEnvironmentalStatus.unavailable,
    );
    expect(
      h.coordinator.report!.pollen.status,
      GuidedWalkEnvironmentalStatus.unavailable,
    );
  });

  test('zero puddle coverage keeps null index and the source reason', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.wet.result = puddleUnknownFixture();
    await h.coordinator.assess();
    final result = h.coordinator.report!.puddle;
    expect(result.status, GuidedWalkEnvironmentalStatus.unavailable);
    expect(result.data!.coverageShare, 0);
    expect(result.data!.riskIndex, isNull);
    expect(result.message, contains('История осадков неполная'));
    expect(
      h.coordinator.report!.coverageWarning,
      isNull,
      reason: 'missing weather is not geographic evidence',
    );
  });

  test(
    'valid pollen concentration zero is retained with all six species',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.coordinator.assess();
      final data = h.coordinator.report!.pollen.data!;
      expect(data.species, hasLength(6));
      expect(data.species.first.meanConcentration, 0.0);
      expect(data.species.first.concentrationLabel, contains('0'));
      expect(h.coordinator.report!.pollen.hasEstimate, isTrue);
    },
  );

  for (final reasons in <List<String>>[
    const ['weather_unavailable'],
    const [],
  ]) {
    test(
      'zero coverage explains unavailable weather for reasons $reasons',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        h.wet.result = _noWeatherPuddle(reasons);
        await h.coordinator.assess();
        expect(
          h.coordinator.report!.puddle.message,
          'Погодный источник недоступен.',
        );
        expect(h.coordinator.report!.puddle.data!.riskIndex, isNull);
        expect(h.coordinator.report!.coverageWarning, isNull);
      },
    );
  }

  test(
    'pollen outside model cell produces a factual coverage warning',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.grains.result = _outsidePollen();
      await h.coordinator.assess();
      expect(h.coordinator.report!.pollen.hasEstimate, isFalse);
      expect(
        h.coordinator.report!.pollen.message,
        contains('модельной ячейки'),
      );
      expect(h.coordinator.report!.coverageWarning, isNotNull);
      expect(h.routing.hasRoute, isTrue);
    },
  );

  test(
    'timeout cancels provider publication and continues remaining checks',
    () async {
      final h = _Harness(timeout: const Duration(milliseconds: 10));
      addTearDown(h.dispose);
      h.shade.pending = Completer();
      await h.coordinator.assess();
      expect(
        h.coordinator.report!.shade.status,
        GuidedWalkEnvironmentalStatus.timedOut,
      );
      expect(h.coordinator.report!.pollen.hasEstimate, isTrue);
      expect(h.routing.isAssessingShade, isFalse);
      h.shade.pending!.complete(shadeFixture());
      await _flush();
      expect(h.routing.shadeAnalysis, isNull);
      expect(h.coordinator.report!.shade.data, isNull);
    },
  );

  test('retry one failed factor does not rerun completed providers', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.wet.error = StateError('offline');
    await h.coordinator.assess();
    final shade = h.coordinator.shade.data;
    final pollen = h.coordinator.pollen.data;
    h.wet.error = null;
    await h.coordinator.retry(GuidedWalkEnvironmentalFactor.puddle);
    expect(h.events, ['shade', 'puddle', 'pollen', 'puddle']);
    expect(h.coordinator.report!.shade.data, same(shade));
    expect(h.coordinator.report!.pollen.data, same(pollen));
    expect(h.coordinator.report!.puddle.hasEstimate, isTrue);
    expect(h.wet.departures, [fixtureInstant, fixtureInstant]);
  });

  test(
    'changing departure invalidates the report and all factor summaries',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.coordinator.assess();
      final next = fixtureInstant.add(const Duration(hours: 1));
      h.coordinator.selectDeparture(next);
      expect(h.coordinator.report, isNull);
      expect(h.coordinator.shade.data, isNull);
      await h.coordinator.assess();
      expect(h.coordinator.report!.evaluatedFor, next);
      expect(h.shade.departures.last, next);
      expect(h.wet.departures.last, next);
      expect(h.grains.departures.last, next);
    },
  );

  test('route replacement removes report and drops old response', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.wet.pending = Completer();
    final pending = h.coordinator.assess();
    await _flush();
    expect(h.events, ['shade', 'puddle']);
    h.install(_route());
    await pending;
    expect(h.coordinator.phase, GuidedWalkEnvironmentPhase.stale);
    expect(h.coordinator.report, isNull);
    h.wet.pending!.complete(puddleHighFixture());
    await _flush();
    expect(h.puddle.analysis, isNull);
    expect(h.events, ['shade', 'puddle']);
  });

  test(
    'navigation start during a check invalidates whole-walk report',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.shade.pending = Completer();
      final pending = h.coordinator.assess();
      await _flush();
      h.routing.setNavigationLocked(true);
      await pending;
      expect(h.coordinator.phase, GuidedWalkEnvironmentPhase.stale);
      expect(h.coordinator.isRunning, isFalse);
      h.shade.pending!.complete(shadeFixture());
      await _flush();
      expect(h.events, ['shade']);
      expect(h.coordinator.report, isNull);
    },
  );

  test(
    'cancel and skip end loading and never clear the native route',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final route = h.routing.currentRoute;
      h.shade.pending = Completer();
      final pending = h.coordinator.assess();
      await _flush();
      h.coordinator.cancel();
      await pending;
      expect(h.coordinator.phase, GuidedWalkEnvironmentPhase.cancelled);
      expect(h.coordinator.isRunning, isFalse);
      h.shade.pending!.complete(shadeFixture());
      await _flush();
      h.coordinator.skip();
      expect(h.coordinator.shade.status, GuidedWalkEnvironmentalStatus.skipped);
      expect(h.routing.currentRoute, same(route));
    },
  );

  test(
    'shared virtual clock stays coherent for all factors and shade retry',
    () async {
      final clock = VirtualShadeClock();
      addTearDown(clock.dispose);
      final h = _Harness(clock: clock);
      addTearDown(h.dispose);
      // The real clock re-reads the diagnostic controller when armed.
      final simulation = _ElapsedSimulation(
        source: SimulatedLocationSource(),
        nav: h.nav,
      );
      clock.attach(simulation);
      addTearDown(simulation.dispose);
      await h.coordinator.assess();
      final evaluated = fixtureInstant.add(const Duration(minutes: 7));
      expect(h.coordinator.report!.evaluatedFor, evaluated);
      expect(h.shade.departures.single, evaluated);
      expect(h.wet.departures.single, evaluated);
      expect(h.grains.departures.single, evaluated);
      expect(clock.analyzedFor, evaluated);
      await h.coordinator.retry(GuidedWalkEnvironmentalFactor.shade);
      expect(h.coordinator.report!.puddle.hasEstimate, isTrue);
      expect(h.coordinator.report!.pollen.hasEstimate, isTrue);
      expect(h.shade.departures.last, evaluated);
      expect(h.wet.departures, hasLength(1));
    },
  );

  test('clock movement between checks cancels the generation', () async {
    final clock = VirtualShadeClock();
    addTearDown(clock.dispose);
    final h = _Harness(clock: clock);
    addTearDown(h.dispose);
    h.wet.pending = Completer();
    final pending = h.coordinator.assess();
    await _flush();
    clock.onSimulationTick(const Duration(minutes: 1));
    await pending;
    expect(h.coordinator.phase, GuidedWalkEnvironmentPhase.stale);
    h.wet.pending!.complete(puddleHighFixture());
    await _flush();
    expect(h.coordinator.report, isNull);
    expect(h.events, ['shade', 'puddle']);
  });

  test(
    'external time selection removes a finished report immediately',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.coordinator.assess();
      h.pollen.selectDeparture(fixtureInstant.add(const Duration(hours: 1)));
      expect(h.coordinator.report, isNull);
      expect(h.coordinator.phase, GuidedWalkEnvironmentPhase.stale);
    },
  );

  test(
    'draft provider adoption retains provenance without new requests',
    () async {
      final target = _Harness();
      addTearDown(target.dispose);
      final source = _Harness(
        suppliedRouting: target.routing.createGuidedDraft()!,
      );
      addTearDown(source.dispose);
      source.routing.setProposedWalk([poi(1)], timeBudgetMinutes: 120);
      await source.routing.buildWalkRoute();
      await source.coordinator.assess();
      expect(target.routing.commitGuidedDraft(source.routing), isTrue);
      expect(target.puddle.adoptWholeWalkAssessmentFrom(source.puddle), isTrue);
      expect(target.pollen.adoptWholeWalkAssessmentFrom(source.pollen), isTrue);
      expect(
        target.routing.adoptWholeWalkShadeAssessmentFrom(source.routing),
        isTrue,
      );
      expect(target.puddle.analysis, same(source.puddle.analysis));
      expect(target.pollen.analysis, same(source.pollen.analysis));
      expect(target.puddle.assessedRoute, same(target.routing.currentRoute));
      expect(target.pollen.evaluatedFor, fixtureInstant);
      expect(target.wet.departures, isEmpty);
      expect(target.grains.departures, isEmpty);
      expect(target.recommendations.context.puddle, isNotNull);
      expect(target.recommendations.context.pollen, isNotNull);
      expect(target.recommendations.context.shade, isNotNull);
      expect(target.recommendations.recommendations, isNotEmpty);
      expect(
        target.routing.currentRoute,
        same(source.coordinator.report!.route),
      );
      expect(target.routing.shadeOverlayEnabled, isFalse);
      target.routing.setShadeOverlayEnabled(true);
      expect(target.routing.shadeOverlayReady, isTrue);
      expect(target.nav.locksPlanning, isFalse);
      source.coordinator.dispose();
      expect(target.puddle.analysis, isNotNull);
      expect(target.pollen.analysis, isNotNull);
      expect(target.routing.shadeAnalysis, isNotNull);
    },
  );

  test(
    'adoption rejects different route, navigation and incompatible clock',
    () async {
      final clock = VirtualShadeClock();
      addTearDown(clock.dispose);
      final target = _Harness(clock: clock);
      addTearDown(target.dispose);
      final source = _Harness(
        suppliedRouting: target.routing.createGuidedDraft()!,
      );
      addTearDown(source.dispose);
      source.routing.setProposedWalk([poi(1)], timeBudgetMinutes: 120);
      await source.routing.buildWalkRoute();
      await source.coordinator.assess();
      expect(
        target.puddle.adoptWholeWalkAssessmentFrom(source.puddle),
        isFalse,
      );
      expect(target.routing.commitGuidedDraft(source.routing), isTrue);
      clock.arm(fixtureInstant.add(const Duration(hours: 1)));
      expect(
        target.pollen.adoptWholeWalkAssessmentFrom(source.pollen),
        isFalse,
      );
      clock.arm(fixtureInstant);
      target.routing.setNavigationLocked(true);
      expect(
        target.puddle.adoptWholeWalkAssessmentFrom(source.puddle),
        isFalse,
      );
      expect(
        target.pollen.adoptWholeWalkAssessmentFrom(source.pollen),
        isFalse,
      );
      target.routing.setNavigationLocked(false);
      expect(target.puddle.adoptWholeWalkAssessmentFrom(source.puddle), isTrue);
      expect(target.pollen.adoptWholeWalkAssessmentFrom(source.pollen), isTrue);
    },
  );

  test(
    'late response from an old time cannot replace the new walk report',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final old = Completer<PuddleAnalysisModel>();
      h.wet.pending = old;
      final first = h.coordinator.assess();
      await _flush();
      final next = fixtureInstant.add(const Duration(hours: 1));
      h.coordinator.selectDeparture(next);
      await first;
      h.wet.pending = null;
      h.wet.result = puddleNoHighFixture();
      await h.coordinator.assess();
      final report = h.coordinator.report!;
      old.complete(puddleHighFixture());
      await _flush();
      expect(h.coordinator.report, same(report));
      expect(report.evaluatedFor, next);
      expect(report.puddle.data, same(h.wet.result));
      expect(h.puddle.analysis, same(h.wet.result));
    },
  );

  test(
    'disposing a pending coordinator releases loading without a late report',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.shade.pending = Completer();
      final pending = h.coordinator.assess();
      await _flush();
      h.coordinator.dispose();
      await pending;
      h.shade.pending!.complete(shadeFixture());
      await _flush();
      expect(h.routing.isAssessingShade, isFalse);
      expect(h.routing.shadeAnalysis, isNull);
      expect(h.coordinator.report, isNull);
    },
  );

  test('self-adoption preserves valid factor estimates', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.coordinator.assess();
    final wet = h.puddle.analysis;
    final grains = h.pollen.analysis;
    expect(h.puddle.adoptWholeWalkAssessmentFrom(h.puddle), isTrue);
    expect(h.pollen.adoptWholeWalkAssessmentFrom(h.pollen), isTrue);
    expect(h.puddle.analysis, same(wet));
    expect(h.pollen.analysis, same(grains));
  });

  test(
    'cancellation from a progress listener prevents the pending provider call',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.coordinator.addListener(() {
        if (h.coordinator.phase == GuidedWalkEnvironmentPhase.shade) {
          h.coordinator.cancel();
        }
      });
      await h.coordinator.assess();
      expect(h.events, isEmpty);
      expect(h.coordinator.phase, GuidedWalkEnvironmentPhase.cancelled);
      expect(h.coordinator.report, isNull);
    },
  );
}

PollenAnalysisModel _outsidePollen() {
  final base = pollenSourceOffFixture();
  return PollenAnalysisModel(
    status: PollenStatus.outsideCoverage,
    method: base.method,
    methodVersion: base.methodVersion,
    confidence: base.confidence,
    periodStart: base.periodStart,
    periodEnd: base.periodEnd,
    timezoneName: base.timezoneName,
    routeLengthMeters: base.routeLengthMeters,
    knownMeters: 0,
    unknownMeters: base.unknownMeters,
    coverageShare: 0,
    walkingDurationSeconds: base.walkingDurationSeconds,
    elapsedDurationSeconds: base.elapsedDurationSeconds,
    concentrationUnit: base.concentrationUnit,
    species: base.species,
    legs: null,
    reasons: const ['outside_source_cell'],
    limitations: base.limitations,
    assumptions: base.assumptions,
    source: base.source,
  );
}

PuddleAnalysisModel _noWeatherPuddle(List<String> reasons) {
  final base = puddleUnknownFixture();
  return PuddleAnalysisModel(
    status: base.status,
    method: base.method,
    methodVersion: base.methodVersion,
    risk: base.risk,
    riskIndex: null,
    routeLengthMeters: base.routeLengthMeters,
    knownMeters: 0,
    unknownMeters: base.unknownMeters,
    lowMeters: 0,
    moderateMeters: 0,
    highMeters: 0,
    coverageShare: 0,
    confidence: base.confidence,
    periodStart: base.periodStart,
    periodEnd: base.periodEnd,
    timezoneName: base.timezoneName,
    datasetVersion: base.datasetVersion,
    datasetSource: base.datasetSource,
    datasetLicense: base.datasetLicense,
    weather: base.weather,
    reasons: reasons,
    limitations: base.limitations,
  );
}
