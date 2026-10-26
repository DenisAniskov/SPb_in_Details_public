import 'package:smart_navigator_spb/core/network/ui_error.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/scenic/scenic_dataset.dart';
import 'package:smart_navigator_spb/services/scenic_diagnostics.dart';
import 'package:smart_navigator_spb/services/scenic_walk_engine.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/smart_walk_preset.dart';
import 'package:smart_navigator_spb/services/location_service.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';
import 'package:smart_navigator_spb/services/quiet_route_engine.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_routing_engine.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';

enum RoutingStatus { idle, calculating, success, error }

/// Which walk the current shade estimate describes (§15.5).
///
/// The two are different questions and must never be mixed. The whole walk is
/// the PLAN: every segment is evaluated at the walk's start plus its scheduled
/// offset, so re-running it never moves the evaluation of segments the user
/// has not walked yet. The remaining path is what the walker still has AHEAD,
/// scheduled from the current instant — the honest answer mid-walk.
enum ShadeAssessmentScope {
  /// The whole walk from its planned start — the planning estimate.
  wholeWalk,

  /// The path still ahead, from the current virtual (or device) time.
  remainingPath,
}

/// Stops an obsolete scenic pass before every native segment, including when
/// the unchanged engine catches a cancelled segment and tries another feature.
class _OwnedScenicRouteService implements BasePedestrianRouteService {
  final MapKitService delegate;
  final bool Function() isCurrent;
  _OwnedScenicRouteService(this.delegate, this.isCurrent);

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    if (!isCurrent()) {
      throw const RouteCalculationFailure(RouteFailureKind.serviceUnavailable);
    }
    final route = await delegate.calculatePointToPointRoute(
      startPoint: startPoint,
      destinationPoint: destinationPoint,
    );
    if (!isCurrent()) {
      throw const RouteCalculationFailure(RouteFailureKind.serviceUnavailable);
    }
    return route;
  }

  @override
  void cancel() {
    if (isCurrent()) delegate.cancel();
  }
}

/// A cancelled pass cannot spend the same retained allowance after a retry
/// starts. This view delegates every valid reservation to the original cap.
class _OwnedScenicRequestBudget extends NativeWalkRequestBudget {
  final NativeWalkRequestBudget delegate;
  final bool Function() isCurrent;
  _OwnedScenicRequestBudget(this.delegate, this.isCurrent)
    : super(delegate.maximumRequests);

  @override
  int get requests => delegate.requests;
  @override
  int get remaining => isCurrent() ? delegate.remaining : 0;
  @override
  void consume() {
    if (!isCurrent()) {
      throw const RouteCalculationFailure(RouteFailureKind.requestLimitReached);
    }
    delegate.consume();
  }
}

/// Reserves native requests for the quiet check before Scenic may spend the
/// shared 12-request allowance. Scenic sees the reservation as unavailable
/// budget instead of consuming the whole operation and leaving no evidence
/// for the user's explicit quiet preference.
class _ReservedNativeWalkRequestBudget extends NativeWalkRequestBudget {
  final NativeWalkRequestBudget delegate;
  final int reserve;
  final bool Function() isCurrent;
  _ReservedNativeWalkRequestBudget(this.delegate, this.reserve, this.isCurrent)
    : super(delegate.maximumRequests);

  @override
  int get requests => delegate.requests;
  @override
  int get remaining =>
      isCurrent() ? math.max(0, delegate.remaining - reserve) : 0;
  @override
  void consume() {
    if (!isCurrent() || remaining <= 0) {
      throw const RouteCalculationFailure(RouteFailureKind.requestLimitReached);
    }
    delegate.consume();
  }
}

/// Explicit opt-in diagnostics for labelled synthetic fixtures only. No GPS,
/// coordinates, route titles, API keys or automatic logging are collected.
class WalkBuildDiagnostic {
  final String testPointId;
  final int? budgetMinutes;
  final List<
    ({List<int> sequence, int? walkingSeconds, int visitMinutes, String result})
  >
  attempts;
  final int reservedNativeLegRequests;
  final int nativeLegRequests;
  final int refinementRemovedCount;
  final List<int> finalSequence;
  final String result;
  const WalkBuildDiagnostic({
    required this.testPointId,
    required this.budgetMinutes,
    required this.attempts,
    required this.reservedNativeLegRequests,
    required this.nativeLegRequests,
    required this.refinementRemovedCount,
    required this.finalSequence,
    required this.result,
  });
}

class RoutingProvider extends ChangeNotifier {
  static const int maxWalkPlaces = 6;
  static const int maxWalkRouteAttempts = 6;
  static const int maxNativeWalkLegRequests = 12;
  bool _navigationLocked = false;
  bool get navigationLocked => _navigationLocked;

  /// The planning lock lives here (RoutingProvider owns every planning
  /// mutation) and is driven solely by NavigationProvider session transitions.
  /// Real transitions notify so public readers never observe stale state; the
  /// session teardown path stays quiet because listeners are being unmounted.
  void setNavigationLocked(bool value, {bool notify = true}) {
    if (_navigationLocked == value) return;
    _navigationLocked = value;
    if (value) {
      _isChoosingStart = false;
      _clearWalkAlternatives();
      cancelPendingWalkBuild(notify: false);
    }
    if (notify && !_disposed) notifyListeners();
  }

  bool _isChoosingStart = false;
  bool get isChoosingStart => _isChoosingStart;

  void beginStartSelection() {
    if (_navigationLocked) return;
    _isChoosingStart = true;
    notifyListeners();
  }

  void cancelStartSelection() {
    _isChoosingStart = false;
    notifyListeners();
  }

  final LocationService _locationService;
  final MapKitService _mapKitService;

  RoutingProvider({
    LocationService? locationService,
    MapKitService? mapKitService,
    BaseShadeAnalysisService? shadeAnalysisService,
    BaseQuietAnalysisService? quietAnalysisService,
  }) : this._(
         locationService ?? LocationService(),
         mapKitService ?? MapKitService(),
         // Phase A6.2: the provider and its engine share ONE shade service.
         // Two internally created services would each fall back to the
         // platform-default backend URL, so in staging the estimate could
         // reach a different host than the catalog and search.
         shadeAnalysisService ?? BackendShadeAnalysisService(),
         quietAnalysisService,
       );

  RoutingProvider._(
    this._locationService,
    this._mapKitService,
    this._shadeService,
    this._quietService,
  ) : _shadeEngine = ShadeRoutingEngine(shadeService: _shadeService);

  RoutingStatus _status = RoutingStatus.idle;
  RoutePointModel _startPoint = RoutePointModel.defaultStart;
  PlaceModel? _destinationPlace;
  ExternalMapPoint? _destinationExternalPoint;
  final List<PlaceModel> _walkPlaces = [];
  PedestrianRouteModel? _currentRoute;
  String? _errorMessage;
  int _requestId = 0;
  bool _disposed = false;
  final Set<RoutingProvider> _guidedDrafts = {};
  RoutingProvider? _guidedOwner;
  VoidCallback? _guidedOwnerListener;
  int? _guidedOwnerRequestId;
  int? _guidedOwnerStartRevision;
  int? _guidedOwnerNavigationVersion;
  PedestrianRouteModel? _guidedOwnerRoute;
  bool _guidedInvalidated = false;

  /// A guided walk edits an isolated provider so the map's published walk is
  /// preserved throughout the wizard, including native failures and cancel.
  bool get isGuidedDraft => _guidedOwner != null;

  /// Monotonic id of the latest routing request. Callers that await a build
  /// capture it beforehand and treat their outcome as superseded when it no
  /// longer matches, so a stale completion never impersonates a fresh result.
  int get requestId => _requestId;
  bool get guidedDraftIsCurrent {
    final owner = _guidedOwner;
    return owner != null &&
        !_disposed &&
        !_guidedInvalidated &&
        !owner._disposed &&
        !owner.navigationLocked &&
        owner._requestId == _guidedOwnerRequestId &&
        owner._startRevision == _guidedOwnerStartRevision &&
        owner._navigationRouteVersion == _guidedOwnerNavigationVersion &&
        identical(owner.currentRoute, _guidedOwnerRoute);
  }

  RoutingProvider? createGuidedDraft() {
    if (_disposed ||
        _navigationLocked ||
        isCalculating ||
        isCheckingScenic ||
        isCheckingQuiet ||
        isAssessingShade ||
        isGuidedDraft) {
      return null;
    }
    // There can be only one active native planning transaction per owner.
    for (final previous in _guidedDrafts.toList()) {
      previous._invalidateGuidedDraft();
    }
    final location = LocationService()..setStartPoint(_startPoint);
    final draft = RoutingProvider(
      locationService: location,
      mapKitService: _mapKitService,
      shadeAnalysisService: _shadeService,
      quietAnalysisService: _quietService,
    );
    draft
      .._startPoint = _startPoint
      .._guidedOwner = this
      .._guidedOwnerRequestId = _requestId
      .._guidedOwnerStartRevision = _startRevision
      .._guidedOwnerNavigationVersion = _navigationRouteVersion
      .._guidedOwnerRoute = _currentRoute
      .._walkBudgetMinutes = _walkBudgetMinutes
      .._walkPreset = _walkPreset
      .._walkCategories = Set.of(_walkCategories)
      .._walkPreferUnusual = _walkPreferUnusual
      .._shadeOverlayEnabled = _shadeOverlayEnabled;
    draft._walkPlaces.addAll(_walkPlaces);
    draft._placeReasons.addAll(_placeReasons);
    void ownerChanged() {
      if (!draft.guidedDraftIsCurrent) draft._invalidateGuidedDraft();
    }

    draft._guidedOwnerListener = ownerChanged;
    addListener(ownerChanged);
    _guidedDrafts.add(draft);
    return draft;
  }

