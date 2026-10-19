import 'package:flutter_test/flutter_test.dart';

import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/services/context_recommendation_engine.dart';
import 'package:smart_navigator_spb/services/recommendation_context.dart';

import 'context_recommendation_fixtures.dart';

// --------------------------------------------------------------------------
// Phase C7.4 §6 — the context consistency gate, tested on its own.
//
// This is the phase's most important engineering gate: these tests pin WHICH
// combinations of results may form one recommendation set, and — equally
// important — that everything excluded is excluded with a stated reason
// instead of being guessed into place.
// --------------------------------------------------------------------------

const _gate = RecommendationContextGate();
const _engine = ContextRecommendationEngine();

final _t1300 = DateTime(2026, 7, 1, 13);
final _t1400 = DateTime(2026, 7, 1, 14);
final _t1410 = DateTime(2026, 7, 1, 14, 10);
final _t1600 = DateTime(2026, 7, 1, 16);

SourceSnapshot<ShadeAnalysisModel> _shade({
  DateTime? evaluatedFor,
  RecommendationScope scope = RecommendationScope.wholeWalk,
  bool identityVerified = true,
  ShadeAnalysisModel? facts,
  double? progressMeters,
}) => SourceSnapshot<ShadeAnalysisModel>(
  facts: facts ?? shadeFixture(),
  scope: scope,
  evaluatedFor: evaluatedFor ?? _t1400,
  identityVerified: identityVerified,
  progressMeters: progressMeters,
);

SourceSnapshot<PuddleAnalysisModel> _puddle({
  DateTime? evaluatedFor,
  RecommendationScope scope = RecommendationScope.wholeWalk,
  bool identityVerified = true,
  double? progressMeters = 0,
  DateTime? validUntil,
}) => SourceSnapshot<PuddleAnalysisModel>(
  facts: puddleHighFixture(),
  scope: scope,
  evaluatedFor: evaluatedFor ?? _t1400,
  identityVerified: identityVerified,
  progressMeters: progressMeters,
  validUntil: validUntil,
);

SourceSnapshot<PollenAnalysisModel> _pollen({
  DateTime? evaluatedFor,
  RecommendationScope scope = RecommendationScope.wholeWalk,
  bool identityVerified = true,
  double? progressMeters = 0,
  DateTime? validUntil,
}) => SourceSnapshot<PollenAnalysisModel>(
  facts: pollenConcentrationsFixture(),
  scope: scope,
  evaluatedFor: evaluatedFor ?? _t1400,
  identityVerified: identityVerified,
  progressMeters: progressMeters,
  validUntil: validUntil,
);

RecommendationContext _evaluate({
  bool navigating = false,
  bool sessionRebuilding = false,
  DateTime? clockModelTime,
  DateTime? now,
  double progressMeters = 0,
  RecommendationPreference preference = RecommendationPreference.all,
  SourceSnapshot<ShadeAnalysisModel> shade =
      const SourceSnapshot<ShadeAnalysisModel>.absent(),
  SourceSnapshot<PuddleAnalysisModel> puddle =
      const SourceSnapshot<PuddleAnalysisModel>.absent(),
  SourceSnapshot<PollenAnalysisModel> pollen =
      const SourceSnapshot<PollenAnalysisModel>.absent(),
  ScenicSnapshot scenic = const ScenicSnapshot(),
  bool hasRoute = true,
}) => _gate.evaluate(
  RecommendationInputs(
    hasRoute: hasRoute,
    navigating: navigating,
    sessionRebuilding: sessionRebuilding,
    preference: preference,
    clockModelTime: clockModelTime,
    now: now,
    progressMeters: progressMeters,
    shade: shade,
    puddle: puddle,
    pollen: pollen,
    scenic: scenic,
  ),
);

RecommendationSourceReport _reportFor(
  RecommendationContext context,
  RecommendationFactor factor,
) {
  final matches = context.sources.where((report) => report.factor == factor);
  expect(matches, hasLength(1));
  return matches.single;
}

List<String> _ids(RecommendationContext context) =>
    _engine.build(context).map((entry) => entry.id).toList();

