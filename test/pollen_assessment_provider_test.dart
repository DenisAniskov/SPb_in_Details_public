import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/simulated_location_source.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';

import 'off_route_reroute_test.dart' show FakeRouteService;
import 'simulated_location_source_test.dart' show SimClock;

// --------------------------------------------------------------------------
// Phase C7.3 provider semantics: an assessment belongs to ONE route and ONE
// time. A changed plan, a rebuilt route, a time change or a navigation session
// must invalidate it — including a request still in flight. None of this may
// ever touch the walk, the lock or the navigation session, and pollen is never
// combined with any other score.
// --------------------------------------------------------------------------

const _p0 = GeoCoord(59.9300, 30.3100);
const _v0 = GeoCoord(59.9435, 30.3200);
const _p1 = GeoCoord(59.9525, 30.3270);
const _p2 = GeoCoord(59.9705, 30.3400);

final _departure = DateTime(2026, 7, 1, 14);

PedestrianRouteModel _walkRoute({GeoCoord first = _p0}) {
  final legs = [
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'POI 1',
      distanceMeters: 2500,
      durationSeconds: 1800,
      geometryPoints: [first, _v0, _p1],
      visitMinutes: 15,
    ),
    const RouteLegModel(
      fromTitle: 'POI 1',
      toTitle: 'Финиш',
      distanceMeters: 2000,
      durationSeconds: 1440,
      geometryPoints: [_p1, _p2],
    ),
  ];
  return PedestrianRouteModel(
    distanceMeters: legs.fold(0.0, (sum, leg) => sum + leg.distanceMeters),
    durationSeconds: legs.fold(0, (sum, leg) => sum + leg.durationSeconds),
    geometryPoints: [first, _v0, _p1, _p2],
    steps: const [],
    legs: legs,
    placesCount: 2,
  );
}

PollenSpeciesModel _species(String code, String name) => PollenSpeciesModel(
  code: code,
  name: name,
  unit: 'grains/m³',
  state: PollenSpeciesState.available,
  knownSeconds: 3240,
  totalSeconds: 3240,
  knownShare: 1,
  meanConcentration: 12.6,
  peakConcentration: 34.2,
  peakAt: '2026-07-01T11:00:00+00:00',
  exposureGrainsHoursPerM3: 11.34,
);

PollenAnalysisModel _analysis() => PollenAnalysisModel(
  status: PollenStatus.available,
  method: 'experimental_pollen_exposure',
  methodVersion: 'c7_3.1',
  confidence: 'low',
  periodStart: _departure,
  periodEnd: _departure.add(const Duration(minutes: 54)),
  timezoneName: '+03:00',
  routeLengthMeters: 1000,
  knownMeters: 1000,
  unknownMeters: 0,
  coverageShare: 1,
  walkingDurationSeconds: 3240,
  elapsedDurationSeconds: 3240,
  concentrationUnit: 'grains/m³',
  species: [
    _species('birch_pollen', 'Берёза'),
    _species('grass_pollen', 'Злаки'),
  ],
  legs: null,
  reasons: const ['modeled_pollen_concentration'],
  limitations: const ['Это концентрации, а не прогноз симптомов.'],
  assumptions: const ['Концентрация постоянна внутри часа [t, t+1h).'],
  source: PollenSourceModel(
    available: true,
    provider: 'Open-Meteo',
    model: 'cams_europe',
    modelName: 'CAMS European Air Quality Forecast (CAMS ENSEMBLE)',
    kind: 'modeled_forecast_and_recent_archived_forecast',
    license: 'CC-BY-4.0',
    attribution: 'Pollen data by Open-Meteo.com; CAMS ENSEMBLE model',
    sourceUrl: 'https://open-meteo.com/en/docs/air-quality-api',
    retrievedAt: _departure,
    validUntil: _departure.add(const Duration(hours: 1)),
    intervalStart: _departure.subtract(const Duration(hours: 1)),
    intervalEnd: _departure.add(const Duration(days: 4)),
    temporalResolutionSeconds: 3600,
    spatialResolutionMeters: 11000,
    gridStepDegrees: 0.1,
    cellLatitude: 59.9,
    cellLongitude: 30.3,
    cellBounds: const [59.85, 30.25, 59.95, 30.35],
    timeSemantics: 'instantaneous concentration valid for the indicated hour',
    reason: null,
  ),
);

