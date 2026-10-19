import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/data/scenic/scenic_dataset.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/context_recommendation_engine.dart';
import 'package:smart_navigator_spb/services/recommendation_context.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';

/// Phase C7.4 — the recommendations provider.
///
/// It owns NO route and NO assessment. It observes the providers that already
/// hold the verified results (RoutingProvider for shade and the scenic
/// outcome, PuddleAssessmentProvider, PollenAssessmentProvider and the virtual
/// clock) and derives the recommendation set from their CURRENT state on every
/// read.
///
/// That is deliberate, and it is what makes the state-safety rules of ТЗ C7.4
/// §6 true by construction rather than by bookkeeping:
///
/// * changing the route, a POI, the simulated time, starting/finishing a walk
///   or rerouting changes the state the derivation reads — old
///   recommendations cannot survive it;
/// * a late in-flight response that a factor provider discarded never becomes
///   part of the set, because the set is never stored;
/// * nothing here is ever recomputed on its own: an assessment runs only when
///   the user presses a button (in a factor card or an allowed
///   recommendation action).
///
/// Two rules need a notion of "now" and are therefore split by context: with
/// the simulator running the shared virtual timeline decides, and in a real
/// walk (navigating without a clock) the injected wall clock decides — an
/// assessment older than the live-walk window, or one whose source validity
/// has passed, is excluded with a reason instead of being presented as
/// current. A deliberately chosen planning time is never aged against the
/// wall clock. The ENGINE stays clock-free and deterministic: the instant is
/// an input the gate receives, and [now] is injectable for tests.
///
/// One thing a derived read cannot notice on its own is TIME PASSING: in a
/// real walk with a stationary walker nothing else notifies — no GPS fix, no
/// provider event — yet an admitted assessment ages out of the live-walk
/// window anyway. The provider therefore keeps ONE self-cancelling wake-up
/// (C7.4.2): a single [Timer] armed for the earliest moment at which an
/// ADMITTED assessment stops being current (its own `maxLiveAge` deadline or
/// the source's `validUntil`, whichever comes first). Waking up only
/// re-reads the gate — it never performs a request and never starts an
/// assessment. The wake-up exists only for a real walk that has something to
/// age: never in planning, never with the simulator armed, never for a fact
/// the gate already rejects (so it cannot loop), and it is cancelled in
/// [dispose].
class ContextRecommendationProvider extends ChangeNotifier {
  ContextRecommendationProvider({
    required RoutingProvider routing,
    required NavigationProvider navigation,
    PuddleAssessmentProvider? puddle,
    PollenAssessmentProvider? pollen,
    VirtualShadeClock? clock,
    ContextRecommendationEngine? engine,
    RecommendationContextGate? gate,
    DateTime Function()? now,
    GuestExperienceProvider? guest,
  }) : _routing = routing,
       _navigation = navigation,
       _puddle = puddle,
       _pollen = pollen,
       _clock = clock,
       _engine = engine ?? const ContextRecommendationEngine(),
       _gate = gate ?? const RecommendationContextGate(),
       _now = now ?? DateTime.now,
       _guest = guest {
    _navigationWasLocked = navigation.locksPlanning;
    routing.addListener(_dependencyChanged);
    navigation.addListener(_dependencyChanged);
    puddle?.addListener(_dependencyChanged);
    pollen?.addListener(_dependencyChanged);
    clock?.addListener(_dependencyChanged);
    guest?.addListener(_preferencesChanged);
    _syncLiveExpiryWakeUp();
  }

  final RoutingProvider _routing;
  final NavigationProvider _navigation;
  final PuddleAssessmentProvider? _puddle;
  final PollenAssessmentProvider? _pollen;
  final VirtualShadeClock? _clock;
  final ContextRecommendationEngine _engine;
  final RecommendationContextGate _gate;

  /// The wall clock, injectable so the live-walk freshness rules can be tested
  /// without waiting. The ENGINE never reads it — the instant a statement is
  /// built for is an input of the gate, which keeps the engine deterministic.
  final DateTime Function() _now;
  final GuestExperienceProvider? _guest;
  bool _disposed = false;

  /// The ONE pending wake-up (C7.4.2), or null when nothing can age on its own
  /// right now. Re-armed on every dependency change and after every firing.
  Timer? _liveExpiryTimer;

  /// A whole second past the computed deadline. Both live-walk comparisons are
  /// inclusive on the gate's side (`age >= maxLiveAge`, `now` strictly after
  /// `validUntil`), so waking up slightly late guarantees the verdict has
  /// really flipped instead of re-reading a not-yet-stale assessment — and the
  /// window is minutes long, so a second of slack is nothing to the user.
  static const Duration _liveExpirySlack = Duration(seconds: 1);

