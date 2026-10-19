import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/core/formatting/pollen_units.dart';

/// Phase C7.4 — Context-Aware Recommendations v1: the user-facing model.
///
/// A recommendation is a deterministic, explainable STATEMENT built from the
/// results of the already-verified models (C7.1 shade, C7.2 puddle, C7.3.1
/// pollen, C5/A6.1 scenic). It never computes a new physical quantity; it
/// reports what those models produced, for which question and with which
/// limitations.
///
/// Every recommendation answers the three questions the card must answer:
///
/// 1. **Что известно** — [title] plus [facts] (values with their original
///    units);
/// 2. **Почему появилась именно эта рекомендация** — [explanation], the rule
///    that produced it in words;
/// 3. **Насколько полны и надёжны данные** — [completenessNote],
///    [completenessShare] and [limitations].
///
/// Three properties are enforced structurally rather than by convention:
///
/// * there is **no combined score** anywhere in this model: shade metres,
///   pollen concentrations, walking minutes and wet-surface metres are
///   physically incomparable, so they are only ever reported side by side
///   (ТЗ C7.4 §4.5);
/// * a recommendation without facts is only ever an honest explanation of a
///   limitation ([RecommendationAvailability.unavailable]) — the absence of
///   data is never turned into a low-risk statement;
/// * the facts carry their own provenance ([method], [methodVersion],
///   [sourceLabel]) and the scope they answer ([scope], [evaluatedFor]).

/// Which factor of the walk a recommendation is about.
enum RecommendationFactor { shade, puddle, pollen, scenic }

/// Which walk question the facts behind a recommendation answer.
///
/// The same distinction C7.1.2 enforces for shade and C7.2/C7.3 for the
/// environmental assessments: the whole planned walk is a different question
/// from the path still ahead, and a fact answering one of them must never be
/// presented as answering the other (ТЗ C7.4 §6).
enum RecommendationScope { wholeWalk, remainingPath }

/// The user's stated goal for the walk.
///
/// UI POLICY ONLY — documented as such and deliberately not a scientific
/// rating: it re-orders the recommendations and may reveal the small "the
/// factor you prefer was not assessed yet" entry. It never recomputes a model,
/// never re-weights physical quantities and never changes the route, the stops
/// or the planning lock (ТЗ C7.4 §5).
enum RecommendationPreference { all, shade, scenic }

/// How much the facts behind a recommendation actually support it.
enum RecommendationAvailability {
  /// Values were produced for the whole question.
  available,

  /// Values were produced, but part of the question stayed unknown — the
  /// unknown share is carried in the facts instead of being hidden.
  limited,

  /// The source HAD values for some species, and this answer publishes none of
  /// them (C7.3.1 withheld panel). Withholding a number is not a claim that
  /// the source had none, and the withheld numbers must never be reconstructed
  /// from coverage shares or diagnostics (ТЗ C7.4 §4.3).
  withheld,

  /// No usable values exist: the entry explains the limitation only.
  unavailable,
}

/// The allowed user actions (ТЗ C7.4 §8). Every one of them is an EXPLICIT
/// user gesture: nothing in C7.4 switches a route, changes a POI, lifts the
/// planning lock or starts an assessment on its own.
enum RecommendationActionKind {
  /// Re-run the assessment the recommendation is built from. The section maps
  /// it to the factor's own provider method.
  recompute,
}

class RecommendationAction {
  const RecommendationAction({required this.kind, required this.label});

  final RecommendationActionKind kind;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is RecommendationAction &&
      other.kind == kind &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, label);

  @override
  String toString() => 'RecommendationAction($kind, $label)';
}

/// One supporting value with its original unit.
///
/// [unit] is null when the value is not a measured quantity (a name, a version
/// string, a benefit line). Concentrations always carry the unit the SOURCE
/// stated — the engine never hardcodes one.
class RecommendationFact {
  const RecommendationFact({
    required this.label,
    required this.value,
    this.unit,
  });

  final String label;
  final String value;
  final String? unit;

  /// «12.6 зёрен пыльцы/м³», «1 240 м», «62%» — the unit is part of the
  /// display. [unit] itself remains the source's exact unit.
  String get display =>
      unit == null ? value : '$value ${pollenUnitForDisplay(unit!)}';

  @override
  bool operator ==(Object other) =>
      other is RecommendationFact &&
      other.label == label &&
      other.value == value &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(label, value, unit);

  @override
  String toString() => 'RecommendationFact($label: $display)';
}

/// One explainable recommendation.
class ContextRecommendation {
  const ContextRecommendation({
    required this.id,
    required this.factor,
    required this.availability,
    required this.title,
    required this.explanation,
    required this.facts,
    required this.completenessNote,
    required this.limitations,
    required this.method,
    required this.methodVersion,
    required this.sourceLabel,
    required this.scope,
    required this.evaluatedFor,
    this.completenessShare,
    this.action,
  });

  /// Stable identifier of the RULE that produced this entry (never of a
  /// particular set of numbers), e.g. `shade.estimate`.
  final String id;

  final RecommendationFactor factor;
  final RecommendationAvailability availability;

  /// Short statement of what is known.
  final String title;

  /// Why this statement appeared — the rule and the values behind it, in
  /// words. Never a promise the models do not support.
  final String explanation;

