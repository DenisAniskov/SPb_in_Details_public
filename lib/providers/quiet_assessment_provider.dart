import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';

enum QuietAssessmentScope { wholeWalk, remainingPath }

/// Optional read-only quiet assessment. It never owns a router, never changes
/// planning, geometry, maneuvers, stop order or navigation, and a failure
/// leaves ordinary navigation untouched.
class QuietAssessmentProvider extends ChangeNotifier {
  QuietAssessmentProvider(
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
  final BaseQuietAnalysisService _service;
  final VirtualShadeClock? _clock;
  final DateTime Function() _now;
  bool _disposed = false;
  int _request = 0;
  bool _loading = false;
  QuietAnalysisModel? _analysis;
  QuietAnalysisFailure? _failure;
  DateTime? _selectedDeparture;
  DateTime? _evaluatedFor;
  QuietAssessmentScope _scope = QuietAssessmentScope.wholeWalk;

  PedestrianRouteModel? _assessedRoute;
  int _assessedSessionVersion = -1;
  double _assessedProgress = 0;
  PedestrianRouteModel? _observedPlan;
  PedestrianRouteModel? _observedSession;
  bool _observedLock = false;
  bool _observedRebuild = false;
  DateTime? _observedModelTime;

  QuietAnalysisModel? get analysis => _analysis;
  QuietAnalysisFailure? get failure => _failure;
  bool get isLoading => _loading;
  DateTime? get selectedDeparture => _selectedDeparture;
  DateTime? get evaluatedFor => _evaluatedFor;
  QuietAssessmentScope get scope => _scope;
  DateTime? get modelTime => _clock?.modelTime;
  PedestrianRouteModel? get assessedRoute =>
      _analysis == null ? null : _assessedRoute;
  int get assessedSessionVersion =>
      _analysis == null ? -1 : _assessedSessionVersion;
  double? get assessedProgress => _analysis == null ? null : _assessedProgress;

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
    ++_request;
    _analysis = null;
    _failure = null;
    _loading = false;
    _evaluatedFor = null;
    _scope = QuietAssessmentScope.wholeWalk;
    _assessedRoute = null;
    _assessedSessionVersion = -1;
    _assessedProgress = 0;
    if (notify && !_disposed) notifyListeners();
  }

  /// Transfers a completed draft estimate only over the exact committed
  /// geometry and the same instant. No request or clock change occurs.
  bool adoptWholeWalkAssessmentFrom(QuietAssessmentProvider source) {
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
        source._scope != QuietAssessmentScope.wholeWalk ||
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
    _scope = QuietAssessmentScope.wholeWalk;
    _assessedRoute = _routing.currentRoute;
    _assessedSessionVersion = _routing.navigationRouteVersion;
    _assessedProgress = 0;
    _rememberContext();
    notifyListeners();
    return true;
  }

  Future<void> assess() async {
    if (_disposed || !canAssess) return;
    final PedestrianRouteModel? route = navigating
        ? _navigation.buildRemainingRoute()
        : _routing.currentRoute;
    if (route == null || route.legs.isEmpty) return;
    final scope = navigating
        ? QuietAssessmentScope.remainingPath
        : QuietAssessmentScope.wholeWalk;
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
        assessedAt: when,
        legs: route.legs,
        visitMinutesAfterLeg: [
          for (var i = 0; i < route.legs.length; i++)
            i < route.legs.length - 1 ? route.legs[i].visitMinutes ?? 0 : 0,
        ],
      );
      if (_disposed || request != _request) return;
      _analysis = analysis;
    } on QuietAnalysisFailure catch (failure) {
      if (_disposed || request != _request) return;
      _failure = failure;
    } catch (_) {
      if (_disposed || request != _request) return;
      _failure = const QuietAnalysisFailure(
        QuietAnalysisFailureKind.serviceUnavailable,
        'Оценка тишины сейчас недоступна. Обычная навигация работает.',
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