  /// Whether a wake-up is currently armed. Read by tests that pin the two
  /// "no redundant timers" properties: no wake-up in planning and none with
  /// the simulator armed, exactly one while a real walk has an admitted fact.
  @visibleForTesting
  bool get hasPendingLiveExpiryWakeUp => _liveExpiryTimer != null;

  RecommendationPreference _preference = RecommendationPreference.all;

  /// C8.1 persists UI ordering only; the C7.4.2 rules and gate stay unchanged.
  RecommendationPreference get preference =>
      _guest?.recommendationPreference ?? _preference;

  bool _hiddenForWalk = false;
  PedestrianRouteModel? _hiddenPlannedRoute;
  bool _navigationWasLocked = false;
  bool get panelVisible =>
      (_guest?.showRecommendations ?? true) && !_hiddenForWalk;

  void hideForCurrentWalk() {
    if (_disposed || _hiddenForWalk) return;
    _hiddenForWalk = true;
    _hiddenPlannedRoute = _routing.currentRoute;
    notifyListeners();
  }

  /// Explicit settings action can restore a temporarily hidden panel too.
  void showForCurrentWalk() {
    if (_disposed || !_hiddenForWalk) return;
    _hiddenForWalk = false;
    _hiddenPlannedRoute = null;
    notifyListeners();
  }

  void _preferencesChanged() {
    if (!_disposed) notifyListeners();
  }

  void setPreference(RecommendationPreference value) {
    if (_disposed || preference == value) return;
    if (_guest != null) {
      unawaited(_guest.setRecommendationPreference(value));
      return;
    }
    _preference = value;
    notifyListeners();
  }

  void _dependencyChanged() {
    if (_disposed) return;
    // Native rerouting updates the navigation route, not this planned route.
    // Keep the user's dismissal throughout that same walk.
    final navigationLocked = _navigation.locksPlanning;
    if (_hiddenForWalk &&
        (!identical(_hiddenPlannedRoute, _routing.currentRoute) ||
            (_navigationWasLocked && !navigationLocked))) {
      _hiddenForWalk = false;
      _hiddenPlannedRoute = null;
    }
    _navigationWasLocked = navigationLocked;
    _syncLiveExpiryWakeUp();
    notifyListeners();
  }

  /// Re-arms the single wake-up for the moment the current set changes on its
  /// own, or drops it when nothing can. Called on every dependency change, on
  /// construction and after every firing — never from a getter, so reading the
  /// panel never schedules anything.
  void _syncLiveExpiryWakeUp() {
    _liveExpiryTimer?.cancel();
    _liveExpiryTimer = null;
    if (_disposed) return;
    final delay = _liveExpiryDelay;
    if (delay == null) return;
    _liveExpiryTimer = Timer(delay, _onLiveExpiry);
  }

  void _onLiveExpiry() {
    _liveExpiryTimer = null;
    if (_disposed) return;
    // Re-arm for whatever expires later, then let the UI re-read the gate: the
    // assessment that just went stale is now reported with its own reason.
    _syncLiveExpiryWakeUp();
    notifyListeners();
  }

  /// How long until the current set changes on its own, or null when nothing
  /// can change without an event.
  ///
  /// Only a REAL walk ages assessments against the wall clock: planning times
  /// are deliberate and the virtual timeline governs whenever the simulator is
  /// armed. Only facts the gate has ADMITTED matter, and the deadlines are
  /// derived from the gate's own verdict — so an assessment the gate already
  /// rejects (another route, an overtaken tail, exactly this expiry) never
  /// keeps a timer alive, and a wake-up can never turn into a loop.
  Duration? get _liveExpiryDelay {
    final currentInputs = inputs;
    final now = currentInputs.now;
    if (now == null ||
        !currentInputs.navigating ||
        currentInputs.clockModelTime != null) {
      return null;
    }
    final admitted = _gate.evaluate(currentInputs);
    final maxAge = _gate.maxLiveAge;
    DateTime? earliest;
    void note(DateTime? deadline) {
      if (deadline == null) return;
      if (earliest == null || deadline.isBefore(earliest!)) earliest = deadline;
    }

    note(
      _deadline(
        admitted.shade?.evaluatedFor,
        currentInputs.shade.validUntil,
        maxAge,
      ),
    );
    note(
      _deadline(
        admitted.puddle?.evaluatedFor,
        currentInputs.puddle.validUntil,
        maxAge,
      ),
    );
    note(
      _deadline(
        admitted.pollen?.evaluatedFor,
        currentInputs.pollen.validUntil,
        maxAge,
      ),
    );
    if (earliest == null) return null;
    return earliest!.difference(now) + _liveExpirySlack;
  }

