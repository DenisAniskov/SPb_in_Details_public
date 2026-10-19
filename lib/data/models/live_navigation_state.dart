import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';

/// Lifecycle state of a live navigation session.
enum NavigationStatus {
  idle,
  starting,
  active,
  /// The session is alive but guidance is suspended until a fresh valid fix
  /// arrives. The route, stops and progress are preserved; enabling the
  /// location service or granting permission resumes this same session.
  waitingForGps,
  rerouting,
  paused,
  completed,
  error,
}

/// Snapshot of the live navigation progress and state at a point in time.
class LiveNavigationState {
  final NavigationStatus status;
  final PedestrianRouteModel? route;
  final int currentLegIndex;
  final int currentManeuverIndex;
  final UserLocationSnapshot? currentLocation;
  final GeoCoord? projectedPoint;
  final double progressOnCurrentLegMeters;
  final double remainingDistanceOnCurrentLegMeters;
  final double totalProgressMeters;
  final double totalRemainingMeters;
  final double distanceFromRouteMeters;
  final bool isOffRoute;
  final bool isGpsLost;
  final String? arrivedPlaceTitle;
  final bool isWaitingForNextLegConfirmation;
  final String? errorMessage;

  const LiveNavigationState({
    this.status = NavigationStatus.idle,
    this.route,
    this.currentLegIndex = 0,
    this.currentManeuverIndex = 0,
    this.currentLocation,
    this.projectedPoint,
    this.progressOnCurrentLegMeters = 0.0,
    this.remainingDistanceOnCurrentLegMeters = 0.0,
    this.totalProgressMeters = 0.0,
    this.totalRemainingMeters = 0.0,
    this.distanceFromRouteMeters = 0.0,
    this.isOffRoute = false,
    this.isGpsLost = false,
    this.arrivedPlaceTitle,
    this.isWaitingForNextLegConfirmation = false,
    this.errorMessage,
  });

  bool get isActive => status == NavigationStatus.active;
  bool get isWaitingForGps => status == NavigationStatus.waitingForGps;
  bool get isRerouting => status == NavigationStatus.rerouting;
  bool get isCompleted => status == NavigationStatus.completed;
  bool get isPaused => status == NavigationStatus.paused;

  /// Current leg being navigated.
  RouteLegModel? get currentLeg {
    if (route == null || route!.legs.isEmpty) return null;
    if (currentLegIndex >= 0 && currentLegIndex < route!.legs.length) {
      return route!.legs[currentLegIndex];
    }
    return null;
  }

  /// Title of the upcoming stop/destination for the active leg.
  String get nextStopTitle {
    final leg = currentLeg;
    if (leg != null) {
      return leg.toTitle;
    }
    return route?.errorMessage ?? 'Точка назначения';
  }

  /// Formatted remaining distance to next stop.
  String get formattedRemainingDistance {
    final meters = remainingDistanceOnCurrentLegMeters;
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} км';
    }
    return '${meters.round()} м';
  }

  /// Tourist stops remain completed when current-leg geometry is rerouted.
  int get totalStopsCount => route?.legs.length ?? 0;

  int get completedStopsCount {
    if (isCompleted) return totalStopsCount;
    final completed =
        currentLegIndex + (isWaitingForNextLegConfirmation ? 1 : 0);
    return completed.clamp(0, totalStopsCount);
  }

  double get stopProgressFraction =>
      totalStopsCount == 0 ? 0 : completedStopsCount / totalStopsCount;

  /// Fraction along the current route geometry [0..1]. Rerouting rebases it;
  /// [completedStopsCount] separately retains tourist stop progress.
  double get totalProgressFraction {
    if (route == null || route!.distanceMeters <= 0) return 0.0;
    return (totalProgressMeters / route!.distanceMeters).clamp(0.0, 1.0);
  }

  LiveNavigationState copyWith({
    NavigationStatus? status,
    PedestrianRouteModel? route,
    int? currentLegIndex,
    int? currentManeuverIndex,
    UserLocationSnapshot? currentLocation,
    GeoCoord? projectedPoint,
    double? progressOnCurrentLegMeters,
    double? remainingDistanceOnCurrentLegMeters,
    double? totalProgressMeters,
    double? totalRemainingMeters,
    double? distanceFromRouteMeters,
    bool? isOffRoute,
    bool? isGpsLost,
    String? arrivedPlaceTitle,
    bool clearArrivedPlace = false,
    bool? isWaitingForNextLegConfirmation,
    String? errorMessage,
    bool clearError = false,
    bool clearProjectedPoint = false,
  }) {
    return LiveNavigationState(
      status: status ?? this.status,
      route: route ?? this.route,
      currentLegIndex: currentLegIndex ?? this.currentLegIndex,
      currentManeuverIndex: currentManeuverIndex ?? this.currentManeuverIndex,
      currentLocation: currentLocation ?? this.currentLocation,
      projectedPoint: clearProjectedPoint
          ? null
          : (projectedPoint ?? this.projectedPoint),
      progressOnCurrentLegMeters:
          progressOnCurrentLegMeters ?? this.progressOnCurrentLegMeters,
      remainingDistanceOnCurrentLegMeters:
          remainingDistanceOnCurrentLegMeters ??
          this.remainingDistanceOnCurrentLegMeters,
      totalProgressMeters: totalProgressMeters ?? this.totalProgressMeters,
      totalRemainingMeters: totalRemainingMeters ?? this.totalRemainingMeters,
      distanceFromRouteMeters:
          distanceFromRouteMeters ?? this.distanceFromRouteMeters,
      isOffRoute: isOffRoute ?? this.isOffRoute,
      isGpsLost: isGpsLost ?? this.isGpsLost,
      arrivedPlaceTitle: clearArrivedPlace
          ? null
          : (arrivedPlaceTitle ?? this.arrivedPlaceTitle),
      isWaitingForNextLegConfirmation:
          isWaitingForNextLegConfirmation ??
          this.isWaitingForNextLegConfirmation,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
