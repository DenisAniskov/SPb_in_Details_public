import 'package:flutter/foundation.dart';

import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';

/// Virtual shade clock for the C4.1 simulator (Phase C7.1 §15.1).
///
/// `virtual_datetime = selected_departure + simulated_route_elapsed`
///
/// The clock mirrors the simulator's own elapsed virtual time — it never
/// mixes device wall-clock time with simulated time. Consequences that are
/// enforced here rather than documented only:
///
/// * while the simulation is paused the elapsed time (and therefore the model
///   time) is frozen, because the controller does not advance it;
/// * on `restart`, `seek` and leg transitions the controller rebases the
///   elapsed time and the model time follows it;
/// * an overlay computed for one model time stays valid only while the model
///   time is within [refreshStep] of it. It is then reported as needing a
///   refresh — the recomputation is a bounded backend call, so it happens on
///   that cadence and never on every simulator tick (§15.3);
/// * after a route rebuild the overlay is invalid outright: a stale overlay
///   must never sit on different geometry (§15.4).
///
/// The clock notifies its listeners only when its meaningful state changes:
/// the refresh verdict flips, an analysis is recorded, the clock is armed or
/// invalidated, or the displayed model time crosses a virtual minute. It is
/// never a per-tick notification.
class VirtualShadeClock extends ChangeNotifier {
  /// How far the model time may drift before the overlay needs a re-analysis.
  static const Duration refreshStep = Duration(minutes: 15);

  VirtualShadeClock({SimulationController? controller}) {
    if (controller != null) attach(controller);
  }

  SimulationController? _controller;
  DateTime? _departure;
  Duration _elapsed = Duration.zero;
  DateTime? _analyzedFor;
  bool _needsRefresh = true;
  int? _notifiedMinuteKey;

  /// The user asked for the overlay (map layer on).
  bool overlayRequested = false;

  void attach(SimulationController controller) {
    _controller?.removeListener(_onControllerTick);
    _controller = controller;
    controller.addListener(_onControllerTick);
    _elapsed = controller.simulatedElapsed;
    _recomputeRefreshFlag();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerTick);
    _controller = null;
    super.dispose();
  }

  void _onControllerTick() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.simulatedElapsed == _elapsed) return;
    _elapsed = controller.simulatedElapsed;
    _recomputeRefreshFlag();
  }

  /// Set (or change) the departure instant the simulation starts from. Any
  /// previous analysis belongs to another virtual time and is dropped.
  void arm(DateTime departure) {
    _departure = departure;
    _elapsed = _controller?.simulatedElapsed ?? Duration.zero;
    _analyzedFor = null;
    _recomputeRefreshFlag();
  }

  /// Mirror an elapsed virtual time directly (tests and callers without a
  /// controller).
  void onSimulationTick(Duration elapsed) {
    if (elapsed == _elapsed) return;
    _elapsed = elapsed;
    _recomputeRefreshFlag();
  }

  Duration get elapsed => _elapsed;

  /// The departure the virtual time is anchored to, or null when unarmed.
  /// With a controller, `modelTime == departure + simulated elapsed`.
  DateTime? get departure => _departure;

  /// The model time the shade analysis must be evaluated at, or null when no
  /// departure has been set yet.
  DateTime? get modelTime => _departure?.add(_elapsed);

  DateTime? get analyzedFor => _analyzedFor;

  /// Whether an overlay may be shown right now.
  bool get overlayValid => overlayRequested && _analyzedFor != null;

  /// True when the current analysis is missing or too far from the model time.
  bool get needsReanalysis => _needsRefresh;

  /// Record that an analysis was produced for [forModelTime].
  void markAnalyzed(DateTime forModelTime) {
    _analyzedFor = forModelTime;
    _recomputeRefreshFlag();
  }

  /// Invalidate the overlay (route rebuilt, navigation started, time changed).
  void invalidate() {
    _analyzedFor = null;
    _recomputeRefreshFlag();
  }

  void _recomputeRefreshFlag() {
    final analyzed = _analyzedFor;
    final now = modelTime;
    final needs = analyzed == null ||
        now == null ||
        now.difference(analyzed).abs() >= refreshStep;
    final verdictChanged = needs != _needsRefresh;
    _needsRefresh = needs;
    final minuteKey = now == null
        ? null
        : now.millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute;
    if (verdictChanged || minuteKey != _notifiedMinuteKey) {
      _notifiedMinuteKey = minuteKey;
      notifyListeners();
    }
  }
}
