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

/// Phase C4.1 Section 5: reproducible end-to-end simulation scenarios over
/// the UNCHANGED Phase C4 engine. The fake router below is an explicit test
/// double for the reroute scenario — on a device, rerouting goes through the
/// real MapKitService and this test makes no claim about it.
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
    List<GeoCoord> points, [
    List<PedestrianManeuverModel> maneuvers = const [],
  ]) =>
      RouteLegModel(
        fromTitle: from,
        toTitle: to,
        distanceMeters: RouteProjectionUtils.polylineLengthMeters(points),
        durationSeconds: 60,
        geometryPoints: points,
        maneuvers: maneuvers,
      );

  /// ~334 m leg (0.003° latitude) with a verified turn at 150 m and a close
  /// straight event at 170 m («Затем …» pairing). The long leg keeps the
  /// whole maneuver sequence inside the walk window before the engine's
  /// 25 m arrival radius completes the leg.
  const longB = GeoCoord(60.0030, 30.0);

  PedestrianRouteModel singleLegRoute() => PedestrianRouteModel(
        distanceMeters: 334,
        durationSeconds: 300,
        geometryPoints: [a, longB],
        steps: const [],
        legs: [
          leg('Старт', 'Смотрительная площадка', [a, longB], [
            maneuver(PedestrianManeuverKind.right, 150),
            maneuver(PedestrianManeuverKind.straight, 170),
          ]),
        ],
        placesCount: 1,
      );

  /// Three-leg tourist walk with a turn on the first leg only.
  PedestrianRouteModel multiStopRoute() => PedestrianRouteModel(
        distanceMeters: 55.6 * 3,
        durationSeconds: 180,
        geometryPoints: [a, b, c, d],
        steps: const [],
        legs: [
          leg('Старт', 'POI 1', [a, b],
              [maneuver(PedestrianManeuverKind.left, 45)]),
          leg('POI 1', 'POI 2', [b, c]),
          leg('POI 2', 'POI 3', [c, d]),
        ],
        placesCount: 3,
      );

  late SimClock clock;
  late SimulatedLocationSource source;
  late RoutingProvider routing;
  late NavigationProvider nav;
  late SimulationController controller;
  StreamSubscription<UserLocationSnapshot>? emissionCounter;
  bool disposedInTest = false;

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
    emissionCounter = source.getPositionStream().listen((_) {});
  });

  tearDown(() async {
    await emissionCounter?.cancel();
    if (!disposedInTest) controller.dispose();
    UserLocationSnapshot.clock = DateTime.now;
    nav.dispose();
    routing.dispose();
  });

  Future<void> step(double seconds) async {
    clock.advance(Duration(milliseconds: (seconds * 1000).round()));
    controller.tickOnceForTesting(deltaSimSeconds: seconds);
    await Future<void>.delayed(Duration.zero);
  }

  group('Scenario: full single-route walk', () {
    test('walks to final arrival through live native instructions', () async {
      await controller.startWithRoute(singleLegRoute());
      final instructions = <String>[];
      var completed = false;
      for (var i = 0; i < 60 && !completed; i++) {
        await step(5);
        instructions.add(nav.guidance.instruction);
        completed = nav.isCompleted;
      }
      expect(completed, isTrue);
      expect(nav.state.arrivedPlaceTitle, 'Смотрительная площадка');
      // The simulator stops itself on the tick following completion.
      await step(0.5);
      // The verified turn was announced with a distance prefix, then became
      // imminent, and the close follower was announced — no invented turns.
      expect(
        instructions.any((text) => text.startsWith('Через')),
        isTrue,
      );
      expect(instructions.contains('Поверните направо'), isTrue);
      expect(instructions.contains('Продолжайте прямо'), isTrue);
      expect(controller.isRunning, isFalse);
    });
  });

  group('Scenario: multi-stop walk', () {
    test('passes both intermediate stops and completes', () async {
      await controller.startWithRoute(multiStopRoute());
      var stopsConfirmed = 0;
      for (var i = 0; i < 90 && !nav.isCompleted; i++) {
        await step(2);
        if (nav.state.isWaitingForNextLegConfirmation) {
          stopsConfirmed++;
          expect(
            nav.state.totalStopsCount,
            3,
          );
          nav.continueToNextLeg();
        }
      }
      expect(nav.isCompleted, isTrue);
      expect(nav.state.completedStopsCount, 3);
      expect(stopsConfirmed, 2);
    });
  });

  group('Scenario: maneuver switching', () {
    test('cursor advances through the verified events in order', () async {
      await controller.startWithRoute(singleLegRoute());
      expect(nav.state.currentManeuverIndex, 0);
      // Walk ~140 m: approaching the turn, cursor still on it.
      for (var i = 0; i < 20; i++) {
        await step(5);
      }
      expect(nav.state.progressOnCurrentLegMeters, greaterThan(130));
      expect(nav.state.currentManeuverIndex, 0);
      expect(nav.guidance.maneuver?.kind, PedestrianManeuverKind.right);
      // Walk past the turn plus the 15 m margin: the close straight event
      // (20 m later) becomes the primary verified instruction.
      var switched = false;
      for (var i = 0; i < 15 && !switched; i++) {
        await step(5);
        switched = nav.state.currentManeuverIndex >= 1;
      }
      expect(switched, isTrue);
      expect(nav.guidance.maneuver?.kind, PedestrianManeuverKind.straight);
    });
  });

  group('Scenario: signal loss and recovery', () {
    test('progress freezes during loss and resumes after recovery', () async {
      await controller.startWithRoute(singleLegRoute());
      await step(4);
      final before = nav.state.progressOnCurrentLegMeters;

      controller.injectGpsLoss(duration: const Duration(seconds: 10));
      for (var i = 0; i < 3; i++) {
        await step(2);
      }
      // Delivery is down: the engine sees no fixes, progress cannot move.
      expect(nav.state.progressOnCurrentLegMeters, before);

      clock.advance(const Duration(seconds: 11));
      await step(2);
      // Delivery is back: fresh accepted evidence resumes progress.
      expect(nav.state.progressOnCurrentLegMeters, greaterThan(before));
      expect(nav.guidance.action, PedestrianGuidanceAction.followRoute);
    });
  });

  group('Scenario: GPS jump confirmation', () {
    test('one implausible fix is held; the consistent pair latches', () async {
      await controller.startWithRoute(singleLegRoute());
      await step(4);
      final before = nav.state.progressOnCurrentLegMeters;

      controller.injectJump(); // one-fix glitch: +120 m report, walker stays
      await step(2);
      // Held: one fix cannot move accepted progress past the jump limit.
      expect(nav.state.progressOnCurrentLegMeters, closeTo(before, 0.5));

      // The follow-up fix contradicts the glitch: the engine re-pends and
      // resumes normal walking — a lone bad fix never latches.
      await step(2);
      expect(
        nav.state.progressOnCurrentLegMeters,
        closeTo(before + 5.6, 1.5),
      );

      // A genuine teleport (reported position jumps and stays) is confirmed
      // by the engine's own two-fix rule.
      final afterGlitch = nav.state.progressOnCurrentLegMeters;
      controller.jumpWalker(meters: 120);
      await step(2);
      expect(nav.state.progressOnCurrentLegMeters, closeTo(afterGlitch, 0.5));
      await step(2);
      expect(
        nav.state.progressOnCurrentLegMeters,
        greaterThan(afterGlitch + 100),
      );
    });
  });

  group('Scenario: deviation and manual reroute', () {
    test('off-route suspends guidance; reroute rebuilds the leg honestly',
        () async {
      final routeService = FakeRouteService();
      final newPoints = [a, const GeoCoord(60.0002, 30.0003), b];
      routeService.result = PedestrianRouteModel(
        distanceMeters: 65,
        durationSeconds: 70,
        geometryPoints: newPoints,
        steps: const [],
        legs: [
          leg('Текущее местоположение', 'Смотрительная площадка', newPoints),
        ],
        placesCount: 1,
      );
      // Rebuild the stack on the fake router (explicit test double).
      await emissionCounter?.cancel();
      controller.dispose();
      nav.dispose();
      source = SimulatedLocationSource(clock: clock.call);
      nav = NavigationProvider(
        locationService: source,
        routingProvider: routing,
        routeService: routeService,
      );
      controller = SimulationController(
        source: source,
        nav: nav,
        tickInterval: const Duration(hours: 1),
      );
      emissionCounter = source.getPositionStream().listen((_) {});

      await controller.startWithRoute(singleLegRoute());
      controller.injectDeviation(meters: 80);
      for (var i = 0; i < 4; i++) {
        await step(3);
      }
      expect(nav.state.isOffRoute, isTrue);
      expect(nav.guidance.action, PedestrianGuidanceAction.returnToRoute);
      expect(nav.guidance.maneuver, isNull);

      await nav.rerouteToNextStop();
      expect(nav.state.isOffRoute, isFalse);
      // The rebuilt leg carries no verified maneuvers: honest fallback.
      expect(nav.guidance.mode, PedestrianGuidanceMode.fallback);
      await step(1);
      expect(source.hasDeviation, isFalse);
      expect(controller.legLengthMeters, closeTo(65.1, 1));
    });
  });

  group('Scenario: stale async fix', () {
    test('backdated fix is rejected without touching the session', () async {
      await controller.startWithRoute(singleLegRoute());
      await step(4);
      final before = nav.state.progressOnCurrentLegMeters;

      controller.injectStaleFix();
      await step(2);
      expect(nav.state.progressOnCurrentLegMeters, before);
      expect(nav.state.status, NavigationStatus.active);
      expect(nav.state.errorMessage, isNull);

      await step(2);
      expect(nav.state.progressOnCurrentLegMeters, greaterThan(before));
    });
  });

  group('Scenario: cancellation and disposal', () {
    test('finish mid-walk tears the session down cleanly', () async {
      await controller.startWithRoute(singleLegRoute());
      await step(4);
      await controller.finish();
      expect(nav.status, NavigationStatus.idle);
      expect(controller.isRunning, isFalse);
      // Late ticks after cancellation are no-ops, not crashes.
      await step(2);
      expect(nav.status, NavigationStatus.idle);
    });

    test('dispose while running closes the fix stream', () async {
      await controller.startWithRoute(singleLegRoute());
      await step(2);
      final done = Completer<void>();
      final sub =
          source.getPositionStream().listen((_) {}, onDone: done.complete);
      controller.dispose();
      disposedInTest = true;
      await done.future.timeout(const Duration(seconds: 1));
      await sub.cancel();
    });
  });
}
