import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/simulated_location_source.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';

import 'off_route_reroute_test.dart' show FakeRouteService, a, b, c, d;
import 'simulated_location_source_test.dart' show SimClock;

/// Phase C4.1 Sections 1–2: the simulator controller drives the UNCHANGED
/// Phase C4 engine through its public APIs. Deterministic fixtures only;
/// the fake router below is an explicit test double — an on-device reroute
/// goes through the real MapKitService and is never inferred from here.
void main() {
  PedestrianManeuverModel maneuver(
    PedestrianManeuverKind kind,
    double offset, {
    int legIndex = 0,
  }) =>
      PedestrianManeuverModel(
        kind: kind,
        segmentIndex: 0,
        segmentPosition: 0,
        offsetMeters: offset,
        legIndex: legIndex,
      );

  RouteLegModel leg(
    String from,
    String to,
    List<GeoCoord> points,
    List<PedestrianManeuverModel> maneuvers,
  ) =>
      RouteLegModel(
        fromTitle: from,
        toTitle: to,
        distanceMeters: RouteProjectionUtils.polylineLengthMeters(points),
        durationSeconds: 60,
        geometryPoints: points,
        maneuvers: maneuvers,
      );

  /// Three ~55.6 m legs; leg 0 carries two verified turns, leg 2 none.
  PedestrianRouteModel fixtureRoute() {
    final leg0 = leg('Старт', 'POI 1', [a, b], [
      maneuver(PedestrianManeuverKind.right, 25),
      maneuver(PedestrianManeuverKind.straight, 45),
    ]);
    final leg1 = leg('POI 1', 'POI 2', [b, c], [
      maneuver(PedestrianManeuverKind.left, 20, legIndex: 1),
    ]);
    final leg2 = leg('POI 2', 'POI 3', [c, d], const []);
    return PedestrianRouteModel(
      distanceMeters: 55.6 * 3,
      durationSeconds: 180,
      geometryPoints: [a, b, c, d],
      steps: const [],
      legs: [leg0, leg1, leg2],
      placesCount: 3,
    );
  }

  late SimClock clock;
  late SimulatedLocationSource source;
  late RoutingProvider routing;
  late NavigationProvider nav;
  late SimulationController controller;
  int emitted = 0;
  StreamSubscription<UserLocationSnapshot>? emissionCounter;
  bool disposedInTest = false;

  /// (Re)builds the simulator + engine stack; used by every test and again
  /// with a fake router in the reroute group.
  void buildStack({FakeRouteService? routeService}) {
    source = SimulatedLocationSource(clock: clock.call);
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
    emitted = 0;
    emissionCounter = source.getPositionStream().listen((_) => emitted++);
    disposedInTest = false;
  }

  setUp(() {
    clock = SimClock();
    // Freshness must follow the simulated clock, exactly like the injected
    // clock contract used by the existing navigation tests.
    UserLocationSnapshot.clock = clock.call;
    routing = RoutingProvider();
    buildStack();
  });

  tearDown(() async {
    await emissionCounter?.cancel();
    if (!disposedInTest) controller.dispose();
    UserLocationSnapshot.clock = DateTime.now;
    nav.dispose();
    routing.dispose();
  });

  /// One deterministic simulation step of [seconds] of simulated time; the
  /// simulated clock advances with it so fix timestamps behave like a real
  /// device's (freshness, hysteresis windows, jump limits).
  Future<void> step(double seconds) async {
    clock.advance(
      Duration(milliseconds: (seconds * 1000).round()),
    );
    controller.tickOnceForTesting(deltaSimSeconds: seconds);
    // Broadcast stream delivery lands in a later microtask.
    await Future<void>.delayed(Duration.zero);
  }

  group('Session lifecycle through public engine APIs', () {
    test('start builds the session and walks the first leg geometry', () async {
      await controller.startWithRoute(fixtureRoute());
      expect(nav.isActive, isTrue);
      expect(controller.isRunning, isTrue);
      expect(controller.simulatedLegIndex, 0);
      expect(source.distanceMeters, 0);
      expect(controller.legLengthMeters, closeTo(55.6, 0.2));
      // The engine's one-shot initial fix is the route start.
      expect(nav.state.progressOnCurrentLegMeters, closeTo(0, 1));
    });

    test('walking updates real engine progress and elapsed sim time', () async {
      await controller.startWithRoute(fixtureRoute());
      await step(5); // 5 s at 5 km/h ≈ 6.9 m
      expect(source.distanceMeters, closeTo(6.9, 0.3));
      expect(nav.state.progressOnCurrentLegMeters, closeTo(6.9, 1));
      expect(controller.simulatedElapsed, const Duration(seconds: 5));
      expect(emitted, greaterThanOrEqualTo(1));
    });

    test('speed scales the walk distance', () async {
      await controller.startWithRoute(fixtureRoute());
      controller.setSpeed(8);
      expect(source.speedMps, closeTo(8 / 3.6, 0.001));
      await step(10); // explicit simulated delta: 10 s at 8 km/h ≈ 22.2 m
      expect(source.distanceMeters, closeTo(22.2, 0.5));
    });

    test('playback rate multiplies the default tick', () async {
      await controller.startWithRoute(fixtureRoute());
      controller.setSpeed(8);
      controller.tickOnceForTesting(); // default tick: 0.5 s × ×1 = 0.5 s
      final baseDistance = source.distanceMeters;
      await controller.restart();
      controller.setSpeed(8);
      controller.setPlaybackRate(5);
      controller.tickOnceForTesting(); // default tick: 0.5 s × ×5 = 2.5 s
      expect(source.distanceMeters, closeTo(baseDistance * 5, 0.3));
    });

    test('arrival at the intermediate stop freezes the walker', () async {
      await controller.startWithRoute(fixtureRoute());
      // 6 steps × 5 s ≈ 41.7 m: two fixes inside the engine's 25 m arrival
      // radius complete the leg by its own two-fix rule.
      for (var i = 0; i < 6; i++) {
        await step(5);
      }
      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);
      final frozenDistance = source.distanceMeters;
      final frozenElapsed = controller.simulatedElapsed;
      await step(5);
      expect(source.distanceMeters, frozenDistance);
      expect(controller.simulatedElapsed, frozenElapsed);
      expect(controller.simulatedLegIndex, 0);
    });

    test('continueToNextLeg switches the walker to the next leg', () async {
      await controller.startWithRoute(fixtureRoute());
      for (var i = 0; i < 6; i++) {
        await step(5);
      }
      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);
      nav.continueToNextLeg();
      await step(1);
      expect(controller.simulatedLegIndex, 1);
      expect(source.distanceMeters, closeTo(1.4, 0.5));
      expect(nav.state.currentLegIndex, 1);
    });

    test('final arrival completes the session and stops the walker', () async {
      await controller.startWithRoute(fixtureRoute());
      // Walk all three legs with the engine's own confirmations.
      for (var legStop = 0; legStop < 3; legStop++) {
        for (var i = 0; i < 8; i++) {
          await step(5);
          if (nav.state.isWaitingForNextLegConfirmation) {
            nav.continueToNextLeg();
          }
        }
      }
      expect(nav.isCompleted, isTrue);
      expect(nav.state.completedStopsCount, 3);
      expect(controller.isRunning, isFalse);
    });

    test('finish stops the session and resets the simulator', () async {
      await controller.startWithRoute(fixtureRoute());
      await step(5);
      await controller.finish();
      expect(nav.status, NavigationStatus.idle);
      expect(controller.isRunning, isFalse);
      expect(controller.legLengthMeters, 0);
      final before = emitted;
      await step(5);
      expect(emitted, before);
    });

    test('restart rebuilds the scenario from leg 0 at zero distance', () async {
      await controller.startWithRoute(fixtureRoute());
      for (var i = 0; i < 6; i++) {
        await step(5);
      }
      expect(nav.state.progressOnCurrentLegMeters, greaterThan(20));
      await controller.restart();
      expect(nav.isActive, isTrue);
      expect(controller.simulatedLegIndex, 0);
      expect(source.distanceMeters, 0);
      expect(nav.state.progressOnCurrentLegMeters, closeTo(0, 1));
      expect(nav.state.completedStopsCount, 0);
      expect(controller.simulatedElapsed, Duration.zero);
    });
  });

  group('Seek and leg selection (honest session rebuild)', () {
    test('seek backward restarts the session at the target position', () async {
      await controller.startWithRoute(fixtureRoute());
      for (var i = 0; i < 6; i++) {
        await step(5);
      }
      expect(nav.state.progressOnCurrentLegMeters, greaterThan(40));

      await controller.seekToLeg(0, distanceMeters: 10);

      expect(nav.isActive, isTrue);
      expect(nav.state.progressOnCurrentLegMeters, closeTo(10, 1));
      expect(nav.state.currentManeuverIndex, 0);
      expect(source.distanceMeters, closeTo(10, 0.5));
      expect(controller.simulatedElapsed, Duration.zero);
      expect(nav.state.completedStopsCount, 0);
      expect(nav.state.isWaitingForNextLegConfirmation, isFalse);
    });

    test('seek to a later leg replays intermediate arrivals honestly', () async {
      await controller.startWithRoute(fixtureRoute());
      await controller.seekToLeg(2);
      // The replay fast-forwards one honest fix per tick: the engine's own
      // two-fix arrival completes each intermediate leg.
      var guard = 0;
      while ((nav.currentLegIndex < 2 ||
              controller.simulatedLegIndex < 2) &&
          guard < 40) {
        await step(0.5);
        guard++;
      }
      expect(nav.currentLegIndex, 2);
      expect(controller.simulatedLegIndex, 2);
      expect(source.distanceMeters, closeTo(0, 1));
      expect(nav.state.completedStopsCount, 2);
      expect(nav.guidance.mode, PedestrianGuidanceMode.fallback);
    });

    test('seek near the leg endpoint lets the engine arrive by itself', () async {
      await controller.startWithRoute(fixtureRoute());
      await controller.seekToLeg(0, distanceMeters: 54);
      // The engine's one-shot fix already counts as the first arrival fix;
      // one more inside the 25 m radius completes the leg by its own rule.
      await step(0.5);
      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);
    });
  });

  group('Reroute geometry reload', () {
    test('after a reroute the walker re-joins the new geometry', () async {
      final routeService = FakeRouteService();
      final newPoints = [a, const GeoCoord(60.0002, 30.0003), b];
      routeService.result = PedestrianRouteModel(
        distanceMeters: 80,
        durationSeconds: 90,
        geometryPoints: newPoints,
        steps: const [],
        legs: [
          RouteLegModel(
            fromTitle: 'Текущее местоположение',
            toTitle: 'POI 1',
            distanceMeters: 80,
            durationSeconds: 90,
            geometryPoints: newPoints,
          ),
        ],
        placesCount: 1,
      );
      // Fresh stack wired to the fake router (documented test double).
      await emissionCounter?.cancel();
      controller.dispose();
      disposedInTest = true;
      nav.dispose();
      buildStack(routeService: routeService);

      await controller.startWithRoute(fixtureRoute());
      controller.injectDeviation(meters: 80);
      for (var i = 0; i < 4; i++) {
        await step(3); // 3 s gaps satisfy the off-route hysteresis window
      }
      expect(nav.state.isOffRoute, isTrue);

      await nav.rerouteToNextStop();
      expect(nav.state.isOffRoute, isFalse);

      await step(1);
      // The controller detected the rebuilt route snapshot and reloaded the
      // replacement leg's real geometry from its start (its polyline length
      // is ~65.1 m; the declared native distance 80 is intentionally not
      // used as the walker's metric).
      expect(controller.legLengthMeters, closeTo(65.1, 1));
      expect(source.hasDeviation, isFalse);
      expect(source.distanceMeters, closeTo(1.4, 1));
      expect(nav.state.progressOnCurrentLegMeters, closeTo(1.4, 2));
    });
  });

  group('Resource hygiene', () {
    test('dispose while running closes the stream exactly once', () async {
      await controller.startWithRoute(fixtureRoute());
      final done = Completer<void>();
      final sub =
          source.getPositionStream().listen((_) {}, onDone: done.complete);
      controller.dispose();
      disposedInTest = true;
      await done.future.timeout(const Duration(seconds: 1));
      await sub.cancel();
    });

    test('session cancellation stops the simulation cleanly', () async {
      await controller.startWithRoute(fixtureRoute());
      await step(5);
      nav.stopNavigation();
      await step(5);
      expect(nav.status, NavigationStatus.idle);
      expect(controller.isRunning, isFalse);
    });
  });
}
