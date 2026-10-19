import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/simulated_location_source.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';

import 'off_route_reroute_test.dart' show FakeRouteService;
import 'simulated_location_source_test.dart' show SimClock;

// --------------------------------------------------------------------------
// Phase C7.1.2: the shade refresh INSIDE a real navigation session.
//
// The isolated-clock widget test cannot see this: it advances virtual time by
// hand and never starts a session, so `navigationLocked` is never raised and
// the section stays reachable by accident. These tests drive the REAL
// NavigationProvider + SimulationController stack — the C4.1 engine with its
// own GPS gates, progress and arrival rules — and check that a stale shade
// layer is both withdrawn and refreshable mid-walk, with the route, the
// geometry and the planning lock untouched.
// --------------------------------------------------------------------------

/// ~2.7 km first leg with an interior vertex still ahead of the 16-minute mark
/// (a remaining path must keep it), then a ~2 km final leg. The walk runs
/// diagonally on purpose: a perpendicular deviation on a due-north line would
/// shift the walker ALONG the route and prove nothing.
const _p0 = GeoCoord(59.9300, 30.3100);
const _v0 = GeoCoord(59.9435, 30.3200); // ≈1600 m along leg 0
const _p1 = GeoCoord(59.9525, 30.3270); // leg 0 end ≈2673 m
const _p2 = GeoCoord(59.9705, 30.3400); // leg 1 end ≈3105 m

final _departure = DateTime(2026, 7, 1, 14);

PedestrianRouteModel _walkRoute() {
  const first = RouteLegModel(
    fromTitle: 'Старт',
    toTitle: 'POI 1',
    distanceMeters: 2500,
    durationSeconds: 1800,
    geometryPoints: [_p0, _v0, _p1],
    visitMinutes: 15,
  );
  const second = RouteLegModel(
    fromTitle: 'POI 1',
    toTitle: 'Финиш',
    distanceMeters: 2000,
    durationSeconds: 1440,
    geometryPoints: [_p1, _p2],
  );
  final legs = [first, second];
  return PedestrianRouteModel(
    distanceMeters: legs.fold(0.0, (sum, leg) => sum + leg.distanceMeters),
    durationSeconds: legs.fold(0, (sum, leg) => sum + leg.durationSeconds),
    geometryPoints: const [_p0, _v0, _p1, _p2],
    steps: const [],
    legs: legs,
    placesCount: 2,
  );
}

ShadeAnalysisModel _analysis({double shaded = 300, double exposed = 700}) {
  final total = shaded + exposed;
  return ShadeAnalysisModel(
    status: ShadeStatus.available,
    method: 'test',
    methodVersion: 'test',
    periodStart: _departure,
    periodEnd: _departure.add(const Duration(hours: 1)),
    timezoneName: 'MSK',
    datasetVersion: 'c7_1_pilot_v1',
    datasetProvenance: 'OpenStreetMap (ODbL).',
    solar: const ShadeSolarSummaryModel(
      minElevationDeg: 40,
      maxElevationDeg: 52,
      minAzimuthDeg: 180,
      maxAzimuthDeg: 220,
      bucketCount: 2,
    ),
    routeLengthMeters: total,
    shadedMeters: shaded,
    exposedMeters: exposed,
    unknownMeters: 0,
    shadeFraction: shaded / total,
    confidence: ShadeConfidence.medium,
    limitations: const ['Тестовое ограничение модели.'],
    segments: const [],
    reason: null,
    datasetZonesTouched: const ['centre_palace'],
    outsideCoverageMeters: 0,
    coverageShare: 1,
    heightProvenance: const ShadeHeightProvenanceModel(),
  );
}

/// Records exactly what the backend would have been asked for.
class _RecordingShadeService implements BaseShadeAnalysisService {
  final List<DateTime> departures = [];
  final List<List<RouteLegModel>> legs = [];
  final List<List<int>> visits = [];

  /// Set by a test so the next call fails like the real service does
  /// (Phase A6.5: a shade timeout is a service problem, never a route problem).
  Object? failure;

  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async {
    departures.add(departure);
    this.legs.add(List.of(legs));
    visits.add(List.of(visitMinutesAfterLeg));
    final thrown = failure;
    if (thrown != null) throw thrown;
    return _analysis();
  }
}

