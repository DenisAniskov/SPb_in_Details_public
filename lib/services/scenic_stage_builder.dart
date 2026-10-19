import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';

/// Why a scenic chain could not be combined into one stage. Every value is a
/// structural-validity failure; the caller keeps the normal stage.
enum ScenicStageFailure {
  emptySegments,
  degenerateGeometry,
  junctionNotContinuous,
  maneuverRebaseFailed,
  maneuverOrderBroken,
  zeroLength,
}

/// Measured state of one junction between two native segments.
class ScenicJunctionGap {
  /// Distance between the end of the earlier segment and the start of the
  /// later one (meters, local tangent plane).
  final double gapMeters;

  /// Whether the join policy accepts this junction — i.e. the two segments
  /// share a bit-identical coordinate. A `false` here with
  /// [bothWithinSnapRadius] true describes a junction that is eligible for
  /// engine-side native confirmation, not one the builder may join.
  final bool accepted;

  /// Whether both endpoints sit within the waypoint snap radius — i.e. both
  /// are MapKit's projections of the same requested verified waypoint.
  final bool bothWithinSnapRadius;

  const ScenicJunctionGap({
    required this.gapMeters,
    required this.accepted,
    required this.bothWithinSnapRadius,
  });
}

/// Structured result of [ScenicStageBuilder.combineDetailed].
class ScenicStageBuildOutcome {
  final RouteLegModel? leg;
  final ScenicStageFailure? failure;
  final List<ScenicJunctionGap> junctions;

  const ScenicStageBuildOutcome({
    required this.leg,
    required this.failure,
    this.junctions = const [],
  });

  bool get ok => leg != null;
}

/// Phase C5 §2: builds ONE tourist stage (one `RouteLegModel`) from several
/// real MapKit pedestrian segments routed through scenic waypoints.
///
/// Invariants:
/// - every input segment is a genuine `PedestrianRouter` result; segments
///   must meet at the SAME physical point (the scenic waypoint) with a
///   bit-identical shared coordinate — acceptance is exactness alone, never a
///   geometric tolerance. A junction MapKit snapped apart is confirmed by the
///   engine with a real route between the two projections, whose own geometry
///   is spliced into the chain as its own segment, so the builder still
///   receives exactly continuous native chains and no geometry is invented;
/// - the combined leg is a single tourist transition: its endpoint is the
///   tourist stop, so waypoints never produce arrivals, visit time or
///   extra stop-count entries;
/// - maneuvers of later segments are REBASED onto the combined geometry
///   (segmentIndex shift + offset shift) and re-validated for order, so
///   the C4 guidance engine works on the combined leg unchanged;
/// - declared distance/duration are the sums of the native segment values;
///   the walking metric stays the application's geometric polyline length.
class ScenicStageBuilder {
  const ScenicStageBuilder();

  /// Maximum coordinate mismatch (degrees) for shared waypoint endpoints.
  /// Two requests through the SAME waypoint may return bit-identical
  /// coordinates; this is the exactness band.
  static const double endpointToleranceDegrees = 1e-9;

  /// §5 confirmation band: a non-exact junction is only *eligible for native
  /// confirmation* when the two projections differ by at most this many
  /// meters AND both stay within [maxSnapFromWaypointMeters] of the shared
  /// verified waypoint. Eligibility never becomes acceptance here: this
  /// builder joins bit-identical coordinates or not at all, and the engine
  /// confirms an eligible junction with a real MapKit route whose geometry it
  /// splices into the stage.
  static const double maxJoinGapMeters = 2.0;

  /// Both snapped endpoints must stay this close to the requested waypoint
  /// (which lies on a verified public pedestrian way).
  static const double maxSnapFromWaypointMeters = 15.0;

  /// A confirming native route may not exceed
  /// `max(connectorDetourFactor × gap, gap + connectorExtraMeters)`: a short
  /// MapKit route between the two projections proves the walkway is
  /// continuous; a longer one means the walk would have to go around
  /// something and the candidate is rejected.
  static const double connectorDetourFactor = 2.0;
  static const double connectorExtraMeters = 5.0;

  /// Whether two coordinates are the same point within the exactness band
  /// ([endpointToleranceDegrees]). Single source of truth for the engine's
  /// junction resolution and the assembly check below.
  static bool sameCoordinate(GeoCoord a, GeoCoord b) =>
      (a.latitude - b.latitude).abs() <= endpointToleranceDegrees &&
      (a.longitude - b.longitude).abs() <= endpointToleranceDegrees;

  /// The largest distance a confirming native connector may span for a
  /// measured [gapMeters].
  static double maxConnectorMeters(double gapMeters) =>
      gapMeters * connectorDetourFactor > gapMeters + connectorExtraMeters
          ? gapMeters * connectorDetourFactor
          : gapMeters + connectorExtraMeters;

  /// Single source of truth for the junction *eligibility* verdict, shared by
  /// the engine diagnostics and the confirmation policy: whether an inexact
  /// junction may be offered to MapKit for confirmation. It never accepts a
  /// junction — only [combineDetailed]'s exactness check does. `false` for
  /// non-finite measurements.
  static bool junctionEligibleForConfirmation({
    required double gapMeters,
    required double snapFromEndMeters,
    required double snapFromStartMeters,
  }) =>
      gapMeters.isFinite &&
      gapMeters <= maxJoinGapMeters &&
      snapFromEndMeters <= maxSnapFromWaypointMeters &&
      snapFromStartMeters <= maxSnapFromWaypointMeters;

  /// Combines [segments] into one leg. Returns null (never throws) when the
  /// input is not a valid scenic chain: the caller keeps the normal stage.
  RouteLegModel? combine({
    required List<RouteLegModel> segments,
    required int legIndex,
    required ScenicStageInfo scenic,
    List<GeoCoord>? junctionWaypoints,
  }) =>
      combineDetailed(
        segments: segments,
        legIndex: legIndex,
        scenic: scenic,
        junctionWaypoints: junctionWaypoints,
      ).leg;

