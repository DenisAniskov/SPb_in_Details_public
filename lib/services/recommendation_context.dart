import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';

/// Phase C7.4 §6 — the context consistency gate.
///
/// This is the phase's most important engineering gate, and it is deliberately
/// a separate, pure layer: providers hand it RAW OFFERS ([SourceSnapshot]),
/// it decides what may appear in one recommendation set, and it reports every
/// exclusion with a reason. It performs no I/O, holds no state and can be
/// unit-tested without a widget tree or a service.
///
/// Four things are verified for every factor before its facts may enter the
/// set (ТЗ C7.4 §6):
///
/// 1. **принадлежность маршруту/сессии** — [SourceSnapshot.identityVerified].
///    The caller proves it (the same route object for a plan, the same session
///    geometry version for a remaining-path estimate); the gate never infers
///    ownership from a non-null analysis;
/// 2. **область анализа** — the facts must answer the SAME question the
///    recommendations answer. Whole-plan shade and remaining-path puddle are
///    never mixed;
/// 3. **согласованность времени** — the facts must lie STRICTLY inside the
///    documented coherence window around the reference instant, so two
///    assessments made for different walk times are never presented as one
///    picture. The boundary is the clock's own: a drift of exactly
///    [VirtualShadeClock.refreshStep] already means "another walk time", just
///    as it already means "stale" to the simulator (C7.4.2);
/// 4. **действительное состояние навигации** — the current scope itself comes
///    from the navigation session, and a session that is rebuilding its
///    geometry has no usable environmental assessments at all.
///
/// Anything that fails a check is EXCLUDED and REPORTED — never guessed into
/// the set and never silently dropped.

/// What one source currently offers, with no verdict attached.
///
/// [facts] is the analysis the provider publishes right now (already null when
/// that provider invalidated it). [identityVerified] is the caller's proof
/// that those facts belong to the CURRENT route or session — see
/// [RecommendationContextGate] for which evidence is accepted.
class SourceSnapshot<T> {
  const SourceSnapshot({
    this.facts,
    this.scope,
    this.evaluatedFor,
    this.identityVerified = false,
    this.inProgress = false,
    this.problem,
    this.failed = false,
    this.progressMeters,
    this.validUntil,
  });

  /// The factor does not exist in this build (no provider mounted).
  const SourceSnapshot.absent()
    : facts = null,
      scope = null,
      evaluatedFor = null,
      identityVerified = false,
      inProgress = false,
      problem = null,
      failed = false,
      progressMeters = null,
      validUntil = null;

  final T? facts;
  final RecommendationScope? scope;
  final DateTime? evaluatedFor;
  final bool identityVerified;
  final bool inProgress;

  /// Human-readable reason the factor carries no facts (already a complete
  /// Russian sentence). Null when there simply is no assessment yet.
  final String? problem;

  /// [problem] describes a failed attempt rather than a missing capability.
  final bool failed;

  /// Explicit progress evidence (ТЗ C7.4 §6): the session's
  /// `totalProgressMeters` at the moment the assessment was made, for a
  /// remaining-path result. The session GEOMETRY VERSION alone cannot see a
  /// walker moving along an unchanged route, so the assessed tail would
  /// silently stop matching the tail ahead; this number is what makes that
  /// checkable. Null means the assessment carries no such evidence — a
  /// remaining-path result is then excluded rather than trusted.
  final double? progressMeters;

  /// The SOURCE's own validity deadline for these values (the weather or
  /// forecast validity the model was built from), when it states one. Only
  /// consulted for a real walk.
  final DateTime? validUntil;
}

/// The scenic factor's offer. A scenic comparison is a PLANNING artifact: it
/// compares the built walk with the normal variant for the same stops, so it
/// has no meaning for a remaining path and no evaluation instant of its own
/// (native walking times do not depend on the time of day).
class ScenicSnapshot {
  const ScenicSnapshot({
    this.comparison,
    this.fallbackMessage,
    this.requested = false,
    this.datasetVersion = '',
  });

