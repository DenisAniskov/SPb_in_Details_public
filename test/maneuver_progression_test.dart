import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/utils/maneuver_instruction_formatter.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/services/pedestrian_guidance_service.dart';

/// Phase C4 Part B/C: typed maneuver localization and the presentation state
/// machine derived from accepted GPS progress. Pure state — no timers, no
/// raw proximity, no native calls.
void main() {
  const a = GeoCoord(60.0, 30.0);
  const b = GeoCoord(60.0005, 30.0); // ~55.6 m north of a
  const c = GeoCoord(60.0010, 30.0);

  PedestrianManeuverModel turnRight(double offset, {int legIndex = 0}) =>
      PedestrianManeuverModel(
        kind: PedestrianManeuverKind.right,
        segmentIndex: 0,
        segmentPosition: 0.5,
        offsetMeters: offset,
        legIndex: legIndex,
      );

  PedestrianManeuverModel turnLeft(double offset, {int legIndex = 0}) =>
      PedestrianManeuverModel(
        kind: PedestrianManeuverKind.left,
        segmentIndex: 0,
        segmentPosition: 0.8,
        offsetMeters: offset,
        legIndex: legIndex,
      );

  RouteLegModel legWith(
    List<PedestrianManeuverModel> maneuvers, {
    String to = 'Таврический дворец',
    int visitMinutes = 30,
  }) =>
      RouteLegModel(
        fromTitle: 'Старт',
        toTitle: to,
        distanceMeters: 55.6,
        durationSeconds: 60,
        geometryPoints: const [a, b],
        maneuvers: maneuvers,
        visitMinutes: visitMinutes,
      );

  PedestrianRouteModel routeWith(List<RouteLegModel> legs) =>
      PedestrianRouteModel(
        distanceMeters: 55.6 * legs.length,
        durationSeconds: 60 * legs.length,
        geometryPoints: const [a, b, c],
        steps: const [],
        legs: legs,
        placesCount: legs.length,
      );

  UserLocationSnapshot freshFix() => UserLocationSnapshot(
        coordinate: const GeoCoord(60.0, 30.0),
        timestamp: DateTime.now(),
      );

  LiveNavigationState activeState({
    required PedestrianRouteModel route,
    double progress = 0,
    int maneuverIndex = 0,
    int legIndex = 0,
    bool gpsLost = false,
    bool offRoute = false,
  }) =>
      LiveNavigationState(
        status: NavigationStatus.active,
        route: route,
        currentLegIndex: legIndex,
        currentManeuverIndex: maneuverIndex,
        currentLocation: freshFix(),
        projectedPoint: a,
        progressOnCurrentLegMeters: progress,
        remainingDistanceOnCurrentLegMeters: 55.6 - progress,
        totalProgressMeters: progress,
        totalRemainingMeters: 55.6 * route.legs.length - progress,
        isGpsLost: gpsLost,
        isOffRoute: offRoute,
      );

  group('ManeuverInstructionFormatter (Part B3 localization)', () {
    test('distance prefix uses rounded meters and lowercase imperative', () {
      final text = ManeuverInstructionFormatter.composeInstruction(
        'Поверните направо',
        distanceMeters: 84,
      );
      expect(text, 'Через 80 м поверните направо');
    });

    test('kilometer distances use Russian decimal comma', () {
      final text = ManeuverInstructionFormatter.composeInstruction(
        'Поверните налево',
        distanceMeters: 1240,
      );
      expect(text, 'Через 1,2 км поверните налево');
    });

    test('imminent maneuver drops the distance prefix', () {
      final text = ManeuverInstructionFormatter.composeInstruction(
        'Поверните налево',
        distanceMeters: 25,
      );
      expect(text, 'Поверните налево');
    });

    test('custom imminent threshold is honoured', () {
      final text = ManeuverInstructionFormatter.composeInstruction(
        'Поверните направо',
        distanceMeters: 40,
        imminentThresholdMeters: 50,
      );
      expect(text, 'Поверните направо');
    });

    test('non-finite or negative distances keep the bare imperative', () {
      expect(
        ManeuverInstructionFormatter.composeInstruction(
          'Поверните направо',
          distanceMeters: double.nan,
        ),
        'Поверните направо',
      );
      // Infinite distance is treated as unknown, not as a huge prefix.
      expect(
        ManeuverInstructionFormatter.composeInstruction(
          'Поверните направо',
          distanceMeters: double.infinity,
        ),
        'Поверните направо',
      );
      // Negative distances cannot exist on the accepted geometry.
      expect(
        ManeuverInstructionFormatter.composeInstruction(
          'Поверните направо',
          distanceMeters: -5,
        ),
        'Поверните направо',
      );
    });

    test('follower line lowercases the following maneuver', () {
      final text = ManeuverInstructionFormatter.composeFollowingInstruction(
        'Продолжайте прямо',
      );
      expect(text, 'Затем продолжайте прямо');
    });

    test('approach distance rounds to decametres for stability', () {
      expect(ManeuverInstructionFormatter.formatApproachDistance(73), '70 м');
      expect(ManeuverInstructionFormatter.formatApproachDistance(77), '80 м');
      expect(ManeuverInstructionFormatter.formatApproachDistance(3), '10 м');
      expect(
        ManeuverInstructionFormatter.formatApproachDistance(-5),
        '',
      );
    });
  });

  group('Guidance maneuver presentation states (Part C2)', () {
    const service = PedestrianGuidanceService();

    test('distant maneuver is upcoming with the distance prefix', () {
      // ~167 m leg: a turn at ~133 m is beyond the approach threshold.
      const farLeg = RouteLegModel(
        fromTitle: 'Старт',
        toTitle: 'Таврический дворец',
        distanceMeters: 167,
        durationSeconds: 150,
        geometryPoints: [GeoCoord(60.0, 30.0), GeoCoord(60.0015, 30.0)],
        maneuvers: [
          PedestrianManeuverModel(
            kind: PedestrianManeuverKind.right,
            segmentIndex: 0,
            segmentPosition: 0.8,
            offsetMeters: 133.6,
          ),
        ],
      );
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([farLeg]),
        ),
      );
      expect(guidance.mode, PedestrianGuidanceMode.nativeAnnotations);
      expect(guidance.maneuverState, ManeuverPresentationState.upcoming);
      expect(guidance.instruction, 'Через 130 м поверните направо');
      expect(guidance.distanceToManeuverMeters, closeTo(133.6, 0.2));
      expect(guidance.maneuver?.kind, PedestrianManeuverKind.right);
    });

    test('maneuver within the approach threshold is approaching', () {
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([legWith([turnRight(55.6)])]),
        ),
      );
      expect(guidance.maneuverState, ManeuverPresentationState.approaching);
      expect(guidance.instruction, 'Через 60 м поверните направо');
      expect(guidance.distanceToManeuverMeters, closeTo(55.6, 0.1));
      expect(guidance.maneuver?.kind, PedestrianManeuverKind.right);
    });

    test('imminent maneuver drops the prefix and keeps the typed event', () {
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([legWith([turnRight(55.6)])]),
          progress: 40,
        ),
      );
      expect(guidance.maneuverState, ManeuverPresentationState.imminent);
      expect(guidance.instruction, 'Поверните направо');
    });

    test('custom thresholds shift the state boundaries', () {
      const wide = PedestrianGuidanceService(
        thresholds: ManeuverProgressionThresholds(
          approachThresholdMeters: 200,
          imminentThresholdMeters: 50,
        ),
      );
      final guidance = wide.guidanceFor(
        activeState(
          route: routeWith([legWith([turnRight(55.6)])]),
          progress: 20,
        ),
      );
      expect(guidance.maneuverState, ManeuverPresentationState.imminent);
    });

    test('all maneuvers passed leaves partial native guidance', () {
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([legWith([turnRight(55.6)])]),
          progress: 55.6,
          maneuverIndex: 1,
        ),
      );
      expect(guidance.mode, PedestrianGuidanceMode.partialNative);
      expect(guidance.maneuver, isNull);
      expect(guidance.maneuverState, ManeuverPresentationState.unavailable);
      expect(
        guidance.instruction,
        contains('Продолжайте движение по отображённому пешеходному маршруту'),
      );
    });

    test('leg without annotations is honest fallback, never invented turns', () {
      final guidance = service.guidanceFor(
        activeState(route: routeWith([legWith(const [])])),
      );
      expect(guidance.mode, PedestrianGuidanceMode.fallback);
      expect(guidance.maneuver, isNull);
      expect(guidance.upcomingSteps, isEmpty);
      expect(
        guidance.instruction,
        'Продолжайте движение по отображённому пешеходному маршруту '
        'к следующей точке.',
      );
    });

    test('no route snapshot is GUIDANCE_UNAVAILABLE', () {
      const state = LiveNavigationState();
      final guidance = service.guidanceFor(state);
      expect(guidance.mode, PedestrianGuidanceMode.unavailable);
      expect(guidance.action, PedestrianGuidanceAction.unavailable);
    });
  });

  group('Unsafe presentation suppression (Parts C2/F1/F3)', () {
    const service = PedestrianGuidanceService();

    test('GPS loss suspends specific turn instructions', () {
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([legWith([turnRight(55.6)])]),
          gpsLost: true,
        ),
      );
      expect(guidance.action, PedestrianGuidanceAction.waitForGps);
      expect(guidance.maneuver, isNull);
      expect(guidance.maneuverState, ManeuverPresentationState.suspended);
      expect(guidance.upcomingSteps, isEmpty);
      expect(guidance.estimatesFrozen, isTrue);
      // Suspended presentation on a native leg reports PARTIAL_NATIVE:
      // verified data exists but nothing is showable ahead right now.
      expect(guidance.mode, PedestrianGuidanceMode.partialNative);
    });

    test('confirmed off-route suspends maneuvers and offers rerouting', () {
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([legWith([turnRight(55.6)])]),
          offRoute: true,
        ),
      );
      expect(guidance.action, PedestrianGuidanceAction.returnToRoute);
      expect(guidance.maneuver, isNull);
      expect(guidance.maneuverState, ManeuverPresentationState.suspended);
    });

    test('paused and waiting-for-confirmation states suspend as well', () {
      final paused = service.guidanceFor(
        activeState(route: routeWith([legWith([turnRight(55.6)])]))
            .copyWith(status: NavigationStatus.paused),
      );
      expect(paused.maneuverState, ManeuverPresentationState.suspended);

      final waiting = service.guidanceFor(
        activeState(route: routeWith([legWith([turnRight(55.6)])]))
            .copyWith(isWaitingForNextLegConfirmation: true),
      );
      expect(waiting.action, PedestrianGuidanceAction.continueToNextStop);
      expect(waiting.maneuver, isNull);
      expect(waiting.maneuverState, ManeuverPresentationState.suspended);
    });

    test('cached fixes never present maneuvers as immediate commands', () {
      final state = LiveNavigationState(
        status: NavigationStatus.active,
        route: routeWith([legWith([turnRight(55.6)])]),
        currentLocation: UserLocationSnapshot(
          coordinate: a,
          timestamp: DateTime.now(),
          isCached: true,
        ),
        progressOnCurrentLegMeters: 0,
        remainingDistanceOnCurrentLegMeters: 55.6,
      );
      final guidance = service.guidanceFor(state);
      expect(guidance.action, PedestrianGuidanceAction.waitForGps);
      expect(guidance.maneuver, isNull);
    });
  });

  group('Close consecutive maneuvers (Part C4)', () {
    const service = PedestrianGuidanceService();

    test('close following maneuver is presented alongside the active one', () {
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([
            legWith([turnRight(55.6), turnLeft(75.6)]),
          ]),
          progress: 20,
        ),
      );
      expect(guidance.maneuver?.kind, PedestrianManeuverKind.right);
      expect(guidance.followingManeuver?.kind, PedestrianManeuverKind.left);
      expect(guidance.followingManeuverGapMeters, closeTo(20, 0.1));
      expect(
        guidance.instruction,
        'Через 40 м поверните направо',
      );
    });

    test('distant following maneuver stays in the steps list only', () {
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([
            legWith([turnRight(55.6), turnLeft(255.6)]),
          ]),
          progress: 0,
        ),
      );
      expect(guidance.followingManeuver, isNull);
      expect(guidance.upcomingSteps, hasLength(2));
      expect(guidance.upcomingSteps[1].maneuver.kind, PedestrianManeuverKind.left);
      expect(
        guidance.upcomingSteps[1].distanceMeters,
        closeTo(255.6, 0.1),
      );
    });

    test('steps list marks the active step and keeps later ones upcoming', () {
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([
            legWith([turnRight(55.6), turnLeft(75.6)]),
          ]),
          progress: 20,
        ),
      );
      expect(guidance.upcomingSteps.first.state,
          ManeuverPresentationState.approaching);
      expect(guidance.upcomingSteps[1].state,
          ManeuverPresentationState.upcoming);
    });
  });

  group('Distance consistency and sanitisation (Part C3)', () {
    const service = PedestrianGuidanceService();

    test('distance to maneuver never becomes negative near the event', () {
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([legWith([turnRight(55.6)])]),
          progress: 55.6,
        ),
      );
      expect(guidance.distanceToManeuverMeters, 0);
      expect(guidance.maneuverState, ManeuverPresentationState.imminent);
    });

    test('non-finite progress never leaks NaN or infinity into guidance', () {
      final state = activeState(
        route: routeWith([legWith([turnRight(55.6)])]),
      ).copyWith(
        progressOnCurrentLegMeters: double.nan,
        remainingDistanceOnCurrentLegMeters: double.infinity,
      );
      final guidance = service.guidanceFor(state);
      final distance = guidance.distanceToManeuverMeters;
      expect(distance == null || distance.isFinite, isTrue);
      expect(guidance.remainingDistanceMeters, isNull);
      expect(guidance.currentLegProgress.isFinite, isTrue);
    });

    test('maneuver distances use the leg geometry metric consistently', () {
      // 0.0005° latitude ≈ 55.6 m — the same Haversine basis as the GPS
      // projection, so the distance shown is exactly the remaining geometry.
      final guidance = service.guidanceFor(
        activeState(
          route: routeWith([legWith([turnRight(27.8)])]),
          progress: 10,
        ),
      );
      expect(guidance.distanceToManeuverMeters, closeTo(17.8, 0.2));
      expect(
        guidance.remainingDistanceMeters,
        closeTo(45.6, 0.2),
      );
    });
  });
}
