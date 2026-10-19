import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/services/simulated_location_source.dart';

/// Operator-side controller of the navigation simulation (Phase C4.1).
///
/// It drives the [SimulatedLocationSource] along the REAL route geometry of
/// the active session and rebuilds session state on seek/restart through the
/// engine's own public APIs (`startNavigation`, `stopNavigation`,
/// `continueToNextLeg`) — the Phase C4 state machine, its GPS quality gates
/// and its arrival safeguards are never bypassed or weakened.
class SimulationController extends ChangeNotifier {
  SimulationController({
    required this.source,
    required this.nav,
    this.tickInterval = const Duration(milliseconds: 500),
  });

  final SimulatedLocationSource source;
  final NavigationProvider nav;
  final Duration tickInterval;

  Timer? _ticker;
  bool _running = false;
  double _speedKmh = 5;
  double _playbackRate = 1;
  Duration _simulatedElapsed = Duration.zero;
  int _simulatedLegIndex = -1;
  PedestrianRouteModel? _loadedRoute;
  PedestrianRouteModel? _scenarioRoute;

  /// Active honest-replay plan: fast-forward the session through every
  /// intermediate leg to [seekTargetLeg], one engine tick per fix, using the
  /// engine's own two-fix arrival and the user-confirmed transition.
  int? _seekTargetLeg;
  double? _seekTargetDistance;

  bool get isRunning => _running;
  bool get hasDeviation => source.hasDeviation;
  double get speedKmh => _speedKmh;
  double get playbackRate => _playbackRate;
  Duration get simulatedElapsed => _simulatedElapsed;
  int get simulatedLegIndex => _simulatedLegIndex;
  double get currentDistanceMeters => source.distanceMeters;
  double get legLengthMeters => source.geometryLengthMeters;

  /// The route the scenario (re)starts from: the frozen session route when a
  /// session exists, otherwise the scenario route captured at first start.
  PedestrianRouteModel? get scenarioRoute =>
      nav.state.route ?? _scenarioRoute;

  Future<void> start() async {
    if (_running) return;
    final route = nav.state.route ?? _scenarioRoute;
    if (route == null) return;
    if (nav.status == NavigationStatus.idle) {
      await startWithRoute(route);
      return;
    }
    // Attaching to an already-running session: follow its current leg.
    _scenarioRoute = route;
    _loadLeg(nav.currentLegIndex, resetDistance: true);
    source.speedMps = _speedKmh / 3.6;
    _startTicker();
    _running = true;
    notifyListeners();
  }

  /// Simulation pause: the virtual walker freezes (unlike injected GPS loss,
  /// where the walker keeps moving while delivery is down).
  void pause() {
    _ticker?.cancel();
    _ticker = null;
    _running = false;
    notifyListeners();
  }

  Future<void> resume() async {
    if (_running) return;
    if (nav.state.route == null) return start();
    _startTicker();
    _running = true;
    notifyListeners();
  }

  /// Ends the scenario and the underlying session; releases all timers.
  Future<void> finish() async {
    _ticker?.cancel();
    _ticker = null;
    _running = false;
    _seekTargetLeg = null;
    _seekTargetDistance = null;
    source.reset();
    if (nav.status != NavigationStatus.idle) {
      nav.stopNavigation();
    }
    notifyListeners();
  }

  /// Restart the whole scenario from the first leg at zero distance. The
  /// session is torn down and rebuilt — nothing is rewound artificially.
  Future<void> restart() async {
    final route = _scenarioRoute ?? nav.state.route;
    if (route == null) return;
    _simulatedElapsed = Duration.zero;
    await startWithRoute(route);
  }

