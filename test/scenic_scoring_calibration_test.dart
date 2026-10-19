import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/scenic_walk_engine.dart';

/// Phase C4/C5 runtime fixes §6.1 — scoring calibration.
///
/// Documents the deterministic model
///   score = benefitWeight × typeWeight × confidence × coverageShare
///         − penaltyPerExtraMinute × max(0, extraMinutes)
///         − uncertaintyPenaltyWeight × (1 − confidence)
/// and its control set, proves the pre-fix defect (with the historical
/// penalty 0.8 any detour from ≈2 minutes is mathematically unaccept­able at
/// ANY coverage), and pins the rebalanced coefficient against the control
/// examples. Hard limits (distance share, extra-minute cap, whole-walk
/// budget, coverage bands) stay untouched and are asserted separately.
const historical = ScenicScoringConfig(penaltyPerExtraMinute: 0.8);
const current = ScenicScoringConfig();

double _score(ScenicScoringConfig config, ScenicFeature feature,
        {required double coverage, required double extraMinutes}) =>
    ScenicWalkEngine(
      routeService: _StraightFake(),
      datasetFeatures: const [],
      config: config,
    ).score(feature: feature, coverageShare: coverage, extraMinutes: extraMinutes);

ScenicFeature _feature({
  ScenicFeatureType type = ScenicFeatureType.embankment,
  double confidence = 0.9,
}) =>
    ScenicFeature(
      id: 'calibration',
      type: type,
      name: 'Набережная контрольной реки',
      district: 'central',
      districtLabel: 'Центральный район',
      waypoint: const GeoCoord(60.0000, 30.0),
      line: const [GeoCoord(60.0, 30.0), GeoCoord(60.001, 30.0)],
      extentMeters: 400,
      osmUrl: 'https://www.openstreetmap.org/way/1',
      accessEvidence: '{"highway":"footway"}',
      verifiedOn: '2026-10-11',
      confidence: confidence,
      uncertainty: 'Контрольный пример',
    );

/// Straight two-point-per-step geometry through the requested points so the
/// junction coordinates are exact (the merge policy is not under test here).
class _StraightFake implements BasePedestrianRouteService {
  _StraightFake({this.callDurations = const [60, 60]});
  final List<int> callDurations;
  int calls = 0;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    final from = GeoCoord(startPoint.latitude, startPoint.longitude);
    final to = GeoCoord(destinationPoint.latitude, destinationPoint.longitude);
    final steps = <GeoCoord>[
      for (var i = 0; i <= 8; i++)
        GeoCoord(
          from.latitude + (to.latitude - from.latitude) * i / 8,
          from.longitude + (to.longitude - from.longitude) * i / 8,
        ),
    ];
    final seconds =
        callDurations[calls % callDurations.length].clamp(1, 1 << 30);
    calls++;
    final leg = RouteLegModel(
      fromTitle: startPoint.title,
      toTitle: destinationPoint.title,
      distanceMeters: RouteProjectionUtils.polylineLengthMeters(steps),
      durationSeconds: seconds,
      geometryPoints: steps,
    );
    return PedestrianRouteModel(
      distanceMeters: leg.distanceMeters,
      durationSeconds: leg.durationSeconds,
      geometryPoints: leg.geometryPoints,
      steps: const [],
      legs: [leg],
      placesCount: 1,
    );
  }

  @override
  void cancel() {}
}