  /// The earlier of "the assessment has aged out" and "the source expired" for
  /// an admitted assessment; null when the factor has no admitted fact.
  static DateTime? _deadline(
    DateTime? evaluatedFor,
    DateTime? validUntil,
    Duration maxAge,
  ) {
    if (evaluatedFor == null) return null;
    final agedOut = evaluatedFor.add(maxAge);
    if (validUntil == null || agedOut.isBefore(validUntil)) return agedOut;
    return validUntil;
  }

  /// True when there is a walk to talk about at all.
  bool get hasRoute => _routing.hasRoute;

  /// The verified context of the current recommendation set: only facts that
  /// passed the consistency gate, plus a report for every factor that did not.
  RecommendationContext get context => _gate.evaluate(inputs);

  /// The full ordered set. Empty when no factor contributed — the section then
  /// shows its honest empty state instead of inventing anything.
  List<ContextRecommendation> get recommendations => _engine.build(context);

  /// What the section shows before «Показать все» (UI policy, documented in
  /// the rules doc). Nothing is hidden permanently.
  List<ContextRecommendation> get visibleRecommendations {
    final all = recommendations;
    if (all.length <= ContextRecommendationEngine.maxVisible) return all;
    return List.unmodifiable(all.take(ContextRecommendationEngine.maxVisible));
  }

  bool isLoading(RecommendationFactor factor) => switch (factor) {
    RecommendationFactor.shade => _routing.isAssessingShade,
    RecommendationFactor.puddle => _puddle?.isLoading ?? false,
    RecommendationFactor.pollen => _pollen?.isLoading ?? false,
    RecommendationFactor.scenic => false,
  };

  /// The ONE allowed action (ТЗ C7.4 §8): re-run an existing assessment on an
  /// explicit user gesture. It never starts a router, never switches a route,
  /// never changes a POI and never lifts the planning lock — the shade re-run
  /// mid-walk asks for the remaining path exactly like the shade card does,
  /// and the scenic factor has no action at all (C7.4 creates no candidates).
  Future<void> recompute(RecommendationFactor factor) async {
    if (_disposed) return;
    switch (factor) {
      case RecommendationFactor.shade:
        if (_routing.navigationLocked) {
          final tail = _navigation.buildRemainingRoute();
          if (tail == null) return;
          // The tail is built from the session's CURRENT progress, so that
          // progress is the estimate's new anchor — exactly what the shade
          // card passes for the same button.
          await _routing.assessShade(
            remainingRoute: tail,
            progressMeters: _navigation.state.totalProgressMeters,
          );
        } else {
          // No alternative probing on a re-run from this panel: the action
          // re-estimates the current walk, it does not search for a better
          // route (that search stays a deliberate press in the shade card).
          await _routing.assessShade(exploreAlternatives: false);
        }
      case RecommendationFactor.puddle:
        await _puddle?.assess();
      case RecommendationFactor.pollen:
        await _pollen?.assess();
      case RecommendationFactor.scenic:
        return;
    }
  }

  // --------------------------------------------------------------- gathering

  RecommendationInputs get inputs {
    final shadeScope = _routing.shadeScope == ShadeAssessmentScope.remainingPath
        ? RecommendationScope.remainingPath
        : RecommendationScope.wholeWalk;
    final shadeAnalysis = _routing.shadeAnalysis;
    final puddleProvider = _puddle;
    final puddleAnalysis = puddleProvider?.analysis;
    final pollenProvider = _pollen;
    final pollenAnalysis = pollenProvider?.analysis;
    return RecommendationInputs(
      hasRoute: _routing.hasRoute,
      navigating: _routing.navigationLocked,
      sessionRebuilding: _navigation.state.isRerouting,
      preference: preference,
      clockModelTime: _clock?.modelTime,
      now: _now(),
      // The progress the walker is at right now, from the session engine
      // itself: the remaining-path evidence each assessment recorded is
      // compared against it.
      progressMeters: _navigation.state.totalProgressMeters,
      shade: SourceSnapshot<ShadeAnalysisModel>(
        facts: shadeAnalysis,
        scope: shadeScope,
        evaluatedFor: _routing.shadeEvaluatedFor,
        identityVerified: _shadeOwnershipProved(shadeScope),
        inProgress: _routing.isAssessingShade,
        problem: _routing.shadeFailure?.message,
        failed: _routing.shadeFailure != null,
        progressMeters: _routing.shadeAnalysisProgress,
      ),
      puddle: _puddleSnapshot(puddleProvider, puddleAnalysis),
      pollen: _pollenSnapshot(pollenProvider, pollenAnalysis),
      scenic: ScenicSnapshot(
        comparison: _verifiedScenicComparison,
        fallbackMessage: _routing.scenicFallbackMessage,
        requested: _routing.walkScenicRequested,
        datasetVersion: spbScenicDataset.version,
      ),
    );
  }

