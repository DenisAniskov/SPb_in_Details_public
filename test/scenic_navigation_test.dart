import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/scenic_stage_builder.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';

import 'live_navigation_test.dart' show MockNavigationLocationService;
import 'off_route_reroute_test.dart' show FixClock, FakeRouteService;
import 'simulated_location_source_test.dart' show SimClock;
import 'package:smart_navigator_spb/services/simulated_location_source.dart';

/// Phase C5 §8–9: scenic walks through the UNCHANGED Phase C4 engine and the
/// C4.1 simulator. The combined stage is one leg: waypoints never arrive,
/// the stop counter never increments, maneuvers survive the rebase, and a
/// reroute honestly drops the scenic detour.
void main() {
  // A→W→B scenic chain with an exact shared waypoint.
  const start = GeoCoord(60.0, 30.0);
  const waypoint = GeoCoord(60.0002, 30.0005);
  const stop = GeoCoord(60.0005, 30.0010);

  RouteLegModel segment(
    GeoCoord from,
    GeoCoord to, {
    int seconds = 60,
    bool destination = false,
  }) {
    final mid = GeoCoord(
      (from.latitude + to.latitude) / 2,
      (from.longitude + to.longitude) / 2,
    );
    return RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'POI 1',
      distanceMeters: RouteProjectionUtils.polylineLengthMeters([from, mid, to]),
      durationSeconds: seconds,
      geometryPoints: [from, mid, to],
      maneuvers: [
        PedestrianManeuverModel(
          kind: PedestrianManeuverKind.right,
          segmentIndex: 0,
          segmentPosition: 0.5,
          offsetMeters:
              RouteProjectionUtils.polylineLengthMeters([from, mid]),
          legIndex: 0,
        ),
      ],
      // Editorial visit time lives on the stage destination only.
      visitMinutes: destination ? 25 : null,
    );
  }

  PedestrianRouteModel scenicStageRoute({List<GeoCoord> via = const [waypoint]}) {
    // Build the chain start → w1 → (w2…) → stop with exact shared points.
    final points = [start, ...via, stop];
    final segments = <RouteLegModel>[];
    for (var i = 0; i + 1 < points.length; i++) {
      segments.add(
        segment(
          points[i],
          points[i + 1],
          destination: i + 2 == points.length,
        ),
      );
    }
    final stage = const ScenicStageBuilder().combine(
      segments: segments,
      legIndex: 0,
      scenic: ScenicStageInfo(
        featureIds: via
            .map((p) => 'f-${p.latitude}-${p.longitude}')
            .toList(),
        featureNames: via.map((p) => 'Набережная ${p.latitude}').toList(),
        evidence: ScenicEvidenceLevel.verifiedOnPath,
        coverageShare: 0.8,
        extraSeconds: 20,
        extraMeters: 15,
        score: 1.2,
        explanation: 'Проходит по проверенной набережной',
      ),
    );
    expect(stage, isNotNull, reason: 'fixture chain must combine cleanly');
    final leg = stage!;
    return PedestrianRouteModel(
      distanceMeters: leg.distanceMeters,
      durationSeconds: leg.durationSeconds,
      geometryPoints: leg.geometryPoints,
      steps: const [],
      legs: [leg],
      placesCount: 1,
      walkKind: WalkKind.scenic,
    );
  }

  group('C4 navigation over a combined scenic stage (§8)', () {
    late FixClock clock;
    late SimClock simClock;
    late MockNavigationLocationService device;
    late RoutingProvider routing;
    late NavigationProvider nav;

    setUp(() {
      clock = FixClock();
      simClock = SimClock();
      UserLocationSnapshot.clock = simClock.call;
      device = MockNavigationLocationService();
      routing = RoutingProvider();
      nav = NavigationProvider(locationService: device, routingProvider: routing);
    });

    tearDown(() {
      UserLocationSnapshot.clock = DateTime.now;
      nav.dispose();
      routing.dispose();
      device.close();
    });

    UserLocationSnapshot fix(
      GeoCoord point, [
      Duration gap = const Duration(milliseconds: 1),
    ]) =>
        UserLocationSnapshot(coordinate: point, timestamp: clock.next(gap));

    void send(GeoCoord point, [Duration gap = const Duration(milliseconds: 1)]) =>
        nav.injectLocationForTesting(fix(point, gap));

    test('scenic waypoint never triggers arrival; stop counts once', () async {
      device.currentPositionResult = fix(start);
      await nav.startNavigation(scenicStageRoute());
      expect(nav.isActive, isTrue);
      expect(nav.state.route!.walkKind, WalkKind.scenic);
      expect(nav.state.totalStopsCount, 1);

      // Walk to the waypoint (mid-stage): no arrival confirmation.
      send(waypoint);
      expect(nav.state.isWaitingForNextLegConfirmation, isFalse);
      expect(nav.state.completedStopsCount, 0);
      expect(nav.guidance.action, PedestrianGuidanceAction.followRoute);

      // Walk to the stage end: the engine's own arrival fires once.
      send(stop);
      send(stop);
      expect(nav.state.isWaitingForNextLegConfirmation || nav.isCompleted,
          isTrue);
      expect(nav.state.completedStopsCount, 1);
    });

    test('rebased maneuvers guide the walker across the waypoint', () async {
      device.currentPositionResult = fix(start);
      await nav.startNavigation(scenicStageRoute());
      // First verified maneuver belongs to segment 1 (before the waypoint).
      expect(nav.guidance.maneuver?.kind, PedestrianManeuverKind.right);
      expect(nav.guidance.maneuver!.offsetMeters, greaterThan(0));
      // Walk past the waypoint and its pass margin: the second (rebased)
      // maneuver becomes the primary instruction.
      const afterWaypoint = GeoCoord(60.0003, 30.0007);
      send(afterWaypoint);
      send(afterWaypoint);
      expect(nav.guidance.maneuver, isNotNull);
      expect(nav.state.currentManeuverIndex, greaterThanOrEqualTo(1));
      // The rebased maneuver still resolves on the combined geometry.
      expect(
        nav.guidance.maneuver!.coordinateOnLeg(
          nav.currentLeg!.geometryPoints,
        ),
        isNotNull,
      );
    });

    test('reroute drops the scenic detour honestly and keeps the request',
        () async {
      final routeService = FakeRouteService();
      nav.dispose();
      nav = NavigationProvider(
        locationService: device,
        routingProvider: routing,
        routeService: routeService,
      );
      final newPoints = [start, const GeoCoord(60.0002, 30.0002), stop];
      routeService.result = PedestrianRouteModel(
        distanceMeters: 60,
        durationSeconds: 70,
        geometryPoints: newPoints,
        steps: const [],
        legs: [
          RouteLegModel(
            fromTitle: 'Текущее местоположение',
            toTitle: 'POI 1',
            distanceMeters: 60,
            durationSeconds: 70,
            geometryPoints: newPoints,
            visitMinutes: 25,
          ),
        ],
        placesCount: 1,
      );
      device.currentPositionResult = fix(start);
      await nav.startNavigation(scenicStageRoute());
      expect(nav.currentLeg!.scenic, isNotNull);

      // Sustained deviation off the combined stage (3 s gaps satisfy the
      // off-route hysteresis window).
      for (var i = 0; i < 3; i++) {
        send(const GeoCoord(60.0, 30.003), const Duration(seconds: 3));
      }
      expect(nav.state.isOffRoute, isTrue);

      await nav.rerouteToNextStop();
      expect(nav.state.isOffRoute, isFalse);
      // The rebuilt stage has no scenic metadata: the detour is gone.
      expect(nav.currentLeg!.scenic, isNull);
      expect(nav.currentLeg!.visitMinutes, 25);
      // The walk kind (the user's request) survives the reroute.
      expect(nav.state.route!.walkKind, WalkKind.scenic);
      expect(nav.state.currentManeuverIndex, 0);
    });
  });

  group('C4.1 simulator over scenic walks (§9)', () {
    late SimClock clock;
    late SimulatedLocationSource source;
    late RoutingProvider routing;
    late NavigationProvider nav;
    late SimulationController controller;

    setUp(() {
      clock = SimClock();
      UserLocationSnapshot.clock = clock.call;
      source = SimulatedLocationSource(clock: clock.call);
      routing = RoutingProvider();
      nav = NavigationProvider(locationService: source, routingProvider: routing);
      controller = SimulationController(
        source: source,
        nav: nav,
        tickInterval: const Duration(hours: 1),
      );
    });

    tearDown(() {
      UserLocationSnapshot.clock = DateTime.now;
      controller.dispose();
      nav.dispose();
      routing.dispose();
    });

    void step(double seconds) {
      clock.advance(Duration(milliseconds: (seconds * 1000).round()));
      controller.tickOnceForTesting(deltaSimSeconds: seconds);
    }

    test('A→W1→W2→B walks through with exactly one arrival at B', () async {
      await controller.startWithRoute(
        scenicStageRoute(via: const [
          GeoCoord(60.0002, 30.0005),
          GeoCoord(60.0003, 30.0007),
        ]),
      );
      expect(nav.isActive, isTrue);
      expect(controller.simulatedLegIndex, 0);
      // The simulator walks the combined geometry continuously; the two
      // scenic waypoints produce NO stop confirmations.
      var confirmations = 0;
      for (var i = 0; i < 60 && !nav.isCompleted; i++) {
        step(5);
        if (nav.state.isWaitingForNextLegConfirmation) {
          confirmations++;
          nav.continueToNextLeg();
        }
      }
      expect(nav.isCompleted, isTrue);
      expect(confirmations, 0);
      expect(nav.state.completedStopsCount, 1);
      expect(nav.state.route!.walkKind, WalkKind.scenic);
    });

    test('restart rebuilds the scenic scenario from its start', () async {
      await controller.startWithRoute(scenicStageRoute());
      step(10);
      expect(source.distanceMeters, greaterThan(10));
      await controller.restart();
      expect(source.distanceMeters, 0);
      expect(nav.state.currentManeuverIndex, 0);
      expect(nav.state.route!.walkKind, WalkKind.scenic);
      // And the scenic walk still completes after the restart.
      for (var i = 0; i < 60 && !nav.isCompleted; i++) {
        step(5);
      }
      expect(nav.isCompleted, isTrue);
    });
  });
}