  /// [combine] with the diagnosis: which structural check failed and what
  /// was measured at every junction. [junctionWaypoints], when given, holds
  /// the requested verified waypoint at each junction (length
  /// `segments.length - 1`); it supplies the MEASUREMENT (waypoint snap
  /// distances, reported below) and the length check only. Acceptance is
  /// bit-identical endpoint equality in every case — a direct caller can
  /// never join two segments by geometric tolerance.
  ScenicStageBuildOutcome combineDetailed({
    required List<RouteLegModel> segments,
    required int legIndex,
    required ScenicStageInfo scenic,
    List<GeoCoord>? junctionWaypoints,
  }) {
    if (segments.isEmpty) {
      return const ScenicStageBuildOutcome(
        leg: null,
        failure: ScenicStageFailure.emptySegments,
      );
    }
    for (final segment in segments) {
      if (segment.geometryPoints.length < 2) {
        return const ScenicStageBuildOutcome(
          leg: null,
          failure: ScenicStageFailure.degenerateGeometry,
        );
      }
      if (segment.geometryPoints.any(
        (p) =>
            !p.latitude.isFinite ||
            !p.longitude.isFinite ||
            p.latitude.abs() > 90 ||
            p.longitude.abs() > 180,
      )) {
        return const ScenicStageBuildOutcome(
          leg: null,
          failure: ScenicStageFailure.degenerateGeometry,
        );
      }
    }
    if (junctionWaypoints != null &&
        junctionWaypoints.length != segments.length - 1) {
      return const ScenicStageBuildOutcome(
        leg: null,
        failure: ScenicStageFailure.junctionNotContinuous,
      );
    }
    final junctions = <ScenicJunctionGap>[];
    for (var i = 0; i + 1 < segments.length; i++) {
      final end = segments[i].geometryPoints.last;
      final nextStart = segments[i + 1].geometryPoints.first;
      final same = sameCoordinate(end, nextStart);
      final gapMeters = RouteProjectionUtils.distanceBetween(end, nextStart);
      final waypoint = junctionWaypoints?[i];
      var snapEnd = double.infinity;
      var snapStart = double.infinity;
      if (waypoint != null) {
        snapEnd = RouteProjectionUtils.distanceBetween(end, waypoint);
        snapStart = RouteProjectionUtils.distanceBetween(nextStart, waypoint);
      }
      final bothWithinSnapRadius =
          waypoint != null &&
              snapEnd <= maxSnapFromWaypointMeters &&
              snapStart <= maxSnapFromWaypointMeters;
      // Acceptance is EXACTNESS only: a non-exact junction is rejected here,
      // whatever the waypoint measurements say. The band constants describe
      // when the engine may spend a native confirmation request on such a
      // junction and splice the confirmed connector's own geometry (making
      // the shared point bit-identical); they never widen the acceptance of a
      // direct call.
      final accepted = same;
      junctions.add(ScenicJunctionGap(
        gapMeters: gapMeters,
        accepted: accepted,
        bothWithinSnapRadius: bothWithinSnapRadius,
      ));
      if (!accepted) {
        return ScenicStageBuildOutcome(
          leg: null,
          failure: ScenicStageFailure.junctionNotContinuous,
          junctions: List.unmodifiable(junctions),
        );
      }
    }

    final combined = <GeoCoord>[
      ...segments.first.geometryPoints,
      for (var i = 1; i < segments.length; i++)
        ...segments[i].geometryPoints.skip(1),
    ];
    if (RouteProjectionUtils.polylineLengthMeters(combined) <= 0) {
      return ScenicStageBuildOutcome(
        leg: null,
        failure: ScenicStageFailure.zeroLength,
        junctions: List.unmodifiable(junctions),
      );
    }

    final maneuvers = <PedestrianManeuverModel>[];
    var pointOffset = 0;
    var lengthOffset = 0.0;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      for (final maneuver in segment.maneuvers) {
        final rebased = maneuver.rebaseOntoCombinedGeometry(
          pointShift: pointOffset,
          lengthShift: lengthOffset,
          combinedGeometry: combined,
        );
        if (rebased == null) {
          // Ambiguous — reject the stage (never guess a turn location).
          return ScenicStageBuildOutcome(
            leg: null,
            failure: ScenicStageFailure.maneuverRebaseFailed,
            junctions: List.unmodifiable(junctions),
          );
        }
        if (maneuvers.isNotEmpty &&
            rebased.offsetMeters < maneuvers.last.offsetMeters) {
          return ScenicStageBuildOutcome(
            leg: null,
            failure: ScenicStageFailure.maneuverOrderBroken,
            junctions: List.unmodifiable(junctions),
          );
        }
        maneuvers.add(rebased.withLegIndex(legIndex));
      }
      pointOffset += segment.geometryPoints.length - 1;
      lengthOffset += RouteProjectionUtils.polylineLengthMeters(
        segment.geometryPoints,
      );
    }

    return ScenicStageBuildOutcome(
      leg: RouteLegModel(
        fromTitle: segments.first.fromTitle,
        toTitle: segments.last.toTitle,
        distanceMeters: segments.fold(0.0, (sum, s) => sum + s.distanceMeters),
        durationSeconds: segments.fold(0, (sum, s) => sum + s.durationSeconds),
        geometryPoints: List.unmodifiable(combined),
        maneuvers: List.unmodifiable(maneuvers),
        visitMinutes: segments.last.visitMinutes,
        scenic: scenic,
      ),
      failure: null,
      junctions: List.unmodifiable(junctions),
    );
  }
}