  /// Ownership of a shade estimate is proved by the geometry it describes: the
  /// planning route OBJECT for a plan, the session geometry VERSION for a
  /// remaining path (the tail itself is rebuilt on every fix, so its object
  /// identity proves nothing). A non-null analysis with an unproved owner is
  /// reported, not used.
  bool _shadeOwnershipProved(RecommendationScope scope) {
    if (_routing.shadeAnalysis == null) return false;
    if (scope == RecommendationScope.remainingPath) {
      return _routing.navigationRoute != null &&
          _routing.shadeAnalysisSessionVersion ==
              _routing.navigationRouteVersion;
    }
    return identical(_routing.shadeAnalysisRoute, _routing.currentRoute);
  }

  SourceSnapshot<PuddleAnalysisModel> _puddleSnapshot(
    PuddleAssessmentProvider? provider,
    PuddleAnalysisModel? analysis,
  ) {
    if (provider == null) {
      return const SourceSnapshot<PuddleAnalysisModel>(
        problem: 'оценка мокрых участков не подключена в этой сборке.',
      );
    }
    return SourceSnapshot<PuddleAnalysisModel>(
      facts: analysis,
      scope: provider.scope == PuddleAssessmentScope.remainingPath
          ? RecommendationScope.remainingPath
          : RecommendationScope.wholeWalk,
      evaluatedFor: provider.evaluatedFor,
      identityVerified:
          analysis != null &&
          _ownershipProved(
            remainingPath:
                provider.scope == PuddleAssessmentScope.remainingPath,
            assessedRoute: provider.assessedRoute,
            assessedSessionVersion: provider.assessedSessionVersion,
          ),
      inProgress: provider.isLoading,
      problem: provider.failure?.message,
      failed: provider.failure != null,
      progressMeters: provider.assessedProgress,
      // The weather forecast the wetness estimate was built from states its
      // own validity; a real walk measured against it is what makes an
      // expired forecast visible instead of silently current-looking.
      validUntil: analysis?.weather.validUntil,
    );
  }

  SourceSnapshot<PollenAnalysisModel> _pollenSnapshot(
    PollenAssessmentProvider? provider,
    PollenAnalysisModel? analysis,
  ) {
    if (provider == null) {
      return const SourceSnapshot<PollenAnalysisModel>(
        problem: 'оценка пыльцы не подключена в этой сборке.',
      );
    }
    return SourceSnapshot<PollenAnalysisModel>(
      facts: analysis,
      scope: provider.scope == PollenAssessmentScope.remainingPath
          ? RecommendationScope.remainingPath
          : RecommendationScope.wholeWalk,
      evaluatedFor: provider.evaluatedFor,
      identityVerified:
          analysis != null &&
          _ownershipProved(
            remainingPath:
                provider.scope == PollenAssessmentScope.remainingPath,
            assessedRoute: provider.assessedRoute,
            assessedSessionVersion: provider.assessedSessionVersion,
          ),
      inProgress: provider.isLoading,
      problem: provider.failure?.message,
      failed: provider.failure != null,
      progressMeters: provider.assessedProgress,
      // The forecast's own validity deadline, same rule as the puddle one.
      validUntil: analysis?.source.validUntil,
    );
  }

  bool _ownershipProved({
    required bool remainingPath,
    required PedestrianRouteModel? assessedRoute,
    required int assessedSessionVersion,
  }) {
    if (remainingPath) {
      return _routing.navigationRoute != null &&
          assessedSessionVersion == _routing.navigationRouteVersion;
    }
    return identical(assessedRoute, _routing.currentRoute);
  }

  /// The scenic comparison describes the CURRENT route only while that route
  /// is the scenic one it was built for. RoutingProvider clears the comparison
  /// and the route together on every planning change; re-stating the invariant
  /// here means C7.4 never leans on a non-null field alone.
  RouteComparison? get _verifiedScenicComparison {
    final comparison = _routing.routeComparison;
    final route = _routing.currentRoute;
    if (comparison == null || route == null) return null;
    return route.walkKind == WalkKind.scenic ? comparison : null;
  }

  @override
  void dispose() {
    _disposed = true;
    _liveExpiryTimer?.cancel();
    _liveExpiryTimer = null;
    _routing.removeListener(_dependencyChanged);
    _navigation.removeListener(_dependencyChanged);
    _puddle?.removeListener(_dependencyChanged);
    _pollen?.removeListener(_dependencyChanged);
    _clock?.removeListener(_dependencyChanged);
    _guest?.removeListener(_preferencesChanged);
    super.dispose();
  }
}