/// The factors the context reports as NOT contributing. A factor that was
/// simply never supplied reports `notAssessed` — that is not a failure, so
/// tests assert on this list instead of on the whole report set.
List<RecommendationFactor> _reportedFactors(RecommendationContext context) =>
    context.sources.map((report) => report.factor).toList();

void main() {
  group('time coherence (ТЗ §6, §9.8)', () {
    test('assessments for different times are never combined', () {
      final context = _evaluate(
        shade: _shade(evaluatedFor: _t1400),
        puddle: _puddle(evaluatedFor: _t1600),
      );
      // The most recent assessment is the reference; the older one is
      // reported, not silently merged into one picture.
      expect(context.referenceInstant, _t1600);
      expect(context.shade, isNull);
      expect(context.puddle, isNotNull);
      expect(_ids(context), ['puddle.high_sections']);
      final report = _reportFor(context, RecommendationFactor.shade);
      expect(report.availability, RecommendationSourceAvailability.rejected);
      expect(report.rejection, RecommendationRejection.timeMismatch);
      expect(report.message, contains('расхождение 15 мин и более'));
      expect(report.evaluatedFor, _t1400);
    });

    test('assessments inside the documented window describe one walk', () {
      final context = _evaluate(
        shade: _shade(evaluatedFor: _t1400),
        puddle: _puddle(evaluatedFor: _t1410),
        pollen: _pollen(evaluatedFor: _t1400),
      );
      expect(context.referenceInstant, _t1410);
      expect(context.shade, isNotNull);
      expect(context.puddle, isNotNull);
      expect(context.pollen, isNotNull);
      expect(context.sources, isEmpty);
      expect(_ids(context), [
        'shade.estimate',
        'puddle.high_sections',
        'pollen.concentrations',
      ]);
    });

    test('the simulator clock is authoritative for the current instant', () {
      final context = _evaluate(
        clockModelTime: _t1600,
        shade: _shade(evaluatedFor: _t1400),
        puddle: _puddle(evaluatedFor: _t1600),
      );
      expect(context.referenceInstant, _t1600);
      expect(
        _reportFor(context, RecommendationFactor.shade).rejection,
        RecommendationRejection.timeMismatch,
        reason: 'оценка для другого виртуального времени не участвует',
      );
      expect(_ids(context), ['puddle.high_sections']);
    });

    test('an armed clock without facts is not an evaluation instant', () {
      final context = _evaluate(clockModelTime: _t1600);
      expect(context.referenceInstant, _t1600);
      expect(_ids(context), isEmpty);
    });

    // --- C7.4.1 review fix #1: the clock decides in BOTH directions -------
    test('seeking the simulator BACK is not a way to keep an old estimate', () {
      final context = _evaluate(
        clockModelTime: _t1300,
        shade: _shade(evaluatedFor: _t1600),
      );
      // Before the fix the reference was the LATER of the two, so a backward
      // seek silently re-admitted an estimate from the virtual future.
      expect(context.referenceInstant, _t1300);
      expect(context.shade, isNull);
      expect(_ids(context), isEmpty);
      final report = _reportFor(context, RecommendationFactor.shade);
      expect(report.rejection, RecommendationRejection.timeMismatch);
      expect(report.evaluatedFor, _t1600);
      expect(report.message, contains('расхождение 15 мин и более'));
    });

    test('seeking the simulator FORWARD excludes the old estimate too', () {
      final context = _evaluate(
        clockModelTime: _t1600,
        shade: _shade(evaluatedFor: _t1300),
      );
      expect(context.referenceInstant, _t1600);
      expect(context.shade, isNull);
      expect(
        _reportFor(context, RecommendationFactor.shade).rejection,
        RecommendationRejection.timeMismatch,
      );
    });

    test('either direction inside the window keeps the estimate', () {
      final behind = _evaluate(
        clockModelTime: _t1600,
        shade: _shade(
          evaluatedFor: _t1600.subtract(const Duration(minutes: 14)),
        ),
      );
      expect(behind.referenceInstant, _t1600);
      expect(behind.shade, isNotNull);
      expect(
        _reportedFactors(behind),
        isNot(contains(RecommendationFactor.shade)),
      );

      final ahead = _evaluate(
        clockModelTime: _t1600,
        shade: _shade(evaluatedFor: _t1600.add(const Duration(minutes: 14))),
      );
      expect(ahead.referenceInstant, _t1600);
      expect(ahead.shade, isNotNull);
      expect(
        _reportedFactors(ahead),
        isNot(contains(RecommendationFactor.shade)),
      );
    });

    test('the boundary itself is another walk time, in both directions', () {
      // C7.4.2: the simulator calls a drift of >= refreshStep stale, so exactly
      // 15 minutes is NOT the same walk time — admitting it would make the gate
      // laxer than the clock it mirrors.
      for (final shift in const [
        Duration(minutes: -15),
        Duration(minutes: 15),
      ]) {
        final boundary = _evaluate(
          clockModelTime: _t1600,
          shade: _shade(evaluatedFor: _t1600.add(shift)),
        );
        expect(boundary.referenceInstant, _t1600);
        expect(
          boundary.shade,
          isNull,
          reason: 'ровно 15 мин — уже другое время прогулки',
        );
        final report = _reportFor(boundary, RecommendationFactor.shade);
        expect(report.rejection, RecommendationRejection.timeMismatch);
        expect(report.message, contains('расхождение 15 мин и более'));
        expect(report.message, contains('пересчитайте её'));
      }

      // A second inside the window still describes one walk.
      for (final shift in const [
        Duration(minutes: -14, seconds: -59),
        Duration(minutes: 14, seconds: 59),
      ]) {
        final inside = _evaluate(
          clockModelTime: _t1600,
          shade: _shade(evaluatedFor: _t1600.add(shift)),
        );
        expect(inside.shade, isNotNull, reason: '14:59 — то же время прогулки');
        expect(
          _reportedFactors(inside),
          isNot(contains(RecommendationFactor.shade)),
        );
      }

      final outside = _evaluate(
        clockModelTime: _t1600,
        shade: _shade(
          evaluatedFor: _t1600.subtract(const Duration(minutes: 31)),
        ),
      );
      expect(outside.shade, isNull);
      expect(
        _reportFor(outside, RecommendationFactor.shade).rejection,
        RecommendationRejection.timeMismatch,
      );
    });

    test('without a clock the facts still name the instant', () {
      final context = _evaluate(
        shade: _shade(evaluatedFor: _t1400),
        puddle: _puddle(evaluatedFor: _t1410),
      );
      expect(context.referenceInstant, _t1410);
      expect(context.shade, isNotNull);
      expect(context.puddle, isNotNull);
    });

    test('a clock that is armed but silent does not age facts', () {
      // With the simulator running, the wall clock is irrelevant: the virtual
      // timeline is the authority, so `now` never enters the verdict.
      final context = _evaluate(
        navigating: true,
        clockModelTime: _t1400,
        now: _t1400.add(const Duration(hours: 5)),
        progressMeters: 245,
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 245,
        ),
      );
      expect(context.puddle, isNotNull);
      expect(
        _reportedFactors(context),
        isNot(contains(RecommendationFactor.puddle)),
      );
    });
  });

  // --- C7.4.1 review fix #2: progress evidence -------------------------------
  group('remaining-path progress evidence (ТЗ §6, C7.4.1)', () {
    test('a small advance along the same geometry keeps the estimate', () {
      final context = _evaluate(
        navigating: true,
        progressMeters: 245,
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 200,
        ),
      );
      expect(
        context.puddle,
        isNotNull,
        reason: '45 м — это GPS-шум, не смена пути',
      );
      expect(
        _reportedFactors(context),
        isNot(contains(RecommendationFactor.puddle)),
      );
    });

    test('a substantial advance excludes the estimate with the distance', () {
      final context = _evaluate(
        navigating: true,
        progressMeters: 645,
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 245,
        ),
      );
      expect(context.puddle, isNull);
      final report = _reportFor(context, RecommendationFactor.puddle);
      expect(report.rejection, RecommendationRejection.progressAdvanced);
      expect(report.message, contains('продвинулись по этому же маршруту'));
      expect(report.message, contains('400 м'));
      expect(report.message, contains('порог — 150 м'));
      expect(report.message, contains('Пересчитайте'));
      expect(report.evaluatedFor, _t1400);
      expect(_ids(context), isEmpty);
    });

    test('the tolerance boundary: 150 м stays, 151 м does not', () {
      final inside = _evaluate(
        navigating: true,
        progressMeters: 250,
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 100,
        ),
      );
      expect(inside.puddle, isNotNull);

      final outside = _evaluate(
        navigating: true,
        progressMeters: 251,
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 100,
        ),
      );
      expect(outside.puddle, isNull);
      expect(
        _reportFor(outside, RecommendationFactor.puddle).rejection,
        RecommendationRejection.progressAdvanced,
      );
    });

    test('a tail estimate without progress evidence is not trusted', () {
      final context = _evaluate(
        navigating: true,
        progressMeters: 245,
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: null,
        ),
      );
      expect(context.puddle, isNull);
      final report = _reportFor(context, RecommendationFactor.puddle);
      expect(report.rejection, RecommendationRejection.unprovenContext);
      expect(report.message, contains('с какого места пути'));
      expect(report.message, contains('Пересчитайте'));
    });

    test('a whole-walk estimate needs no progress evidence', () {
      // The plan answer the planning question: how far the user has walked
      // says nothing about whether the plan's estimate still describes it.
      final context = _evaluate(
        progressMeters: 900,
        shade: _shade(progressMeters: null),
      );
      expect(context.shade, isNotNull);
    });

    test(
      'a backward progress reading is judged by distance, not direction',
      () {
        final context = _evaluate(
          navigating: true,
          progressMeters: 100,
          puddle: _puddle(
            scope: RecommendationScope.remainingPath,
            progressMeters: 900,
          ),
        );
        expect(context.puddle, isNull);
        expect(
          _reportFor(context, RecommendationFactor.puddle).rejection,
          RecommendationRejection.progressAdvanced,
        );
      },
    );
  });

  // --- C7.4.1 review fix #2: live-walk freshness -----------------------------
  group('live-walk freshness, real walk only (C7.4.1)', () {
    test('an assessment older than the window is excluded', () {
      final context = _evaluate(
        navigating: true,
        now: _t1400.add(const Duration(minutes: 16)),
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 0,
        ),
      );
      expect(context.puddle, isNull);
      final report = _reportFor(context, RecommendationFactor.puddle);
      expect(report.rejection, RecommendationRejection.assessmentAged);
      expect(report.message, contains('не менее 15 мин назад'));
      expect(report.message, contains('Пересчитайте'));
    });

    test('an assessment inside the window is current', () {
      final context = _evaluate(
        navigating: true,
        now: _t1400.add(const Duration(minutes: 14)),
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 0,
        ),
      );
      expect(context.puddle, isNotNull);
    });

    test('the ageing boundary is inclusive too, like the clock step', () {
      // The same `>= refreshStep` verdict the simulator uses: an assessment
      // exactly 15 minutes old is stale, one second younger is not.
      final boundary = _evaluate(
        navigating: true,
        now: _t1400.add(const Duration(minutes: 15)),
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 0,
        ),
      );
      expect(boundary.puddle, isNull);
      final report = _reportFor(boundary, RecommendationFactor.puddle);
      expect(report.rejection, RecommendationRejection.assessmentAged);
      expect(report.message, contains('не менее 15 мин назад'));

      final justInside = _evaluate(
        navigating: true,
        now: _t1400.add(const Duration(minutes: 14, seconds: 59)),
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 0,
        ),
      );
      expect(justInside.puddle, isNotNull);
    });

    test('the source validity deadline is its own reason', () {
      final context = _evaluate(
        navigating: true,
        now: _t1410,
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 0,
          validUntil: _t1400.add(const Duration(minutes: 5)),
        ),
      );
      expect(context.puddle, isNull);
      final report = _reportFor(context, RecommendationFactor.puddle);
      expect(report.rejection, RecommendationRejection.sourceExpired);
      expect(report.message, contains('актуален до 01.07.2026 14:05'));
    });

    test('planning is never aged against the wall clock', () {
      // The user deliberately chose a walk time; measuring it against "now"
      // would be exactly the confusion §6 forbids.
      final context = _evaluate(
        now: _t1600.add(const Duration(days: 2)),
        shade: _shade(evaluatedFor: _t1600),
        puddle: _puddle(
          evaluatedFor: _t1600,
          validUntil: _t1600.add(const Duration(minutes: 1)),
        ),
      );
      expect(context.shade, isNotNull);
      expect(context.puddle, isNotNull);
      expect(
        _reportedFactors(context),
        isNot(
          anyOf(
            contains(RecommendationFactor.shade),
            contains(RecommendationFactor.puddle),
          ),
        ),
      );
    });

    test('without a now the gate cannot age anything', () {
      final context = _evaluate(
        navigating: true,
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 0,
        ),
      );
      expect(context.puddle, isNotNull);
    });
  });

  // --- C7.4.1 review fix #3: a reroute in flight ----------------------------
  group('a rebuilding session rejects results that are still published', () {
    test('even a complete, verified result is excluded while rebuilding', () {
      final context = _evaluate(
        navigating: true,
        sessionRebuilding: true,
        progressMeters: 245,
        shade: _shade(
          scope: RecommendationScope.remainingPath,
          progressMeters: 245,
        ),
        puddle: _puddle(
          scope: RecommendationScope.remainingPath,
          progressMeters: 245,
        ),
        pollen: _pollen(
          scope: RecommendationScope.remainingPath,
          progressMeters: 245,
        ),
      );
      expect(context.shade, isNull);
      expect(context.puddle, isNull);
      expect(context.pollen, isNull);
      expect(_ids(context), isEmpty);
      for (final factor in [
        RecommendationFactor.shade,
        RecommendationFactor.puddle,
        RecommendationFactor.pollen,
      ]) {
        final report = _reportFor(context, factor);
        expect(report.availability, RecommendationSourceAvailability.rejected);
        expect(report.rejection, RecommendationRejection.sessionRebuilding);
        expect(report.message, contains('идёт перестроение маршрута'));
        expect(report.message, contains('Пересчитайте'));
      }
    });

    test('the same result is admitted again once the rebuild finished', () {
      final snapshot = _puddle(
        scope: RecommendationScope.remainingPath,
        progressMeters: 245,
      );
      final during = _evaluate(
        navigating: true,
        sessionRebuilding: true,
        progressMeters: 245,
        puddle: snapshot,
      );
      expect(during.puddle, isNull);

      final after = _evaluate(
        navigating: true,
        sessionRebuilding: false,
        progressMeters: 245,
        puddle: snapshot,
      );
      expect(after.puddle, isNotNull);
      expect(
        _reportedFactors(after),
        isNot(contains(RecommendationFactor.puddle)),
      );
    });

    test('a whole-walk estimate is excluded while rebuilding too', () {
      // The rebuilding verdict is the strongest one and precedes the scope
      // check: while the ground under the walker is being replaced, nothing
      // that was computed over the old ground is presented, plan or tail.
      final context = _evaluate(sessionRebuilding: true, shade: _shade());
      expect(context.shade, isNull);
      expect(
        _reportFor(context, RecommendationFactor.shade).rejection,
        RecommendationRejection.sessionRebuilding,
      );
    });
  });

  group('ownership and scope (ТЗ §6, §9.9, §9.10)', () {
    test('an assessment for another route is excluded with a reason', () {
      final context = _evaluate(
        shade: _shade(),
        puddle: _puddle(identityVerified: false),
      );
      expect(context.puddle, isNull);
      final report = _reportFor(context, RecommendationFactor.puddle);
      expect(report.rejection, RecommendationRejection.routeMismatch);
      expect(report.message, contains('не подтверждена как относящаяся'));
      expect(_ids(context), ['shade.estimate']);
    });

    test('whole-plan shade and remaining-path puddle are never mixed', () {
      final context = _evaluate(
        navigating: true,
        shade: _shade(scope: RecommendationScope.wholeWalk),
        puddle: _puddle(scope: RecommendationScope.remainingPath),
      );
      expect(context.scope, RecommendationScope.remainingPath);
      expect(context.shade, isNull);
      expect(context.puddle, isNotNull);
      final report = _reportFor(context, RecommendationFactor.shade);
      expect(report.rejection, RecommendationRejection.scopeMismatch);
      expect(report.message, contains('«Вся прогулка»'));
      expect(report.message, contains('«Путь впереди»'));
      expect(_ids(context), ['puddle.high_sections']);
    });

    test('a remaining-path fact never answers the whole-walk question', () {
      final context = _evaluate(
        puddle: _puddle(scope: RecommendationScope.remainingPath),
      );
      expect(context.puddle, isNull);
      expect(
        _reportFor(context, RecommendationFactor.puddle).rejection,
        RecommendationRejection.scopeMismatch,
      );
    });
  });

  group('provenance contract', () {
    test('facts without an instant or a scope are excluded, not guessed', () {
      final noInstant = _evaluate(
        shade: SourceSnapshot<ShadeAnalysisModel>(
          facts: shadeFixture(),
          scope: RecommendationScope.wholeWalk,
          identityVerified: true,
        ),
      );
      expect(noInstant.shade, isNull);
      expect(
        _reportFor(noInstant, RecommendationFactor.shade).rejection,
        RecommendationRejection.unprovenContext,
      );

      final noScope = _evaluate(
        shade: SourceSnapshot<ShadeAnalysisModel>(
          facts: shadeFixture(),
          evaluatedFor: _t1400,
          identityVerified: true,
        ),
      );
      expect(noScope.shade, isNull);
      expect(
        _reportFor(noScope, RecommendationFactor.shade).rejection,
        RecommendationRejection.unprovenContext,
      );
    });

    test('an unproved owner is excluded even when the facts look complete', () {
      final context = _evaluate(pollen: _pollen(identityVerified: false));
      expect(context.pollen, isNull);
      expect(
        _reportFor(context, RecommendationFactor.pollen).rejection,
        RecommendationRejection.routeMismatch,
      );
      expect(_ids(context), isEmpty);
    });
  });

  group('absence is reported, never inferred (ТЗ §7)', () {
    test('a factor that was never assessed says so and points at its card', () {
      final context = _evaluate(shade: _shade());
      final puddle = _reportFor(context, RecommendationFactor.puddle);
      expect(puddle.availability, RecommendationSourceAvailability.notAssessed);
      expect(puddle.message, contains('оценка ещё не выполнялась'));
      expect(puddle.message, contains('Мокрые участки после дождя'));
      final pollen = _reportFor(context, RecommendationFactor.pollen);
      expect(pollen.availability, RecommendationSourceAvailability.notAssessed);
      expect(pollen.message, contains('Пыльца на маршруте'));
    });

    test('a running assessment is named as running', () {
      final context = _evaluate(
        puddle: const SourceSnapshot<PuddleAnalysisModel>(inProgress: true),
      );
      final report = _reportFor(context, RecommendationFactor.puddle);
      expect(report.availability, RecommendationSourceAvailability.inProgress);
      expect(report.message, contains('оценка выполняется прямо сейчас'));
    });

    test('a failure and a missing capability are distinguished', () {
      final failed = _evaluate(
        pollen: const SourceSnapshot<PollenAnalysisModel>(
          problem:
              'Оценка пыльцы сейчас недоступна. Обычная навигация работает.',
          failed: true,
        ),
      );
      expect(
        _reportFor(failed, RecommendationFactor.pollen).availability,
        RecommendationSourceAvailability.failed,
      );
      expect(
        _reportFor(failed, RecommendationFactor.pollen).message,
        contains('Обычная навигация работает'),
      );

      final missing = _evaluate(
        puddle: const SourceSnapshot<PuddleAnalysisModel>(
          problem: 'оценка мокрых участков не подключена в этой сборке.',
        ),
      );
      expect(
        _reportFor(missing, RecommendationFactor.puddle).availability,
        RecommendationSourceAvailability.unavailable,
      );
    });

    test('a rebuilding session has its own reason', () {
      final context = _evaluate(sessionRebuilding: true);
      for (final factor in [
        RecommendationFactor.shade,
        RecommendationFactor.puddle,
        RecommendationFactor.pollen,
      ]) {
        final report = _reportFor(context, factor);
        expect(
          report.availability,
          RecommendationSourceAvailability.unavailable,
        );
        expect(report.message, contains('идёт перестроение маршрута'));
      }
    });
  });

  group('scenic participation (ТЗ §4.4)', () {
    const comparison = RouteComparison(
      normalWalkingSeconds: 600,
      scenicWalkingSeconds: 780,
      normalDistanceMeters: 800,
      scenicDistanceMeters: 950,
      stopCount: 3,
      benefitLines: ['Проходит по набережной реки Мойки'],
    );

    test('a requested and received comparison participates in planning', () {
      final context = _evaluate(
        scenic: const ScenicSnapshot(
          comparison: comparison,
          requested: true,
          datasetVersion: 'scenic-spb-2026-04',
        ),
      );
      expect(context.scenicComparison, isNotNull);
      expect(_ids(context), ['scenic.comparison']);
    });

    test(
      'mid-walk the comparison is not a recommendation about the path ahead',
      () {
        final context = _evaluate(
          navigating: true,
          scenic: const ScenicSnapshot(comparison: comparison, requested: true),
        );
        expect(context.scenicComparison, isNull);
        expect(_ids(context), isEmpty);
        expect(
          context.sources.map((report) => report.factor),
          isNot(contains(RecommendationFactor.scenic)),
          reason: 'живописность молчит, когда оценивается путь впереди',
        );
        expect(context.sources.map((report) => report.factor), [
          RecommendationFactor.shade,
          RecommendationFactor.puddle,
          RecommendationFactor.pollen,
        ]);
      },
    );

    test('a walk that never asked for scenic mentions nothing', () {
      final context = _evaluate();
      expect(_ids(context), isEmpty);
      expect(
        context.sources.map((report) => report.factor),
        isNot(contains(RecommendationFactor.scenic)),
      );
    });

    test('a requested but not yet received comparison is reported as such', () {
      final context = _evaluate(scenic: const ScenicSnapshot(requested: true));
      final report = _reportFor(context, RecommendationFactor.scenic);
      expect(report.availability, RecommendationSourceAvailability.notAssessed);
      expect(report.message, contains('результат его проверки ещё не получен'));
    });

    test('the fallback message becomes the honest explanation', () {
      final context = _evaluate(
        scenic: const ScenicSnapshot(
          requested: true,
          fallbackMessage:
              'Найденные варианты не прошли все условия проверки. '
              'Построен обычный пешеходный маршрут.',
        ),
      );
      expect(context.scenicFallbackMessage, isNotNull);
      expect(_ids(context), ['scenic.fallback']);
      // The factor contributed an entry, so it is not also reported as absent.
      expect(
        context.sources.map((report) => report.factor),
        isNot(contains(RecommendationFactor.scenic)),
      );
    });
  });

  group('context edges', () {
    test('without a route there is no recommendation context at all', () {
      final context = _evaluate(hasRoute: false, shade: _shade());
      expect(context.hasRoute, isFalse);
      expect(context.isEmpty, isTrue);
      expect(context.sources, isEmpty);
      expect(_engine.build(context), isEmpty);
    });

    test('the report order is documented and stable', () {
      final context = _evaluate(
        shade: const SourceSnapshot<ShadeAnalysisModel>(
          problem: 'оценка тени недоступна.',
        ),
        scenic: const ScenicSnapshot(requested: true),
      );
      expect(context.sources.map((report) => report.factor).toList(), [
        RecommendationFactor.shade,
        RecommendationFactor.puddle,
        RecommendationFactor.pollen,
        RecommendationFactor.scenic,
      ]);
    });

    test('every report carries a complete Russian sentence', () {
      final context = _evaluate(
        navigating: true,
        puddle: _puddle(scope: RecommendationScope.wholeWalk),
        pollen: _pollen(),
      );
      for (final report in context.sources) {
        expect(report.message, isNotEmpty);
        expect(
          report.message.trim().endsWith('.'),
          isTrue,
          reason: report.message,
        );
        expect(report.message, contains(':'), reason: report.message);
      }
    });
  });
}
