import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/scenic_diagnostics.dart';
import 'package:smart_navigator_spb/services/scenic_walk_engine.dart';

// Controlled native answers test accounting, never SDK walkability.
const _a = GeoCoord(60, 30);
const _b = GeoCoord(60.012, 30);
const _w1 = GeoCoord(60.004, 30);
const _w2 = GeoCoord(60.008, 30);

ScenicFeature _feature(
  String id,
  GeoCoord waypoint, {
  List<GeoCoord> line = const [_a, _b],
}) => ScenicFeature(
  id: id,
  type: ScenicFeatureType.embankment,
  name: id,
  district: 'central',
  districtLabel: 'Центральный район',
  waypoint: waypoint,
  line: line,
  extentMeters: 1300,
  osmUrl: 'https://www.openstreetmap.org/way/1',
  accessEvidence: '{"highway":"footway"}',
  verifiedOn: '2026-10-11',
  confidence: 0.9,
  uncertainty: 'Controlled fixture',
);

PedestrianRouteModel _normal({double meters = 1350, int seconds = 600}) {
  final leg = RouteLegModel(
    fromTitle: 'Start',
    toTitle: 'Stop',
    distanceMeters: meters,
    durationSeconds: seconds,
    geometryPoints: const [_a, _w1, _w2, _b],
    visitMinutes: 30,
  );
  return PedestrianRouteModel(
    distanceMeters: meters,
    durationSeconds: seconds,
    geometryPoints: leg.geometryPoints,
    steps: const [],
    legs: [leg],
    placesCount: 1,
  );
}

class _NativeAnswers implements BasePedestrianRouteService {
  _NativeAnswers(this.meters, this.seconds);
  final List<double> meters;
  final List<int> seconds;
  int calls = 0;

  @override
  void cancel() {}

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    final index = calls++;
    final points = [
      GeoCoord(startPoint.latitude, startPoint.longitude),
      GeoCoord(destinationPoint.latitude, destinationPoint.longitude),
    ];
    final leg = RouteLegModel(
      fromTitle: startPoint.title,
      toTitle: destinationPoint.title,
      distanceMeters: meters[index],
      durationSeconds: seconds[index],
      geometryPoints: points,
    );
    return PedestrianRouteModel(
      distanceMeters: leg.distanceMeters,
      durationSeconds: leg.durationSeconds,
      geometryPoints: points,
      steps: const [],
      legs: [leg],
      placesCount: 1,
    );
  }
}

Future<ScenicEnhancementResult> _run(
  _NativeAnswers service, {
  ScenicScoringConfig config = const ScenicScoringConfig(
    maxCandidatesPerStep: 1,
    penaltyPerExtraMinute: 0, // Isolate the hard gates under test.
  ),
  List<ScenicFeature>? features,
  PedestrianRouteModel? normal,
  int walkingBudget = 10000,
}) =>
    ScenicWalkEngine(
      routeService: service,
      datasetFeatures: features ?? [_feature('a', _w1), _feature('b', _w2)],
      config: config,
    ).enhance(
      normalRoute: normal ?? _normal(),
      walkBudgetSeconds: walkingBudget,
      requestBudget: NativeWalkRequestBudget(12),
      diagnosticsContext: ScenicAttemptContext(
        visitSeconds: 1800,
        presetBudgetSeconds: walkingBudget + 1800,
        datasetVersion: 'controlled-native-answers',
        datasetFeaturesCount: features?.length ?? 2,
      ),
    );