  /// Start (or re-start) the simulation on an explicit route. The session is
  /// always rebuilt from leg 0; the source is primed with leg 0's real
  /// geometry first so the engine's one-shot initial fix is the route start.
  Future<void> startWithRoute(PedestrianRouteModel route) async {
    _scenarioRoute = route;
    _ticker?.cancel();
    _ticker = null;
    _running = false;
    _seekTargetLeg = null;
    _seekTargetDistance = null;
    _simulatedElapsed = Duration.zero;
    source.reset();
    source.loadGeometry(route.legs.first.geometryPoints);
    if (nav.status != NavigationStatus.idle) nav.stopNavigation();
    await nav.startNavigation(route);
    _loadLeg(nav.currentLegIndex, resetDistance: true);
    source.speedMps = _speedKmh / 3.6;
    _startTicker();
    _running = true;
    notifyListeners();
  }

  void setSpeed(double kmh) {
    _speedKmh = kmh;
    source.speedMps = kmh / 3.6;
    notifyListeners();
  }

  void setPlaybackRate(double rate) {
    if (rate <= 0) return;
    _playbackRate = rate;
    notifyListeners();
  }

  /// Seeks to [distanceMeters] inside [legIndex].
  ///
  /// The session is always REBUILT (stop + fresh start): backward movement
  /// never rewinds accepted progress, it restarts the scenario honestly.
  /// For leg 0 the engine's one-shot initial fix already lands on the target
  /// position. For later legs a bounded honest replay fast-forwards the
  /// session through every intermediate leg — one fix per tick — so the
  /// engine's own two-fix arrival and the user-confirmed transition do the
  /// advancing; nothing is teleported across stops.
  Future<void> seekToLeg(
    int legIndex, {
    double? distanceMeters,
  }) async {
    final route = nav.state.route ?? _scenarioRoute;
    if (route == null || legIndex < 0 || legIndex >= route.legs.length) {
      return;
    }
    _ticker?.cancel();
    _ticker = null;
    _running = false;
    _simulatedElapsed = Duration.zero;
    _seekTargetLeg = null;
    _seekTargetDistance = null;
    source.reset();
    source.loadGeometry(route.legs.first.geometryPoints);
    if (legIndex == 0 && distanceMeters != null) {
      // The engine's one-shot initial fix becomes the target position.
      source.distanceMeters = distanceMeters;
    }
    if (nav.status != NavigationStatus.idle) nav.stopNavigation();
    await nav.startNavigation(route);
    if (legIndex == 0) {
      _loadLeg(0, resetDistance: true);
      if (distanceMeters != null) source.distanceMeters = distanceMeters;
    } else {
      _seekTargetLeg = legIndex;
      _seekTargetDistance = distanceMeters;
      _simulatedLegIndex = -1;
      _loadedRoute = null;
    }
    source.speedMps = _speedKmh / 3.6;
    _startTicker();
    _running = true;
    notifyListeners();
  }

  void _loadLeg(int index, {required bool resetDistance}) {
    final route = nav.state.route ?? _scenarioRoute;
    final legs = route?.legs;
    if (route == null || legs == null || index < 0 || index >= legs.length) {
      return;
    }
    source.loadGeometry(legs[index].geometryPoints);
    _simulatedLegIndex = index;
    _loadedRoute = route;
    if (resetDistance) source.distanceMeters = 0;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(tickInterval, (_) => _advanceOneTick(null));
  }

