import 'dart:math' as math;
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';

/// Mathematically sound geospatial projection utilities for pedestrian routes.
class RouteProjectionUtils {
  RouteProjectionUtils._();

  static const double earthRadiusMeters = 6371000.0;

  /// Haversine distance in meters between two coordinates.
  static double distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);

    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  static double distanceBetween(GeoCoord a, GeoCoord b) {
    return distanceMeters(a.latitude, a.longitude, b.latitude, b.longitude);
  }

  /// Total distance in meters along a polyline.
  static double polylineLengthMeters(List<GeoCoord> points) {
    if (points.length < 2) return 0.0;
    double total = 0.0;
    for (int i = 0; i < points.length - 1; i++) {
      total += distanceBetween(points[i], points[i + 1]);
    }
    return total;
  }

  /// Convert (lat, lon) to local tangent plane Cartesian coordinates (x, y in meters)
  /// centered at [reference].
  static ({double x, double y}) toLocalMeters(
    GeoCoord point,
    GeoCoord reference,
  ) {
    final dLat = _degToRad(point.latitude - reference.latitude);
    final dLon = _degToRad(point.longitude - reference.longitude);
    final refLatRad = _degToRad(reference.latitude);

    final y = dLat * earthRadiusMeters;
    final x = dLon * earthRadiusMeters * math.cos(refLatRad);
    return (x: x, y: y);
  }

  /// Project Cartesian point P onto segment AB.
  /// Returns clamped factor t in [0.0, 1.0], projected point, and distance in meters.
  static ({
    double t,
    double projX,
    double projY,
    double distance,
  }) projectPointToSegmentCartesian({
    required double px,
    required double py,
    required double ax,
    required double ay,
    required double bx,
    required double by,
  }) {
    final dx = bx - ax;
    final dy = by - ay;
    final segLenSq = dx * dx + dy * dy;

    double t = 0.0;
    if (segLenSq > 1e-9) {
      t = ((px - ax) * dx + (py - ay) * dy) / segLenSq;
      t = t.clamp(0.0, 1.0);
    }

    final projX = ax + t * dx;
    final projY = ay + t * dy;
    final distSq = (px - projX) * (px - projX) + (py - projY) * (py - projY);
    return (
      t: t,
      projX: projX,
      projY: projY,
      distance: math.sqrt(distSq),
    );
  }

  /// The REMAINING tail of a polyline: everything after [distanceMeters],
  /// measured along the line from its start.
  ///
  /// The cut point is interpolated inside its segment, so the tail begins
  /// exactly where the walker stands and keeps every original vertex that
  /// still lies ahead — a remaining path is never straightened into a chord
  /// between its ends. Fewer than two points back means nothing is left of
  /// the line; a non-positive distance returns the whole polyline.
  static List<GeoCoord> polylineTail(
    List<GeoCoord> points,
    double distanceMeters,
  ) {
    if (points.length < 2) return const [];
    if (distanceMeters <= 0) return List.unmodifiable(points);
    final tail = <GeoCoord>[];
    var accumulated = 0.0;
    for (var i = 1; i < points.length; ++i) {
      final segment = distanceBetween(points[i - 1], points[i]);
      if (tail.isEmpty) {
        if (accumulated + segment <= distanceMeters) {
          accumulated += segment;
          continue; // wholly behind the walker
        }
        if (segment > 0) {
          final local = ((distanceMeters - accumulated) / segment).clamp(0.0, 1.0);
          if (local < 1.0) {
            tail.add(
              GeoCoord(
                points[i - 1].latitude +
                    (points[i].latitude - points[i - 1].latitude) * local,
                points[i - 1].longitude +
                    (points[i].longitude - points[i - 1].longitude) * local,
              ),
            );
          }
        }
      }
      tail.add(points[i]);
      accumulated += segment;
    }
    return List.unmodifiable(tail);
  }

  /// Project a GPS position onto a route polyline.
  /// Finds the closest point on any segment of the polyline, distance from route,
  /// cumulative progress along polyline in meters, and remaining distance in meters.
  static RouteProjectionResult projectOntoPolyline({
    required GeoCoord point,
    required List<GeoCoord> polyline,
  }) {
    if (polyline.isEmpty) {
      return const RouteProjectionResult(
        distanceFromRouteMeters: 0.0,
        progressMeters: 0.0,
        remainingDistanceMeters: 0.0,
        nearestPoint: GeoCoord(0.0, 0.0),
        segmentIndex: 0,
      );
    }

    if (polyline.length == 1) {
      final dist = distanceBetween(point, polyline.first);
      return RouteProjectionResult(
        distanceFromRouteMeters: dist,
        progressMeters: 0.0,
        remainingDistanceMeters: 0.0,
        nearestPoint: polyline.first,
        segmentIndex: 0,
      );
    }

    final totalLen = polylineLengthMeters(polyline);
    final ref = polyline.first;
    final pLoc = toLocalMeters(point, ref);

    double minDistance = double.infinity;
    double bestProgressMeters = 0.0;
    int bestSegmentIndex = 0;
    GeoCoord bestProjPoint = polyline.first;

    double accumulatedDistanceBeforeSegment = 0.0;

    for (int i = 0; i < polyline.length - 1; i++) {
      final aLoc = toLocalMeters(polyline[i], ref);
      final bLoc = toLocalMeters(polyline[i + 1], ref);
      final segLen = distanceBetween(polyline[i], polyline[i + 1]);

      final proj = projectPointToSegmentCartesian(
        px: pLoc.x,
        py: pLoc.y,
        ax: aLoc.x,
        ay: aLoc.y,
        bx: bLoc.x,
        by: bLoc.y,
      );

      if (proj.distance < minDistance) {
        minDistance = proj.distance;
        bestSegmentIndex = i;
        bestProgressMeters = accumulatedDistanceBeforeSegment + (proj.t * segLen);

        // Approximate geographic coordinate of projected point
        final lat = polyline[i].latitude +
            proj.t * (polyline[i + 1].latitude - polyline[i].latitude);
        final lon = polyline[i].longitude +
            proj.t * (polyline[i + 1].longitude - polyline[i].longitude);
        bestProjPoint = GeoCoord(lat, lon);
      }

      accumulatedDistanceBeforeSegment += segLen;
    }

    final remaining = (totalLen - bestProgressMeters).clamp(0.0, totalLen);

    return RouteProjectionResult(
      distanceFromRouteMeters: minDistance,
      progressMeters: bestProgressMeters,
      remainingDistanceMeters: remaining,
      nearestPoint: bestProjPoint,
      segmentIndex: bestSegmentIndex,
    );
  }

  static double _degToRad(double deg) => deg * (math.pi / 180.0);
}

class RouteProjectionResult {
  final double distanceFromRouteMeters;
  final double progressMeters;
  final double remainingDistanceMeters;
  final GeoCoord nearestPoint;
  final int segmentIndex;

  const RouteProjectionResult({
    required this.distanceFromRouteMeters,
    required this.progressMeters,
    required this.remainingDistanceMeters,
    required this.nearestPoint,
    required this.segmentIndex,
  });
}
