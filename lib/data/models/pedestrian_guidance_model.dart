import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';

/// Data-availability mode of the guidance snapshot. Internal distinction only:
/// it never claims that the current route actually returned annotations.
/// - [nativeAnnotations] — the current leg carries verified native maneuvers
///   and one is upcoming (NATIVE_MANEUVER_GUIDANCE).
/// - [partialNative] — the route carries some verified native maneuvers but
///   nothing is currently showable ahead (all passed on this leg, or a leg
///   without annotations inside an otherwise native route)
///   (PARTIAL_NATIVE_GUIDANCE).
/// - [fallback] — no verified maneuver metadata is available for the current
///   leg; honest route-following guidance only (GUIDANCE_FALLBACK).
/// - [unavailable] — no active navigation session or route snapshot
///   (GUIDANCE_UNAVAILABLE).
enum PedestrianGuidanceMode { nativeAnnotations, partialNative, fallback, unavailable }

enum PedestrianGuidanceAction {
  unavailable,
  starting,
  followRoute,
  waitForGps,
  returnToRoute,
  rerouting,
  paused,
  continueToNextStop,
  completed,
}

/// Presentation state of a maneuver relative to accepted GPS progress.
/// Transitions are derived from geometry progress only — never from timers or
/// raw straight-line proximity.
enum ManeuverPresentationState {
  /// A verified maneuver is ahead beyond the approach threshold.
  upcoming,

  /// Close enough that the maneuver deserves attention.
  approaching,

  /// Near the current accepted route position; the instruction drops its
  /// «Через …» distance prefix.
  imminent,

  /// Accepted progress confirms the event has been passed.
  passed,

  /// Native metadata is missing or ambiguous for this position.
  unavailable,

  /// GPS is unavailable, navigation is paused, waiting for the next stop
  /// confirmation or the user is off-route; specific instructions are
  /// suppressed as unsafe.
  suspended,
}

/// One row of the upcoming-steps view: a verified maneuver, its distance from
/// the accepted progress and its presentation state.
class PedestrianManeuverStep {
  final PedestrianManeuverModel maneuver;
  final double? distanceMeters;
  final ManeuverPresentationState state;

  const PedestrianManeuverStep({
    required this.maneuver,
    required this.state,
    this.distanceMeters,
  });
}

/// Presentation snapshot tied to one immutable route and leg. This contains
/// no GPS history and cannot advance navigation itself.
class PedestrianGuidanceModel {
  final PedestrianRouteModel? routeSnapshot;
  final int legIndex;
  final PedestrianGuidanceMode mode;
  final PedestrianGuidanceAction action;
  final String instruction;

  /// Next verified maneuver ahead, when native metadata permits.
  final PedestrianManeuverModel? maneuver;

  /// Verified maneuver right after [maneuver] on the same leg, shown as the
  /// «Затем …» line when the two events are close enough to present together.
  final PedestrianManeuverModel? followingManeuver;

  /// Distance from accepted progress to [maneuver], meters on the leg.
  final double? distanceToManeuverMeters;

  /// Distance from [maneuver] to [followingManeuver] along the leg.
  final double? followingManeuverGapMeters;

  /// Remaining verified steps on the current leg from the active cursor,
  /// including the active one. Empty in fallback and suspended states.
  final List<PedestrianManeuverStep> upcomingSteps;

  /// Presentation state of [maneuver] (or of the guidance itself when no
  /// maneuver is shown).
  final ManeuverPresentationState maneuverState;

  final double? remainingDistanceMeters;
  final int? remainingWalkingSeconds;
  final double currentLegProgress;
  final bool estimatesFrozen;
  final bool gpsAvailable;

  const PedestrianGuidanceModel({
    required this.routeSnapshot,
    required this.legIndex,
    required this.mode,
    required this.action,
    required this.instruction,
    required this.currentLegProgress,
    required this.estimatesFrozen,
    required this.gpsAvailable,
    this.maneuver,
    this.followingManeuver,
    this.distanceToManeuverMeters,
    this.followingManeuverGapMeters,
    this.upcomingSteps = const [],
    this.maneuverState = ManeuverPresentationState.unavailable,
    this.remainingDistanceMeters,
    this.remainingWalkingSeconds,
  });

  String? get formattedRemainingDistance => remainingDistanceMeters == null
      ? null : formatDistance(remainingDistanceMeters!);
  String? get formattedManeuverDistance => distanceToManeuverMeters == null
      ? null : formatDistance(distanceToManeuverMeters!);

  String? get formattedRemainingWalkingTime {
    final seconds = remainingWalkingSeconds;
    if (seconds == null) return null;
    if (seconds == 0) return '0 мин';
    if (seconds < 60) return '< 1 мин';
    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '$minutes мин';
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    return remainder == 0 ? '$hours ч' : '$hours ч $remainder мин';
  }

  static String formatDistance(double meters) => meters >= 1000
      ? '${(meters / 1000).toStringAsFixed(1)} км'
      : '${meters.round()} м';
}