  void _advanceOneTick(double? deltaSimSecondsOverride) {
    // Session ended (stop/complete/error) — stop the walker honestly.
    if (nav.status != NavigationStatus.active) {
      if (_running &&
          (nav.status == NavigationStatus.idle ||
              nav.status == NavigationStatus.completed ||
              nav.status == NavigationStatus.error)) {
        _ticker?.cancel();
        _ticker = null;
        _running = false;
        notifyListeners();
      }
      return;
    }
    if (_seekTargetLeg != null) {
      _advanceReplayTick();
      return;
    }
    // Follow the session across leg transitions (arrival + continue) and
    // across route rebuilds: a manual reroute replaces the current leg's
    // geometry under the SAME leg index, so the route snapshot identity is
    // tracked as well. On a rebuilt route the walker re-joins from the new
    // geometry's start (like the real user, who stands at its origin), and
    // the stale deviation injection is cleared with the obsolete line.
    final route = nav.state.route;
    final routeChanged = !identical(route, _loadedRoute);
    if (nav.currentLegIndex != _simulatedLegIndex || routeChanged) {
      _loadLeg(nav.currentLegIndex, resetDistance: true);
      if (routeChanged) source.returnToRoute();
    }
    // Hold the walker while the engine is not consuming progress: stop
    // confirmation (visiting) or reroute rebuild.
    if (nav.state.isWaitingForNextLegConfirmation || nav.state.isRerouting) {
      return;
    }
    final delta = deltaSimSecondsOverride ??
        tickInterval.inMilliseconds / 1000.0 * _playbackRate;
    _simulatedElapsed += Duration(milliseconds: (delta * 1000).round());
    source.tick(delta);
    notifyListeners();
  }

  /// One honest-replay fix per tick: place the walker at the current
  /// intermediate leg's endpoint and let the engine arrive by its own
  /// two-fix rule, then perform the user-confirmed transition.
  void _advanceReplayTick() {
    final route = nav.state.route ?? _scenarioRoute;
    final target = _seekTargetLeg;
    if (route == null || target == null) {
      _seekTargetLeg = null;
      _seekTargetDistance = null;
      return;
    }
    if (nav.currentLegIndex >= target) {
      // Target reached: prime the requested position and resume walking.
      _seekTargetLeg = null;
      final distance = _seekTargetDistance;
      _seekTargetDistance = null;
      _loadLeg(nav.currentLegIndex, resetDistance: true);
      if (distance != null) source.distanceMeters = distance;
      return;
    }
    final index = nav.currentLegIndex;
    final leg = route.legs[index];
    source.loadGeometry(leg.geometryPoints);
    _simulatedLegIndex = index;
    _loadedRoute = route;
    source.distanceMeters =
        RouteProjectionUtils.polylineLengthMeters(leg.geometryPoints);
    source.emitCurrent();
    if (nav.state.isWaitingForNextLegConfirmation) {
      nav.continueToNextLeg();
    }
  }

  /// Deterministic single-step for tests: advance by one tick's worth of
  /// simulated time without waiting for a real timer.
  void tickOnceForTesting({double? deltaSimSeconds}) =>
      _advanceOneTick(deltaSimSeconds);

  // Error-injection passthrough (Section 4). The controller adds no policy —
  // the source produces imperfect data and the engine reacts with its own
  // unmodified Phase C4 safeguards.
  void injectGpsLoss({Duration duration = const Duration(seconds: 10)}) {
    source.injectGpsLoss(duration: duration);
    notifyListeners();
  }

  void injectLowAccuracy({double accuracyMeters = 45}) {
    source.injectLowAccuracy(accuracyMeters: accuracyMeters);
    notifyListeners();
  }

  void injectStaleFix() {
    source.injectStaleFix();
    notifyListeners();
  }

  /// One-fix GPS glitch: a single fix reports a far position while the
  /// virtual walker stays put. The engine must hold it as unconfirmed.
  void injectJump({double forwardMeters = 120}) {
    source.injectJump(forwardMeters: forwardMeters);
    notifyListeners();
  }

  /// Persistent position jump (a real device teleport: the reported
  /// position jumps and stays). Two consecutive fixes confirm it through
  /// the engine's own jump rule.
  void jumpWalker({double meters = 120}) {
    source.distanceMeters = source.distanceMeters + meters;
    notifyListeners();
  }

  void injectDeviation({double meters = 80}) {
    source.injectDeviation(meters: meters);
    notifyListeners();
  }

  void returnToRoute() {
    source.returnToRoute();
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    source.dispose();
    super.dispose();
  }
}