  void _invalidateGuidedDraft() {
    if (_disposed || _guidedInvalidated) return;
    _guidedInvalidated = true;
    cancelPendingWalkBuild(notify: false);
    clearShadeAssessment(notify: false);
    _navigationLocked = true;
    notifyListeners();
  }

  /// Publishes the exact chosen snapshot, preserving assessment provenance.
  /// No route request or navigation start is performed here.
  bool commitGuidedDraft(RoutingProvider draft) {
    if (_disposed ||
        _navigationLocked ||
        !identical(draft._guidedOwner, this) ||
        !draft.guidedDraftIsCurrent ||
        !draft.isWalkRoute ||
        draft.isCalculating ||
        draft.isCheckingScenic ||
        draft.isCheckingQuiet ||
        draft.isAssessingShade) {
      return false;
    }
    final selected = draft.currentRoute;
    if (selected == null ||
        (!identical(selected, draft.verifiedNormalRoute) &&
            !identical(selected, draft.verifiedScenicRoute) &&
            !identical(selected, draft.verifiedQuietRoute))) {
      return false;
    }
    clearShadeAssessment(notify: false);
    ++_requestId;
    ++_startRevision;
    _startPoint = draft._startPoint;
    _locationService.setStartPoint(_startPoint);
    _walkPlaces
      ..clear()
      ..addAll(draft._walkPlaces);
    _placeReasons
      ..clear()
      ..addAll(draft._placeReasons);
    _walkAlternatives
      ..clear()
      ..addAll(draft._walkAlternatives);
    _walkBudgetMinutes = draft._walkBudgetMinutes;
    _walkPreset = draft._walkPreset;
    _walkCategories = Set.of(draft._walkCategories);
    _walkPreferUnusual = draft._walkPreferUnusual;
    _walkScenic = selected.walkKind == WalkKind.scenic;
    _routeComparison = draft._routeComparison;
    _scenicFallbackMessage = draft._scenicFallbackMessage;
    _budgetWarningMessage = draft._budgetWarningMessage;
    _walkDiagnostic = draft._walkDiagnostic;
    _verifiedNormalRoute = draft._verifiedNormalRoute;
    _verifiedScenicRoute = draft._verifiedScenicRoute;
    _verifiedQuietRoute = draft._verifiedQuietRoute;
    _walkNativeBudget = null;
    _scenicChecked = draft._scenicChecked;
    _quietChecked = draft._quietChecked;
    _quietNormalAnalysis = draft._quietNormalAnalysis;
    _quietCandidateAnalysis = draft._quietCandidateAnalysis;
    _quietDecision = draft._quietDecision;
    _quietFailure = draft._quietFailure;
    _quietEvaluatedAt = draft._quietEvaluatedAt;
    _isWalkRequest = true;
    _isChoosingStart = false;
    _destinationPlace = _walkPlaces.last;
    _destinationExternalPoint = null;
    _currentRoute = selected;
    _status = RoutingStatus.success;
    _errorMessage = null;
    // A committed draft no longer participates in owner-change invalidation;
    // its environmental results remain readable for immediate safe adoption.
    final listener = draft._guidedOwnerListener;
    if (listener != null) removeListener(listener);
    draft._guidedOwnerListener = null;
    draft._guidedInvalidated = true;
    draft._navigationLocked = true;
    _guidedDrafts.remove(draft);
    notifyListeners();
    return true;
  }

  int _startRevision = 0;
  int get startRevision => _startRevision;
  int? _walkBudgetMinutes;
  int? get walkBudgetMinutes => _walkBudgetMinutes;
  SmartWalkPreset? _walkPreset;
  SmartWalkPreset? get walkPreset => _walkPreset;
  Set<PlaceCategoryEnum> _walkCategories = {};
  bool _walkPreferUnusual = false;
  bool _walkScenic = false;
  RouteComparison? _routeComparison;
  String? _scenicFallbackMessage;
  PedestrianRouteModel? _verifiedNormalRoute;
  PedestrianRouteModel? _verifiedScenicRoute;
  PedestrianRouteModel? _verifiedQuietRoute;
  NativeWalkRequestBudget? _walkNativeBudget;
  bool _scenicChecked = false;
  bool _checkingScenic = false;
  PedestrianRouteModel? get verifiedNormalRoute => _verifiedNormalRoute;
  PedestrianRouteModel? get verifiedScenicRoute => _verifiedScenicRoute;
  PedestrianRouteModel? get verifiedQuietRoute => _verifiedQuietRoute;
  bool get scenicChecked => _scenicChecked;
  bool get isCheckingScenic => _checkingScenic;

  // --- Phase C11: quiet-route comparison state --------------------------
  bool _quietChecked = false;
  bool _checkingQuiet = false;
  QuietAnalysisModel? _quietNormalAnalysis;
  QuietAnalysisModel? _quietCandidateAnalysis;
  QuietRoutingDecision? _quietDecision;
  QuietAnalysisFailure? _quietFailure;
  DateTime? _quietEvaluatedAt;
  bool get quietChecked => _quietChecked;
  bool get isCheckingQuiet => _checkingQuiet;
  QuietAnalysisModel? get quietNormalAnalysis => _quietNormalAnalysis;
  QuietAnalysisModel? get quietCandidateAnalysis => _quietCandidateAnalysis;
  QuietRoutingDecision? get quietDecision => _quietDecision;
  QuietAnalysisFailure? get quietFailure => _quietFailure;
  DateTime? get quietEvaluatedAt => _quietEvaluatedAt;
  bool get quietAvailable => _quietService != null;
  final List<AutoWalkAlternativeModel> _walkAlternatives = [];
  WalkBuildDiagnostic? _walkDiagnostic;
  WalkBuildDiagnostic? get walkDiagnostic => _walkDiagnostic;
  @visibleForTesting
  int get walkAlternativeCount => _walkAlternatives.length;

  // --- Phase C7.1: shade assessment state -------------------------------
  // The assessment belongs to ONE built route at ONE departure instant. Any
  // route change or time change invalidates it: a stale shade estimate must
  // never be displayed over different geometry (§14.2, §15.4).
  static const int maxAlternativeLegs = 3;
  static const int maxAlternativesPerLeg = 2;

  final BaseShadeAnalysisService _shadeService;
  final ShadeRoutingEngine _shadeEngine;
  final BaseQuietAnalysisService? _quietService;
  ShadeAnalysisModel? _shadeAnalysis;
  ShadeRoutingDecision? _shadeDecision;
  ShadeAnalysisFailure? _shadeFailure;
  DateTime? _shadeDeparture;
  bool _assessingShade = false;
  int _shadeRequestId = 0;
  PedestrianRouteModel? _shadeAnalysisRoute;
  bool _shadeOverlayEnabled = false;
  ShadeAssessmentScope _shadeScope = ShadeAssessmentScope.wholeWalk;

  /// Which question the current estimate answers: the whole walk's plan or the
  /// remaining path from the current instant (§15.5). With no applicable
  /// estimate this is the whole-walk scope, i.e. what the section offers next.
  ShadeAssessmentScope get shadeScope =>
      _shadeEstimateApplies ? _shadeScope : ShadeAssessmentScope.wholeWalk;

  /// The session geometry version the current estimate was computed against.
  int _shadeAnalysisSessionVersion = -1;

  /// The session progress the current estimate was anchored at, when the
  /// caller supplied it (C7.4 §6 evidence). A remaining-path estimate is cut
  /// from where the walker stood when the button was pressed: the version only
  /// proves the geometry was not rebuilt, so without this number a walker who
  /// advanced along the same route would keep seeing the old tail.
  double? _shadeAnalysisProgress;

  /// Map layer toggle. Off by default: the overlay is an explicit opt-in and
  /// turning it off never touches the route itself (§14.4).
  bool get shadeOverlayEnabled => _shadeOverlayEnabled && shadeAnalysis != null;

  /// Whether the overlay may actually be DRAWN right now (§15.3).
  ///
  /// With a virtual clock (simulator) the estimate belongs to the instant it
  /// was computed for; once the virtual time drifts past the documented
  /// refresh step the overlay describes a different Sun and must not stay on
  /// the map — the UI asks for a re-analysis instead.
  bool get shadeOverlayReady {
    if (!shadeOverlayEnabled) return false;
    final clock = _shadeClock;
    return clock == null || !clock.needsReanalysis;
  }

  void setShadeOverlayEnabled(bool value) {
    if (_shadeOverlayEnabled == value) return;
    _shadeOverlayEnabled = value;
    _shadeClock?.overlayRequested = value;
    if (!_disposed) notifyListeners();
  }

  // --- Phase C7.1 §15: the simulator's virtual clock ---------------------
  // The clock exists only in simulator builds. The provider owns the calls
  // that make it truthful: a departure arms it, a finished analysis marks it,
  // and a route/time change invalidates it — so `modelTime` and
  // `needsReanalysis` are never decorative.
  VirtualShadeClock? _shadeClock;

  @visibleForTesting
  VirtualShadeClock? get shadeClock => _shadeClock;

  void attachShadeClock(VirtualShadeClock? clock) {
    _shadeClock = clock;
    clock?.overlayRequested = shadeOverlayEnabled;
  }

