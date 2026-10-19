import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';

/// UI-layer «Следить за мной» camera-follow mode for active navigation.
///
/// Deliberately separate from the GPS navigation state machine: it only
/// reacts to already-accepted, projected positions and to native camera
/// gesture events. It owns no GPS subscription, no timers and no heading —
/// the map is never rotated, because no reliable pedestrian heading is
/// available.
class CameraFollowController extends ChangeNotifier {
  CameraFollowController({
    this.minFollowStepMeters = 8.0,
    this.onFollowMove,
  });

  /// Skip camera animation for micro-jitter below this distance: fewer
  /// native moves, less battery and no visible tremble while standing still.
  final double minFollowStepMeters;

  /// Invoked when the map should center on [GeoCoord]. The screen wires this
  /// to an animated native `Map.move`; the controller itself stays free of
  /// MapKit types so it stays unit-testable.
  final void Function(GeoCoord point)? onFollowMove;

  bool _following = false;
  GeoCoord? _lastFollowed;

  bool get following => _following;

  /// Opt in (or recenter after a manual gesture): follow immediately.
  void start(GeoCoord point) {
    _following = true;
    _lastFollowed = point;
    onFollowMove?.call(point);
    notifyListeners();
  }

  /// Feed an accepted, already-validated navigation position. Off-route,
  /// stale or unprojected positions must not reach this method.
  void onAcceptedPosition(GeoCoord projectedPoint) {
    if (!_following) return;
    if (!projectedPoint.latitude.isFinite ||
        !projectedPoint.longitude.isFinite) {
      return;
    }
    final last = _lastFollowed;
    if (last != null &&
        RouteProjectionUtils.distanceBetween(last, projectedPoint) <
            minFollowStepMeters) {
      return;
    }
    _lastFollowed = projectedPoint;
    onFollowMove?.call(projectedPoint);
  }

  /// The user dragged or zoomed the map (native CameraUpdateReason.Gestures):
  /// automatic following stops until an explicit recenter.
  void onCameraGesture() {
    if (!_following) return;
    _following = false;
    _lastFollowed = null;
    notifyListeners();
  }

  /// The explicit recenter action.
  void recenter(GeoCoord point) => start(point);
}

/// Bearing-free great-circle step used by tests and callers that need the
/// follow threshold math without a controller instance.
double followStepMeters(GeoCoord from, GeoCoord to) =>
    math.max(0, RouteProjectionUtils.distanceBetween(from, to));