void main() {
  late SimClock simClock;
  late SimulatedLocationSource source;
  late _RecordingShadeService shade;
  late FakeRouteService routeService;
  late RoutingProvider routing;
  late NavigationProvider nav;
  late SimulationController controller;
  late VirtualShadeClock clock;
  StreamSubscription<UserLocationSnapshot>? emissionCounter;
  int emitted = 0;

  setUp(() {
    simClock = SimClock();
    // Fix freshness must follow the simulated clock, exactly like a device.
    UserLocationSnapshot.clock = simClock.call;
    source = SimulatedLocationSource(clock: simClock.call);
    shade = _RecordingShadeService();
    routeService = FakeRouteService();
    routing = RoutingProvider(shadeAnalysisService: shade)
      ..setProposedWalkForScenicTest(
        scenic: false,
        comparison: null,
        walkKind: WalkKind.normal,
        route: _walkRoute(),
      );
    nav = NavigationProvider(
      locationService: source,
      routingProvider: routing,
      routeService: routeService,
    );
    controller = SimulationController(
      source: source,
      nav: nav,
      // Deterministic path: tests step manually, the real timer never fires.
      tickInterval: const Duration(hours: 1),
    );
    clock = VirtualShadeClock(controller: controller);
    routing.attachShadeClock(clock);
    emitted = 0;
    emissionCounter = source.getPositionStream().listen((_) => emitted++);
  });

  tearDown(() async {
    await emissionCounter?.cancel();
    controller.dispose();
    clock.dispose();
    UserLocationSnapshot.clock = DateTime.now;
    nav.dispose();
    routing.dispose();
  });

  /// One deterministic simulation step of [seconds] of simulated time; the
  /// simulated clock advances with it so fix timestamps behave like a real
  /// device's.
  Future<void> step(double seconds) async {
    simClock.advance(Duration(milliseconds: (seconds * 1000).round()));
    controller.tickOnceForTesting(deltaSimSeconds: seconds);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> walkSixteenMinutes() async {
    // 16 virtual minutes at 5 km/h ≈ 1.33 km: past the documented 15-minute
    // refresh step, still inside the first leg.
    for (var i = 0; i < 16; ++i) {
      await step(60);
    }
  }

  test('mid-walk: the withdrawn layer is refreshed without lifting the lock', () async {
    // 1. The plan: the whole walk, evaluated from its chosen start.
    routing.setShadeOverlayEnabled(true);
    await routing.assessShade(departure: _departure);
    expect(shade.departures.single, _departure);
    expect(shade.legs.single.map((l) => l.toTitle), ['POI 1', 'Финиш']);
    expect(routing.shadeScope, ShadeAssessmentScope.wholeWalk);
    expect(routing.shadeOverlayReady, isTrue);
    final plannedRoute = routing.currentRoute!;

    // 2. A REAL navigation session (the C4.1 engine, not a stub).
    await controller.startWithRoute(plannedRoute);
    expect(nav.isActive, isTrue);
    expect(routing.navigationLocked, isTrue);
    expect(identical(routing.navigationRoute, nav.state.route), isTrue,
        reason: 'сессия передала провайдеру свою замороженную геометрию');

    // 3. Sixteen virtual minutes: the layer is withdrawn, the lock stays.
    await walkSixteenMinutes();
    expect(emitted, greaterThan(0), reason: 'движок получал реальные фиксы');
    expect(clock.modelTime, _departure.add(const Duration(minutes: 16)));
    expect(nav.state.progressOnCurrentLegMeters, greaterThan(1300));
    expect(routing.shadeOverlayReady, isFalse,
        reason: 'оценка для 14:00 больше не описывает текущее Солнце');
    expect(routing.navigationLocked, isTrue);

    // 4. The session reports what is still ahead — with the interior vertex.
    final remaining = nav.buildRemainingRoute();
    expect(remaining, isNotNull);
    expect(remaining!.legs.map((l) => l.toTitle), ['POI 1', 'Финиш']);
    expect(remaining.legs.first.geometryPoints.length, 3,
        reason: 'точка стояния + поворот впереди + конец участка');
    expect(remaining.legs.first.geometryPoints[1].latitude, _v0.latitude,
        reason: 'поворот впереди сохраняется: обрезка не выпрямляет путь');
    expect(remaining.legs.first.geometryPoints.last.latitude, _p1.latitude);
    expect(remaining.legs.first.geometryPoints.first.latitude,
        closeTo(nav.state.currentLocation!.coordinate.latitude, 0.00002));

    // 5. The refresh: allowed, scoped to the remaining path, from NOW.
    await routing.assessShade(remainingRoute: remaining);
    expect(shade.departures.last, _departure.add(const Duration(minutes: 16)));
    expect(shade.legs.last.first.geometryPoints.first.latitude,
        closeTo(remaining.geometryPoints.first.latitude, 1e-9));
    expect(shade.visits.last, [15, 0],
        reason: 'осмотр остановки, которая ещё впереди, входит в расписание');
    expect(routing.shadeScope, ShadeAssessmentScope.remainingPath);
    expect(routing.shadeOverlayReady, isTrue);
    expect(routing.shadeDeparture, _departure,
        reason: 'старт прогулки не переписан оценкой');
    final sentMeters = shade.legs.last.fold<double>(
        0, (sum, leg) => sum + RouteProjectionUtils.polylineLengthMeters(leg.geometryPoints));
    expect(sentMeters,
        closeTo(
            RouteProjectionUtils.polylineLengthMeters(plannedRoute.geometryPoints) -
                nav.state.progressOnCurrentLegMeters,
            5),
        reason: 'на бэкенд уходит только оставшийся путь');

    // 6. Nothing about the session or the route moved.
    expect(routing.navigationLocked, isTrue, reason: 'блокировка не снята');
    expect(identical(routing.currentRoute, plannedRoute), isTrue,
        reason: 'геометрия планирования не изменена');
    expect(clock.departure, _departure, reason: 'виртуальный старт не сдвинут');
    expect(nav.state.currentLegIndex, 0);
  });

  test('the walker can refresh again after a mid-session reroute', () async {
    routing.setShadeOverlayEnabled(true);
    await routing.assessShade(departure: _departure);
    final plannedRoute = routing.currentRoute!;
    await controller.startWithRoute(plannedRoute);
    await walkSixteenMinutes();
    await routing.assessShade(remainingRoute: nav.buildRemainingRoute());
    expect(routing.shadeOverlayReady, isTrue);

    // The walker leaves the line: 80 m to the side, sustained (the engine's
    // own three-fix confirmation; nothing here weakens it). Fixes arrive
    // inside the 10-second continuity window a device produces.
    source.injectDeviation(meters: 80);
    for (var i = 0; i < 8; ++i) {
      await step(5);
    }
    expect(nav.state.distanceFromRouteMeters, greaterThan(50));
    expect(nav.state.isOffRoute, isTrue);
    expect(routing.shadeOverlayReady, isTrue,
        reason: 'до перестройки слой ещё описывает геометрию сессии');

    await nav.rerouteToNextStop();
    expect(nav.status, NavigationStatus.active);
    expect(routeService.calls, 1, reason: 'один явный запрос пользователя');
    expect(identical(nav.state.route, plannedRoute), isFalse,
        reason: 'текущий участок перестроен нативной геометрией');
    expect(routing.shadeAnalysis, isNull);
    expect(routing.shadeOverlayReady, isFalse,
        reason: 'старый слой снят: это уже другая земля');
    expect(clock.needsReanalysis, isTrue);
    expect(routing.navigationLocked, isTrue, reason: 'сессия продолжается');

    // …and the refresh works again on the rebuilt geometry.
    final rebuilt = nav.buildRemainingRoute();
    expect(rebuilt, isNotNull);
    await routing.assessShade(remainingRoute: rebuilt);
    expect(routing.shadeOverlayReady, isTrue);
    expect(routing.shadeScope, ShadeAssessmentScope.remainingPath);
    expect(routing.navigationLocked, isTrue);
    expect(routing.shadeDeparture, _departure);
  });

  test('a shade timeout mid-session leaves the walk, the lock and the route untouched', () async {
    routing.setShadeOverlayEnabled(true);
    await routing.assessShade(departure: _departure);
    final plannedRoute = routing.currentRoute!;
    await controller.startWithRoute(plannedRoute);
    await walkSixteenMinutes();
    expect(routing.navigationLocked, isTrue);

    // Phase A6.5: the engine's own 15 s budget expires while the walker moves.
    shade.failure = const ShadeAnalysisFailure(
      ShadeAnalysisFailureKind.serviceUnavailable,
      'Сервис оценки тени не ответил вовремя. Обычный маршрут продолжает работать.',
    );
    await routing.assessShade(remainingRoute: nav.buildRemainingRoute());

    expect(routing.shadeFailure?.kind, ShadeAnalysisFailureKind.serviceUnavailable);
    expect(routing.shadeFailure?.message, contains('не ответил вовремя'),
        reason: 'таймаут объясняется словами, а не техническим кодом');
    expect(routing.shadeAnalysis, isNull);
    expect(routing.isAssessingShade, isFalse);
    expect(routing.navigationLocked, isTrue, reason: 'сессия не разблокирована');
    expect(nav.isActive, isTrue, reason: 'нативная навигация продолжается');
    expect(identical(routing.currentRoute, plannedRoute), isTrue);
    expect(nav.state.currentLegIndex, 0);

    // Recovery needs no reinstall: the same walk can be assessed again.
    shade.failure = null;
    await routing.assessShade(remainingRoute: nav.buildRemainingRoute());
    expect(routing.shadeFailure, isNull);
    expect(routing.shadeOverlayReady, isTrue, reason: 'оценка снова доступна');
    expect(routing.navigationLocked, isTrue);
  });

  test('ending the session never leaves a remaining-path estimate in plan clothes', () async {
    routing.setShadeOverlayEnabled(true);
    await routing.assessShade(departure: _departure);
    final plannedRoute = routing.currentRoute!;
    await controller.startWithRoute(plannedRoute);
    await walkSixteenMinutes();
    await routing.assessShade(remainingRoute: nav.buildRemainingRoute());
    expect(routing.shadeOverlayReady, isTrue);

    await controller.finish();

    expect(nav.status, NavigationStatus.idle);
    expect(routing.navigationLocked, isFalse);
    expect(routing.shadeAnalysis, isNull,
        reason: 'оставшийся путь закончился вместе с прогулкой');
    expect(routing.shadeOverlayReady, isFalse);
    expect(routing.shadeScope, ShadeAssessmentScope.wholeWalk);
    expect(routing.shadeEvaluatedFor, isNull,
        reason: 'оценка оставшегося пути не выдаётся за план');
  });

  testWidgets('the live navigation sheet keeps the refresh reachable and labels it',
      (tester) async {
    Future<void> walkStep(double seconds) async {
      simClock.advance(Duration(milliseconds: (seconds * 1000).round()));
      controller.tickOnceForTesting(deltaSimSeconds: seconds);
      await tester.pump();
    }

    routing.setShadeOverlayEnabled(true);
    await routing.assessShade(departure: _departure);
    final plannedRoute = routing.currentRoute!;
    await controller.startWithRoute(plannedRoute);
    for (var i = 0; i < 16; ++i) {
      await walkStep(60);
    }
    expect(routing.shadeOverlayReady, isFalse);

    // The sheet the user actually sees DURING navigation (the route details
    // card, which carries the shade section before the walk, is not mounted
    // then — this is the only surface available mid-walk).
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RoutingProvider>.value(value: routing),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ChangeNotifierProvider<VirtualShadeClock>.value(value: clock),
        ],
        child: MaterialApp(
          theme: ThemeData.light(),
          home: const Scaffold(body: LiveNavigationSheet()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Оценить оставшийся путь'), findsOneWidget,
        reason: 'кнопка доступна во время навигации');
    expect(find.textContaining('слой тени снят с карты'), findsOneWidget);

    await tester.tap(find.text('Оценить оставшийся путь'));
    await tester.pumpAndSettle();

    expect(shade.departures.last, _departure.add(const Duration(minutes: 16)));
    expect(routing.shadeScope, ShadeAssessmentScope.remainingPath);
    expect(routing.shadeOverlayReady, isTrue, reason: 'слой вернулся на карту');
    expect(routing.navigationLocked, isTrue, reason: 'блокировка не снята');
    expect(find.textContaining('оценка соответствует этому времени'),
        findsOneWidget);
    expect(find.textContaining('Оценка оставшегося пути'), findsOneWidget,
        reason: 'подпись называет оценку тем, чем она является');
    expect(find.textContaining('Старт прогулки: 01.07.2026 14:00'),
        findsOneWidget);

    // Release the engine's watchdog and the simulator ticker in-body: the
    // widget-test invariant check rejects still-pending timers.
    await controller.finish();
    await tester.pump();
  });
}