  // --- Phase C7.1.2: the live navigation session ------------------------
  // The frozen geometry the user is actually walking, pushed by
  // NavigationProvider. While a session runs this is the ONLY route a shade
  // estimate may describe: a reroute replaces the session geometry while the
  // planning route stays untouched, so the planning object is no longer proof
  // that the map matches the ground under the walker.
  PedestrianRouteModel? _navigationRoute;
  PedestrianRouteModel? get navigationRoute => _navigationRoute;
  int _navigationRouteVersion = 0;

  /// Monotonic version of the session geometry state. A remaining-path
  /// estimate belongs to a version, not to an object (the tail is rebuilt on
  /// every fix), so this is the PUBLIC evidence of ownership that consumers
  /// outside this file verify (C7.4 §6) — it is no longer test-only.
  int get navigationRouteVersion => _navigationRouteVersion;

  /// Session geometry transition (start, reroute, stop). Replacing one live
  /// session route with ANOTHER means the route was rebuilt under the walker:
  /// every estimate over the previous geometry is dropped and the overlay goes
  /// with it (§15.4), including the clock's claim that a current estimate
  /// exists. Starting or ending a session keeps the estimate — the planning
  /// geometry is the same object then.
  void setNavigationRoute(PedestrianRouteModel? route, {bool notify = true}) {
    if (identical(_navigationRoute, route)) return;
    final rebuiltUnderWalker = _navigationRoute != null && route != null;
    _navigationRoute = route;
    ++_navigationRouteVersion;
    if (rebuiltUnderWalker) clearShadeAssessment(notify: false);
    if (notify && !_disposed) notifyListeners();
  }

  ShadeAnalysisModel? get shadeAnalysis =>
      _shadeEstimateApplies ? _shadeAnalysis : null;
  ShadeRoutingDecision? get shadeDecision =>
      _shadeEstimateApplies ? _shadeDecision : null;
  ShadeAnalysisFailure? get shadeFailure =>
      _shadeEstimateApplies ? _shadeFailure : null;

  /// The geometry the current estimate describes, or null when no estimate
  /// applies. Exposed as EVIDENCE for consumers that must verify provenance
  /// themselves instead of trusting a non-null analysis (C7.4 §6): for a plan
  /// estimate this is the planning route object it was computed from.
  PedestrianRouteModel? get shadeAnalysisRoute =>
      _shadeEstimateApplies ? _shadeAnalysisRoute : null;

  /// The session geometry version the current estimate was computed against,
  /// or -1 when no estimate applies. A remaining-path estimate belongs to a
  /// session GEOMETRY STATE, so this — not the (rebuilt on every fix) tail
  /// object — is the proof of ownership.
  int get shadeAnalysisSessionVersion =>
      _shadeEstimateApplies ? _shadeAnalysisSessionVersion : -1;

  /// The session progress the current estimate was anchored at, or null when
  /// no estimate applies (or the caller supplied none for a remaining-path
  /// run). Together with the version it pins WHICH tail was analysed.
  double? get shadeAnalysisProgress =>
      _shadeEstimateApplies ? _shadeAnalysisProgress : null;

  /// Whether the current estimate still describes the geometry it claims to.
  ///
  /// A plan estimate belongs to the planning route. A remaining-path estimate
  /// belongs to a session GEOMETRY STATE, not to an object: the remaining path
  /// is rebuilt from live progress on every fix, so only the session geometry
  /// version can tell whether the ground it described is still the ground
  /// ahead (a rebuilt route bumps the version and drops it).
  bool get _shadeEstimateApplies {
    if (_shadeAnalysisRoute == null) return false;
    if (_shadeScope == ShadeAssessmentScope.remainingPath) {
      return _shadeAnalysisSessionVersion == _navigationRouteVersion &&
          _navigationRoute != null;
    }
    return identical(_shadeAnalysisRoute, _currentRoute);
  }

  bool get isAssessingShade => _assessingShade;

  /// The instant the walk is planned to START (with a clock: the departure the
  /// virtual time is anchored to, NOT the running model time).
  DateTime? get shadeDeparture => _shadeDeparture;

  /// The instant the current estimate was computed FOR (with a clock this is
  /// the model time at the moment of the analysis).
  DateTime? _shadeEvaluatedFor;
  DateTime? get shadeEvaluatedFor =>
      _shadeEstimateApplies ? _shadeEvaluatedFor : null;

  /// True when the current assessment was made for a different instant than
  /// [instant], so the UI must not present it as current.
  bool shadeAssessmentIsStaleFor(DateTime instant) {
    final evaluated = _shadeEvaluatedFor;
    if (evaluated == null) return true;
    return evaluated.difference(instant).inMinutes.abs() >= 1;
  }

  void clearShadeAssessment({bool notify = true}) {
    _shadeClock?.invalidate();
    if (_shadeAnalysis == null &&
        _shadeDecision == null &&
        _shadeFailure == null &&
        _shadeDeparture == null) {
      return;
    }
    ++_shadeRequestId;
    _shadeAnalysis = null;
    _shadeDecision = null;
    _shadeFailure = null;
    _shadeDeparture = null;
    _shadeEvaluatedFor = null;
    _shadeAnalysisRoute = null;
    _shadeScope = ShadeAssessmentScope.wholeWalk;
    _shadeAnalysisSessionVersion = -1;
    _shadeAnalysisProgress = null;
    _assessingShade = false;
    if (notify && !_disposed) notifyListeners();
  }

  void _clearWalkAlternatives() {
    _walkAlternatives.clear();
    _walkDiagnostic = null;
  }

  @visibleForTesting
  Set<PlaceCategoryEnum> get walkCategories =>
      Set.unmodifiable(_walkCategories);
  @visibleForTesting
  bool get walkPreferUnusual => _walkPreferUnusual;

  /// Whether the user requested a scenic walk (Phase C5). The BUILT route
  /// may honestly be normal when no verified scenic alternative passed the
  /// scoring and budget gates; [scenicFallbackMessage] explains it.
  bool get walkScenicRequested => _walkScenic;
  RouteComparison? get routeComparison => _routeComparison;
  String? get scenicFallbackMessage => _scenicFallbackMessage;

  @visibleForTesting
  void setWalkScenicRequestedForTesting(bool value) => _walkScenic = value;

  /// UI-test seeding: a built route with its scenic outcome, bypassing the
  /// native build. Never used by production flows.
  @visibleForTesting
  void setProposedWalkForScenicTest({
    required bool scenic,
    required RouteComparison? comparison,
    required WalkKind walkKind,
    required PedestrianRouteModel route,
    String? fallbackMessage,
  }) {
    _isWalkRequest = true;
    _walkScenic = scenic;
    _routeComparison = comparison;
    _scenicFallbackMessage = fallbackMessage;
    _currentRoute = route.immutableSnapshot();
    _status = RoutingStatus.success;
  }

  /// Smart Walk parameters belong to the proposal/walk that set them. Leaving
  /// that planning context — an ordinary POI route, an external route, a
  /// cleared route — must reset them, or a later manual walk silently inherits
  /// a stale budget and starts dropping stops. The place list itself is the
  /// user's editing scratchpad and deliberately survives route dismissal;
  /// clearWalk() is the explicit reset for it. Continuing to edit the walk the
  /// proposal created (add/remove/reorder) legitimately keeps its budget.
  void _resetSmartWalkParameters() {
    _clearWalkAlternatives();
    _walkBudgetMinutes = null;
    _walkPreset = null;
    _walkCategories = {};
    _walkPreferUnusual = false;
    _walkScenic = false;
    _routeComparison = null;
    _scenicFallbackMessage = null;
    _clearVerifiedWalkVariants();
  }

  void _clearVerifiedWalkVariants() {
    _verifiedNormalRoute = null;
    _verifiedScenicRoute = null;
    _verifiedQuietRoute = null;
    _walkNativeBudget = null;
    _scenicChecked = false;
    _checkingScenic = false;
    _quietChecked = false;
    _checkingQuiet = false;
    _quietNormalAnalysis = null;
    _quietCandidateAnalysis = null;
    _quietDecision = null;
    _quietFailure = null;
    _quietEvaluatedAt = null;
  }

  /// Cancels native work and releases loading immediately. A scenic check
  /// never removes its confirmed normal route; a wizard draft never touches
  /// its owner's already published walk.
  void cancelPendingWalkBuild({bool notify = true}) {
    if (!isCalculating && !_checkingScenic && !_checkingQuiet) return;
    ++_requestId;
    _mapKitService.cancel();
    _checkingScenic = false;
    _checkingQuiet = false;
    _status = _currentRoute == null
        ? RoutingStatus.idle
        : RoutingStatus.success;
    _errorMessage = null;
    if (notify && !_disposed) notifyListeners();
  }