  final RouteComparison? comparison;

  /// The engine's own honest fallback text when a scenic variant was requested
  /// but not built (Phase C5 §8). Present exactly when [comparison] is null.
  final String? fallbackMessage;

  /// The user asked for a scenic walk when the route was planned.
  final bool requested;

  final String datasetVersion;
}

/// Everything the recommendation layer may look at, gathered by the provider
/// without interpretation.
class RecommendationInputs {
  const RecommendationInputs({
    required this.hasRoute,
    required this.navigating,
    required this.preference,
    this.sessionRebuilding = false,
    this.clockModelTime,
    this.now,
    this.progressMeters = 0.0,
    this.shade = const SourceSnapshot<ShadeAnalysisModel>.absent(),
    this.puddle = const SourceSnapshot<PuddleAnalysisModel>.absent(),
    this.pollen = const SourceSnapshot<PollenAnalysisModel>.absent(),
    this.scenic = const ScenicSnapshot(),
  });

  final bool hasRoute;
  final bool navigating;

  /// The session is rebuilding its geometry (reroute in flight): assessments
  /// are cleared for the duration and their absence must not be read as
  /// "nothing to report" — nor may a result that is still published be used,
  /// because it describes ground that is being replaced right now.
  final bool sessionRebuilding;

  final RecommendationPreference preference;

  /// The virtual clock's model time, when the opted-in simulator is running.
  /// The shared virtual timeline is ALWAYS authoritative then: a factor
  /// evaluated for another virtual instant is stale by definition (§15.3), no
  /// matter whether the simulator moved forward or backward.
  final DateTime? clockModelTime;

  /// The current wall-clock instant, supplied by the provider through an
  /// injectable time source. Consulted ONLY for a real walk — i.e. navigating
  /// without a virtual timeline — where "now" is what the walk is happening
  /// at; a deliberate planning time is never aged against it, and the gate
  /// itself still reads no clock.
  final DateTime? now;

  /// The session's progress along the route right now. Compared with the
  /// progress an assessment recorded, so a walker advancing along the SAME
  /// session geometry cannot keep seeing a tail that starts 300 m behind.
  final double progressMeters;

  final SourceSnapshot<ShadeAnalysisModel> shade;
  final SourceSnapshot<PuddleAnalysisModel> puddle;
  final SourceSnapshot<PollenAnalysisModel> pollen;
  final ScenicSnapshot scenic;

  /// The question the recommendations answer right now (§15.5): mid-walk only
  /// the remaining path is ever assessed.
  RecommendationScope get scope => navigating
      ? RecommendationScope.remainingPath
      : RecommendationScope.wholeWalk;
}

/// Facts admitted into one recommendation set, together with the instant they
/// were computed for — the engine must be able to state the instant it used.
class AdmittedFacts<T> {
  const AdmittedFacts({required this.facts, required this.evaluatedFor});

  final T facts;
  final DateTime evaluatedFor;
}

/// The verified inputs of ONE recommendation set: only facts that passed the
/// gate, plus a report for every factor that did not.
class RecommendationContext {
  const RecommendationContext({
    required this.scope,
    required this.preference,
    required this.hasRoute,
    this.referenceInstant,
    this.shade,
    this.puddle,
    this.pollen,
    this.scenicComparison,
    this.scenicFallbackMessage,
    this.scenicDatasetVersion = '',
    this.sources = const [],
  });

  final RecommendationScope scope;
  final RecommendationPreference preference;
  final bool hasRoute;

  /// The instant the set is built for: the virtual clock's model time whenever
  /// the simulator is armed — the shared timeline is the authority and a
  /// factor evaluated for a different virtual instant is excluded in either
  /// direction — otherwise the latest evaluation instant among the admitted
  /// facts. Null when neither exists.
  final DateTime? referenceInstant;

