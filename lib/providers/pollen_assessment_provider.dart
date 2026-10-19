import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';

enum PollenAssessmentScope { wholeWalk, remainingPath }

/// Optional read-only pollen assessment. It never owns a router and never
/// changes the planning lock, the native geometry, the maneuvers, the POI
/// order or the navigation.
///
/// The provider is a deliberate copy of the C7.2 puddle assessment contract:
/// invalidation on any route/lock/reroute/clock change, in-flight responses
/// discarded after invalidation, and the remaining-path cut taken from the
/// real [NavigationProvider.buildRemainingRoute] during an active walk.
class PollenAssessmentProvider extends ChangeNotifier {
  PollenAssessmentProvider(
    this._service, {
    required RoutingProvider routing,
    required NavigationProvider navigation,
    VirtualShadeClock? clock,
    DateTime Function()? now,
  }) : _routing = routing,
       _navigation = navigation,
       _clock = clock,
       _now = now ?? DateTime.now {
    _rememberContext();
    routing.addListener(_contextChanged);
    navigation.addListener(_contextChanged);
    clock?.addListener(_contextChanged);
  }

  final RoutingProvider _routing;
  final NavigationProvider _navigation;
  final BasePollenAnalysisService _service;
  final VirtualShadeClock? _clock;
  final DateTime Function() _now;
  bool _disposed = false;
  int _request = 0;
  bool _loading = false;
  PollenAnalysisModel? _analysis;
  PollenAnalysisFailure? _failure;
  DateTime? _selectedDeparture;
  DateTime? _evaluatedFor;
  PollenAssessmentScope _scope = PollenAssessmentScope.wholeWalk;

  /// Provenance evidence for consumers that must verify ownership themselves
  /// (C7.4 §6): the route object a whole-walk estimate describes, and — for a
  /// remaining-path estimate — the session geometry version it was computed
  /// against (the tail is rebuilt on every fix, so its object identity proves
  /// nothing). Cleared together with the result.
  PedestrianRouteModel? _assessedRoute;
  int _assessedSessionVersion = -1;

  /// The session progress the published estimate was anchored at (C7.4 §6
  /// evidence). The geometry version only proves the session was not rebuilt;
  /// this is what proves the tail still starts where the walker stands.
  double _assessedProgress = 0;
  PedestrianRouteModel? _observedPlan;
  PedestrianRouteModel? _observedSession;
  bool _observedLock = false;
  bool _observedRebuild = false;
  DateTime? _observedModelTime;

  PollenAnalysisModel? get analysis => _analysis;
  PollenAnalysisFailure? get failure => _failure;
  bool get isLoading => _loading;
  DateTime? get selectedDeparture => _selectedDeparture;
  DateTime? get evaluatedFor => _evaluatedFor;
  PollenAssessmentScope get scope => _scope;
  DateTime? get modelTime => _clock?.modelTime;

  /// The exact route object the published estimate describes (whole-walk
  /// scope), or null when nothing is published.
  PedestrianRouteModel? get assessedRoute =>
      _analysis == null ? null : _assessedRoute;

  /// The session geometry version the published remaining-path estimate
  /// describes, or -1 when nothing is published.
  int get assessedSessionVersion =>
      _analysis == null ? -1 : _assessedSessionVersion;

  /// The session progress (metres walked) at the moment the published estimate
  /// was made, or null when nothing is published. The session engine measures
  /// it (`LiveNavigationState.totalProgressMeters`), so a consumer can compare
  /// it with the progress right now instead of trusting the geometry version.
  double? get assessedProgress => _analysis == null ? null : _assessedProgress;

  /// True only in the opted-in simulator, where ONE virtual timeline is shared
  /// with the C7.1 shade estimate and the C7.2 puddle estimate — the picker
  /// below then changes the simulation's own time, not a pollen-only setting.
  bool get usesSharedSimulationTime => _clock != null;

  bool get navigating => _routing.navigationLocked;
  bool get canAssess =>
      _routing.hasRoute &&
      (!navigating ||
          (_navigation.locksPlanning && !_navigation.state.isRerouting));

  void _rememberContext() {
    _observedPlan = _routing.currentRoute;
    _observedSession = _routing.navigationRoute;
    _observedLock = _routing.navigationLocked;
    _observedRebuild = _navigation.state.isRerouting;
    _observedModelTime = _clock?.modelTime;
  }

  void _contextChanged() {
    if (_disposed) return;
    final changed =
        !identical(_observedPlan, _routing.currentRoute) ||
        !identical(_observedSession, _routing.navigationRoute) ||
        _observedLock != _routing.navigationLocked ||
        _observedRebuild != _navigation.state.isRerouting ||
        _observedModelTime != _clock?.modelTime;
    _rememberContext();
    if (changed) clear();
  }