  /// Checks only the normal snapshot that MapKit already verified. The
  /// retained budget is shared with that build, including previous fallback
  /// attempts; moving to this step never creates a fresh request allowance.
  Future<void> checkScenicForCurrentWalk() async {
    final normal = _verifiedNormalRoute;
    final nativeBudget = _walkNativeBudget;
    if (_disposed ||
        _navigationLocked ||
        isCalculating ||
        _checkingScenic ||
        _checkingQuiet ||
        _scenicChecked ||
        normal == null ||
        nativeBudget == null ||
        !identical(_currentRoute, normal)) {
      return;
    }
    final requestId = ++_requestId;
    _checkingScenic = true;
    notifyListeners();
    bool current() =>
        !_disposed &&
        !_navigationLocked &&
        (!isGuidedDraft || guidedDraftIsCurrent) &&
        requestId == _requestId &&
        identical(_currentRoute, normal);
    try {
      final engine = ScenicWalkEngine(
        routeService: _OwnedScenicRouteService(_mapKitService, current),
        datasetFeatures: spbScenicDataset.features,
      );
      final visitSeconds = _walkPlaces.fold<int>(
        0,
        (sum, place) => sum + place.recommendedVisitMinutes * 60,
      );
      final budget = _walkBudgetMinutes;
      // Reserve native requests for the quiet comparison BEFORE Scenic spends
      // the shared allowance. Without this, an optional scenic detour could
      // consume all 12 requests and leave the user's quieter preference
      // unverified.
      final quietReserve = (!_quietChecked && _quietService != null) ? 3 : 0;
      final scenicBudget = _ReservedNativeWalkRequestBudget(
        nativeBudget,
        quietReserve,
        current,
      );
      final result = await engine.enhance(
        normalRoute: normal,
        walkBudgetSeconds: budget == null ? null : budget * 60 - visitSeconds,
        requestBudget: _OwnedScenicRequestBudget(scenicBudget, current),
        recognizeOnPath: true,
      );
      if (!current()) return;
      _verifiedScenicRoute = result.isScenic && result.route != null
          ? result.route!.immutableSnapshot()
          : null;
      _routeComparison = _verifiedScenicRoute == null
          ? null
          : result.comparison?.immutableSnapshot();
      _scenicFallbackMessage = _verifiedScenicRoute == null
          ? scenicFallbackReasonText(result.fallbackReason)
          : null;
    } catch (_) {
      if (!current()) return;
      _verifiedScenicRoute = null;
      _routeComparison = null;
      _scenicFallbackMessage = scenicFallbackReasonText(
        ScenicFallbackReason.mapkitUnavailable,
      );
    }
    if (!current()) return;
    _scenicChecked = true;
    _checkingScenic = false;
    notifyListeners();
  }

  /// Phase C11: verified quieter alternative for the SAME normal walk.
  ///
  /// It uses only real MapKit variants from the shared 12-request budget and
  /// backend estimates of the exact candidate geometries. If no alternative
  /// improves the proxy by the documented minimum with comparable coverage,
  /// the normal route stays selected and the reason is published.
  Future<void> checkQuietForCurrentWalk() async {
    final normal = _verifiedNormalRoute;
    final nativeBudget = _walkNativeBudget;
    final service = _quietService;
    if (_disposed ||
        _navigationLocked ||
        isCalculating ||
        _checkingScenic ||
        _checkingQuiet ||
        _quietChecked ||
        normal == null ||
        nativeBudget == null ||
        service == null ||
        !identical(_currentRoute, normal)) {
      return;
    }
    final requestId = ++_requestId;
    _checkingQuiet = true;
    _quietFailure = null;
    notifyListeners();
    bool current() =>
        !_disposed &&
        !_navigationLocked &&
        (!isGuidedDraft || guidedDraftIsCurrent) &&
        requestId == _requestId &&
        identical(_currentRoute, normal);
    final when = DateTime.now();
    final visitSeconds = _walkPlaces.fold<int>(
      0,
      (sum, place) => sum + place.recommendedVisitMinutes * 60,
    );
    try {
      final normalAnalysis = await service.analyzeWalk(
        assessedAt: when,
        legs: normal.legs,
        visitMinutesAfterLeg: _visitMinutesFor(normal),
      );
      if (!current()) return;
      _quietNormalAnalysis = normalAnalysis;
      final decision = await QuietRouteEngine().enhance(
        normalRoute: normal,
        normalAnalysis: normalAnalysis,
        requestBudget: nativeBudget,
        walkBudgetSeconds: _walkBudgetMinutes == null
            ? null
            : _walkBudgetMinutes! * 60 - visitSeconds,
        isCurrent: current,
        requestVariants: (index, leg, budget) =>
            _mapKitService.requestLegVariants(
              fromLat: leg.geometryPoints.first.latitude,
              fromLon: leg.geometryPoints.first.longitude,
              fromTitle: leg.fromTitle,
              toLat: leg.geometryPoints.last.latitude,
              toLon: leg.geometryPoints.last.longitude,
              toTitle: leg.toTitle,
              requestBudget: budget,
              legIndex: index,
              visitMinutes: leg.visitMinutes,
              maxVariants: 2,
            ),
        analyze: (candidate) => service.analyzeWalk(
          assessedAt: when,
          legs: candidate.legs,
          visitMinutesAfterLeg: _visitMinutesFor(candidate),
        ),
      );
      if (!current()) return;
      _quietDecision = decision;
      _quietCandidateAnalysis = decision.candidateAnalysis;
      _verifiedQuietRoute = decision.candidateRoute?.immutableSnapshot();
      _quietEvaluatedAt = when;
    } on QuietAnalysisFailure catch (failure) {
      if (!current()) return;
      _quietFailure = failure;
      _verifiedQuietRoute = null;
    } catch (_) {
      if (!current()) return;
      _quietFailure = const QuietAnalysisFailure(
        QuietAnalysisFailureKind.serviceUnavailable,
        'Оценка тишины сейчас недоступна. Обычный маршрут сохранён.',
      );
      _verifiedQuietRoute = null;
    }
    if (!current()) return;
    _quietChecked = true;
    _checkingQuiet = false;
    notifyListeners();
  }

  List<int> _visitMinutesFor(PedestrianRouteModel route) => [
    for (var i = 0; i < route.legs.length; i++)
      i < route.legs.length - 1 ? route.legs[i].visitMinutes ?? 0 : 0,
  ];

  /// Explicitly chooses between actual immutable native results. Scenic
  /// metadata alone cannot manufacture an alternative, and switching costs
  /// no additional native requests.
  bool selectVerifiedWalkVariant(WalkKind kind) {
    if (_disposed ||
        _navigationLocked ||
        isCalculating ||
        _checkingScenic ||
        _checkingQuiet) {
      return false;
    }
    final selected = switch (kind) {
      WalkKind.scenic => _verifiedScenicRoute,
      WalkKind.quiet => _verifiedQuietRoute,
      WalkKind.normal => _verifiedNormalRoute,
    };
    if (selected == null) return false;
    if (identical(_currentRoute, selected)) return true;
    ++_requestId;
    _currentRoute = selected;
    _walkScenic = kind == WalkKind.scenic;
    _status = RoutingStatus.success;
    _errorMessage = null;
    clearShadeAssessment(notify: false);
    notifyListeners();
    return true;
  }

  int get visitDurationMinutes => isWalkRoute
      ? _walkPlaces.fold(0, (sum, p) => sum + p.recommendedVisitMinutes)
      : 0;
  int? get totalWalkDurationSeconds => isWalkRoute
      ? _currentRoute!.durationSeconds + visitDurationMinutes * 60
      : null;
  bool _isWalkRequest = false;

  void _invalidateRoute() {
    ++_requestId;
    _mapKitService.cancel();
    _currentRoute = null;
    _status = RoutingStatus.idle;
    _errorMessage = null;
    _budgetWarningMessage = null;
    _routeComparison = null;
    _scenicFallbackMessage = null;
    _clearVerifiedWalkVariants();
    // A shade assessment describes geometry that no longer exists.
    clearShadeAssessment(notify: false);
  }

  Future<void> setMapStartPoint(
    double lat,
    double lon, {
    required Future<ExternalMapPoint?> Function(double, double) reverseGeocode,
  }) async {
    if (_navigationLocked) return;
    setCustomStartPoint(lat, lon);
    final revision = _startRevision;
    final resolved = await reverseGeocode(lat, lon);
    if (_disposed || revision != _startRevision || resolved == null) return;
    updateStartPointTitle(resolved.title, subtitle: resolved.address);
  }

  RoutingStatus get status => _status;
  RoutePointModel get startPoint => _startPoint;
  PlaceModel? get destinationPlace => _destinationPlace;
  ExternalMapPoint? get destinationExternalPoint => _destinationExternalPoint;
  List<PlaceModel> get walkPlaces => List.unmodifiable(_walkPlaces);
  PedestrianRouteModel? get currentRoute => _currentRoute;
  String? get errorMessage => _errorMessage;

  String get destinationTitle {
    if (_isWalkRequest && _walkPlaces.isNotEmpty) {
      return 'Маршрут прогулки (${_walkPlaces.length} мест)';
    }
    return _destinationPlace?.title ??
        _destinationExternalPoint?.title ??
        'Точка назначения';
  }

  String? get destinationAddress {
    return _destinationPlace?.address ??
        _destinationExternalPoint?.address ??
        _destinationExternalPoint?.subtitle;
  }

  bool get isCalculating => _status == RoutingStatus.calculating;
  bool get hasRoute =>
      _status == RoutingStatus.success && _currentRoute != null;
  bool get isWalkRoute => hasRoute && _isWalkRequest;

  bool isPlaceInWalk(PlaceModel place) {
    return _walkPlaces.any((p) => p.id == place.id);
  }

  bool isInWalk(PlaceModel place) => isPlaceInWalk(place);

  /// Добавление места в туристическую прогулку.
  /// Возвращает false, если место уже добавлено или достигнут лимит (максимум 6 мест).
  bool addPlaceToWalk(PlaceModel place) {
    if (_navigationLocked) return false;
    if (isPlaceInWalk(place)) return false;
    if (_walkPlaces.length >= maxWalkPlaces) {
      return false;
    }
    _walkPlaces.add(place);
    _clearWalkAlternatives();
    _placeReasons.clear();
    // При изменении состава прогулки сбрасываем предыдущий построенный маршрут
    _invalidateRoute();
    notifyListeners();
    return true;
  }

