import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/core/network/ui_error.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/guided_walk_state.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/smart_walk_preset.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/quiet_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/puddle_analysis_service.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/controllers/guided_walk_environment_coordinator.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';

export 'package:smart_navigator_spb/data/models/guided_walk_state.dart';

/// Orders existing engines; the source route is published only by [showMap].
class GuidedWalkController extends ChangeNotifier {
  GuidedWalkController({
    required RoutingProvider source,
    required this.repository,
    GuestExperienceProvider? guest,
    this.navigation,
    BasePuddleAnalysisService? puddleService,
    BasePollenAnalysisService? pollenService,
    BaseQuietAnalysisService? quietService,
    this.mainPuddle,
    this.mainPollen,
    this.mainQuiet,
    VirtualShadeClock? mainClock,
    SimulationController? simulation,
    this.requestTimeout = const Duration(seconds: 45),
  }) : _source = source,
       _mainClock = mainClock {
    final draft = source.createGuidedDraft();
    routing = draft ?? source;
    _ownsDraft = draft != null;
    _state = GuidedWalkState(
      preset: source.walkPreset ?? SmartWalkPreset.defaultPreset,
      categories: guest?.categories ?? {},
      preferUnusual:
          guest?.preferUnusual ?? SmartWalkConfiguration.automaticPreferUnusual,
    );
    _startRevision = routing.startRevision;
    _placeIds = _ids;
    _manualPlaces = routing.walkPlaces.toList();
    if (mainClock != null && _ownsDraft) {
      _draftClock = VirtualShadeClock(controller: simulation);
      routing.attachShadeClock(_draftClock);
    }
    final nav = navigation;
    if (nav != null && _ownsDraft) {
      if (puddleService != null) {
        puddle = PuddleAssessmentProvider(
          puddleService,
          routing: routing,
          navigation: nav,
          clock: _draftClock,
        );
      }
      if (pollenService != null) {
        pollen = PollenAssessmentProvider(
          pollenService,
          routing: routing,
          navigation: nav,
          clock: _draftClock,
        );
      }
      if (quietService != null) {
        quiet = QuietAssessmentProvider(
          quietService,
          routing: routing,
          navigation: nav,
          clock: _draftClock,
        );
      }
      recommendations = ContextRecommendationProvider(
        routing: routing,
        navigation: nav,
        puddle: puddle,
        pollen: pollen,
        guest: guest,
        clock: _draftClock,
      );
      environment = GuidedWalkEnvironmentCoordinator(
        routing: routing,
        navigation: nav,
        puddle: puddle,
        pollen: pollen,
        quiet: quiet,
        recommendations: recommendations!,
        clock: _draftClock,
      );
      environment!.addListener(_environmentChanged);
    }
    routing.addListener(_routeChanged);
    source.addListener(_sourceChanged);
  }

  final RoutingProvider _source;
  final PlacesRepository repository;
  final NavigationProvider? navigation;
  final PuddleAssessmentProvider? mainPuddle;
  final PollenAssessmentProvider? mainPollen;
  final QuietAssessmentProvider? mainQuiet;
  final VirtualShadeClock? _mainClock;
  VirtualShadeClock? _draftClock;
  final Duration requestTimeout;
  late final RoutingProvider routing;
  late final bool _ownsDraft;
  PuddleAssessmentProvider? puddle;
  PollenAssessmentProvider? pollen;
  QuietAssessmentProvider? quiet;
  ContextRecommendationProvider? recommendations;
  GuidedWalkEnvironmentCoordinator? environment;
  late GuidedWalkState _state;
  GuidedWalkState get state => _state;
  GuidedWalkStep get step => _state.step;
  GuidedWalkMode get mode => _state.mode;
  SmartWalkPreset get preset => _state.preset;
  Set<PlaceCategoryEnum> get categories => _state.categories;
  bool get preferUnusual => _state.preferUnusual;
  AutoWalkProposalResponseModel? get proposal => _state.proposal;
  bool get busy => _state.busy || (environment?.isRunning ?? false);
  String? get error => _state.error;
  WalkKind get selectedKind => _state.selectedKind;
  bool get routeChoiceConfirmed => _state.routeChoiceConfirmed;
  bool get _routeChoiceSatisfied =>
      (routing.verifiedScenicRoute == null &&
          routing.verifiedQuietRoute == null) ||
      routeChoiceConfirmed;
  bool get canContinueRouteChoice =>
      !locked && !busy && routing.hasRoute && _routeChoiceSatisfied;
  bool get canContinueScenic => canContinueRouteChoice;
  bool get locked =>
      !_ownsDraft || _source.navigationLocked || !routing.guidedDraftIsCurrent;
  bool _disposed = false;
  bool _committed = false;
  bool _routingMutation = false;
  int? _buildingPreviewGeneration;
  List<PlaceModel> _manualPlaces = [];
  int _generation = 0;
  late int _startRevision;
  late String _placeIds;
  String get _ids => routing.walkPlaces.map((p) => p.id).join(',');

