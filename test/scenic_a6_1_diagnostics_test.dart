import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/scenic_diagnostics.dart';
import 'package:smart_navigator_spb/services/scenic_walk_engine.dart';

const _start = GeoCoord(60, 30);
const _waypoint = GeoCoord(60.0025, 30);
const _end = GeoCoord(60.005, 30);

ScenicFeature _feature(String id, {double confidence = 0.4}) => ScenicFeature(
  id: id,
  type: ScenicFeatureType.square,
  name: 'Контрольный участок $id',
  district: 'test',
  districtLabel: 'Контрольный район',
  waypoint: _waypoint,
  line: const [_start, _end],
  extentMeters: 556,
  osmUrl: 'https://www.openstreetmap.org/way/1',
  accessEvidence: '{"highway":"pedestrian"}',
  verifiedOn: '2026-10-11',
  confidence: confidence,
  uncertainty: 'Детерминированная тестовая геометрия',
);

PedestrianRouteModel _route(RouteLegModel leg) => PedestrianRouteModel(
  distanceMeters: leg.distanceMeters,
  durationSeconds: leg.durationSeconds,
  geometryPoints: leg.geometryPoints,
  steps: const [],
  legs: [leg],
  placesCount: 1,
);

PedestrianRouteModel _normal() => _route(
  RouteLegModel(
    fromTitle: 'Старт',
    toTitle: 'Остановка',
    distanceMeters: RouteProjectionUtils.polylineLengthMeters(const [
      _start,
      _end,
    ]),
    durationSeconds: 400,
    geometryPoints: const [_start, _end],
  ),
);

enum _Reply { valid, failure, noLeg, unusableLeg }

class _FakeNativeRoutes implements BasePedestrianRouteService {
  _FakeNativeRoutes({this.replies = const [], this.seconds = const []});

  final List<_Reply> replies;
  final List<int> seconds;
  int calls = 0;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    final index = calls++;
    final reply = index < replies.length ? replies[index] : _Reply.valid;
    if (reply == _Reply.failure) {
      throw const RouteCalculationFailure(RouteFailureKind.serviceUnavailable);
    }
    if (reply == _Reply.noLeg) {
      return const PedestrianRouteModel(
        distanceMeters: 0,
        durationSeconds: 0,
        geometryPoints: [],
        steps: [],
        legs: [],
        placesCount: 1,
      );
    }
    final from = GeoCoord(startPoint.latitude, startPoint.longitude);
    final to = GeoCoord(destinationPoint.latitude, destinationPoint.longitude);
    final geometry = reply == _Reply.unusableLeg ? [from] : [from, to];
    return _route(
      RouteLegModel(
        fromTitle: startPoint.title,
        toTitle: destinationPoint.title,
        distanceMeters: RouteProjectionUtils.polylineLengthMeters(geometry),
        durationSeconds: index < seconds.length ? seconds[index] : 200,
        geometryPoints: geometry,
      ),
    );
  }

  @override
  void cancel() {}
}

Future<ScenicEnhancementResult> _enhance(
  _FakeNativeRoutes service,
  List<ScenicFeature> features, {
  NativeWalkRequestBudget? requestBudget,
}) =>
    ScenicWalkEngine(
      routeService: service,
      datasetFeatures: features,
      config: const ScenicScoringConfig(maxWaypointsPerStage: 1),
    ).enhance(
      normalRoute: _normal(),
      walkBudgetSeconds: 3600,
      requestBudget: requestBudget ?? NativeWalkRequestBudget(12),
      diagnosticsContext: const ScenicAttemptContext(
        visitSeconds: 0,
        presetBudgetSeconds: 3600,
        datasetVersion: 'controlled-test',
        datasetFeaturesCount: 2,
      ),
    );