  final AdmittedFacts<ShadeAnalysisModel>? shade;
  final AdmittedFacts<PuddleAnalysisModel>? puddle;
  final AdmittedFacts<PollenAnalysisModel>? pollen;

  /// Admitted scenic comparison, or null. [scenicFallbackMessage] carries the
  /// engine's honest "requested but not built" explanation when the factor must
  /// not claim a scenic route.
  final RouteComparison? scenicComparison;
  final String? scenicFallbackMessage;
  final String scenicDatasetVersion;

  /// One report per factor that does NOT contribute to the set, in the
  /// documented factor order. Empty messages never appear here.
  final List<RecommendationSourceReport> sources;

  bool get planning => scope == RecommendationScope.wholeWalk;

  /// True when no factor could contribute anything.
  bool get isEmpty =>
      shade == null &&
      puddle == null &&
      pollen == null &&
      scenicComparison == null &&
      scenicFallbackMessage == null;
}

/// The gate itself. Stateless, deterministic, I/O-free.
class RecommendationContextGate {
  const RecommendationContextGate({
    this.tolerance = defaultTolerance,
    this.progressTolerance = defaultProgressTolerance,
    this.maxLiveAge = defaultMaxLiveAge,
  });

  /// How far apart two evaluation instants may be while still describing the
  /// SAME walk. Identical to the virtual clock's documented refresh step
  /// ([VirtualShadeClock.refreshStep]): that is already the app's own answer to
  /// "how long a shade estimate stays current", so the coherence window does
  /// not invent a second, competing notion of freshness. The boundary follows
  /// the clock as well: [VirtualShadeClock.needsReanalysis] already treats a
  /// drift of `>= refreshStep` as stale, so an assessment exactly
  /// [defaultTolerance] away from the reference is a different walk time, not
  /// a current one — only a STRICTLY smaller difference is admitted. Pressing
  /// two factor buttons minutes apart describes one walk; assessments made for
  /// explicitly different walk times (or the same distance into the virtual
  /// past) never enter one set.
  static const Duration defaultTolerance = VirtualShadeClock.refreshStep;

  /// How far the walker may advance along the SAME session geometry before a
  /// remaining-path assessment stops describing the path ahead. A context
  /// POLICY, not a model parameter: it is one order of magnitude above the
  /// GPS-noise bounds the navigation session itself already tolerates
  /// (a 15 m rewind is clamped, a ≥60 m forward jump needs a second fix), so
  /// jitter never trips it, and it is the same order as the app's own 150 m
  /// proximity bound («Я на месте»).
  static const double defaultProgressTolerance = 150.0;

  /// How long an assessment may be old in a REAL walk (navigating without a
  /// virtual timeline) before it stops describing "now". The same documented
  /// window the shade overlay uses for its own freshness, applied to a live
  /// walk; a deliberately chosen planning time is never measured against it.
  /// Ageing is inclusive at the boundary (`age >= maxLiveAge`), exactly like
  /// the clock's own `needsReanalysis` — the gate is never laxer than the
  /// simulator it mirrors.
  static const Duration defaultMaxLiveAge = VirtualShadeClock.refreshStep;

  final Duration tolerance;
  final double progressTolerance;
  final Duration maxLiveAge;

  static const String _shadeCard = 'Тень на маршруте';
  static const String _puddleCard = 'Мокрые участки после дождя';
  static const String _pollenCard = 'Пыльца на маршруте';

  /// The card titles above are the ones the C7.1/C7.2/C7.3 sections render, so
  /// "where to start the assessment" in a report points at a real control.
  static String _cardName(RecommendationFactor factor) => switch (factor) {
    RecommendationFactor.shade => _shadeCard,
    RecommendationFactor.puddle => _puddleCard,
    RecommendationFactor.pollen => _pollenCard,
    RecommendationFactor.scenic => '',
  };