void main() {
  group('Scoring calibration: the pre-fix penalty made moderate detours '
      'mathematically impossible (§6 reproduced)', () {
    test('historical 0.8/min: a 1-minute detour fails at realistic coverage',
        () {
      final feature = _feature(); // embankment, confidence 0.9
      final score = _score(historical, feature, coverage: 0.5, extraMinutes: 1);
      // 2.0·0.95·0.9·0.5 − 0.8·1 − 1.0·0.1 = −0.045
      expect(score, closeTo(-0.045, 0.001));
      expect(score, lessThan(historical.acceptanceThreshold),
          reason: 'the historical model rejected the textbook example');
    });

    test('historical 0.8/min: from ≈2 minutes NO coverage can ever pass', () {
      final bestFeature = _feature(confidence: 0.95);
      // Maximum achievable benefit: benefitWeight × 0.95 × 0.95 × cov(≤1).
      const maxBenefit = 2.0 * 0.95 * 0.95 * 1.0; // 1.805
      final atTwoMinutes = _score(historical, bestFeature,
          coverage: 1.0, extraMinutes: 2);
      expect(atTwoMinutes, closeTo(maxBenefit - 1.6 - 0.05, 0.001));
      expect(atTwoMinutes, lessThan(historical.acceptanceThreshold));
      // Generalised defect: for the strongest dataset feature (confidence
      // 0.95) the acceptance inequality has no solution for extra ≥ 2 min.
      expect(
        (historical.acceptanceThreshold +
                0.8 * 2 +
                historical.uncertaintyPenaltyWeight * 0.05) /
            maxBenefit,
        greaterThan(1.0),
        reason: 'required coverage share exceeds 100% at 2 extra minutes',
      );
    });

    test('historical 0.8/min: a 3-minute detour needs coverage > 1 even on '
        'the strongest embankment at maximum confidence', () {
      final required = (historical.acceptanceThreshold +
              0.8 * 3 +
              historical.uncertaintyPenaltyWeight * 0.05) /
          (2.0 * 0.95 * 0.95);
      expect(required, greaterThan(1.0));
    });
  });

  group('Scoring calibration: rebalanced control set (§6.1)', () {
    // Control examples from §6.1 with exact expected scores under the
    // current (rebalanced) coefficients.
    final embankment09 = _feature(); // 0.95 × 0.9
    final street09 = _feature(type: ScenicFeatureType.pedestrianStreet);
    final square08 =
        _feature(type: ScenicFeatureType.square, confidence: 0.8);

    test('quality embankment, 1-minute detour: accepted with real engagement',
        () {
      final score = _score(current, embankment09,
          coverage: 0.5, extraMinutes: 1);
      // 2.0·0.95·0.9·0.5 − 0.2 − 0.1 = 0.555
      expect(score, closeTo(0.555, 0.001));
      expect(score, greaterThanOrEqualTo(current.acceptanceThreshold));
    });

    test('pedestrian street, 2-minute detour: accepted', () {
      final score = _score(current, street09,
          coverage: 0.5, extraMinutes: 2);
      // 2.0·0.85·0.9·0.5 − 0.4 − 0.1 = 0.265
      expect(score, closeTo(0.265, 0.001));
      expect(score, greaterThanOrEqualTo(current.acceptanceThreshold));
    });

    test('square, 3-minute detour: accepted only with strong engagement', () {
      final weak = _score(current, square08, coverage: 0.5, extraMinutes: 3);
      // 2.0·0.75·0.8·0.5 − 0.6 − 0.2 = −0.2
      expect(weak, closeTo(-0.2, 0.001));
      expect(weak, lessThan(current.acceptanceThreshold));
      final strong = _score(current, square08, coverage: 0.9, extraMinutes: 3);
      // 1.08 − 0.6 − 0.2 = 0.28
      expect(strong, closeTo(0.28, 0.001));
      expect(strong, greaterThanOrEqualTo(current.acceptanceThreshold));
    });

    test('long detours (10 and 15 minutes) never pass, even in the best case',
        () {
      final best = _feature(confidence: 0.95);
      for (final minutes in [10.0, 15.0]) {
        final score = _score(current, best,
            coverage: 1.0, extraMinutes: minutes);
        expect(score, lessThan(current.acceptanceThreshold),
            reason: '$minutes min detour must not pass');
        expect(score, lessThan(0));
      }
    });

    test('low confidence and thin coverage stay rejected', () {
      final lowConfidence = _score(current, square08,
          coverage: 0.3, extraMinutes: 0);
      // 0.36 − 0 − 0.2 = 0.16
      expect(lowConfidence, closeTo(0.16, 0.001));
      expect(lowConfidence, lessThan(current.acceptanceThreshold));
      final thinCoverage = _score(current, embankment09,
          coverage: 0.25, extraMinutes: 0);
      // 0.4275 − 0.1 = 0.3275 — above threshold but below the on-path band;
      // the coverage band gate (tested in the engine suite) is what keeps it
      // honest, not the score alone.
      expect(thinCoverage, closeTo(0.3275, 0.001));
    });

    test('ordering: more engagement wins over a slightly shorter detour', () {
      final engaged = _score(current, embankment09,
          coverage: 0.9, extraMinutes: 2);
      final shorter = _score(current, embankment09,
          coverage: 0.6, extraMinutes: 0.5);
      expect(engaged, greaterThan(shorter));
    });
  });

  group('Scoring calibration: end-to-end decision through the engine', () {
    // 417 m stage; the feature line covers the first 60% of it plus the 60 m
    // proximity band. Waypoint at t=0.4 (~167 m from the start, ~250 m from
    // the end — outside the 150 m waypoint separation band).
    const a = GeoCoord(60.0, 30.0);
    const b = GeoCoord(60.0, 30.0075);
    const w = GeoCoord(60.0, 30.003);

    ScenicFeature lineFeature() => const ScenicFeature(
          id: 'calibration-line',
          type: ScenicFeatureType.embankment,
          name: 'Набережная контрольной реки',
          district: 'central',
          districtLabel: 'Центральный район',
          waypoint: w,
          line: [a, GeoCoord(60.0, 30.0045)],
          extentMeters: 250,
          osmUrl: 'https://www.openstreetmap.org/way/1',
          accessEvidence: '{"highway":"footway"}',
          verifiedOn: '2026-10-11',
          confidence: 0.9,
          uncertainty: 'Контрольный пример',
        );

    PedestrianRouteModel normalRoute() {
      final steps = <GeoCoord>[
        for (var i = 0; i <= 8; i++)
          GeoCoord(a.latitude, a.longitude + (b.longitude - a.longitude) * i / 8),
      ];
      final leg = RouteLegModel(
        fromTitle: 'Старт',
        toTitle: 'POI 1',
        distanceMeters: RouteProjectionUtils.polylineLengthMeters(steps),
        durationSeconds: 300,
        geometryPoints: steps,
      );
      return PedestrianRouteModel(
        distanceMeters: leg.distanceMeters,
        durationSeconds: leg.durationSeconds,
        geometryPoints: leg.geometryPoints,
        steps: const [],
        legs: [leg],
        placesCount: 1,
      );
    }

    /// Scenic legs 195 s + 195 s vs the 300 s normal stage: a controlled
    /// +1.5-minute detour at ~0.71 measured coverage.
    Future<ScenicEnhancementResult> run(ScenicScoringConfig config) {
      final service = _StraightFake(callDurations: const [195, 195]);
      return ScenicWalkEngine(
        routeService: service,
        datasetFeatures: [lineFeature()],
        config: config,
      ).enhance(
        normalRoute: normalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
    }

    test('a 1.5-minute detour over an honest embankment is accepted by the '
        'rebalanced model', () async {
      final result = await run(current);
      expect(result.isScenic, isTrue);
      final scenic = result.route!.legs.single.scenic!;
      expect(scenic.coverageShare, greaterThanOrEqualTo(0.6));
      expect(scenic.extraSeconds, 90);
      expect(scenic.evidence.name, 'verifiedOnPath');
    });

    test('the same real scenario is rejected by the historical model — the '
        'reproduced defect', () async {
      final result = await run(historical);
      expect(result.isScenic, isFalse);
      // Rejected at the score gate: 1.71·0.71 − 0.8·1.5 − 0.1 = −0.093.
      expect(result.fallbackReason, ScenicFallbackReason.insufficientBenefit);
      expect(result.stats.candidatesConsidered, 1);
    });
  });

  test('documented coefficients of the current model', () {
    expect(current.benefitWeight, 2.0);
    expect(current.penaltyPerExtraMinute, 0.2);
    expect(current.uncertaintyPenaltyWeight, 1.0);
    expect(current.acceptanceThreshold, 0.25);
    // Hard limits unchanged (§6 preservation list).
    expect(current.maxDetourShare, 1.6);
    expect(current.maxExtraMinutes, 15);
    expect(current.verifiedOnPathShare, 0.5);
    expect(current.verifiedNearbyShare, 0.15);
    expect(current.minCoverageShare, 0.1);
    expect(current.featureProximityMeters, 60);
    expect(current.maxCandidateCorridorMeters, 400);
    expect(current.minWaypointSeparationMeters, 150);
  });
}