void main() {
  setUp(() {
    ScenicDiagnostics.enabled = true;
    ScenicDiagnostics.clear();
  });
  tearDown(() => ScenicDiagnostics.enabled = false);

  test('a native scenic route shorter than normal remains eligible', () async {
    final result = await _run(
      _NativeAnswers([600, 700], [250, 250]),
      normal: _normal(meters: 1500),
      features: [_feature('shorter', _w1)],
      config: const ScenicScoringConfig(maxWaypointsPerStage: 1),
    );
    expect(result.isScenic, isTrue);
    expect(result.route!.distanceMeters, 1300);
    expect(result.route!.durationSeconds, 500);
    expect(result.route!.legs.single.visitMinutes, 30);
    expect(result.comparison!.extraDistanceMeters, -200);
    expect(result.comparison!.extraWalkingSeconds, -100);
  });

  test(
    'second insertion cannot compound the original stage distance cap',
    () async {
      final result = await _run(
        _NativeAnswers([600, 1200, 800, 800], [300, 300, 150, 150]),
      );
      expect(result.isScenic, isTrue);
      expect(result.route!.legs.single.scenic!.featureIds, ['a']);
      expect(result.route!.distanceMeters, 1800);
      expect(result.route!.distanceMeters, lessThanOrEqualTo(1350 * 1.6));
    },
  );

  test(
    'second insertion cannot reset the per-stage fifteen extra minutes',
    () async {
      final result = await _run(
        _NativeAnswers([450, 900, 450, 450], [400, 900, 800, 800]),
      );
      expect(result.isScenic, isTrue);
      expect(result.route!.legs.single.scenic!.featureIds, ['a']);
      expect(result.route!.durationSeconds, 1300);
      expect(result.route!.durationSeconds - 600, lessThanOrEqualTo(15 * 60));
    },
  );

  test('whole-walk budget includes earlier insertions and excludes visit allowance', () async {
    // 60-minute preset minus 30-minute visit = 1800 walking seconds.
    final result = await _run(
      _NativeAnswers([450, 900, 450, 450], [400, 900, 500, 1000]),
      walkingBudget: 1800,
    );
    expect(result.route!.legs.single.scenic!.featureIds, ['a']);
    expect(result.route!.durationSeconds + 30 * 60, lessThanOrEqualTo(3600));
  });

  test(
    'configured minimum coverage is applied as well as evidence bands',
    () async {
      final result = await _run(
        _NativeAnswers([450, 900], [300, 300]),
        features: [
          _feature('limited', _w1, line: const [_a, _w1]),
        ],
        config: const ScenicScoringConfig(
          minCoverageShare: 0.8,
          maxWaypointsPerStage: 1,
        ),
      );
      expect(result.isScenic, isFalse);
      expect(result.fallbackReason, ScenicFallbackReason.noVerifiedGeometry);
    },
  );

  test(
    'second insertion pays the score penalty for all stage extra minutes',
    () async {
      final result = await _run(
        _NativeAnswers([450, 900, 450, 450], [300, 600, 420, 420]),
        config: const ScenicScoringConfig(maxCandidatesPerStep: 1),
      );
      expect(result.route!.legs.single.scenic!.featureIds, ['a']);
      expect(result.route!.durationSeconds, 900);
      expect(
        result.route!.legs.single.scenic!.score,
        closeTo(0.61, 0.000001),
        reason: 'stored net score includes the five extra native minutes',
      );
      final rejected =
          ScenicDiagnostics.reports.single.rejectedCandidates.single;
      expect(rejected.category, ScenicRejectionCategory.score);
      expect(
        rejected.extraMinutes,
        9,
        reason: 'diagnostics must explain the same cumulative penalty as score',
      );
    },
  );

  for (final invalid in [-1.0, double.nan, double.infinity]) {
    test(
      'invalid native segment distance $invalid cannot become a shorter route',
      () async {
        final result = await _run(
          _NativeAnswers([invalid, 700], [250, 250]),
          features: [_feature('invalid', _w1)],
        );
        expect(result.isScenic, isFalse);
        expect(result.fallbackReason, ScenicFallbackReason.mapkitUnavailable);
      },
    );
  }

  test('negative native duration cannot become a shorter route', () async {
    final result = await _run(
      _NativeAnswers([600, 700], [-1, 250]),
      features: [_feature('invalid', _w1)],
    );
    expect(result.isScenic, isFalse);
    expect(result.fallbackReason, ScenicFallbackReason.mapkitUnavailable);
  });
}