  RecommendationContext evaluate(RecommendationInputs inputs) {
    if (!inputs.hasRoute) {
      // There is no walk to talk about. This is not an unavailability story:
      // it is simply not a context for recommendations.
      return RecommendationContext(
        scope: inputs.scope,
        preference: inputs.preference,
        hasRoute: false,
      );
    }

    final scope = inputs.scope;
    final reports = <RecommendationSourceReport>[];
    final admitted = <RecommendationFactor, _Admitted>{};

    // A real walk is the only context where the wall clock decides: with the
    // simulator running the virtual timeline governs (below), and in planning
    // the walk happens at the time the user deliberately chose.
    final liveNow = inputs.navigating && inputs.clockModelTime == null
        ? inputs.now
        : null;

    void consider<T>(RecommendationFactor factor, SourceSnapshot<T> snapshot) {
      final facts = snapshot.facts;
      if (facts == null) {
        reports.add(
          RecommendationSourceReport(
            factor: factor,
            availability: _absenceAvailability(snapshot, inputs),
            message: _absenceMessage(factor, snapshot, inputs),
          ),
        );
        return;
      }
      if (inputs.sessionRebuilding) {
        // A reroute in flight replaces the ground the session measures. A
        // result that is still published — and even one whose ownership was
        // proved a moment ago — describes geometry that is being rebuilt, so
        // it is excluded instead of presented as a fact about the path ahead.
        reports.add(
          _rejected(
            factor,
            RecommendationRejection.sessionRebuilding,
            'идёт перестроение маршрута: прежняя оценка не относится к новому '
            'пути. Пересчитайте её после завершения перестроения.',
            evaluatedFor: snapshot.evaluatedFor,
          ),
        );
        return;
      }
      if (!snapshot.identityVerified) {
        reports.add(
          _rejected(
            factor,
            RecommendationRejection.routeMismatch,
            'найденная оценка не подтверждена как относящаяся к текущему '
            'маршруту — в рекомендациях она не используется.',
            evaluatedFor: snapshot.evaluatedFor,
          ),
        );
        return;
      }
      final factsScope = snapshot.scope;
      final factsInstant = snapshot.evaluatedFor;
      if (factsScope == null || factsInstant == null) {
        reports.add(
          _rejected(
            factor,
            RecommendationRejection.unprovenContext,
            'в оценке нет признаков, к какому маршруту и времени она '
            'относится — в рекомендациях она не используется.',
            evaluatedFor: factsInstant,
          ),
        );
        return;
      }
      if (factsScope != scope) {
        reports.add(
          _rejected(
            factor,
            RecommendationRejection.scopeMismatch,
            'оценка сделана для «${recommendationScopeLabel(factsScope)}», '
            'а сейчас рекомендации относятся к '
            '«${recommendationScopeLabel(scope)}» — смешивать их нельзя. '
            'Пересчитайте оценку.',
            evaluatedFor: factsInstant,
          ),
        );
        return;
      }
      if (factsScope == RecommendationScope.remainingPath) {
        // The session geometry VERSION does not move while the walker walks
        // the same route, so the version alone cannot tell that the assessed
        // tail was cut where the walker no longer stands. The progress
        // evidence recorded at assessment time can, and it is required: an
        // estimate whose anchor cannot be checked is excluded, not trusted.
        final assessedProgress = snapshot.progressMeters;
        if (assessedProgress == null) {
          reports.add(
            _rejected(
              factor,
              RecommendationRejection.unprovenContext,
              'в оценке нет признака, с какого места пути она начиналась, — '
              'её актуальность для текущего остатка пути проверить нельзя. '
              'Пересчитайте оценку.',
              evaluatedFor: factsInstant,
            ),
          );
          return;
        }
        final advanced = inputs.progressMeters - assessedProgress;
        if (advanced.abs() > progressTolerance) {
          reports.add(
            _rejected(
              factor,
              RecommendationRejection.progressAdvanced,
              'с момента оценки вы продвинулись по этому же маршруту примерно '
              'на ${advanced.abs().round()} м (порог — '
              '${progressTolerance.round()} м), поэтому она описывает уже '
              'пройденную часть пути. Пересчитайте её для текущего остатка.',
              evaluatedFor: factsInstant,
            ),
          );
          return;
        }
      }
      if (liveNow != null) {
        // Two honest reasons the values no longer describe THIS walk; both
        // are stated, never turned into a quiet downgrade.
        final validUntil = snapshot.validUntil;
        if (validUntil != null && liveNow.isAfter(validUntil)) {
          reports.add(
            _rejected(
              factor,
              RecommendationRejection.sourceExpired,
              'источник был актуален до ${_instant(validUntil)}, а прогулка '
              'идёт позже — значения больше не описывают текущий момент. '
              'Пересчитайте оценку.',
              evaluatedFor: factsInstant,
            ),
          );
          return;
        }
        final age = liveNow.difference(factsInstant);
        if (age >= maxLiveAge) {
          // The boundary is inclusive here too (`>=`), so the message says
          // "not less than" instead of claiming a strictly greater age.
          reports.add(
            _rejected(
              factor,
              RecommendationRejection.assessmentAged,
              'оценка сделана не менее ${maxLiveAge.inMinutes} мин назад, а '
              'прогулка идёт сейчас — данные успели устареть. Пересчитайте '
              'оценку, чтобы рекомендация относилась к текущему моменту.',
              evaluatedFor: factsInstant,
            ),
          );
          return;
        }
      }
      admitted[factor] = _Admitted(facts: facts, evaluatedFor: factsInstant);
    }

    consider(RecommendationFactor.shade, inputs.shade);
    consider(RecommendationFactor.puddle, inputs.puddle);
    consider(RecommendationFactor.pollen, inputs.pollen);

    // --- the reference instant -------------------------------------------
    // When the simulator runs, the shared virtual timeline is the reference
    // UNCONDITIONALLY: it is the instant the walk is at, and an assessment
    // made for another virtual instant is excluded in EITHER direction — a
    // simulator seek backward invalidates a later estimate exactly like a seek
    // forward invalidates an earlier one. Without a clock the latest
    // assessment is the reference: it reflects what the user asked for last,
    // and everything older is the part to re-run.
    DateTime? reference;
    final clockTime = inputs.clockModelTime;
    if (clockTime != null) {
      reference = clockTime;
    } else {
      for (final value in admitted.values) {
        if (reference == null || value.evaluatedFor.isAfter(reference)) {
          reference = value.evaluatedFor;
        }
      }
    }

    if (reference != null) {
      admitted.removeWhere((factor, value) {
        // STRICTLY inside the window, in either direction. The boundary itself
        // belongs to "another walk time": exactly [tolerance] of drift is
        // already stale to the virtual clock (`>= refreshStep`), so admitting
        // it here would make the gate laxer than the simulator it mirrors.
        if (value.evaluatedFor.difference(reference!).abs() < tolerance) {
          return false;
        }
        reports.add(
          _rejected(
            factor,
            RecommendationRejection.timeMismatch,
            'оценка сделана для другого времени (расхождение '
            '${tolerance.inMinutes} мин и более) — пересчитайте её, чтобы '
            'она участвовала в рекомендациях.',
            evaluatedFor: value.evaluatedFor,
          ),
        );
        return true;
      });
    }

    // --- scenic: a planning question only --------------------------------
    RouteComparison? scenicComparison;
    String? scenicFallback;
    if (scope == RecommendationScope.wholeWalk && inputs.scenic.requested) {
      scenicComparison = inputs.scenic.comparison;
      if (scenicComparison == null) {
        if (inputs.scenic.fallbackMessage != null) {
          scenicFallback = inputs.scenic.fallbackMessage;
        } else {
          reports.add(
            const RecommendationSourceReport(
              factor: RecommendationFactor.scenic,
              availability: RecommendationSourceAvailability.notAssessed,
              message:
                  'Живописный вариант запрашивался, но результат его '
                  'проверки ещё не получен.',
            ),
          );
        }
      }
    }

    final context = RecommendationContext(
      scope: scope,
      preference: inputs.preference,
      hasRoute: true,
      referenceInstant: reference,
      shade: _asAdmitted<ShadeAnalysisModel>(
        admitted,
        RecommendationFactor.shade,
      ),
      puddle: _asAdmitted<PuddleAnalysisModel>(
        admitted,
        RecommendationFactor.puddle,
      ),
      pollen: _asAdmitted<PollenAnalysisModel>(
        admitted,
        RecommendationFactor.pollen,
      ),
      scenicComparison: scenicComparison,
      scenicFallbackMessage: scenicFallback,
      scenicDatasetVersion: inputs.scenic.datasetVersion,
      sources: _ordered(reports),
    );
    return context;
  }

