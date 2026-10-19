import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';

class GeoCoord {
  final double latitude;
  final double longitude;

  const GeoCoord(this.latitude, this.longitude);
}

class RouteStepModel {
  final String instruction;
  final double distanceMeters;
  final int durationSeconds;

  const RouteStepModel({
    required this.instruction,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

/// Only actions/landmarks supplied by MapKit pedestrian fitness annotations.
/// A leg is a transition between stops; these events are a separate layer.
enum PedestrianManeuverKind {
  straight,
  left,
  right,
  crosswalk,
  stairsToUnderpass,
  stairsToOverpass,
  stairs,
  stairsDown,
  stairsUp,
}

/// Where a maneuver came from. Only verified native annotation data is
/// accepted; no fabricated geometry-angle turns exist anywhere in the app.
enum PedestrianManeuverSource { nativeAnnotation }

class PedestrianManeuverModel {
  final PedestrianManeuverKind kind;
  final int segmentIndex;
  final double segmentPosition;

  /// Distance along the owning leg's geometry, in the same meters as the GPS
  /// projection (application-computed polyline length, not a native scale).
  final double offsetMeters;

  /// Index of the owning leg inside the route. A maneuver never leaks its
  /// identity across legs; rerouted legs re-stamp their replacement events.
  final int legIndex;

  final PedestrianManeuverSource source;

  const PedestrianManeuverModel({
    required this.kind,
    required this.segmentIndex,
    required this.segmentPosition,
    required this.offsetMeters,
    this.legIndex = 0,
    this.source = PedestrianManeuverSource.nativeAnnotation,
  });

  /// Re-association when a rebuilt leg adopts verified maneuvers: identities
  /// are preserved, only the owning-leg stamp changes.
  PedestrianManeuverModel withLegIndex(int newLegIndex) =>
      PedestrianManeuverModel(
        kind: kind,
        segmentIndex: segmentIndex,
        segmentPosition: segmentPosition,
        offsetMeters: offsetMeters,
        legIndex: newLegIndex,
        source: source,
      );

  /// Application localization of a typed SDK event, never parsed for logic.
  String get instruction => switch (kind) {
    PedestrianManeuverKind.straight => 'Продолжайте прямо',
    PedestrianManeuverKind.left => 'Поверните налево',
    PedestrianManeuverKind.right => 'Поверните направо',
    PedestrianManeuverKind.crosswalk => 'Перейдите по пешеходному переходу',
    PedestrianManeuverKind.stairsToUnderpass =>
      'Спуститесь в подземный переход',
    PedestrianManeuverKind.stairsToOverpass =>
      'Поднимитесь на надземный переход',
    PedestrianManeuverKind.stairs => 'Пройдите по лестнице',
    PedestrianManeuverKind.stairsDown => 'Спуститесь по лестнице',
    PedestrianManeuverKind.stairsUp => 'Поднимитесь по лестнице',
  };

  /// Phase C5: re-stamps a validated maneuver onto a combined scenic-stage
  /// geometry (real MapKit segments merged at shared waypoints). Returns
  /// null when the rebased position no longer resolves on the combined
  /// geometry, so an ambiguous stage is rejected instead of guessed.
  PedestrianManeuverModel? rebaseOntoCombinedGeometry({
    required int pointShift,
    required double lengthShift,
    required List<GeoCoord> combinedGeometry,
  }) {
    final shiftedIndex = segmentIndex + pointShift;
    final shiftedOffset = offsetMeters + lengthShift;
    if (shiftedIndex < 0 || shiftedIndex >= combinedGeometry.length) {
      return null;
    }
    if (!shiftedOffset.isFinite || shiftedOffset < 0) return null;
    final coordinate = PedestrianManeuverModel(
      kind: kind,
      segmentIndex: shiftedIndex,
      segmentPosition: segmentPosition,
      offsetMeters: shiftedOffset,
      legIndex: legIndex,
      source: source,
    ).coordinateOnLeg(combinedGeometry);
    if (coordinate == null) return null;
    return PedestrianManeuverModel(
      kind: kind,
      segmentIndex: shiftedIndex,
      segmentPosition: segmentPosition,
      offsetMeters: shiftedOffset,
      legIndex: legIndex,
      source: source,
    );
  }

  /// Verified map location of the event: interpolation of the native
  /// (segmentIndex, segmentPosition) over the owning leg's geometry. Returns
  /// null when the position no longer matches the geometry it was validated
  /// against, so a map marker can never be placed at a guessed point.
  GeoCoord? coordinateOnLeg(List<GeoCoord> geometry) {
    if (geometry.length < 2) return null;
    final index = segmentIndex;
    final fraction = segmentPosition;
    if (!fraction.isFinite || fraction < 0 || fraction > 1) return null;
    if (index < 0 || index >= geometry.length) return null;
    if (!geometry[index].latitude.isFinite ||
        !geometry[index].longitude.isFinite) {
      return null;
    }
    // Terminal position (last point, fraction 0) is a legal validated event.
    if (index == geometry.length - 1) {
      if (fraction != 0) return null;
      return geometry[index];
    }
    if (index >= geometry.length - 1) return null;
    final a = geometry[index];
    final b = geometry[index + 1];
    final lat = a.latitude + fraction * (b.latitude - a.latitude);
    final lon = a.longitude + fraction * (b.longitude - a.longitude);
    if (!lat.isFinite || !lon.isFinite) return null;
    return GeoCoord(lat, lon);
  }
}

class RouteLegModel {
  final String fromTitle;
  final String toTitle;
  final double distanceMeters;
  final int durationSeconds;
  final List<GeoCoord> geometryPoints;
  final List<PedestrianManeuverModel> maneuvers;

  /// Editorial visiting time at [toTitle], when the leg destination is a
  /// catalog place. Null for synthetic or rerouted origins that carry no
  /// catalog record; display code must treat null as «неизвестно».
  final int? visitMinutes;

  /// Scenic metadata when this leg is a combined scenic stage (Phase C5):
  /// real MapKit segments through verified scenic waypoints, merged into
  /// ONE tourist transition. Null for normal legs and for rerouted stages
  /// (a reroute honestly drops the scenic detour). A scenic leg is still
  /// exactly one leg: waypoints never become tourist stops.
  final ScenicStageInfo? scenic;

  const RouteLegModel({
    required this.fromTitle,
    required this.toTitle,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.geometryPoints,
    this.maneuvers = const [],
    this.visitMinutes,
    this.scenic,
  });
}

class PedestrianRouteModel {
  final double distanceMeters;
  final int durationSeconds;
  final List<GeoCoord> geometryPoints;
  final List<RouteStepModel> steps;
  final List<RouteLegModel> legs;
  final int placesCount;
  final String? errorMessage;

  /// The kind of walk this snapshot represents (Phase C5): scenic when the
  /// route was actually built through verified scenic waypoints, normal for
  /// ordinary walks and for honest scenic fallbacks. The fallback reason
  /// lives in the routing provider, not in the immutable snapshot.
  final WalkKind walkKind;

  const PedestrianRouteModel({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.geometryPoints,
    required this.steps,
    this.legs = const [],
    this.placesCount = 1,
    this.errorMessage,
    this.walkKind = WalkKind.normal,
  });

  /// Copy at the publication boundary: native routing implementations may
  /// retain mutable lists, while map updates compare snapshot identities.
  PedestrianRouteModel immutableSnapshot() => PedestrianRouteModel(
    distanceMeters: distanceMeters,
    durationSeconds: durationSeconds,
    geometryPoints: List.unmodifiable(geometryPoints),
    steps: List.unmodifiable(steps),
    legs: List.unmodifiable(
      legs.map(
        (leg) => RouteLegModel(
          fromTitle: leg.fromTitle,
          toTitle: leg.toTitle,
          distanceMeters: leg.distanceMeters,
          durationSeconds: leg.durationSeconds,
          geometryPoints: List.unmodifiable(leg.geometryPoints),
          maneuvers: List.unmodifiable(leg.maneuvers),
          visitMinutes: leg.visitMinutes,
          scenic: leg.scenic?.immutableSnapshot(),
        ),
      ),
    ),
    placesCount: placesCount,
    errorMessage: errorMessage,
    walkKind: walkKind,
  );

  String get formattedDistance {
    if (distanceMeters >= 1000) {
      final km = distanceMeters / 1000;
      return '${km.toStringAsFixed(1)} км';
    }
    return '${distanceMeters.round()} м';
  }

  String get formattedDuration {
    final minutes = (durationSeconds / 60).round();
    if (minutes < 1) {
      return '< 1 мин';
    } else if (minutes < 60) {
      return '$minutes мин';
    } else {
      final hours = minutes ~/ 60;
      final remainingMins = minutes % 60;
      return remainingMins > 0 ? '$hours ч $remainingMins мин' : '$hours ч';
    }
  }

  bool get isWalkRoute => legs.isNotEmpty && placesCount > 1;

  /// Явное обозначение времени чисто пешего перехода (без осмотра достопримечательностей)
  String get formattedWalkingDurationNote =>
      'Время ходьбы: ~$formattedDuration (без учёта времени посещения объектов)';
}