  final List<RecommendationFact> facts;

  /// How complete the facts are, in words, and — where the model produced one —
  /// the share they cover (0..1).
  final String completenessNote;
  final double? completenessShare;

  final List<String> limitations;

  /// Provenance of the facts: the producing method, its version and a short
  /// human-readable source label.
  final String method;
  final String methodVersion;
  final String sourceLabel;

  /// The walk question the facts answer, and the instant they were computed
  /// for (null when the statement does not depend on an instant, e.g. the
  /// native walking-time comparison of a scenic variant).
  final RecommendationScope scope;
  final DateTime? evaluatedFor;

  final RecommendationAction? action;

  @override
  bool operator ==(Object other) =>
      other is ContextRecommendation &&
      other.id == id &&
      other.factor == factor &&
      other.availability == availability &&
      other.title == title &&
      other.explanation == explanation &&
      listEquals(other.facts, facts) &&
      other.completenessNote == completenessNote &&
      other.completenessShare == completenessShare &&
      listEquals(other.limitations, limitations) &&
      other.method == method &&
      other.methodVersion == methodVersion &&
      other.sourceLabel == sourceLabel &&
      other.scope == scope &&
      other.evaluatedFor == evaluatedFor &&
      other.action == action;

  @override
  int get hashCode => Object.hashAll([
    id,
    factor,
    availability,
    title,
    explanation,
    Object.hashAll(facts),
    completenessNote,
    completenessShare,
    Object.hashAll(limitations),
    method,
    methodVersion,
    sourceLabel,
    scope,
    evaluatedFor,
    action,
  ]);

  @override
  String toString() =>
      'ContextRecommendation($id, $factor/$availability, «$title»)';
}

/// What happened to one factor while the recommendation set was assembled.
enum RecommendationSourceAvailability {
  /// The factor produced an admitted recommendation.
  contributes,

  /// The factor was assessed and needs no recommendation of its own (its card
  /// carries the details). Explaining this is not the same as reporting an
  /// error.
  noted,

  /// No assessment exists yet.
  notAssessed,

  /// An assessment is running right now.
  inProgress,

  /// The assessment exists but failed.
  failed,

  /// The factor cannot be assessed in this context (source not configured,
  /// not mounted, requested but not received).
  unavailable,

  /// The factor HAS a result, but it does not belong to the current context.
  /// Never silently dropped: the reason is stated.
  rejected,
}

/// Why an existing result was excluded from the current recommendation set.
enum RecommendationRejection {
  /// The result describes a different route.
  routeMismatch,

  /// The session is rebuilding its geometry RIGHT NOW (reroute in flight):
  /// nothing computed over the previous ground may be presented while the new
  /// one is not known yet — even when the result still looks complete.
  sessionRebuilding,

  /// The result answers the other scope (whole plan vs remaining path).
  scopeMismatch,

  /// The result was computed for an instant outside the coherence window —
  /// including an instant the shared virtual timeline has moved BACK from.
  timeMismatch,

  /// The result does not carry the evidence needed to prove it belongs here.
  unprovenContext,

  /// The walker has moved substantially along the same session geometry since
  /// the assessment was made, so the remaining path it described is no longer
  /// the path still ahead. Small GPS noise is inside the documented tolerance
  /// and never lands here.
  progressAdvanced,

  /// In a real walk (no virtual timeline) the assessment is older than the
  /// live-walk freshness window.
  assessmentAged,

  /// In a real walk the SOURCE's own validity deadline has already passed for
  /// the current instant, so the values no longer describe now.
  sourceExpired,
}

/// One factor's state in the current context, for the compact
/// «почему другие факторы не учтены» list. The message is always a complete
/// Russian sentence; a rejected factor additionally names the reason.
class RecommendationSourceReport {
  const RecommendationSourceReport({
    required this.factor,
    required this.availability,
    required this.message,
    this.evaluatedFor,
    this.rejection,
  });

  final RecommendationFactor factor;
  final RecommendationSourceAvailability availability;
  final String message;
  final DateTime? evaluatedFor;
  final RecommendationRejection? rejection;

  @override
  bool operator ==(Object other) =>
      other is RecommendationSourceReport &&
      other.factor == factor &&
      other.availability == availability &&
      other.message == message &&
      other.evaluatedFor == evaluatedFor &&
      other.rejection == rejection;

  @override
  int get hashCode =>
      Object.hash(factor, availability, message, evaluatedFor, rejection);

  @override
  String toString() =>
      'RecommendationSourceReport($factor/$availability, «$message»)';
}

/// Russian display names of the factors, used by the section header chips and
/// the report list.
String recommendationFactorLabel(RecommendationFactor factor) =>
    switch (factor) {
      RecommendationFactor.shade => 'Тень',
      RecommendationFactor.puddle => 'Мокрые участки',
      RecommendationFactor.pollen => 'Пыльца',
      RecommendationFactor.scenic => 'Живописность',
    };

/// Russian display names of the walk scopes.
String recommendationScopeLabel(RecommendationScope scope) => switch (scope) {
  RecommendationScope.wholeWalk => 'Вся прогулка',
  RecommendationScope.remainingPath => 'Путь впереди',
};