void main() {
  setUp(() {
    ScenicDiagnostics.enabled = true;
    ScenicDiagnostics.clear();
  });
  tearDown(() {
    ScenicDiagnostics.enabled = false;
    ScenicDiagnostics.clear();
  });

  test('diagnostics flag follows the compiled debug-mode boundary', () async {
    ScenicDiagnostics.enabled = true;
    expect(ScenicDiagnostics.enabled, kDebugMode);
    await _enhance(_FakeNativeRoutes(), [_feature('build-mode')]);
    expect(ScenicDiagnostics.reports, kDebugMode ? hasLength(1) : isEmpty);
  });

  test(
    'verified geometry rejected only by score has an honest fallback',
    () async {
      final result = await _enhance(_FakeNativeRoutes(), [_feature('score')]);
      final report = ScenicDiagnostics.reports.single;
      expect(report.rejectionCounts, {ScenicRejectionCategory.score: 1});
      expect(report.rejectedCandidates.single.coverageShare, closeTo(1, 1e-9));
      expect(result.fallbackReason.name, 'insufficientBenefit');
      expect(
        scenicFallbackReasonText(result.fallbackReason),
        contains('преимуществ'),
      );
      expect(
        scenicFallbackReasonText(result.fallbackReason),
        isNot(contains('подтвердить')),
      );
    },
  );

  test(
    'a native failure plus a score rejection reports mixed obstacles',
    () async {
      final service = _FakeNativeRoutes(replies: const [_Reply.failure]);
      final result = await _enhance(service, [
        _feature('failed', confidence: 0.4),
        _feature('scored', confidence: 0.3),
      ]);
      final report = ScenicDiagnostics.reports.single;
      expect(service.calls, 3);
      expect(report.rejectionCounts, {
        ScenicRejectionCategory.mapkitUnavailable: 1,
        ScenicRejectionCategory.score: 1,
      });
      expect(result.fallbackReason.name, 'mixedRejections');
      expect(report.candidatesNativeRouted, 1);
    },
  );

  test(
    'time limit plus a score rejection is not solely a duration failure',
    () async {
      final service = _FakeNativeRoutes(seconds: const [1000, 1000, 200, 200]);
      final result = await _enhance(service, [
        _feature('over-time', confidence: 0.4),
        _feature('score', confidence: 0.3),
      ]);
      expect(ScenicDiagnostics.reports.single.rejectionCounts, {
        ScenicRejectionCategory.walkingBudget: 1,
        ScenicRejectionCategory.score: 1,
      });
      expect(result.fallbackReason.name, 'mixedRejections');
    },
  );

  test(
    'score rejection plus untested candidates reports request starvation',
    () async {
      final budget = NativeWalkRequestBudget(12);
      for (var i = 0; i < 10; i++) {
        budget.consume();
      }
      final service = _FakeNativeRoutes();
      final result = await _enhance(service, [
        _feature('score', confidence: 0.4),
        _feature('not-tested', confidence: 0.3),
      ], requestBudget: budget);
      final report = ScenicDiagnostics.reports.single;
      expect(report.rejectionCounts, {
        ScenicRejectionCategory.score: 1,
        ScenicRejectionCategory.requestBudget: 1,
      });
      expect(result.fallbackReason.name, 'mixedRejections');
      expect(report.nativeRequestsUsedBeforeScenic, 10);
      expect(report.nativeRequestsUsedAfterScenic, 12);
      expect(service.calls, 2);
    },
  );

  for (final replies in <List<_Reply>>[
    [_Reply.failure],
    [_Reply.valid, _Reply.failure],
    [_Reply.noLeg, _Reply.valid],
    [_Reply.valid, _Reply.unusableLeg],
  ]) {
    test(
      'unusable native pair $replies is not counted as native routed',
      () async {
        final service = _FakeNativeRoutes(replies: replies);
        final result = await _enhance(service, [_feature('unusable')]);
        final report = ScenicDiagnostics.reports.single;
        expect(result.fallbackReason, ScenicFallbackReason.mapkitUnavailable);
        expect(report.candidatesConsidered, 1);
        expect(report.candidatesNativeRouted, 0);
        expect(
          report.nativeRequestsUsedAfterScenic,
          2,
          reason: 'conservative two-request reservation stays unchanged',
        );
        expect(service.calls, replies.length == 1 ? 1 : 2);
      },
    );
  }
}
