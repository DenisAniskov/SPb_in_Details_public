/// Stability policy for live off-route detection (v2.2).
///
/// A single noisy GPS fix must never flip the navigation UI into the off-route
/// state, and a confirmed state must not flap when fixes hover near the
/// threshold. The detector is a deterministic stateful filter:
///
/// onRoute → (fixes beyond the entry threshold, debounced) → offRoute
/// offRoute → (fixes clearly inside the return threshold, debounced) → onRoute
///
/// `suspected` marks that at least one accepted fix crossed the entry
/// threshold but the confirmation policy is not satisfied yet; it stays
/// internal and never reaches the UI on its own.
enum OffRoutePhase { onRoute, suspected, offRoute }

/// Consumes one already-validated live fix per call together with its distance
/// to the active route geometry (metres, from RouteProjectionUtils) and emits
/// the current phase. Fixes rejected by the navigation session (stale, cached,
/// invalid, out-of-order, accuracy >50 m) are never fed here.
class OffRouteDetector {
  OffRouteDetector({
    this.offRouteThresholdMeters = 50.0,
    this.returnToRouteThresholdMeters = 35.0,
    this.requiredOffRouteFixes = 3,
    this.offRouteSustainDuration = const Duration(seconds: 5),
    this.requiredOnRouteFixes = 2,
  }) : assert(offRouteThresholdMeters > returnToRouteThresholdMeters),
       assert(returnToRouteThresholdMeters > 0),
       assert(requiredOffRouteFixes >= 1),
       assert(requiredOnRouteFixes >= 1);

  /// Distance from route geometry above this value counts as a deviation fix.
  /// This is an engineering threshold, not a measured GPS error guarantee.
  /// Several fixes and a minimum time span are required to confirm deviation;
  /// physical-device field validation remains necessary for this policy.
  final double offRouteThresholdMeters;

  /// Hysteresis exit: a confirmed off-route session only starts returning to
  /// onRoute when fixes are clearly *inside* this tighter band. The dead band
  /// between [returnToRouteThresholdMeters] and [offRouteThresholdMeters]
  /// prevents on/off flapping for jitter near the boundary.
  final double returnToRouteThresholdMeters;

  /// Consecutive deviation fixes required to confirm off-route.
  final int requiredOffRouteFixes;

  /// Minimum wall-clock span from the first to the last deviation fix.
  /// Combined with the fix count it keeps confirmation time stable across
  /// devices with different GPS delivery rates (fast devices need the time
  /// span, slow devices need the fix count).
  final Duration offRouteSustainDuration;

  /// Consecutive fixes inside the return threshold required to accept the
  /// return to onRoute.
  final int requiredOnRouteFixes;

  OffRoutePhase _phase = OffRoutePhase.onRoute;
  int _deviationFixes = 0;
  int _returnFixes = 0;
  DateTime? _firstDeviationAt;

  OffRoutePhase get phase => _phase;
  bool get isConfirmedOffRoute => _phase == OffRoutePhase.offRoute;

  /// Feed one validated fix. Returns the phase after processing it.
  OffRoutePhase registerFix(
    DateTime timestamp,
    double distanceFromRouteMeters,
  ) {
    switch (_phase) {
      case OffRoutePhase.onRoute:
      case OffRoutePhase.suspected:
        if (distanceFromRouteMeters > offRouteThresholdMeters) {
          _returnFixes = 0;
          if (_phase == OffRoutePhase.onRoute) {
            _phase = OffRoutePhase.suspected;
            _firstDeviationAt = timestamp;
          }
          _deviationFixes++;
          final span = timestamp.difference(_firstDeviationAt!);
          if (_deviationFixes >= requiredOffRouteFixes &&
              span >= offRouteSustainDuration) {
            _phase = OffRoutePhase.offRoute;
          }
        } else {
          // Back within the entry threshold: a short excursion never latches.
          _phase = OffRoutePhase.onRoute;
          _deviationFixes = 0;
          _firstDeviationAt = null;
        }
        break;
      case OffRoutePhase.offRoute:
        if (distanceFromRouteMeters <= returnToRouteThresholdMeters) {
          _deviationFixes = 0;
          _firstDeviationAt = null;
          _returnFixes++;
          if (_returnFixes >= requiredOnRouteFixes) {
            _phase = OffRoutePhase.onRoute;
            _returnFixes = 0;
          }
        } else {
          // Dead band or still away: the return streak must start over.
          _returnFixes = 0;
        }
        break;
    }
    return _phase;
  }

  /// Breaks confirmation streaks when GPS observation is interrupted, while
  /// retaining a deviation that was already confirmed. An outage is not proof
  /// that the user returned to the route.
  void clearPendingFixes() {
    if (_phase == OffRoutePhase.suspected) _phase = OffRoutePhase.onRoute;
    _deviationFixes = 0;
    _returnFixes = 0;
    _firstDeviationAt = null;
  }

  /// Clears all state for a fresh leg, a reroute or a new session.
  void reset() {
    _phase = OffRoutePhase.onRoute;
    clearPendingFixes();
  }
}
