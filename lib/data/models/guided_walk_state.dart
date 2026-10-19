import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/smart_walk_preset.dart';

enum GuidedWalkStep {
  start,
  mode,
  duration,
  interests,
  proposal,
  scenic,
  environment,
  report,
}

enum GuidedWalkMode { smart, manual }

/// Answers are local to this walk; moving backwards never writes guest settings.
class GuidedWalkState {
  GuidedWalkState({
    this.step = GuidedWalkStep.start,
    this.mode = GuidedWalkMode.smart,
    this.preset = SmartWalkPreset.defaultPreset,
    Set<PlaceCategoryEnum> categories = const {},
    this.preferUnusual = SmartWalkConfiguration.automaticPreferUnusual,
    this.proposal,
    this.busy = false,
    this.error,
    this.selectedKind = WalkKind.normal,
    this.routeChoiceConfirmed = false,
  }) : categories = Set.unmodifiable(categories);

  final GuidedWalkStep step;
  final GuidedWalkMode mode;
  final SmartWalkPreset preset;
  final Set<PlaceCategoryEnum> categories;
  final bool preferUnusual;
  final AutoWalkProposalResponseModel? proposal;
  final bool busy;
  final String? error;
  final WalkKind selectedKind;
  final bool routeChoiceConfirmed;

  GuidedWalkState copyWith({
    GuidedWalkStep? step,
    GuidedWalkMode? mode,
    SmartWalkPreset? preset,
    Set<PlaceCategoryEnum>? categories,
    bool? preferUnusual,
    AutoWalkProposalResponseModel? proposal,
    bool clearProposal = false,
    bool? busy,
    String? error,
    bool clearError = false,
    WalkKind? selectedKind,
    bool? routeChoiceConfirmed,
  }) => GuidedWalkState(
    step: step ?? this.step,
    mode: mode ?? this.mode,
    preset: preset ?? this.preset,
    categories: categories ?? this.categories,
    preferUnusual: preferUnusual ?? this.preferUnusual,
    proposal: clearProposal ? null : proposal ?? this.proposal,
    busy: busy ?? this.busy,
    error: clearError ? null : error ?? this.error,
    selectedKind: selectedKind ?? this.selectedKind,
    routeChoiceConfirmed: routeChoiceConfirmed ?? this.routeChoiceConfirmed,
  );
}
