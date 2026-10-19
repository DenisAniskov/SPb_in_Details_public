import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/models/guided_walk_environment_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/quiet_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';

export 'package:smart_navigator_spb/data/models/guided_walk_environment_model.dart';

/// Sequences existing providers. It never owns a model, route algorithm,
/// navigation session or overlay preference. Providers retain request guards.
class GuidedWalkEnvironmentCoordinator extends ChangeNotifier {
  GuidedWalkEnvironmentCoordinator({
    required RoutingProvider routing,
    required NavigationProvider navigation,
    required this.recommendations,
    PuddleAssessmentProvider? puddle,
    PollenAssessmentProvider? pollen,
    QuietAssessmentProvider? quiet,
    this.clock,
    this.timeout = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _routing = routing,
       _navigation = navigation,
       _puddle = puddle,
       _pollen = pollen,
       _quiet = quiet,
       _now = now ?? DateTime.now {
    routing.addListener(_contextChanged);
    navigation.addListener(_contextChanged);
    puddle?.addListener(_contextChanged);
    pollen?.addListener(_contextChanged);
    quiet?.addListener(_contextChanged);
    clock?.addListener(_contextChanged);
  }

  final RoutingProvider _routing;
  final NavigationProvider _navigation;
  final ContextRecommendationProvider recommendations;
  final PuddleAssessmentProvider? _puddle;
  final PollenAssessmentProvider? _pollen;
  final QuietAssessmentProvider? _quiet;
  final VirtualShadeClock? clock;
  final DateTime Function() _now;
  final Duration timeout;

  GuidedWalkEnvironmentPhase _phase = GuidedWalkEnvironmentPhase.idle;
  GuidedWalkEnvironmentPhase get phase => _phase;
  bool _running = false;
  bool get isRunning => _running;
  bool _disposed = false;
  bool _preparing = false;
  int _generation = 0;
  Completer<void>? _interrupted;
  Future<void>? _pending;
  GuidedWalkEnvironmentalFactor? _active;
  PedestrianRouteModel? _route;
  int _routeVersion = -1;
  DateTime? _selectedDeparture;
  DateTime? get selectedDeparture => _selectedDeparture;
  DateTime? _evaluatedFor;
  GuidedWalkEnvironmentReport? _report;
  GuidedWalkEnvironmentReport? get report => _report;

  GuidedWalkEnvironmentalResult<ShadeAnalysisModel> _shade =
      const GuidedWalkEnvironmentalResult();
  GuidedWalkEnvironmentalResult<ShadeAnalysisModel> get shade => _shade;
  GuidedWalkEnvironmentalResult<PuddleAnalysisModel> _puddleResult =
      const GuidedWalkEnvironmentalResult();
  GuidedWalkEnvironmentalResult<PuddleAnalysisModel> get puddle =>
      _puddleResult;
  GuidedWalkEnvironmentalResult<PollenAnalysisModel> _pollenResult =
      const GuidedWalkEnvironmentalResult();
  GuidedWalkEnvironmentalResult<PollenAnalysisModel> get pollen =>
      _pollenResult;
  GuidedWalkEnvironmentalResult<QuietAnalysisModel> _quietResult =
      const GuidedWalkEnvironmentalResult();
  GuidedWalkEnvironmentalResult<QuietAnalysisModel> get quiet => _quietResult;

  bool get _planningAllowed =>
      _routing.hasRoute &&
      !_routing.navigationLocked &&
      !_navigation.locksPlanning &&
      !_navigation.state.isRerouting;

  /// A user time change invalidates all factors before another request starts.
  void selectDeparture(DateTime departure) {
    if (_disposed || _selectedDeparture == departure) return;
    _invalidate(GuidedWalkEnvironmentPhase.idle);
    _selectedDeparture = departure;
    _notify();
  }

  Future<void> assess() {
    if (_disposed || !_planningAllowed) return Future.value();
    if (_running) return _pending ?? Future.value();
    if (_report != null) return Future.value();
    _running = true;
    final generation = ++_generation;
    _interrupted = Completer<void>();
    return _pending = _run(generation);
  }

  Future<void> _run(int generation) async {
    _preparing = true;
    try {
      final departure = _selectedDeparture ?? _now();
      _selectedDeparture = departure;
      // Prepare ALL pickers before shade is computed. In diagnostic mode the
      // one existing virtual timeline stays authoritative, including elapsed
      // simulation time. Later factors and retries never re-arm the clock.
      _puddle?.selectDeparture(departure);
      _pollen?.selectDeparture(departure);
      _quiet?.selectDeparture(departure);
      if (clock?.departure != departure) {
        clock?.arm(departure);
      }
      _route = _routing.currentRoute;
      _routeVersion = _routing.navigationRouteVersion;
      _evaluatedFor = clock?.modelTime ?? departure;
      _report = null;
      _shade = const GuidedWalkEnvironmentalResult();
      _puddleResult = const GuidedWalkEnvironmentalResult();
      _pollenResult = const GuidedWalkEnvironmentalResult();
      _quietResult = const GuidedWalkEnvironmentalResult();
    } finally {
      _preparing = false;
    }
    for (final factor in GuidedWalkEnvironmentalFactor.values) {
      if (!_isCurrent(generation)) break;
      await _assessFactor(factor, generation);
    }
    if (_isCurrent(generation)) _buildReport();
    _finish(generation);
  }

  /// Retrying one factor preserves the others and their common instant.
  Future<void> retry(GuidedWalkEnvironmentalFactor factor) {
    if (_disposed || !_planningAllowed) return Future.value();
    if (_running) return _pending ?? Future.value();
    if (_route == null || !_contextMatches()) return assess();
    _running = true;
    _report = null;
    final generation = ++_generation;
    _interrupted = Completer<void>();
    return _pending = _retry(factor, generation);
  }

  Future<void> _retry(
    GuidedWalkEnvironmentalFactor factor,
    int generation,
  ) async {
    await _assessFactor(factor, generation);
    if (_isCurrent(generation)) _buildReport();
    _finish(generation);
  }

  bool _contextMatches() =>
      _planningAllowed &&
      identical(_route, _routing.currentRoute) &&
      _routeVersion == _routing.navigationRouteVersion &&
      (clock == null || clock?.modelTime == _evaluatedFor) &&
      (_puddle == null || _puddle.selectedDeparture == _selectedDeparture) &&
      (_pollen == null || _pollen.selectedDeparture == _selectedDeparture) &&
      (_quiet == null || _quiet.selectedDeparture == _selectedDeparture);

  bool _isCurrent(int generation) =>
      !_disposed && generation == _generation && _contextMatches();

  void _contextChanged() {
    if (_disposed || _preparing || _route == null) return;
    final completedFactorChanged =
        (_active != GuidedWalkEnvironmentalFactor.shade &&
            _shade.data != null &&
            (!identical(_shade.data, _routing.shadeAnalysis) ||
                _routing.shadeEvaluatedFor != _evaluatedFor)) ||
        (_active != GuidedWalkEnvironmentalFactor.puddle &&
            _puddleResult.data != null &&
            (!identical(_puddleResult.data, _puddle?.analysis) ||
                _puddle?.evaluatedFor != _evaluatedFor)) ||
        (_active != GuidedWalkEnvironmentalFactor.pollen &&
            _pollenResult.data != null &&
            (!identical(_pollenResult.data, _pollen?.analysis) ||
                _pollen?.evaluatedFor != _evaluatedFor)) ||
        (_active != GuidedWalkEnvironmentalFactor.quiet &&
            _quietResult.data != null &&
            (!identical(_quietResult.data, _quiet?.analysis) ||
                _quiet?.evaluatedFor != _evaluatedFor));
    if (!_contextMatches() || completedFactorChanged) {
      _invalidate(GuidedWalkEnvironmentPhase.stale);
      _notify();
    }
  }

  Future<void> _assessFactor(
    GuidedWalkEnvironmentalFactor factor,
    int generation,
  ) async {
    _active = factor;
    _phase = switch (factor) {
      GuidedWalkEnvironmentalFactor.shade => GuidedWalkEnvironmentPhase.shade,
      GuidedWalkEnvironmentalFactor.puddle => GuidedWalkEnvironmentPhase.puddle,
      GuidedWalkEnvironmentalFactor.pollen => GuidedWalkEnvironmentPhase.pollen,
      GuidedWalkEnvironmentalFactor.quiet => GuidedWalkEnvironmentPhase.quiet,
    };
    _setStatus(factor, GuidedWalkEnvironmentalStatus.running);
    _notify();
    if (!_isCurrent(generation)) return;
    try {
      final interrupted = _interrupted!;
      await Future.any<void>([
        Future<void>.sync(() => _invoke(factor)).timeout(timeout),
        interrupted.future,
      ]);
      if (!_isCurrent(generation)) return;
      _capture(factor);
    } on TimeoutException {
      if (!_isCurrent(generation)) return;
      _clearFactor(factor);
      if (!_isCurrent(generation)) return;
      _setStatus(
        factor,
        GuidedWalkEnvironmentalStatus.timedOut,
        'Проверка заняла слишком много времени. Можно повторить её отдельно.',
      );
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _clearFactor(factor);
      if (!_isCurrent(generation)) return;
      _setStatus(
        factor,
        GuidedWalkEnvironmentalStatus.failed,
        'Оценка сейчас недоступна. Пешеходный маршрут сохранён.',
      );
    } finally {
      if (generation == _generation) _active = null;
    }
    if (_isCurrent(generation)) _notify();
  }

  Future<void> _invoke(GuidedWalkEnvironmentalFactor factor) async {
    switch (factor) {
      case GuidedWalkEnvironmentalFactor.shade:
        await _routing.assessShade(
          departure: clock == null ? _selectedDeparture : null,
          exploreAlternatives: false,
        );
      case GuidedWalkEnvironmentalFactor.puddle:
        await _puddle?.assess();
      case GuidedWalkEnvironmentalFactor.pollen:
        await _pollen?.assess();
      case GuidedWalkEnvironmentalFactor.quiet:
        await _quiet?.assess();
    }
  }

  void _capture(GuidedWalkEnvironmentalFactor factor) {
    switch (factor) {
      case GuidedWalkEnvironmentalFactor.shade:
        final data = _routing.shadeAnalysis;
        _shade = GuidedWalkEnvironmentalResult(
          status: _status(
            data?.hasEstimate ?? false,
            data?.status == ShadeStatus.partial,
            _routing.shadeFailure != null,
          ),
          data: data,
          message: _routing.shadeFailure?.message ?? data?.statusMessage,
          evaluatedFor: _routing.shadeEvaluatedFor,
        );
      case GuidedWalkEnvironmentalFactor.puddle:
        final data = _puddle?.analysis;
        _puddleResult = GuidedWalkEnvironmentalResult(
          status: _status(
            data?.hasEstimate ?? false,
            data?.status == PuddleStatus.partial,
            _puddle?.failure != null,
          ),
          data: data,
          message:
              _puddle?.failure?.message ??
              (data != null && data.coverageShare == 0
                  ? _puddleMissingDataMessage(data)
                  : _puddle == null
                  ? 'Оценка мокрых участков недоступна.'
                  : null),
          evaluatedFor: _puddle?.evaluatedFor,
        );
      case GuidedWalkEnvironmentalFactor.pollen:
        final data = _pollen?.analysis;
        _pollenResult = GuidedWalkEnvironmentalResult(
          status: _status(
            data?.hasEstimate ?? false,
            data?.status == PollenStatus.partial,
            _pollen?.failure != null,
          ),
          data: data,
          message:
              _pollen?.failure?.message ??
              (data?.status == PollenStatus.outsideCoverage
                  ? 'Маршрут выходит за пределы модельной ячейки источника пыльцы.'
                  : data != null && !data.hasEstimate
                  ? _pollenMissingDataMessage(data)
                  : _pollen == null
                  ? 'Оценка пыльцы недоступна.'
                  : null),
          evaluatedFor: _pollen?.evaluatedFor,
        );
      case GuidedWalkEnvironmentalFactor.quiet:
        final data = _quiet?.analysis;
        _quietResult = GuidedWalkEnvironmentalResult(
          status: _status(
            data?.hasEstimate ?? false,
            data?.status == QuietStatus.partial,
            _quiet?.failure != null,
          ),
          data: data,
          message:
              _quiet?.failure?.message ??
              (data?.status == QuietStatus.outsideCoverage
                  ? 'Маршрут вне проверенного пилотного района дорожной сети.'
                  : data != null && !data.hasEstimate
                  ? _quietMissingDataMessage(data)
                  : _quiet == null
                  ? 'Оценка тишины недоступна.'
                  : null),
          evaluatedFor: _quiet?.evaluatedFor,
        );
    }
    // A non-null result alone is insufficient proof: reuse C7.4's ownership
    // and scope gate and require this run's exact instant as well.
    final context = recommendations.context;
    final accepted = switch (factor) {
      GuidedWalkEnvironmentalFactor.shade =>
        _shade.data == null ||
            (context.shade != null && _shade.evaluatedFor == _evaluatedFor),
      GuidedWalkEnvironmentalFactor.puddle =>
        _puddleResult.data == null ||
            (context.puddle != null &&
                _puddleResult.evaluatedFor == _evaluatedFor),
      GuidedWalkEnvironmentalFactor.pollen =>
        _pollenResult.data == null ||
            (context.pollen != null &&
                _pollenResult.evaluatedFor == _evaluatedFor),
      GuidedWalkEnvironmentalFactor.quiet =>
        _quietResult.data == null ||
            (identical(_quiet?.assessedRoute, _routing.currentRoute) &&
                _quietResult.evaluatedFor == _evaluatedFor),
    };
    if (!accepted) {
      _invalidate(GuidedWalkEnvironmentPhase.stale);
    }
  }

  String _puddleMissingDataMessage(PuddleAnalysisModel data) {
    if (!data.weather.available) {
      final reasons = data.reasons.where(
        (reason) => reason.startsWith('weather_'),
      );
      return reasons.isEmpty
          ? puddleReasonText('weather_unavailable')
          : reasons.map(puddleReasonText).take(2).join(' ');
    }
    return data.reasons.isEmpty
        ? 'Недостаточно подтверждённых исходных данных. '
              'Это не означает, что маршрут сухой.'
        : data.reasons.map(puddleReasonText).take(2).join(' ');
  }

  String _pollenMissingDataMessage(PollenAnalysisModel data) {
    final messages = <String>[];
    for (final reason in data.reasons) {
      final message = pollenReasonText(reason);
      if (message != reason) messages.add(message);
    }
    return messages.isEmpty
        ? 'Недостаточно подтверждённых модельных данных о пыльце.'
        : messages.take(2).join(' ');
  }

  String _quietMissingDataMessage(QuietAnalysisModel data) {
    final messages = <String>[];
    for (final reason in data.reasons) {
      final message = quietReasonText(reason);
      if (message != reason) messages.add(message);
    }
    return messages.isEmpty
        ? 'Недостаточно подтверждённых дорожных данных для оценки тишины.'
        : messages.take(2).join(' ');
  }

  GuidedWalkEnvironmentalStatus _status(
    bool estimate,
    bool partial,
    bool failed,
  ) => failed
      ? GuidedWalkEnvironmentalStatus.failed
      : !estimate
      ? GuidedWalkEnvironmentalStatus.unavailable
      : partial
      ? GuidedWalkEnvironmentalStatus.partial
      : GuidedWalkEnvironmentalStatus.available;

  void _buildReport() {
    _phase = GuidedWalkEnvironmentPhase.preparingReport;
    _notify();
    if (_route == null || !_contextMatches()) return;
    _report = GuidedWalkEnvironmentReport(
      route: _route!,
      routeVersion: _routeVersion,
      selectedDeparture: _selectedDeparture!,
      evaluatedFor: _evaluatedFor!,
      shade: _shade,
      puddle: _puddleResult,
      pollen: _pollenResult,
      quiet: _quietResult,
      context: recommendations.context,
      recommendations: recommendations.recommendations,
    );
    _phase = GuidedWalkEnvironmentPhase.complete;
  }

  void _finish(int generation) {
    if (generation != _generation) return;
    if (!_contextMatches()) {
      _invalidate(GuidedWalkEnvironmentPhase.stale);
      _notify();
      return;
    }
    _running = false;
    _pending = null;
    _active = null;
    _notify();
  }

  void _setStatus(
    GuidedWalkEnvironmentalFactor factor,
    GuidedWalkEnvironmentalStatus status, [
    String? message,
  ]) {
    switch (factor) {
      case GuidedWalkEnvironmentalFactor.shade:
        _shade = GuidedWalkEnvironmentalResult(
          status: status,
          message: message,
        );
      case GuidedWalkEnvironmentalFactor.puddle:
        _puddleResult = GuidedWalkEnvironmentalResult(
          status: status,
          message: message,
        );
      case GuidedWalkEnvironmentalFactor.pollen:
        _pollenResult = GuidedWalkEnvironmentalResult(
          status: status,
          message: message,
        );
      case GuidedWalkEnvironmentalFactor.quiet:
        _quietResult = GuidedWalkEnvironmentalResult(
          status: status,
          message: message,
        );
    }
  }

  void _clearFactor(GuidedWalkEnvironmentalFactor factor) {
    switch (factor) {
      case GuidedWalkEnvironmentalFactor.shade:
        _routing.clearShadeAssessment();
      case GuidedWalkEnvironmentalFactor.puddle:
        _puddle?.clear();
      case GuidedWalkEnvironmentalFactor.pollen:
        _pollen?.clear();
      case GuidedWalkEnvironmentalFactor.quiet:
        _quiet?.clear();
    }
  }

  void _invalidate(GuidedWalkEnvironmentPhase phase) {
    ++_generation;
    _route = null;
    _routeVersion = -1;
    _report = null;
    final active = _active;
    _active = null;
    _running = false;
    _pending = null;
    final interruption = _interrupted;
    if (interruption != null && !interruption.isCompleted) {
      interruption.complete();
    }
    if (active != null) _clearFactor(active);
    final status = phase == GuidedWalkEnvironmentPhase.stale
        ? GuidedWalkEnvironmentalStatus.stale
        : GuidedWalkEnvironmentalStatus.notAssessed;
    for (final factor in GuidedWalkEnvironmentalFactor.values) {
      _setStatus(factor, status);
    }
    _phase = phase;
  }

  void cancel() {
    if (_disposed) return;
    _invalidate(GuidedWalkEnvironmentPhase.cancelled);
    for (final factor in GuidedWalkEnvironmentalFactor.values) {
      _setStatus(factor, GuidedWalkEnvironmentalStatus.cancelled);
    }
    _notify();
  }

  void skip() {
    if (_disposed) return;
    _invalidate(GuidedWalkEnvironmentPhase.idle);
    for (final factor in GuidedWalkEnvironmentalFactor.values) {
      _setStatus(factor, GuidedWalkEnvironmentalStatus.skipped);
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidate(GuidedWalkEnvironmentPhase.cancelled);
    _routing.removeListener(_contextChanged);
    _navigation.removeListener(_contextChanged);
    _puddle?.removeListener(_contextChanged);
    _pollen?.removeListener(_contextChanged);
    _quiet?.removeListener(_contextChanged);
    clock?.removeListener(_contextChanged);
    super.dispose();
  }
}
