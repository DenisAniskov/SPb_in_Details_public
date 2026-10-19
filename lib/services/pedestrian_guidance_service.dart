import 'dart:math' as math;

import 'package:smart_navigator_spb/core/utils/maneuver_instruction_formatter.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';

/// Configurable, unit-tested presentation thresholds for maneuver
/// progression. Every value is meters along the accepted leg geometry — the
/// same application-computed basis as GPS progress — so no native distance
/// scale is ever mixed in.
class ManeuverProgressionThresholds {
  /// A maneuver within this distance of accepted progress «deserves
  /// attention». Default 100 m ≈ 1.2–1.5 min at tourist walking speed, and
  /// comfortably above typical urban GPS error for fixes that passed the
  /// accuracy gate, so the approaching state is driven by real progress.
  final double approachThresholdMeters;

  /// Under this distance the maneuver is imminent and the instruction drops
  /// its «Через …» prefix. Default 30 m: the same magnitude as the arrival
  /// radius, above the projection jitter of accepted fixes.
  final double imminentThresholdMeters;

  /// Two consecutive maneuvers closer than this are presented together
  /// («Затем …»), because between them the user has no time to act on a
  /// separate screen state. Default 40 m ≈ imminent threshold + GPS noise.
  final double closeManeuverGapMeters;

  const ManeuverProgressionThresholds({
    this.approachThresholdMeters = 100.0,
    this.imminentThresholdMeters = 30.0,
    this.closeManeuverGapMeters = 40.0,
  });
}

/// A future verified provider can replace presentation without owning the GPS
/// state machine. Guidance is synchronous and always tied to the given snapshot.
abstract class BasePedestrianGuidanceService {
  PedestrianGuidanceModel guidanceFor(LiveNavigationState state);
}

class PedestrianGuidanceService implements BasePedestrianGuidanceService {
  final ManeuverProgressionThresholds thresholds;

  const PedestrianGuidanceService({
    this.thresholds = const ManeuverProgressionThresholds(),
  });