  /// Re-types an admitted offer; a factor's facts are always of its own type,
  /// so this only restores what [consider] proved.
  static AdmittedFacts<T>? _asAdmitted<T>(
    Map<RecommendationFactor, _Admitted> admitted,
    RecommendationFactor factor,
  ) {
    final value = admitted[factor];
    if (value == null || value.facts is! T) return null;
    return AdmittedFacts<T>(
      facts: value.facts as T,
      evaluatedFor: value.evaluatedFor,
    );
  }

  static RecommendationSourceReport _rejected(
    RecommendationFactor factor,
    RecommendationRejection rejection,
    String reason, {
    DateTime? evaluatedFor,
  }) => RecommendationSourceReport(
    factor: factor,
    availability: RecommendationSourceAvailability.rejected,
    message: '${recommendationFactorLabel(factor)}: $reason',
    evaluatedFor: evaluatedFor,
    rejection: rejection,
  );

  RecommendationSourceAvailability _absenceAvailability(
    SourceSnapshot<Object?> snapshot,
    RecommendationInputs inputs,
  ) {
    if (snapshot.inProgress) return RecommendationSourceAvailability.inProgress;
    final problem = snapshot.problem;
    if (problem != null) {
      return snapshot.failed
          ? RecommendationSourceAvailability.failed
          : RecommendationSourceAvailability.unavailable;
    }
    if (inputs.sessionRebuilding) {
      return RecommendationSourceAvailability.unavailable;
    }
    return RecommendationSourceAvailability.notAssessed;
  }