  void removePlaceFromWalk(int placeId) {
    if (_navigationLocked) return;
    _walkPlaces.removeWhere((p) => p.id == placeId);
    _clearWalkAlternatives();
    _placeReasons.clear();
    _invalidateRoute();
    notifyListeners();
  }

  void reorderWalkPlaces(int oldIndex, int newIndex) {
    if (_navigationLocked) return;
    if (oldIndex < 0 || oldIndex >= _walkPlaces.length) return;
    if (newIndex < 0 || newIndex > _walkPlaces.length) return;

    final rebuild =
        !isGuidedDraft && _isWalkRequest && (hasRoute || isCalculating);
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final item = _walkPlaces.removeAt(oldIndex);
    _clearWalkAlternatives();
    _walkPlaces.insert(newIndex, item);
    _placeReasons.clear();

    _invalidateRoute();
    notifyListeners();
    if (rebuild) buildWalkRoute();
  }

  final Map<int, List<String>> _placeReasons = {};
  Map<int, List<String>> get placeReasons => Map.unmodifiable(_placeReasons);
  String? _budgetWarningMessage;
  String? get budgetWarningMessage => _budgetWarningMessage;

  void clearBudgetWarning() {
    _budgetWarningMessage = null;
    notifyListeners();
  }

  void setProposedWalk(
    List<PlaceModel> places, {
    Map<int, List<String>>? reasons,
    int? timeBudgetMinutes,
    SmartWalkPreset? preset,
    Set<PlaceCategoryEnum> categories = const {},
    bool preferUnusual = SmartWalkConfiguration.automaticPreferUnusual,
    List<AutoWalkAlternativeModel> alternatives = const [],
    bool scenic = false,
  }) {
    if (_navigationLocked) return;
    final budget = preset?.timeBudgetMinutes ?? timeBudgetMinutes;
    SmartWalkConfiguration.validateBudget(budget);
    if (preset != null &&
        timeBudgetMinutes != null &&
        timeBudgetMinutes != preset.timeBudgetMinutes) {
      throw ArgumentError('The preset and time budget must agree');
    }
    if (places.any((p) => !isValidWalkPlace(p, categories))) {
      throw ArgumentError('Invalid place or selected category in proposal');
    }
    _clearWalkAlternatives();
    _walkPlaces.clear();
    final seen = <int>{};
    _walkPlaces.addAll(places.where((p) => seen.add(p.id)).take(maxWalkPlaces));
    _walkBudgetMinutes = budget;
    _walkPreset = preset;
    _walkCategories = Set.of(categories);
    _walkPreferUnusual = preferUnusual;
    _walkScenic = scenic;
    _routeComparison = null;
    _scenicFallbackMessage = null;
    final sets = <String>{_placeSetKey(_walkPlaces)};
    for (final alternative in alternatives) {
      if (_walkAlternatives.length >= 2) break;
      final candidate = alternative.items.map((i) => i.place).toList();
      if (alternative.timeBudgetMinutes != budget ||
          candidate.isEmpty ||
          candidate.length > maxWalkPlaces ||
          candidate.any((p) => !isValidWalkPlace(p, categories)) ||
          candidate.map((p) => p.id).toSet().length != candidate.length ||
          !listEquals(
            candidate.map((p) => p.id).toList(),
            alternative.suggestedPlacesSequence,
          ) ||
          alternative.items.any(
            (i) => i.visitDurationMinutes != i.place.recommendedVisitMinutes,
          ) ||
          !sets.add(_placeSetKey(candidate))) {
        continue;
      }
      _walkAlternatives.add(
        AutoWalkAlternativeModel(
          timeBudgetMinutes: alternative.timeBudgetMinutes,
          suggestedPlacesSequence: List.unmodifiable(
            alternative.suggestedPlacesSequence,
          ),
          items: List.unmodifiable(
            alternative.items.map(
              (item) => ProposedWalkItemModel(
                place: item.place,
                visitDurationMinutes: item.visitDurationMinutes,
                reasons: List.unmodifiable(item.reasons),
              ),
            ),
          ),
        ),
      );
    }
    _placeReasons.clear();
    if (reasons != null) {
      for (final p in _walkPlaces) {
        if (reasons[p.id] != null) {
          _placeReasons[p.id] = List.unmodifiable(reasons[p.id]!);
        }
      }
    }
    _budgetWarningMessage = null;
    _invalidateRoute();
    notifyListeners();
  }

  void clearWalk() {
    if (_navigationLocked) return;
    _walkPlaces.clear();
    _placeReasons.clear();
    _resetSmartWalkParameters();
    _budgetWarningMessage = null;
    clearRoute();
  }

  void setStartPoint(RoutePointModel point) {
    if (_navigationLocked) return;
    final rebuild = !isGuidedDraft && (hasRoute || isCalculating);
    ++_startRevision;
    _clearWalkAlternatives();
    _placeReasons.clear();
    _budgetWarningMessage = null;
    _isChoosingStart = false;
    _startPoint = point;
    _locationService.setStartPoint(point);
    _invalidateRoute();
    notifyListeners();

    // Пересчитываем активный маршрут, если он уже был построен
    if (rebuild) {
      if (_isWalkRequest && _walkPlaces.isNotEmpty) {
        buildWalkRoute();
      } else if (_destinationPlace != null) {
        buildRouteTo(_destinationPlace!);
      } else if (_destinationExternalPoint != null) {
        buildRouteToExternalPoint(_destinationExternalPoint!);
      }
    }
  }

  void setCustomStartPoint(
    double lat,
    double lon, {
    String title = 'Выбранная точка',
  }) {
    if (_navigationLocked) return;
    final rebuild = !isGuidedDraft && (hasRoute || isCalculating);
    ++_startRevision;
    _clearWalkAlternatives();
    _placeReasons.clear();
    _budgetWarningMessage = null;
    _locationService.setCustomStartPoint(lat, lon, title: title);
    _isChoosingStart = false;
    _startPoint = _locationService.currentStartPoint;
    _invalidateRoute();
    notifyListeners();

    if (rebuild) {
      if (_isWalkRequest && _walkPlaces.isNotEmpty) {
        buildWalkRoute();
      } else if (_destinationPlace != null) {
        buildRouteTo(_destinationPlace!);
      } else if (_destinationExternalPoint != null) {
        buildRouteToExternalPoint(_destinationExternalPoint!);
      }
    }
  }

  /// Обновление названия точки старта (например, после обратного геокодирования)
  void updateStartPointTitle(String title, {String? subtitle}) {
    if (_navigationLocked) return;
    _startPoint = _startPoint.copyWith(
      title: title,
      subtitle: subtitle ?? _startPoint.subtitle,
    );
    notifyListeners();
  }

  /// Установка внешней точки (из поиска Яндекса) в качестве старта
  void setExternalStartPoint(ExternalMapPoint point) {
    setStartPoint(point.toRoutePoint());
  }

  /// Построение пешеходного маршрута A -> B (до одного места каталога)
  Future<void> buildRouteTo(PlaceModel destination) async {
    if (_navigationLocked) return;
    _isWalkRequest = false;
    _resetSmartWalkParameters();
    final requestId = ++_requestId;
    _destinationPlace = destination;
    _destinationExternalPoint = null;
    _currentRoute = null;
    _status = RoutingStatus.calculating;
    _errorMessage = null;
    _budgetWarningMessage = null;
    notifyListeners();

    try {
      final route = await _mapKitService.calculatePedestrianRoute(
        startPoint: _startPoint,
        destination: destination,
      );
      if (_disposed || requestId != _requestId) return;
      _currentRoute = route.immutableSnapshot();
      _status = RoutingStatus.success;
    } catch (e) {
      if (_disposed || requestId != _requestId) return;
      _errorMessage = routeUiError(e, walk: false);
      _status = RoutingStatus.error;
    }
    notifyListeners();
  }

  /// Построение пешеходного маршрута A -> B до произвольного внешнего адреса/объекта
  Future<void> buildRouteToExternalPoint(ExternalMapPoint destination) async {
    if (_navigationLocked) return;
    _isWalkRequest = false;
    final requestId = ++_requestId;
    _destinationExternalPoint = destination;
    _destinationPlace = null;
    _walkPlaces.clear();
    _placeReasons.clear();
    _resetSmartWalkParameters();
    _currentRoute = null;
    _status = RoutingStatus.calculating;
    _errorMessage = null;
    _budgetWarningMessage = null;
    notifyListeners();

    try {
      final route = await _mapKitService.calculatePointToPointRoute(
        startPoint: _startPoint,
        destinationPoint: destination.toRoutePoint(),
      );
      if (_disposed || requestId != _requestId) return;
      _currentRoute = route.immutableSnapshot();
      _status = RoutingStatus.success;
    } catch (e) {
      if (_disposed || requestId != _requestId) return;
      _errorMessage = routeUiError(e, walk: false);
      _status = RoutingStatus.error;
    }
    notifyListeners();
  }