  void _emit(GuidedWalkState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  void _environmentChanged() {
    if (!_disposed) notifyListeners();
  }

  void _sourceChanged() {
    if (_disposed || _committed || !locked) return;
    ++_generation;
    environment?.cancel();
    _emit(
      _state.copyWith(
        busy: false,
        error: 'Маршрут изменился или началась навигация. Закройте мастер и откройте его снова.',
      ),
    );
  }

  void _routeChanged() {
    if (_disposed || _routingMutation) return;
    final startChanged = _startRevision != routing.startRevision;
    final placesChanged = _placeIds != _ids;
    _startRevision = routing.startRevision;
    _placeIds = _ids;
    if (placesChanged &&
        _buildingPreviewGeneration == _generation &&
        routing.hasRoute &&
        !startChanged) {
      return;
    }
    if (placesChanged && mode == GuidedWalkMode.manual) {
      _manualPlaces = routing.walkPlaces.toList();
    }
    if (startChanged || placesChanged) {
      ++_generation;
      environment?.cancel();
      _emit(
        _state.copyWith(
          clearProposal: startChanged || mode == GuidedWalkMode.smart,
          busy: false,
          clearError: true,
          selectedKind: WalkKind.normal,
          routeChoiceConfirmed: false,
          step: startChanged
              ? GuidedWalkStep.start
              : mode == GuidedWalkMode.manual
              ? GuidedWalkStep.proposal
              : _state.step,
        ),
      );
    } else if (!_disposed) {
      notifyListeners();
    }
  }

  void _invalidate({bool clearProposal = true}) {
    ++_generation;
    environment?.cancel();
    _routingMutation = true;
    routing.cancelPendingWalkBuild();
    routing.clearRoute();
    _routingMutation = false;
    _emit(
      _state.copyWith(
        clearProposal: clearProposal,
        busy: false,
        clearError: true,
        selectedKind: WalkKind.normal,
        routeChoiceConfirmed: false,
      ),
    );
  }

  void setMode(GuidedWalkMode value) {
    if (locked || mode == value) return;
    if (mode == GuidedWalkMode.manual) {
      _manualPlaces = routing.walkPlaces.toList();
    }
    _invalidate();
    if (value == GuidedWalkMode.manual) {
      _routingMutation = true;
      routing.clearWalk();
      for (final place in _manualPlaces) {
        routing.addPlaceToWalk(place);
      }
      _placeIds = _ids;
      _routingMutation = false;
    }
    _emit(_state.copyWith(mode: value));
  }

  void setPreset(SmartWalkPreset value) {
    if (locked || preset == value) return;
    _invalidate();
    _emit(_state.copyWith(preset: value));
  }

  void toggleCategory(PlaceCategoryEnum category) {
    if (locked) return;
    final value = Set<PlaceCategoryEnum>.of(categories);
    value.contains(category) ? value.remove(category) : value.add(category);
    _invalidate();
    _emit(_state.copyWith(categories: value));
  }

  void setPreferUnusual(bool value) {
    if (locked || preferUnusual == value) return;
    _invalidate();
    _emit(_state.copyWith(preferUnusual: value));
  }

  void next() {
    if (locked || busy) return;
    switch (step) {
      case GuidedWalkStep.start:
        _emit(_state.copyWith(step: GuidedWalkStep.mode, clearError: true));
      case GuidedWalkStep.mode:
        _emit(
          _state.copyWith(
            step: mode == GuidedWalkMode.smart
                ? GuidedWalkStep.duration
                : GuidedWalkStep.proposal,
            clearError: true,
          ),
        );
      case GuidedWalkStep.duration:
        _emit(
          _state.copyWith(step: GuidedWalkStep.interests, clearError: true),
        );
      case GuidedWalkStep.interests:
        unawaited(generateProposal());
      case GuidedWalkStep.proposal:
        unawaited(buildPreview());
      case GuidedWalkStep.scenic:
        if (!canContinueScenic) return;
        _emit(
          _state.copyWith(step: GuidedWalkStep.environment, clearError: true),
        );
      case GuidedWalkStep.environment:
        skipEnvironment();
      case GuidedWalkStep.report:
        break;
    }
  }

  void back() {
    if (_disposed || locked || step == GuidedWalkStep.start) return;
    ++_generation;
    environment?.cancel();
    routing.cancelPendingWalkBuild();
    final previous = switch (step) {
      GuidedWalkStep.start => GuidedWalkStep.start,
      GuidedWalkStep.mode => GuidedWalkStep.start,
      GuidedWalkStep.duration => GuidedWalkStep.mode,
      GuidedWalkStep.interests => GuidedWalkStep.duration,
      GuidedWalkStep.proposal =>
        mode == GuidedWalkMode.smart
            ? GuidedWalkStep.interests
            : GuidedWalkStep.mode,
      GuidedWalkStep.scenic => GuidedWalkStep.proposal,
      GuidedWalkStep.environment => GuidedWalkStep.scenic,
      GuidedWalkStep.report => GuidedWalkStep.environment,
    };
    _emit(_state.copyWith(step: previous, busy: false, clearError: true));
  }

  Future<void> generateProposal({bool another = false}) async {
    if (locked || busy || mode != GuidedWalkMode.smart) return;
    if (proposal != null && !another) {
      _emit(_state.copyWith(step: GuidedWalkStep.proposal, clearError: true));
      return;
    }
    if (routing.hasRoute) _invalidate();
    final token = ++_generation;
    final start = routing.startPoint;
    final selectedPreset = preset;
    final selectedCategories = Set<PlaceCategoryEnum>.of(categories);
    final unusual = preferUnusual;
    _emit(
      _state.copyWith(
        step: GuidedWalkStep.proposal,
        busy: true,
        clearProposal: true,
        clearError: true,
      ),
    );
    try {
      final response = await repository
          .proposeWalk(
            startLatitude: start.latitude,
            startLongitude: start.longitude,
            timeBudgetMinutes: selectedPreset.timeBudgetMinutes,
            categories: selectedCategories.isEmpty
                ? null
                : selectedCategories.toList(),
            preferUnusual: unusual,
            maxPlaces: RoutingProvider.maxWalkPlaces,
          )
          .timeout(requestTimeout);
      if (!_current(token)) return;
      final ids = response.items.map((i) => i.place.id).toList();
      final valid =
          ((response.status == 'success' && ids.isNotEmpty) ||
              (response.status == 'empty' && ids.isEmpty)) &&
          response.timeBudgetMinutes == selectedPreset.timeBudgetMinutes &&
          ids.length <= RoutingProvider.maxWalkPlaces &&
          ids.toSet().length == ids.length &&
          response.items.every(
            (i) =>
                RoutingProvider.isValidWalkPlace(i.place, selectedCategories) &&
                i.visitDurationMinutes == i.place.recommendedVisitMinutes,
          ) &&
          ids.join(',') == response.suggestedPlacesSequence.join(',') &&
          response.estimatedTotalDistanceMeters.isFinite &&
          response.estimatedTotalDistanceMeters >= 0 &&
          response.estimatedWalkingDurationSeconds >= 0 &&
          response.estimatedVisitDurationMinutes ==
              response.items.fold<int>(
                0,
                (sum, item) => sum + item.visitDurationMinutes,
              ) &&
          response.estimatedTotalDurationMinutes >=
              response.estimatedVisitDurationMinutes;
      _emit(
        _state.copyWith(
          busy: false,
          proposal: valid ? response : null,
          error: valid ? null : 'Ответ сервера не соответствует выбранной прогулке. Попробуйте подобрать маршрут ещё раз.',
          clearError: valid,
        ),
      );
    } catch (e) {
      if (_current(token)) {
        _emit(_state.copyWith(busy: false, error: walkProposalUiError(e)));
      }
    }
  }

  bool _current(int token) =>
      !_disposed && !_committed && !locked && token == _generation;

  Future<void> buildPreview() async {
    if (locked || busy) return;
    if (mode == GuidedWalkMode.smart &&
        (proposal == null || proposal!.items.isEmpty)) {
      return;
    }
    if (mode == GuidedWalkMode.manual && routing.walkPlaces.isEmpty) return;
    if (routing.hasRoute && routing.verifiedNormalRoute != null) {
      _emit(_state.copyWith(step: GuidedWalkStep.scenic, clearError: true));
      await checkScenic();
      await checkQuiet();
      return;
    }
    final token = ++_generation;
    _emit(_state.copyWith(busy: true, clearError: true));
    _routingMutation = true;
    if (mode == GuidedWalkMode.smart) {
      final value = proposal!;
      routing.setProposedWalk(
        value.items.map((i) => i.place).toList(),
        reasons: {for (final item in value.items) item.place.id: item.reasons},
        preset: preset,
        categories: categories,
        preferUnusual: preferUnusual,
        alternatives: value.alternatives,
      );
    } else {
      // Re-enter the existing planner's same points as a manual walk, with no
      // inherited automatic budget/category filter silently trimming them.
      final places = routing.walkPlaces.toList();
      routing.clearWalk();
      for (final place in places) {
        routing.addPlaceToWalk(place);
      }
    }
    _startRevision = routing.startRevision;
    _placeIds = _ids;
    _routingMutation = false;
    _buildingPreviewGeneration = token;
    try {
      await routing.buildWalkRoute().timeout(requestTimeout);
      // Native validation may have selected a safe alternative or fewer stops.
      _placeIds = _ids;
      if (!_current(token)) return;
      if (!routing.hasRoute) {
        _emit(
          _state.copyWith(
            busy: false,
            error: routing.errorMessage ?? 'Пешеходный маршрут не найден. Измените места или точку отправления.',
          ),
        );
        return;
      }
      _emit(_state.copyWith(busy: false, step: GuidedWalkStep.scenic));
      await checkScenic();
      await checkQuiet();
    } on TimeoutException {
      if (_current(token)) {
        routing.cancelPendingWalkBuild();
        _emit(
          _state.copyWith(
            busy: false,
            error: 'Проверка маршрута заняла слишком много времени. Можно повторить её или изменить места.',
          ),
        );
      }
    } catch (_) {
      if (_current(token)) {
        _emit(
          _state.copyWith(
            busy: false,
            error: 'Не удалось проверить пешеходный путь. Попробуйте ещё раз.',
          ),
        );
      }
    } finally {
      if (_buildingPreviewGeneration == token) {
        _buildingPreviewGeneration = null;
      }
    }
  }

  Future<void> checkScenic() async {
    if (locked || busy || !routing.hasRoute || routing.scenicChecked) return;
    final token = ++_generation;
    _emit(
      _state.copyWith(
        busy: true,
        clearError: true,
        routeChoiceConfirmed: false,
      ),
    );
    try {
      await routing.checkScenicForCurrentWalk().timeout(requestTimeout);
      if (_current(token)) _emit(_state.copyWith(busy: false));
    } on TimeoutException {
      if (_current(token)) {
        routing.cancelPendingWalkBuild();
        _emit(
          _state.copyWith(
            busy: false,
            error: 'Проверка живописности недоступна. Обычный пешеходный маршрут готов.',
          ),
        );
      }
    } catch (_) {
      if (_current(token)) {
        _emit(
          _state.copyWith(
            busy: false,
            error: 'Не удалось проверить живописность. Обычный пешеходный маршрут готов.',
          ),
        );
      }
    }
  }

  Future<void> checkQuiet() async {
    if (locked ||
        busy ||
        !routing.hasRoute ||
        !routing.quietAvailable ||
        routing.quietChecked) {
      return;
    }
    final token = ++_generation;
    _emit(
      _state.copyWith(
        busy: true,
        clearError: true,
        routeChoiceConfirmed: false,
      ),
    );
    try {
      await routing.checkQuietForCurrentWalk().timeout(requestTimeout);
      if (_current(token)) {
        _emit(
          _state.copyWith(
            busy: false,
            error: routing.quietFailure?.message,
            clearError: routing.quietFailure == null,
          ),
        );
      }
    } on TimeoutException {
      if (_current(token)) {
        routing.cancelPendingWalkBuild();
        _emit(
          _state.copyWith(
            busy: false,
            error:
                'Проверка тихого варианта заняла слишком много времени. '
                'Обычный маршрут готов.',
          ),
        );
      }
    } catch (_) {
      if (_current(token)) {
        _emit(
          _state.copyWith(
            busy: false,
            error:
                'Не удалось проверить более тихий вариант. '
                'Обычный маршрут готов.',
          ),
        );
      }
    }
  }

  void selectRoute(WalkKind value) {
    if (locked || busy || !routing.selectVerifiedWalkVariant(value)) return;
    _emit(
      _state.copyWith(
        selectedKind: value,
        routeChoiceConfirmed: true,
        clearError: true,
      ),
    );
  }

  Future<void> assessEnvironment() async {
    if (locked || busy || !routing.hasRoute || !_routeChoiceSatisfied) return;
    final env = environment;
    if (env == null) {
      _emit(_state.copyWith(step: GuidedWalkStep.report));
      return;
    }
    final token = ++_generation;
    await env.assess();
    if (_current(token)) _emit(_state.copyWith(step: GuidedWalkStep.report));
  }

  void skipEnvironment() {
    if (locked || !routing.hasRoute || !_routeChoiceSatisfied) return;
    environment?.skip();
    _emit(
      _state.copyWith(
        step: GuidedWalkStep.report,
        busy: false,
        clearError: true,
      ),
    );
  }

  bool showMap() {
    if (locked ||
        busy ||
        step != GuidedWalkStep.report ||
        !routing.hasRoute ||
        !_routeChoiceSatisfied) {
      return false;
    }
    // commit notifies source listeners; suppress our own stale-source handler.
    _committed = true;
    if (!_source.commitGuidedDraft(routing)) {
      _committed = false;
      _emit(
        _state.copyWith(error: 'Маршрут изменился. Откройте мастер ещё раз.'),
      );
      return false;
    }
    final report = environment?.report;
    if (report != null) {
      final clock = _mainClock;
      if (clock != null && clock.modelTime != report.evaluatedFor) {
        // Simulator elapsed time is included by VirtualShadeClock.arm.
        // A mismatched diagnostic instant must remain unavailable on the map.
        clock.arm(report.selectedDeparture);
      }
      if (_source.adoptWholeWalkShadeAssessmentFrom(routing)) {
        _source.setShadeOverlayEnabled(routing.shadeOverlayEnabled);
      }
      if (puddle != null) mainPuddle?.adoptWholeWalkAssessmentFrom(puddle!);
      if (pollen != null) mainPollen?.adoptWholeWalkAssessmentFrom(pollen!);
      if (quiet != null) mainQuiet?.adoptWholeWalkAssessmentFrom(quiet!);
    }
    return true;
  }

  void cancel() {
    if (_disposed || _committed) return;
    ++_generation;
    environment?.cancel();
    if (_ownsDraft) routing.cancelPendingWalkBuild();
    _emit(_state.copyWith(busy: false));
  }

  @override
  void dispose() {
    if (_disposed) return;
    cancel();
    _disposed = true;
    _source.removeListener(_sourceChanged);
    routing.removeListener(_routeChanged);
    environment?.removeListener(_environmentChanged);
    environment?.dispose();
    recommendations?.dispose();
    puddle?.dispose();
    pollen?.dispose();
    quiet?.dispose();
    if (_ownsDraft) routing.dispose();
    _draftClock?.dispose();
    super.dispose();
  }
}
