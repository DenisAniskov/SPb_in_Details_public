import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';

import 'live_navigation_test.dart' show MockNavigationLocationService;
import 'off_route_reroute_test.dart'
    show FixClock, FakeRouteService, a, b, c, d;

/// Phase C4 Part C/F/H: live maneuver progression over accepted GPS evidence.
/// Deterministic fake GPS streams only — no live Yandex requests.
void main() {
  // a→b→c→d: three straight northward legs, ~55.6 m each (0.0005° latitude).
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

  /// Leg 0 carries a right turn at 35 m and a close straight event at 45 m;
  /// leg 1 one left turn; leg 2 no native annotations (fallback leg).
  PedestrianRouteModel route() {
    final leg0 = leg('Старт', 'POI 1', [a, b], [
      maneuver(PedestrianManeuverKind.right, 35),
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

  /// Long legs (~334 m) keep maneuver offsets far from the 25 m arrival
  /// radius, so progression tests exercise the cursor, not arrival.
  const longB = GeoCoord(60.0030, 30.0);
  const longC = GeoCoord(60.0060, 30.0);

  PedestrianRouteModel longRoute() {
    final leg0 = leg('Старт', 'POI 1', [a, longB], [
      maneuver(PedestrianManeuverKind.right, 35),
      maneuver(PedestrianManeuverKind.straight, 45),
    ]);
    final leg1 = leg('POI 1', 'POI 2', [longB, longC], [
      maneuver(PedestrianManeuverKind.left, 20, legIndex: 1),
    ]);
    return PedestrianRouteModel(
      distanceMeters: 334 * 2,
      durationSeconds: 480,
      geometryPoints: [a, longB, longC],
      steps: const [],
      legs: [leg0, leg1],
      placesCount: 2,
    );
  }

  late FixClock clock;
  late MockNavigationLocationService device;
  late RoutingProvider routing;
  late NavigationProvider nav;

  setUp(() {
    clock = FixClock();
    device = MockNavigationLocationService();
    routing = RoutingProvider();
    nav = NavigationProvider(locationService: device, routingProvider: routing);
  });

  tearDown(() {
    nav.dispose();
    routing.dispose();
    device.close();
  });

  UserLocationSnapshot fix(GeoCoord point, [Duration gap = Duration.zero]) =>
      UserLocationSnapshot(
        coordinate: point,
        timestamp: clock.next(
          gap == Duration.zero ? const Duration(milliseconds: 1) : gap,
        ),
      );

  void send(GeoCoord point, [Duration gap = const Duration(milliseconds: 1)]) =>
      nav.injectLocationForTesting(fix(point, gap));

  Future<void> start() async {
    device.currentPositionResult = fix(a);
    await nav.startNavigation(route());
  }

  group('Maneuver cursor progression (Part C1)', () {
    Future<void> startLong() async {
      device.currentPositionResult = fix(a);
      await nav.startNavigation(longRoute());
    }

    test('presentation moves through approaching and imminent states', () async {
      await startLong();
      expect(nav.state.currentManeuverIndex, 0);
      // Turn at 35 m: beyond the imminent threshold, inside approach.
      expect(nav.guidance.maneuverState, ManeuverPresentationState.approaching);
      expect(nav.guidance.instruction, 'Через 40 м поверните направо');

      // Walk to ~20 m: 15 m before the turn — imminent.
      send(const GeoCoord(60.00018, 30.0));
      expect(nav.guidance.maneuverState, ManeuverPresentationState.imminent);
      expect(nav.guidance.instruction, 'Поверните направо');
    });

    test('cursor advances only after accepted progress passes the margin', () async {
      await startLong();
      // At the turn (35 m): not yet passed.
      send(const GeoCoord(60.000315, 30.0));
      expect(nav.state.currentManeuverIndex, 0);
      expect(nav.guidance.maneuverState, ManeuverPresentationState.imminent);

      // 8 m past: inside the rewind-bound margin, cursor holds.
      send(const GeoCoord(60.000387, 30.0)); // ~43 m
      expect(nav.state.currentManeuverIndex, 0);

      // Past turn + 15 m margin: cursor advances to the next verified event.
      send(const GeoCoord(60.000459, 30.0)); // ~51 m
      expect(nav.state.currentManeuverIndex, 1);
      expect(
        nav.guidance.maneuver?.kind,
        PedestrianManeuverKind.straight,
      );
    });

    test('position noise near a turn never rewinds the cursor', () async {
      await startLong();
      // Oscillate around 20 m: the cursor must never rewind, and the shown
      // maneuver stays the same verified event.
      send(const GeoCoord(60.00018, 30.0));
      send(const GeoCoord(60.00010, 30.0));
      send(const GeoCoord(60.00020, 30.0));
      send(const GeoCoord(60.00012, 30.0));
      send(const GeoCoord(60.00019, 30.0));
      expect(nav.state.currentManeuverIndex, 0);
      expect(nav.guidance.maneuver?.kind, PedestrianManeuverKind.right);
    });

    test('one GPS jump needs a second consistent fix before skipping', () async {
      await startLong();
      // A single implausible jump to ~334 m is held as a candidate: the
      // cursor must not advance on one fix alone.
      send(longB);
      expect(nav.state.currentManeuverIndex, 0);
      expect(nav.state.progressOnCurrentLegMeters, closeTo(0, 0.5));

      // The same position again confirms the jump: both leg-0 events are
      // genuinely behind accepted progress, so the cursor ends past them.
      send(longB);
      expect(nav.state.currentManeuverIndex, 2);
      expect(nav.state.progressOnCurrentLegMeters, closeTo(334, 1));
    });

    test('fresh accepted evidence restores guidance after suspension', () async {
      await start();
      expect(nav.guidance.action, PedestrianGuidanceAction.followRoute);

      nav.pauseNavigation();
      expect(nav.guidance.maneuverState, ManeuverPresentationState.suspended);
      await nav.resumeNavigation();
      send(a);
      expect(nav.guidance.action, PedestrianGuidanceAction.followRoute);
      expect(nav.guidance.maneuver, isNotNull);
    });

    test('sustained deviation suspends maneuvers with the reroute action', () async {
      await startLong();
      // Three deviation fixes spanning the 5 s hysteresis window.
      send(const GeoCoord(60.0, 30.003), const Duration(seconds: 3));
      send(const GeoCoord(60.0, 30.003), const Duration(seconds: 3));
      send(const GeoCoord(60.0, 30.003), const Duration(seconds: 3));
      expect(nav.state.isOffRoute, isTrue);
      expect(nav.guidance.action, PedestrianGuidanceAction.returnToRoute);
      expect(nav.guidance.maneuver, isNull);
      expect(nav.guidance.maneuverState, ManeuverPresentationState.suspended);
      // The verified maneuvers remain owned by the preserved route.
      expect(nav.currentLeg?.maneuvers, hasLength(2));
    });
  });

  group('Leg transitions and multi-stop stops (Part D4)', () {
    test('continueToNextLeg resets the maneuver cursor for the new leg', () async {
      await start();
      // Walk the whole first leg to trigger auto-arrival.
      send(b);
      send(b);
      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);
      expect(nav.guidance.action, PedestrianGuidanceAction.continueToNextStop);
      expect(nav.guidance.maneuver, isNull);

      nav.continueToNextLeg();
      expect(nav.state.currentLegIndex, 1);
      expect(nav.state.currentManeuverIndex, 0);
      expect(nav.guidance.maneuver?.kind, PedestrianManeuverKind.left);
      expect(nav.guidance.maneuver?.legIndex, 1);
    });

    test('visited stops survive leg transitions; final leg completes', () async {
      await start();
      send(b);
      send(b);
      nav.continueToNextLeg();
      expect(nav.state.completedStopsCount, 1);
      send(c);
      send(c);
      nav.continueToNextLeg();
      // Leg 2 has no native annotations: honest fallback, real geometry.
      expect(nav.guidance.mode, PedestrianGuidanceMode.fallback);
      send(d);
      send(d);
      expect(nav.state.isCompleted, isTrue);
      expect(nav.guidance.action, PedestrianGuidanceAction.completed);
      expect(nav.state.completedStopsCount, 3);
    });
  });

  group('Manual reroute invalidation (Part F2)', () {
    late FakeRouteService routeService;

    setUp(() {
      routeService = FakeRouteService();
      nav.dispose();
      nav = NavigationProvider(
        locationService: device,
        routingProvider: routing,
        routeService: routeService,
      );
    });

    PedestrianRouteModel rerouteResult(
      List<PedestrianManeuverModel> newManeuvers,
    ) {
      final points = [a, const GeoCoord(60.0002, 30.0003), b];
      return PedestrianRouteModel(
        distanceMeters: 80,
        durationSeconds: 90,
        geometryPoints: points,
        steps: const [],
        legs: [
          RouteLegModel(
            fromTitle: 'Текущее местоположение',
            toTitle: 'POI 1',
            distanceMeters: 80,
            durationSeconds: 90,
            geometryPoints: points,
            maneuvers: newManeuvers,
          ),
        ],
        placesCount: 1,
      );
    }

    Future<void> confirmOffRoute() async {
      await start();
      send(const GeoCoord(60.0, 30.003), const Duration(seconds: 3));
      send(const GeoCoord(60.0, 30.003), const Duration(seconds: 3));
      send(const GeoCoord(60.0, 30.003), const Duration(seconds: 3));
      expect(nav.state.isOffRoute, isTrue);
      expect(
        nav.currentLeg?.maneuvers.first.kind,
        PedestrianManeuverKind.right,
      );
    }

    test('successful reroute replaces maneuvers and resets the cursor', () async {
      routeService.result = rerouteResult([
        maneuver(PedestrianManeuverKind.crosswalk, 30),
      ]);
      await confirmOffRoute();

      await nav.rerouteToNextStop();

      expect(nav.state.status, NavigationStatus.active);
      expect(nav.state.isOffRoute, isFalse);
      expect(nav.state.currentManeuverIndex, 0);
      final newManeuvers = nav.currentLeg?.maneuvers;
      expect(newManeuvers, hasLength(1));
      expect(newManeuvers!.first.kind, PedestrianManeuverKind.crosswalk);
      expect(newManeuvers.first.legIndex, 0);
      expect(nav.guidance.maneuver?.kind, PedestrianManeuverKind.crosswalk);
    });

    test('reroute without native annotations yields honest fallback', () async {
      routeService.result = rerouteResult(const []);
      await confirmOffRoute();

      await nav.rerouteToNextStop();

      expect(nav.currentLeg?.maneuvers, isEmpty);
      expect(nav.guidance.mode, PedestrianGuidanceMode.fallback);
      expect(
        nav.guidance.instruction,
        contains('Продолжайте движение по отображённому пешеходному маршруту'),
      );
    });

    test('failed reroute keeps the previous verified maneuvers', () async {
      routeService.error = StateError('network down');
      await confirmOffRoute();

      await nav.rerouteToNextStop();

      expect(nav.state.status, NavigationStatus.active);
      // The old route and its verified maneuvers survive untouched…
      expect(nav.currentLeg?.maneuvers.first.kind, PedestrianManeuverKind.right);
      // …while the user is still off-route, so specific turn commands stay
      // suppressed until the deviation is resolved (Part F1).
      expect(nav.guidance.action, PedestrianGuidanceAction.returnToRoute);
      expect(nav.guidance.maneuver, isNull);
    });
  });
}