  /// Построение пешеходного маршрута для прогулки через выбранные места
  /// С возможностью проверки бюджета времени и автокоррекции
  // Correction ranks removals by lost preference value per estimated saved
  // minute; duplicate categories go first. The final time is always MapKit.
  static bool isValidWalkPlace(
    PlaceModel p,
    Set<PlaceCategoryEnum> categories,
  ) =>
      p.id > 0 &&
      p.latitude.isFinite &&
      p.longitude.isFinite &&
      p.latitude >= -90 &&
      p.latitude <= 90 &&
      p.longitude >= -180 &&
      p.longitude <= 180 &&
      p.recommendedVisitMinutes >= 5 &&
      p.recommendedVisitMinutes <= 180 &&
      (categories.isEmpty || categories.contains(p.category));

  String _placeSetKey(List<PlaceModel> places) {
    final ids = places.map((p) => p.id).toList()..sort();
    return ids.join(',');
  }

  int _removalIndex(List<PlaceModel> places, RoutePointModel start) {
    double distance(double a, double b, double c, double d) {
      final lat1 = a * math.pi / 180, lat2 = c * math.pi / 180;
      final x =
          math.pow(math.sin((lat2 - lat1) / 2), 2) +
          math.cos(lat1) *
              math.cos(lat2) *
              math.pow(math.sin((d - b) * math.pi / 360), 2);
      return 6371000 * 2 * math.asin(math.sqrt(x.clamp(0, 1)));
    }

    final counts = <PlaceCategoryEnum, int>{};
    for (final p in places) {
      counts[p.category] = (counts[p.category] ?? 0) + 1;
    }
    final ranked = <(int, double, int, int)>[];
    for (int i = 0; i < places.length; i++) {
      final p = places[i];
      final fromLat = i == 0 ? start.latitude : places[i - 1].latitude;
      final fromLon = i == 0 ? start.longitude : places[i - 1].longitude;
      var saved = distance(fromLat, fromLon, p.latitude, p.longitude);
      if (i + 1 < places.length) {
        final next = places[i + 1];
        saved +=
            distance(p.latitude, p.longitude, next.latitude, next.longitude) -
            distance(fromLat, fromLon, next.latitude, next.longitude);
      }
      final value =
          (_walkCategories.isEmpty ? 30.0 : 50.0) +
          (_walkPreferUnusual && p.isUnusual ? 4.0 : 0.0);
      final uniqueInterest =
          _walkCategories.contains(p.category) && counts[p.category] == 1;
      ranked.add((
        uniqueInterest ? 1 : 0,
        value / (p.recommendedVisitMinutes + math.max(0, saved) / 75),
        p.id,
        i,
      ));
    }
    ranked.sort((a, b) {
      var result = a.$1.compareTo(b.$1);
      if (result == 0) result = a.$2.compareTo(b.$2);
      return result == 0 ? a.$3.compareTo(b.$3) : result;
    });
    return ranked.first.$4;
  }

  Future<void> buildWalkRoute({
    int? timeBudgetMinutes,
    String? syntheticDiagnosticTestPointId,
  }) async {
    if (_navigationLocked || _disposed) return;
    SmartWalkConfiguration.validateBudget(timeBudgetMinutes);
    if (_walkPlaces.isEmpty) {
      _errorMessage = 'Добавьте хотя бы одно место для прогулки';
      notifyListeners();
      return;
    }
    if (timeBudgetMinutes != null) {
      if (timeBudgetMinutes != _walkBudgetMinutes) _clearWalkAlternatives();
      _walkBudgetMinutes = timeBudgetMinutes;
      if (_walkPreset?.timeBudgetMinutes != timeBudgetMinutes) {
        _walkPreset = null;
      }
    }
    final budget = _walkBudgetMinutes;
    final places = List<PlaceModel>.of(_walkPlaces);
    final alternatives = List<AutoWalkAlternativeModel>.of(_walkAlternatives);
    _walkDiagnostic = null;
    final start = _startPoint;
    _isWalkRequest = true;
    final requestId = ++_requestId;
    _destinationPlace = places.last;
    _destinationExternalPoint = null;
    _currentRoute = null;
    _clearVerifiedWalkVariants();
    _status = RoutingStatus.calculating;
    _errorMessage = null;
    _budgetWarningMessage = null;
    notifyListeners();

    final nativeBudget = NativeWalkRequestBudget(maxNativeWalkLegRequests);
    var reservedLegs = 0;
    var builds = 0;
    var hadBudgetFailure = false;
    var hadUnavailablePath = false;
    var hadZeroLengthPath = false;
    var refinementRemovedCount = 0;
    String outcome = 'request_limit_reached';
    final attempted = <String>{};
    final attempts =
        <
          ({
            List<int> sequence,
            int? walkingSeconds,
            int visitMinutes,
            String result,
          })
        >[];
    final diagnosticEnabled =
        kDebugMode && syntheticDiagnosticTestPointId != null;

    bool current() =>
        !_disposed &&
        !_navigationLocked &&
        (!isGuidedDraft || guidedDraftIsCurrent) &&
        requestId == _requestId;
    bool canRequest(List<PlaceModel> candidate) =>
        builds < maxWalkRouteAttempts &&
        candidate.isNotEmpty &&
        reservedLegs + candidate.length <= maxNativeWalkLegRequests;

    Future<bool> tryCandidate(
      List<PlaceModel> candidate, {
      AutoWalkAlternativeModel? alternative,
    }) async {
      final key = candidate.map((p) => p.id).join(',');
      if (!canRequest(candidate) || !attempted.add(key)) return false;
      ++builds;
      // Reserve every leg even when a request fails part-way through. This is
      // conservative for injected services and caps worst-case native work.
      reservedLegs += candidate.length;
      final visit = candidate.fold<int>(
        0,
        (sum, p) => sum + p.recommendedVisitMinutes,
      );
      PedestrianRouteModel route;
      try {
        route = await _mapKitService.calculateBoundedWalkRoute(
          startPoint: start,
          places: List.unmodifiable(candidate),
          requestBudget: nativeBudget,
        );
      } on RouteCalculationFailure catch (e) {
        if (!current()) return false;
        if (e.kind != RouteFailureKind.pedestrianUnavailable) rethrow;
        hadUnavailablePath = true;
        if (diagnosticEnabled) {
          attempts.add((
            sequence: List.unmodifiable(candidate.map((p) => p.id)),
            walkingSeconds: null,
            visitMinutes: visit,
            result: 'pedestrian_unavailable',
          ));
        }
        return false;
      }
      if (!current()) return false;
      if (route.durationSeconds < 0 ||
          !route.distanceMeters.isFinite ||
          route.distanceMeters < 0) {
        throw const RouteCalculationFailure(RouteFailureKind.invalidResponse);
      }
      if (route.distanceMeters == 0) {
        hadZeroLengthPath = true;
        if (diagnosticEnabled) {
          attempts.add((
            sequence: List.unmodifiable(candidate.map((p) => p.id)),
            walkingSeconds: route.durationSeconds,
            visitMinutes: visit,
            result: 'no_meaningful_route',
          ));
        }
        return false;
      }
      if (budget != null && route.durationSeconds + visit * 60 > budget * 60) {
        hadBudgetFailure = true;
        if (diagnosticEnabled) {
          attempts.add((
            sequence: List.unmodifiable(candidate.map((p) => p.id)),
            walkingSeconds: route.durationSeconds,
            visitMinutes: visit,
            result: 'native_budget_exceeded',
          ));
        }
        return false;
      }
      _walkPlaces
        ..clear()
        ..addAll(candidate);
      final changed = !listEquals(
        places.map((p) => p.id).toList(),
        candidate.map((p) => p.id).toList(),
      );
      if (changed) {
        _placeReasons.clear();
        if (alternative != null) {
          if (candidate.length == alternative.items.length) {
            for (final item in alternative.items) {
              _placeReasons[item.place.id] = List.unmodifiable(item.reasons);
            }
            _budgetWarningMessage = 'Выбран другой вариант прогулки после проверки пешеходного маршрута MapKit.';
          } else {
            refinementRemovedCount +=
                alternative.items.length - candidate.length;
            _budgetWarningMessage =
                'После проверки MapKit выбрана короткая прогулка по другому варианту: ${candidate.length} мест.';
          }
        } else {
          final remaining = candidate.map((p) => p.id).toSet();
          final removed = places
              .where((p) => !remaining.contains(p.id))
              .map((p) => p.title);
          _budgetWarningMessage =
              'Исключены после проверки бюджета $budget мин и пешеходной доступности: ${removed.join(', ')}.';
        }
      }
      _destinationPlace = candidate.last;
      final normalSnapshot = route.immutableSnapshot();
      PedestrianRouteModel? scenicSnapshot;
      var built = normalSnapshot;
      if (_walkScenic && built.legs.isNotEmpty) {
        // One bounded scenic enhancement per build operation: real MapKit
        // segments through verified waypoints, sharing the SAME request
        // budget (the 12-request cap is not raised).
        final engine = ScenicWalkEngine(
          routeService: _OwnedScenicRouteService(_mapKitService, current),
          datasetFeatures: spbScenicDataset.features,
        );
        final visitSeconds =
            candidate.fold<int>(
              0,
              (sum, p) => sum + p.recommendedVisitMinutes,
            ) *
            60;
        final result = await engine.enhance(
          normalRoute: built,
          walkBudgetSeconds: budget == null ? null : budget * 60 - visitSeconds,
          requestBudget: _OwnedScenicRequestBudget(nativeBudget, current),
          recognizeOnPath: true,
          diagnosticsContext: ScenicDiagnostics.enabled
              ? ScenicAttemptContext(
                  visitSeconds: visitSeconds,
                  presetBudgetSeconds: budget == null ? null : budget * 60,
                  datasetVersion: spbScenicDataset.version,
                  datasetFeaturesCount: spbScenicDataset.features.length,
                )
              : null,
        );
        if (!current()) return false;
        if (result.isScenic && result.route != null) {
          scenicSnapshot = result.route!.immutableSnapshot();
          built = scenicSnapshot;
          _routeComparison = result.comparison?.immutableSnapshot();
          _scenicFallbackMessage = null;
        } else {
          _routeComparison = null;
          // The exact honest reason (§8) — never a single generic text.
          _scenicFallbackMessage = scenicFallbackReasonText(
            result.fallbackReason,
          );
        }
      }
      _verifiedNormalRoute = normalSnapshot;
      _verifiedScenicRoute = scenicSnapshot;
      _walkNativeBudget = nativeBudget;
      _scenicChecked = _walkScenic;
      // Legacy callers retain their scenic preference. Guided walks always
      // begin with the confirmed normal route and ask for an explicit choice.
      _currentRoute = isGuidedDraft ? normalSnapshot : built;
      _status = RoutingStatus.success;
      outcome = 'success';
      if (diagnosticEnabled) {
        attempts.add((
          sequence: List.unmodifiable(candidate.map((p) => p.id)),
          walkingSeconds: route.durationSeconds,
          visitMinutes: visit,
          result: outcome,
        ));
      }
      return true;
    }

    try {
      var success = await tryCandidate(places);
      if (!current()) return;
      // At most three distinct backend POI sets. Leave one native request for
      // a smaller fallback; proposals too expensive for the remaining cap are
      // skipped rather than silently generating additional native requests.
      for (final alternative in alternatives) {
        if (success) break;
        final candidate = alternative.items.map((i) => i.place).toList();
        if (candidate.length > 1 &&
            reservedLegs + candidate.length >= maxNativeWalkLegRequests) {
          continue;
        }
        success = await tryCandidate(candidate, alternative: alternative);
        if (!current()) return;
      }
      // Try a small genuine alternative before deleting the primary's stops.
      // Its canonical visit estimate is preserved; no synthetic visit modes.
      if (!success && alternatives.isNotEmpty) {
        final singles =
            alternatives.expand((a) => a.items).map((i) => i.place).toList()
              ..sort((a, b) {
                double estimate(PlaceModel p) =>
                    p.recommendedVisitMinutes +
                    math.sqrt(
                          math.pow(p.latitude - start.latitude, 2) +
                              math.pow(
                                (p.longitude - start.longitude) *
                                    math.cos(start.latitude * math.pi / 180),
                                2,
                              ),
                        ) *
                        111000 /
                        75;
                final comparison = estimate(a).compareTo(estimate(b));
                return comparison == 0 ? a.id.compareTo(b.id) : comparison;
              });
        for (final p in singles) {
          if (attempted.contains('${p.id}')) continue;
          final source = alternatives.firstWhere(
            (a) => a.items.any((i) => i.place.id == p.id),
          );
          success = await tryCandidate([p], alternative: source);
          if (!current()) return;
          break;
        }
      }
      final corrected = List<PlaceModel>.of(places);
      while (!success &&
          corrected.length > 1 &&
          builds < maxWalkRouteAttempts) {
        corrected.removeAt(_removalIndex(corrected, start));
        ++refinementRemovedCount;
        if (!canRequest(corrected)) continue;
        // Preserve enough capacity to reach a one-stop check if this fails.
        if (corrected.length > 1 &&
            reservedLegs + corrected.length == maxNativeWalkLegRequests) {
          continue;
        }
        success = await tryCandidate(corrected);
        if (!current()) return;
      }
      if (!success) {
        final kind = hadUnavailablePath && hadBudgetFailure
            ? RouteFailureKind.mixedNativeConstraints
            : hadUnavailablePath
            ? RouteFailureKind.pedestrianUnavailable
            : hadBudgetFailure
            ? RouteFailureKind.nativeBudgetExceeded
            : hadZeroLengthPath
            ? RouteFailureKind.noMeaningfulRoute
            : RouteFailureKind.requestLimitReached;
        throw RouteCalculationFailure(kind);
      }
    } catch (e) {
      if (!current()) return;
      outcome = e is RouteCalculationFailure
          ? e.kind.name
          : 'service_or_network_failure';
      _currentRoute = null;
      _errorMessage = routeUiError(e, walk: true);
      _status = RoutingStatus.error;
    }
    if (diagnosticEnabled && current()) {
      _walkDiagnostic = WalkBuildDiagnostic(
        testPointId: syntheticDiagnosticTestPointId,
        budgetMinutes: budget,
        attempts: List.unmodifiable(attempts),
        reservedNativeLegRequests: reservedLegs,
        nativeLegRequests: nativeBudget.requests,
        refinementRemovedCount: refinementRemovedCount,
        finalSequence: _status == RoutingStatus.success
            ? List.unmodifiable(_walkPlaces.map((p) => p.id))
            : const [],
        result: outcome,
      );
    }
    notifyListeners();
  }