class _NoopShadeService implements BaseShadeAnalysisService {
  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async => throw StateError('shade is not exercised in C7.3 tests');
}

/// Returns one prepared route for the external-point flow, so a route REBUILD
/// exercises the same notifying code path the production UI uses.
class _FakeMapKit extends MapKitService {
  _FakeMapKit(this.route);

  final PedestrianRouteModel route;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async => route;
}

class _RecordingPollenService implements BasePollenAnalysisService {
  final List<DateTime> departures = [];
  final List<List<RouteLegModel>> legs = [];
  final List<List<int>> visits = [];
  Object? failure;
  Completer<PollenAnalysisModel>? pending;

  @override
  Future<PollenAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    departures.add(departure);
    this.legs.add(List.of(legs));
    visits.add(List.of(visitMinutesAfterLeg));
    final pending = this.pending;
    if (pending != null) return pending.future;
    final thrown = failure;
    if (thrown != null) throw thrown;
    return _analysis();
  }
}

void main() {
  late SimClock simClock;
  late SimulatedLocationSource source;
  late _RecordingPollenService service;
  late RoutingProvider routing;
  late NavigationProvider nav;
  late SimulationController controller;
  late PollenAssessmentProvider provider;

  setUp(() {
    simClock = SimClock();
    UserLocationSnapshot.clock = simClock.call;
    source = SimulatedLocationSource(clock: simClock.call);
    service = _RecordingPollenService();
    routing = RoutingProvider(shadeAnalysisService: _NoopShadeService())
      ..setProposedWalkForScenicTest(
        scenic: false,
        comparison: null,
        walkKind: WalkKind.normal,
        route: _walkRoute(),
      );
    nav = NavigationProvider(
      locationService: source,
      routingProvider: routing,
      routeService: FakeRouteService(),
    );
    controller = SimulationController(
      source: source,
      nav: nav,
      tickInterval: const Duration(hours: 1),
    );
    provider = PollenAssessmentProvider(
      service,
      routing: routing,
      navigation: nav,
      now: () => _departure,
    );
  });

  tearDown(() {
    provider.dispose();
    controller.dispose();
    UserLocationSnapshot.clock = DateTime.now;
    nav.dispose();
    routing.dispose();
  });

  Future<void> step(double seconds) async {
    simClock.advance(Duration(milliseconds: (seconds * 1000).round()));
    controller.tickOnceForTesting(deltaSimSeconds: seconds);
    await Future<void>.delayed(Duration.zero);
  }

  test('without a route nothing is assessed and nothing is sent', () async {
    final bare = PollenAssessmentProvider(
      service,
      routing: RoutingProvider(shadeAnalysisService: _NoopShadeService()),
      navigation: nav,
      now: () => _departure,
    );
    expect(bare.canAssess, isFalse);
    await bare.assess();
    expect(service.departures, isEmpty);
    bare.dispose();
  });

  test('the plan is assessed whole, with real legs and visit times', () async {
    await provider.assess();
    expect(provider.scope, PollenAssessmentScope.wholeWalk);
    expect(provider.analysis, isNotNull);
    expect(provider.failure, isNull);
    expect(provider.isLoading, isFalse);
    expect(service.departures.single, _departure);
    expect(service.legs.single.map((leg) => leg.toTitle), ['POI 1', 'Финиш']);
    expect(service.visits.single, [
      15,
      0,
    ], reason: 'осмотр промежуточной остановки сдвигает последующие этапы');
    expect(provider.evaluatedFor, _departure);
    expect(provider.modelTime, isNull);
    expect(provider.usesSharedSimulationTime, isFalse);
  });

  test('selecting a departure time re-evaluates from that time', () async {
    final clock = VirtualShadeClock();
    final withClock = PollenAssessmentProvider(
      service,
      routing: routing,
      navigation: nav,
      clock: clock,
      now: () => DateTime(2030),
    );
    withClock.selectDeparture(_departure.add(const Duration(hours: 5)));
    expect(clock.departure, _departure.add(const Duration(hours: 5)));
    await withClock.assess();
    expect(
      service.departures.single,
      _departure.add(const Duration(hours: 5)),
      reason: 'виртуальные часы — источник времени оценки',
    );
    withClock.dispose();
    clock.dispose();
  });

  test('a time change is the shared simulation time: the shade estimate goes '
      'to needs-reanalysis instead of staying stale', () async {
    final clock = VirtualShadeClock();
    final withClock = PollenAssessmentProvider(
      service,
      routing: routing,
      navigation: nav,
      clock: clock,
      now: () => DateTime(2030),
    );
    expect(withClock.usesSharedSimulationTime, isTrue);
    expect(provider.usesSharedSimulationTime, isFalse);

    clock.arm(_departure);
    clock.overlayRequested = true;
    clock.markAnalyzed(_departure);
    expect(clock.overlayValid, isTrue);
    expect(clock.needsReanalysis, isFalse);

    final earlier = _departure.subtract(const Duration(hours: 5));
    withClock.selectDeparture(earlier);
    await withClock.assess();

    expect(clock.departure, earlier);
    expect(
      clock.analyzedFor,
      isNull,
      reason: 'оценка тени для другого виртуального времени не сохраняется',
    );
    expect(clock.needsReanalysis, isTrue);
    expect(
      clock.overlayValid,
      isFalse,
      reason: 'устаревший слой тени не показывается на карте',
    );
    expect(service.departures.single, earlier);
    expect(withClock.analysis, isNotNull);

    // Re-picking the SAME instant is not a change: nothing is reset.
    withClock.selectDeparture(earlier);
    expect(withClock.analysis, isNotNull);
    expect(clock.overlayValid, isFalse);
    withClock.dispose();
    clock.dispose();
  });

  test('a rebuilt route invalidates the stored result', () async {
    final rebuiltRouting =
        RoutingProvider(
          mapKitService: _FakeMapKit(
            _walkRoute(first: const GeoCoord(59.9350, 30.3150)),
          ),
          shadeAnalysisService: _NoopShadeService(),
        )..setProposedWalkForScenicTest(
          scenic: false,
          comparison: null,
          walkKind: WalkKind.normal,
          route: _walkRoute(),
        );
    final rebuiltProvider = PollenAssessmentProvider(
      service,
      routing: rebuiltRouting,
      navigation: nav,
      now: () => _departure,
    );
    await rebuiltProvider.assess();
    expect(rebuiltProvider.analysis, isNotNull);

    // A real rebuild through the production code path (notifying setter).
    await rebuiltRouting.buildRouteToExternalPoint(
      const ExternalMapPoint(
        title: 'Новая цель',
        latitude: 59.9500,
        longitude: 30.3300,
      ),
    );

    expect(
      rebuiltProvider.analysis,
      isNull,
      reason: 'оценка для другого маршрута не показывается',
    );
    expect(rebuiltProvider.failure, isNull);
    rebuiltProvider.dispose();
    rebuiltRouting.dispose();
  });

  test('a response still in flight is discarded after invalidation', () async {
    service.pending = Completer<PollenAnalysisModel>();
    final future = provider.assess();
    expect(provider.isLoading, isTrue);
    provider.clear();
    service.pending!.complete(_analysis());
    await future;
    expect(provider.analysis, isNull);
    expect(provider.isLoading, isFalse);
  });

  test('during a real walk only the remaining path is assessed', () async {
    final plannedRoute = routing.currentRoute!;
    await controller.startWithRoute(plannedRoute);
    expect(routing.navigationLocked, isTrue);
    for (var i = 0; i < 6; ++i) {
      await step(60);
    }
    expect(nav.state.currentLocation, isNotNull);
    final remaining = nav.buildRemainingRoute()!;

    await provider.assess();

    expect(provider.scope, PollenAssessmentScope.remainingPath);
    final sent = service.legs.single;
    expect(
      sent.first.geometryPoints.first.latitude,
      closeTo(remaining.geometryPoints.first.latitude, 1e-9),
      reason: 'оценивается оставшийся путь от текущей точки, не весь план',
    );
    expect(
      sent.first.geometryPoints.length,
      3,
      reason: 'внутренний поворот впереди сохраняется',
    );
    expect(service.departures.single, provider.evaluatedFor);
    // The walk itself is untouched by the assessment.
    final held = nav.state.route!;
    expect(identical(held, routing.navigationRoute), isTrue);
    expect(held.geometryPoints.length, plannedRoute.geometryPoints.length);
    expect(
      held.geometryPoints.last.latitude,
      plannedRoute.geometryPoints.last.latitude,
    );
    expect(held.legs.length, plannedRoute.legs.length);
    expect(routing.navigationLocked, isTrue);
    expect(nav.isActive, isTrue);
  });

  test('choosing a new departure time is ignored during navigation', () async {
    await controller.startWithRoute(routing.currentRoute!);
    await step(60);
    expect(provider.navigating, isTrue);
    provider.selectDeparture(_departure.add(const Duration(days: 1)));
    expect(
      provider.selectedDeparture,
      isNull,
      reason: 'во время прогулки время не переписывается',
    );
  });

  test(
    'a service failure leaves the walk, the lock and the route untouched',
    () async {
      final plannedRoute = routing.currentRoute!;
      await controller.startWithRoute(plannedRoute);
      await step(60);
      service.failure = const PollenAnalysisFailure(
        PollenAnalysisFailureKind.serviceUnavailable,
        'Оценка пыльцы сейчас недоступна. Обычная навигация работает.',
      );
      await provider.assess();
      expect(provider.analysis, isNull);
      expect(provider.failure, isNotNull);
      expect(provider.failure!.message, contains('Обычная навигация работает'));
      expect(provider.isLoading, isFalse);
      expect(nav.isActive, isTrue);
      expect(routing.navigationLocked, isTrue);
      expect(identical(nav.state.route, routing.navigationRoute), isTrue);
      expect(
        nav.state.route!.geometryPoints.length,
        plannedRoute.geometryPoints.length,
      );

      // Recovery: the same session re-assesses cleanly afterwards.
      service.failure = null;
      await provider.assess();
      expect(provider.analysis, isNotNull);
      expect(provider.failure, isNull);
    },
  );

  test(
    'an unexpected service error becomes a typed unavailable failure',
    () async {
      service.failure = StateError('boom');
      await provider.assess();
      expect(provider.analysis, isNull);
      expect(
        provider.failure!.kind,
        PollenAnalysisFailureKind.serviceUnavailable,
      );
      expect(provider.failure!.message, contains('Обычная навигация работает'));
    },
  );

  test(
    'the assessment exposes only pollen: no combined risk is produced',
    () async {
      await provider.assess();
      final analysis = provider.analysis!;
      expect(analysis.species, isNotEmpty);
      // Species are reported separately; nothing on the model aggregates them.
      expect(
        analysis.species
            .map((item) => item.meanConcentration)
            .whereType<double>(),
        hasLength(analysis.species.length),
      );
      final total = analysis.species
          .map((item) => item.meanConcentration ?? 0)
          .fold<double>(0, (sum, value) => sum + value);
      expect(total, greaterThan(0));
      expect(analysis.knownMeters, isNot(total));
      // The provider never touches shade or puddle state.
      expect(provider.usesSharedSimulationTime, isFalse);
    },
  );
}