  /// Choosing a plan time is explicit and is blocked during navigation.
  ///
  /// In the simulator the existing shared virtual timeline is authoritative:
  /// this arms the SAME clock the shade and puddle estimates use, because a
  /// walk happens at ONE virtual instant. Arming drops the stale analyses
  /// instead of leaving an estimate computed for another instant on screen.
  void selectDeparture(DateTime departure) {
    if (_disposed || navigating) return;
    if (_selectedDeparture == departure && _clock?.departure == departure) {
      return;
    }
    _selectedDeparture = departure;
    clear(notify: false);
    _clock?.arm(departure);
    _rememberContext();
    notifyListeners();
  }

  void clear({bool notify = true}) {
    ++_request; // Also invalidates a response currently in flight.
    _analysis = null;
    _failure = null;
    _loading = false;
    _evaluatedFor = null;
    _scope = PollenAssessmentScope.wholeWalk;
    _assessedRoute = null;
    _assessedSessionVersion = -1;
    _assessedProgress = 0;
    if (notify && !_disposed) notifyListeners();
  }

  /// Transfers a completed draft estimate after the exact native route object
  /// has been committed. No request or clock change occurs during adoption.
  bool adoptWholeWalkAssessmentFrom(PollenAssessmentProvider source) {
    final when = source._evaluatedFor;
    if (_disposed ||
        source._disposed ||
        navigating ||
        (source.navigating && !source._routing.isGuidedDraft) ||
        source._navigation.locksPlanning ||
        _loading ||
        source._loading ||
        source._analysis == null ||
        when == null ||
        source._scope != PollenAssessmentScope.wholeWalk ||
        !identical(source._assessedRoute, _routing.currentRoute) ||
        !identical(source._routing.currentRoute, _routing.currentRoute) ||
        (_clock != null && _clock.modelTime != when)) {
      return false;
    }
    if (identical(source, this)) return true;
    clear(notify: false);
    _analysis = source._analysis;
    _selectedDeparture = source._selectedDeparture;
    _evaluatedFor = when;
    _scope = PollenAssessmentScope.wholeWalk;
    _assessedRoute = _routing.currentRoute;
    _assessedSessionVersion = _routing.navigationRouteVersion;
    _assessedProgress = 0;
    _rememberContext();
    notifyListeners();
    return true;
  }

  Future<void> assess() async {
    if (_disposed || !canAssess) return;
    // A caller cannot supply an arbitrary tail: use C7.1.2's validated cut
    // from the REAL NavigationProvider (native seconds scaled by length,
    // remaining visits, all interior vertices, no rebased fake maneuvers).
    final PedestrianRouteModel? route = navigating
        ? _navigation.buildRemainingRoute()
        : _routing.currentRoute;
    if (route == null || route.legs.isEmpty) return;
    final scope = navigating
        ? PollenAssessmentScope.remainingPath
        : PollenAssessmentScope.wholeWalk;
    if (_clock != null && _clock.departure == null) {
      _clock.arm((_selectedDeparture ?? _now()).subtract(_clock.elapsed));
    }
    final when =
        _clock?.modelTime ??
        (navigating ? _now() : _selectedDeparture ?? _now());
    _rememberContext();
    _assessedRoute = route;
    _assessedSessionVersion = _routing.navigationRouteVersion;
    _assessedProgress = _navigation.state.totalProgressMeters;
    final request = ++_request;
    _loading = true;
    _analysis = null;
    _failure = null;
    _scope = scope;
    _evaluatedFor = when;
    notifyListeners();
    try {
      final analysis = await _service.analyzeWalk(
        departure: when,
        legs: route.legs,
        visitMinutesAfterLeg: [
          for (var i = 0; i < route.legs.length; i++)
            i < route.legs.length - 1 ? route.legs[i].visitMinutes ?? 0 : 0,
        ],
      );
      if (_disposed || request != _request) return;
      _analysis = analysis;
    } on PollenAnalysisFailure catch (failure) {
      if (_disposed || request != _request) return;
      _failure = failure;
    } catch (_) {
      if (_disposed || request != _request) return;
      _failure = const PollenAnalysisFailure(
        PollenAnalysisFailureKind.serviceUnavailable,
        'Оценка пыльцы сейчас недоступна. Обычная навигация работает.',
      );
    }
    if (_disposed || request != _request) return;
    _loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_request;
    _routing.removeListener(_contextChanged);
    _navigation.removeListener(_contextChanged);
    _clock?.removeListener(_contextChanged);
    super.dispose();
  }
}