  void clearRoute() {
    if (_navigationLocked) return;
    _isWalkRequest = false;
    _resetSmartWalkParameters();
    _routeComparison = null;
    _scenicFallbackMessage = null;
    ++_requestId;
    _mapKitService.cancel();
    _status = RoutingStatus.idle;
    _destinationPlace = null;
    _destinationExternalPoint = null;
    _currentRoute = null;
    _errorMessage = null;
    _budgetWarningMessage = null;
    clearShadeAssessment(notify: false);
    notifyListeners();
  }

  @override
  void dispose() {
    final listener = _guidedOwnerListener;
    final owner = _guidedOwner;
    if (listener != null && owner != null && !owner._disposed) {
      owner.removeListener(listener);
    }
    owner?._guidedDrafts.remove(this);
    for (final draft in _guidedDrafts.toList()) {
      draft._invalidateGuidedDraft();
    }
    _guidedDrafts.clear();
    final hadNativeWork = isCalculating || _checkingScenic;
    _disposed = true;
    ++_startRevision;
    ++_requestId;
    ++_shadeRequestId;
    // The clock is a separate provider that may already be gone; drop the
    // reference before any further invalidation reaches it.
    _shadeClock = null;
    if (!isGuidedDraft || hadNativeWork) _mapKitService.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------- C7.1 shade
  /// Analyses a route for shade. What gets analysed depends on whether a walk
  /// is in progress (§15.5):
  ///
  /// * **No session — the PLAN.** The whole current route, evaluated from
  ///   [departure]; without an explicit instant that is the current virtual
  ///   (or device) time, and with a clock the walk's start is anchored to it.
  ///   Re-running the plan therefore never shifts the evaluation of segments
  ///   still ahead: the schedule only moves when the virtual time itself does.
  /// * **Active session — the REMAINING PATH.** [remainingRoute] from the
  ///   navigation session (the path the walker still has ahead, cut at the
  ///   engine's own progress) is evaluated from the CURRENT instant. The
  ///   walk's start is not touched, the route is not touched, the planning
  ///   lock is not lifted, and alternatives are never probed: a mid-walk
  ///   comparison could not be applied anyway (the lock forbids it) and would
  ///   spend native requests on a route the user is already walking.
  ///
  /// Nothing is switched silently: [applyShadeAlternative] is the explicit
  /// user action that replaces the route. When no alternative qualifies, the
  /// normal route stays and [shadeDecision]!.fallback explains why in words.
  ///
  /// [progressMeters] is the session progress the remaining path starts from
  /// (the caller has it: it built the tail). It is recorded as ownership
  /// EVIDENCE for C7.4 §6 — the session version alone cannot see a walker
  /// advancing along an unchanged route — and never changes what is analysed.
  Future<void> assessShade({
    DateTime? departure,
    bool exploreAlternatives = true,
    PedestrianRouteModel? remainingRoute,
    double? progressMeters,
  }) async {
    // --- what may be analysed right now ------------------------------------
    final ShadeAssessmentScope scope;
    final PedestrianRouteModel route;
    if (_navigationLocked) {
      // A walk is under way. The planning route is no longer proof of the
      // ground ahead (a reroute replaced the session geometry while the
      // planning object stayed), and the plan's schedule belongs to a start
      // that already happened. Only the session's own remaining path may be
      // re-estimated; the route, the lock and the geometry stay untouched.
      final remaining = remainingRoute;
      if (remaining == null || !_remainingPathBelongsToSession(remaining)) {
        return;
      }
      scope = ShadeAssessmentScope.remainingPath;
      route = remaining;
    } else {
      final planned = _currentRoute;
      if (planned == null || planned.legs.isEmpty) return;
      scope = ShadeAssessmentScope.wholeWalk;
      route = planned;
    }
    if (route.legs.isEmpty) return;

    // --- §15: where does the estimate belong on the virtual timeline? ------
    final clock = _shadeClock;
    DateTime when;
    if (scope == ShadeAssessmentScope.remainingPath) {
      if (clock != null && clock.departure == null) {
        // A session that never had a chosen departure: its honest start is
        // the instant it began, i.e. "now" minus the virtual time already
        // simulated — so the model time is the device time, not a guess.
        clock.arm(DateTime.now().subtract(clock.elapsed));
      }
      // The remaining path begins where the walker stands: it is scheduled
      // from NOW, and the plan's own schedule is history that must not move.
      when = clock?.modelTime ?? DateTime.now();
    } else {
      // The plan is evaluated for the instant it is planned at. An explicit
      // time choice anchors the virtual walk there; without one, the plan
      // follows the current virtual time, so pressing the button cannot
      // re-schedule the walk from a past start.
      final anchor = departure;
      if (anchor != null) {
        clock?.arm(anchor);
      } else if (clock != null && clock.departure == null) {
        clock.arm(DateTime.now());
      }
      when = anchor ?? clock?.modelTime ?? DateTime.now();
    }

    final requestId = ++_shadeRequestId;
    _assessingShade = true;
    _shadeFailure = null;
    _shadeAnalysis = null;
    _shadeDecision = null;
    _shadeScope = scope;
    _shadeAnalysisSessionVersion = _navigationRouteVersion;
    // A whole-walk estimate is anchored at the plan itself (progress 0 is the
    // honest value: no session has been walked). A remaining-path estimate is
    // anchored where the walker stood when it was requested.
    _shadeAnalysisProgress = scope == ShadeAssessmentScope.remainingPath
        ? progressMeters
        : 0.0;
    // The walk's start (stable while a session runs) and the instant actually
    // evaluated (moves with the virtual clock) are different things: only the
    // second one may drift into staleness. A plan states its own start (the
    // instant it is planned for), a remaining-path estimate names the walk
    // start it continues.
    _shadeDeparture = scope == ShadeAssessmentScope.remainingPath
        ? (clock?.departure ?? when)
        : when;
    _shadeEvaluatedFor = when;
    _shadeAnalysisRoute = route;
    notifyListeners();

    bool current() => !_disposed && requestId == _shadeRequestId;

    ShadeAnalysisModel normal;
    try {
      normal = await _shadeService.analyzeWalk(
        departure: when,
        legs: route.legs,
        visitMinutesAfterLeg: _shadeVisitMinutes(route.legs),
      );
    } on ShadeAnalysisFailure catch (failure) {
      if (!current()) return;
      _assessingShade = false;
      _shadeFailure = failure;
      notifyListeners();
      return;
    }
    if (!current()) return;

    List<PedestrianRouteModel> alternatives = const [];
    ShadeRoutingFallback? explorationFailure;
    if (exploreAlternatives && scope == ShadeAssessmentScope.wholeWalk) {
      try {
        final explored = await _discoverAlternatives(route);
        alternatives = explored.routes;
        explorationFailure = explored.failure;
      } on RouteCalculationFailure catch (failure) {
        // Alternative discovery is optional: the normal route's estimate is
        // still valuable, so a native failure only affects the comparison.
        explorationFailure = failure.kind == RouteFailureKind.serviceUnavailable
            ? ShadeRoutingFallback.serviceUnavailable
            : ShadeRoutingFallback.noAlternatives;
      }
    }
    if (!current()) return;

    var decision = await _shadeEngine.evaluate(
      normalRoute: route,
      alternatives: alternatives,
      departure: when,
      budgetMinutes: _walkBudgetMinutes,
      normalAnalysis: normal,
    );
    if (!current()) return;
    if (!decision.offersAlternative &&
        decision.fallback == ShadeRoutingFallback.noAlternatives &&
        explorationFailure != null) {
      decision = ShadeRoutingDecision(
        normalAnalysis: decision.normalAnalysis,
        best: null,
        fallback: explorationFailure,
        evaluated: decision.evaluated,
      );
    }

    _assessingShade = false;
    _shadeAnalysis = normal;
    _shadeDecision = decision;
    _shadeAnalysisRoute = route;
    // The estimate now describes exactly this virtual instant; the clock can
    // tell the user when the simulation has moved far enough to re-run it.
    clock?.markAnalyzed(when);
    notifyListeners();
  }

  /// The remaining path is a SESSION measurement, not arbitrary geometry: it
  /// must end where the session ends, or it is not what the walker still has
  /// ahead and the estimate would describe someone else's walk.
  bool _remainingPathBelongsToSession(PedestrianRouteModel remaining) {
    final session = _navigationRoute;
    if (session == null || session.legs.isEmpty || remaining.legs.isEmpty) {
      return false;
    }
    final expected = session.legs.last.geometryPoints.last;
    final actual = remaining.legs.last.geometryPoints.last;
    return expected.latitude == actual.latitude &&
        expected.longitude == actual.longitude;
  }

  List<int> _shadeVisitMinutes(List<RouteLegModel> legs) => [
    for (var i = 0; i < legs.length; ++i)
      i < legs.length - 1 ? (legs[i].visitMinutes ?? 0) : 0,
  ];

  /// Real MapKit alternatives, bounded and shared across the whole operation.
  ///
  /// ONE request per probed leg returns up to [maxAlternativesPerLeg] real
  /// routes (the SDK answers a request with a list), and this operation's
  /// [NativeWalkRequestBudget] covers every probe — the cap is never bypassed
  /// by spinning up a fresh budget per sub-request (§12.3).
  Future<({List<PedestrianRouteModel> routes, ShadeRoutingFallback? failure})>
  _discoverAlternatives(PedestrianRouteModel route) async {
    if (route.legs.isEmpty || !MapKitService.isMapKitInitialized) {
      return (routes: const <PedestrianRouteModel>[], failure: null);
    }
    final budget = NativeWalkRequestBudget(maxNativeWalkLegRequests);
    final candidates = <PedestrianRouteModel>[];
    final legsToProbe = math.min(maxAlternativeLegs, route.legs.length);
    for (var index = 0; index < legsToProbe; ++index) {
      if (budget.remaining <= 0) break;
      final leg = route.legs[index];
      if (leg.geometryPoints.length < 2) continue;
      final from = leg.geometryPoints.first;
      final to = leg.geometryPoints.last;
      List<RouteLegModel> variants;
      try {
        variants = await _mapKitService.requestLegVariants(
          fromLat: from.latitude,
          fromLon: from.longitude,
          fromTitle: leg.fromTitle,
          toLat: to.latitude,
          toLon: to.longitude,
          toTitle: leg.toTitle,
          requestBudget: budget,
          legIndex: index,
          visitMinutes: leg.visitMinutes,
          maxVariants: maxAlternativesPerLeg,
        );
      } on RouteCalculationFailure {
        continue; // this leg has no variants; others may still have them
      }
      for (var variant = 1; variant < variants.length; ++variant) {
        candidates.add(_routeWithReplacedLeg(route, index, variants[variant]));
      }
    }
    return (routes: candidates, failure: null);
  }

  /// The normal walk with exactly ONE leg replaced by real MapKit geometry.
  ///
  /// Every other leg, all visit times and the stop sequence are unchanged, so
  /// the comparison is about the same walk with a different real path — not
  /// about a different tour.
  PedestrianRouteModel _routeWithReplacedLeg(
    PedestrianRouteModel route,
    int legIndex,
    RouteLegModel replacement,
  ) {
    final legs = <RouteLegModel>[
      for (var i = 0; i < route.legs.length; ++i)
        i == legIndex ? replacement : route.legs[i],
    ];
    var distance = 0.0;
    var duration = 0;
    final points = <GeoCoord>[];
    for (final leg in legs) {
      distance += leg.distanceMeters;
      duration += leg.durationSeconds;
      points.addAll(leg.geometryPoints);
    }
    return PedestrianRouteModel(
      distanceMeters: distance,
      durationSeconds: duration,
      geometryPoints: points,
      steps: const [],
      legs: legs,
      placesCount: route.placesCount,
      walkKind: route.walkKind,
    );
  }

  /// Explicit user action: adopt the offered shaded alternative.
  ///
  /// Returns false when there is nothing offerable or planning is locked. The
  /// replaced route keeps every stop and visit time; the shade assessment is
  /// invalidated because it described the previous geometry.
  bool applyShadeAlternative() {
    final decision = shadeDecision;
    final current = _currentRoute;
    if (decision == null || current == null || _navigationLocked) return false;
    final best = decision.best;
    if (best == null) return false;
    _routeComparison = null;
    // A swapped route is a normal route: the scenic detour is not part of it.
    _currentRoute = best.route.immutableSnapshot();
    _status = RoutingStatus.success;
    _errorMessage = null;
    _scenicFallbackMessage = null;
    _clearVerifiedWalkVariants();
    clearShadeAssessment(notify: false);
    notifyListeners();
    return true;
  }

  /// Transfers only a whole-walk result over the exact committed geometry and
  /// chosen instant. An attached clock must already have the agreed time; this
  /// method never re-arms it or enables an overlay on the user's behalf.
  bool adoptWholeWalkShadeAssessmentFrom(RoutingProvider source) {
    final evaluated = source.shadeEvaluatedFor;
    final analysis = source.shadeAnalysis;
    final clock = _shadeClock;
    if (_disposed ||
        source._disposed ||
        _navigationLocked ||
        source.isAssessingShade ||
        source.shadeScope != ShadeAssessmentScope.wholeWalk ||
        analysis == null ||
        evaluated == null ||
        !identical(source.shadeAnalysisRoute, _currentRoute) ||
        (clock != null && clock.modelTime != evaluated)) {
      return false;
    }
    ++_shadeRequestId;
    _shadeAnalysis = analysis;
    _shadeDecision = source.shadeDecision;
    _shadeFailure = source.shadeFailure;
    _shadeDeparture = source.shadeDeparture;
    _shadeEvaluatedFor = evaluated;
    _shadeAnalysisRoute = _currentRoute;
    _shadeScope = ShadeAssessmentScope.wholeWalk;
    _shadeAnalysisSessionVersion = _navigationRouteVersion;
    _shadeAnalysisProgress = 0;
    _assessingShade = false;
    clock?.markAnalyzed(evaluated);
    notifyListeners();
    return true;
  }
}