  String _absenceMessage(
    RecommendationFactor factor,
    SourceSnapshot<Object?> snapshot,
    RecommendationInputs inputs,
  ) {
    if (snapshot.inProgress) {
      return '${recommendationFactorLabel(factor)}: оценка выполняется '
          'прямо сейчас.';
    }
    final problem = snapshot.problem;
    if (problem != null) {
      return '${recommendationFactorLabel(factor)}: $problem';
    }
    if (inputs.sessionRebuilding) {
      return '${recommendationFactorLabel(factor)}: идёт перестроение '
          'маршрута — оценки станут доступны после его завершения.';
    }
    return '${recommendationFactorLabel(factor)}: оценка ещё не выполнялась. '
        'Её можно запустить в карточке «${_cardName(factor)}» ниже.';
  }

  /// Documented factor order of the report list.
  static const List<RecommendationFactor> factorOrder = [
    RecommendationFactor.shade,
    RecommendationFactor.puddle,
    RecommendationFactor.pollen,
    RecommendationFactor.scenic,
  ];

  static List<RecommendationSourceReport> _ordered(
    List<RecommendationSourceReport> reports,
  ) {
    final copy = List<RecommendationSourceReport>.of(reports)
      ..sort(
        (a, b) => factorOrder
            .indexOf(a.factor)
            .compareTo(factorOrder.indexOf(b.factor)),
      );
    return List.unmodifiable(copy);
  }

  /// The same shape the section shows for an evaluation instant.
  static String _instant(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

/// An admissible offer: the facts plus the instant they were computed for.
class _Admitted {
  const _Admitted({required this.facts, required this.evaluatedFor});

  final Object facts;
  final DateTime evaluatedFor;
}
