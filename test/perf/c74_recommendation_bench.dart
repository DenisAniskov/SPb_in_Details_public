// Phase C7.4 perf bench: the cost of one panel read (gate + rules).
//
// NOT part of the test suite: it is a manual benchmark, run explicitly with
//
//   flutter test test/perf/c74_recommendation_bench.dart
//
// It measures PROCESSING COST ONLY on a fully populated context (all four
// factors admitted). No network access, no widgets, no services: the engine
// and the gate are pure Dart, so this is exactly what a panel read costs.

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/services/context_recommendation_engine.dart';
import 'package:smart_navigator_spb/services/recommendation_context.dart';

import '../context_recommendation_fixtures.dart';

double medianMs(int iterations, void Function() work) {
  final samples = <double>[];
  for (var run = 0; run < 9; ++run) {
    final watch = Stopwatch()..start();
    for (var i = 0; i < iterations; ++i) {
      work();
    }
    watch.stop();
    samples.add(watch.elapsedMicroseconds / 1000 / iterations);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

void main() {
  test('panel read cost (gate + rules) on a fully populated context', () {
    final inputs = RecommendationInputs(
      hasRoute: true,
      navigating: false,
      preference: RecommendationPreference.all,
      clockModelTime: fixtureInstant,
      shade: SourceSnapshot<ShadeAnalysisModel>(
        facts: shadeFixture(),
        scope: RecommendationScope.wholeWalk,
        evaluatedFor: fixtureInstant,
        identityVerified: true,
      ),
      puddle: SourceSnapshot<PuddleAnalysisModel>(
        facts: puddleHighFixture(),
        scope: RecommendationScope.wholeWalk,
        evaluatedFor: fixtureInstant,
        identityVerified: true,
      ),
      pollen: SourceSnapshot<PollenAnalysisModel>(
        facts: pollenConcentrationsFixture(),
        scope: RecommendationScope.wholeWalk,
        evaluatedFor: fixtureInstant,
        identityVerified: true,
      ),
      scenic: const ScenicSnapshot(
        comparison: RouteComparison(
          normalWalkingSeconds: 600,
          scenicWalkingSeconds: 780,
          normalDistanceMeters: 800,
          scenicDistanceMeters: 950,
          stopCount: 3,
          benefitLines: ['Проходит по набережной реки Мойки'],
        ),
        requested: true,
        datasetVersion: 'scenic-spb-2026-04',
      ),
    );
    const gate = RecommendationContextGate();
    const engine = ContextRecommendationEngine();
    final context = gate.evaluate(inputs);
    expect(engine.build(context), hasLength(4));

    final gateMs = medianMs(2000, () => gate.evaluate(inputs));
    final rulesMs = medianMs(2000, () => engine.build(context));
    final readMs = medianMs(2000, () => engine.build(gate.evaluate(inputs)));

    // ignore: avoid_print
    print('gate.evaluate         : ${gateMs.toStringAsFixed(3)} ms');
    // ignore: avoid_print
    print('engine.build          : ${rulesMs.toStringAsFixed(3)} ms');
    // ignore: avoid_print
    print('one panel read (both) : ${readMs.toStringAsFixed(3)} ms');
  });
}