  @override
  PedestrianGuidanceModel guidanceFor(LiveNavigationState state) {
    final leg = state.currentLeg;
    final fix = state.currentLocation;
    final gpsAvailable = !state.isGpsLost && !state.isPaused &&
        fix != null && !fix.isCached &&
        fix.isFresh(maxAge: const Duration(seconds: 15));
    final action = switch (state.status) {
      NavigationStatus.idle || NavigationStatus.error =>
        PedestrianGuidanceAction.unavailable,
      NavigationStatus.starting => PedestrianGuidanceAction.starting,
      NavigationStatus.rerouting => PedestrianGuidanceAction.rerouting,
      NavigationStatus.paused => PedestrianGuidanceAction.paused,
      NavigationStatus.completed => PedestrianGuidanceAction.completed,
      NavigationStatus.waitingForGps => PedestrianGuidanceAction.waitForGps,
      NavigationStatus.active => state.isWaitingForNextLegConfirmation
          ? PedestrianGuidanceAction.continueToNextStop
          : !gpsAvailable ? PedestrianGuidanceAction.waitForGps
          : state.isOffRoute ? PedestrianGuidanceAction.returnToRoute
          : PedestrianGuidanceAction.followRoute,
    };
    final progress = _nonNegative(state.progressOnCurrentLegMeters);
    final remaining = _nonNegative(state.remainingDistanceOnCurrentLegMeters);
    final total = progress + remaining;
    final fraction = total > 0 ? (progress / total).clamp(0.0, 1.0) : 0.0;
    final canEstimate = leg != null && total.isFinite && total > 0 &&
        state.remainingDistanceOnCurrentLegMeters.isFinite &&
        state.progressOnCurrentLegMeters.isFinite &&
        action != PedestrianGuidanceAction.rerouting &&
        action != PedestrianGuidanceAction.unavailable;
    final duration = canEstimate && leg.durationSeconds > 0
        ? (leg.durationSeconds * (1 - fraction)).ceil() : null;

    // Safe presentation state: accepted fresh GPS on the accepted route.
    // Everything else suppresses specific turn commands as unsafe.
    final presenting =
        action == PedestrianGuidanceAction.followRoute;
    final maneuvers = leg?.maneuvers;
    final cursor = state.currentManeuverIndex;
    final hasNativeData = maneuvers != null && maneuvers.isNotEmpty;
    final primary = presenting && hasNativeData && cursor < maneuvers.length
        ? maneuvers[cursor] : null;
    final distanceToManeuver = primary == null ? null : _gap(
      primary.offsetMeters, progress);
    final stepState = primary == null
        ? (presenting
            ? ManeuverPresentationState.unavailable
            : ManeuverPresentationState.suspended)
        : _stateFor(distanceToManeuver ?? 0, thresholds);
    final following = presenting &&
        primary != null &&
        hasNativeData &&
        cursor + 1 < maneuvers.length
        ? maneuvers[cursor + 1] : null;
    final followingGap = following == null
        ? null
        : _gap(following.offsetMeters, primary?.offsetMeters ?? 0);
    final showFollowing = following != null &&
        followingGap != null &&
        followingGap <= thresholds.closeManeuverGapMeters;

    final steps = <PedestrianManeuverStep>[];
    if (presenting && hasNativeData) {
      for (var i = cursor; i < maneuvers.length; i++) {
        final maneuver = maneuvers[i];
        final distance = _gap(maneuver.offsetMeters, progress);
        steps.add(PedestrianManeuverStep(
          maneuver: maneuver,
          distanceMeters: distance,
          state: i == cursor
              ? _stateFor(distance, thresholds)
              : ManeuverPresentationState.upcoming,
        ));
      }
    }

    // Data availability is a property of the route, not of the session
    // status: nativeAnnotations means a verified maneuver is showable ahead
    // right now. Suspended presentation (GPS loss, pause, off-route) on a
    // native leg therefore reports partialNative, and the presentation state
    // communicates the suppression.
    final mode = state.route == null ||
        state.status == NavigationStatus.idle ||
        state.status == NavigationStatus.error
        ? PedestrianGuidanceMode.unavailable
        : hasNativeData && primary != null
            ? PedestrianGuidanceMode.nativeAnnotations
            : hasNativeData
                ? PedestrianGuidanceMode.partialNative
                : PedestrianGuidanceMode.fallback;

    final native = primary != null && distanceToManeuver != null;
    final instruction = switch (action) {
      PedestrianGuidanceAction.unavailable => 'Навигация пока недоступна.',
      PedestrianGuidanceAction.starting => 'Получаем свежий сигнал GPS для прогулки.',
      PedestrianGuidanceAction.rerouting =>
        'Дождитесь нового маршрута к «${state.nextStopTitle}».',
      PedestrianGuidanceAction.paused =>
        'Вернитесь в приложение, чтобы продолжить навигацию.',
      PedestrianGuidanceAction.completed => 'Вы достигли последней точки прогулки.',
      PedestrianGuidanceAction.continueToNextStop =>
        'Осмотрите это место, затем продолжите к следующей точке.',
      PedestrianGuidanceAction.waitForGps =>
        'Дождитесь свежего сигнала GPS. Прогресс временно не обновляется.',
      PedestrianGuidanceAction.returnToRoute =>
        'Вернитесь к линии на карте или перестройте маршрут к следующей точке.',
      PedestrianGuidanceAction.followRoute => native
          ? ManeuverInstructionFormatter.composeInstruction(
              primary.instruction,
              distanceMeters: distanceToManeuver,
              imminentThresholdMeters: thresholds.imminentThresholdMeters,
            )
          : 'Продолжайте движение по отображённому пешеходному маршруту '
              'к следующей точке.',
    };
    return PedestrianGuidanceModel(
      routeSnapshot: state.route,
      legIndex: state.currentLegIndex,
      mode: mode,
      action: action,
      instruction: instruction,
      maneuver: native ? primary : null,
      followingManeuver: showFollowing ? following : null,
      distanceToManeuverMeters: native ? distanceToManeuver : null,
      followingManeuverGapMeters: showFollowing ? followingGap : null,
      upcomingSteps: List.unmodifiable(steps),
      maneuverState: stepState,
      remainingDistanceMeters: canEstimate ? remaining : null,
      remainingWalkingSeconds: duration,
      currentLegProgress: fraction,
      estimatesFrozen: action == PedestrianGuidanceAction.waitForGps ||
          action == PedestrianGuidanceAction.returnToRoute ||
          action == PedestrianGuidanceAction.paused,
      gpsAvailable: gpsAvailable,
    );
  }

  /// Remaining distance to a verified event, clamped against GPS noise:
  /// never negative, never NaN or infinite.
  double _gap(double offsetMeters, double progressMeters) {
    if (!offsetMeters.isFinite || offsetMeters < 0) return 0;
    return math.max(0.0, offsetMeters - progressMeters);
  }

  ManeuverPresentationState _stateFor(
    double distanceMeters,
    ManeuverProgressionThresholds thresholds,
  ) {
    if (distanceMeters <= thresholds.imminentThresholdMeters) {
      return ManeuverPresentationState.imminent;
    }
    if (distanceMeters <= thresholds.approachThresholdMeters) {
      return ManeuverPresentationState.approaching;
    }
    return ManeuverPresentationState.upcoming;
  }

  double _nonNegative(double value) => value.isFinite ? math.max(0, value) : 0;
}
