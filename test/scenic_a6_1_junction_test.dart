import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/scenic_diagnostics.dart';
import 'package:smart_navigator_spb/services/scenic_stage_builder.dart';
import 'package:smart_navigator_spb/services/scenic_walk_engine.dart';

const _a = GeoCoord(60, 30);
const _b = GeoCoord(60, 30.01);

GeoCoord _north(GeoCoord point, double meters) =>
    GeoCoord(point.latitude + meters / 111320, point.longitude);

bool _same(GeoCoord a, GeoCoord b) => ScenicStageBuilder.sameCoordinate(a, b);

ScenicFeature _feature(
  String id,
  double longitude, {
  ScenicFeatureType type = ScenicFeatureType.embankment,
  double confidence = 0.9,
}) => ScenicFeature(
  id: id,
  type: type,
  name: id,
  district: 'test',
  districtLabel: 'Test',
  waypoint: GeoCoord(60, longitude),
  line: const [_a, _b],
  extentMeters: 560,
  osmUrl: 'https://www.openstreetmap.org/way/1',
  accessEvidence: 'highway=pedestrian',
  verifiedOn: '2026-10-16',
  confidence: confidence,
  uncertainty: '',
);

PedestrianRouteModel _route(
  List<GeoCoord> points,
  int seconds, {
  double? meters,
}) {
  final distance = meters ?? RouteProjectionUtils.polylineLengthMeters(points);
  final leg = RouteLegModel(
    fromTitle: 'A',
    toTitle: 'B',
    distanceMeters: distance,
    durationSeconds: seconds,
    geometryPoints: points,
    visitMinutes: 10,
  );
  return PedestrianRouteModel(
    distanceMeters: distance,
    durationSeconds: seconds,
    geometryPoints: points,
    steps: const [],
    legs: [leg],
  );
}

enum _Connector {
  exact,
  collapsed,
  invalidEndpoint,
  shiftedEndpoint,
  farEndpoint,
  tooLong,
}

class _NativeFake implements BasePedestrianRouteService {
  _NativeFake(
    this.features, {
    this.snapped = const {},
    this.connectorSeconds = 2,
    this.connector = _Connector.exact,
    this.collapsedMeters = 0,
    this.featureSeconds = const {},
    this.snapMeters = 1.3,
  });

  final List<ScenicFeature> features;
  final Set<String> snapped;
  final int connectorSeconds;
  final _Connector connector;
  final double collapsedMeters;
  final Map<String, int> featureSeconds;
  final double snapMeters;
  int calls = 0;
  int connectorCalls = 0;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    calls++;
    final start = GeoCoord(startPoint.latitude, startPoint.longitude);
    final end = GeoCoord(destinationPoint.latitude, destinationPoint.longitude);
    for (final feature in features) {
      if (_same(end, feature.waypoint)) {
        return _route([start, end], featureSeconds[feature.id] ?? 300);
      }
      if (_same(start, feature.waypoint) && _same(end, _b)) {
        return _route([
          snapped.contains(feature.id) ? _north(start, snapMeters) : start,
          end,
        ], featureSeconds[feature.id] ?? 300);
      }
    }
    connectorCalls++;
    switch (connector) {
      case _Connector.exact:
        return _route([start, end], connectorSeconds);
      case _Connector.collapsed:
        final middle = GeoCoord(
          (start.latitude + end.latitude) / 2,
          (start.longitude + end.longitude) / 2,
        );
        return _route([middle, middle], 0, meters: collapsedMeters);
      case _Connector.invalidEndpoint:
        return _route(
          [GeoCoord(double.nan, start.longitude), end],
          1,
          meters: 1,
        );
      case _Connector.farEndpoint:
        return _route([_north(start, 3), _north(end, 3)], 2);
      case _Connector.shiftedEndpoint:
        return _route([_north(start, 0.4), _north(end, 0.4)], 2);
      case _Connector.tooLong:
        return _route([start, _north(start, 20), end], 30);
    }
  }

  @override
  void cancel() {}
}

Future<ScenicEnhancementResult> _enhance(
  _NativeFake service, {
  NativeWalkRequestBudget? budget,
}) =>
    ScenicWalkEngine(
      routeService: service,
      datasetFeatures: service.features,
      config: const ScenicScoringConfig(maxWaypointsPerStage: 1),
    ).enhance(
      normalRoute: _route(const [_a, _b], 600),
      walkBudgetSeconds: 3600,
      requestBudget: budget ?? NativeWalkRequestBudget(12),
      diagnosticsContext: ScenicAttemptContext(
        visitSeconds: 600,
        presetBudgetSeconds: 4200,
        datasetVersion: 'a6-1-junction-controlled',
        datasetFeaturesCount: service.features.length,
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

  test(
    'best final score wins after a native connector changes the ranking',
    () async {
      final service = _NativeFake(
        [
          _feature('initial-best', 30.004),
          _feature(
            'final-best',
            30.006,
            type: ScenicFeatureType.pedestrianStreet,
          ),
        ],
        snapped: {'initial-best'},
        connectorSeconds: 300,
      );
      final result = await _enhance(service);
      expect(result.isScenic, isTrue);
      expect(result.route!.legs.single.scenic!.featureIds, ['final-best']);
      expect(result.route!.durationSeconds, 600);
      expect(service.calls, lessThanOrEqualTo(12));
    },
  );

  test(
    'an exact alternative avoids a connector that cannot improve the score',
    () async {
      final service = _NativeFake(
        [
          _feature('exact-best', 30.004),
          _feature('weaker-snapped', 30.006, confidence: 0.8),
        ],
        snapped: {'weaker-snapped'},
      );
      final result = await _enhance(service);
      expect(result.route!.legs.single.scenic!.featureIds, ['exact-best']);
      expect(service.connectorCalls, 0);
      expect(service.calls, 4);
    },
  );

  test(
    'an ineligible junction reserves no requests against an exact alternative',
    () async {
      final service = _NativeFake(
        [
          _feature('ineligible', 30.004),
          _feature(
            'exact-alternative',
            30.006,
            type: ScenicFeatureType.pedestrianStreet,
          ),
        ],
        snapped: {'ineligible'},
        snapMeters: 5.6,
      );
      final budget = NativeWalkRequestBudget(12);
      for (var i = 0; i < 8; i++) {
        budget.consume();
      }
      final result = await _enhance(service, budget: budget);
      expect(result.isScenic, isTrue);
      expect(result.route!.legs.single.scenic!.featureIds, [
        'exact-alternative',
      ]);
      expect(service.connectorCalls, 0);
      expect(budget.requests, 12);
    },
  );

  test(
    'candidate pairs leave enough request budget to confirm a viable chain',
    () async {
      final service = _NativeFake(
        [
          _feature('first', 30.004),
          _feature('second', 30.006),
          _feature('third', 30.007),
        ],
        snapped: {'first', 'second', 'third'},
      );
      final budget = NativeWalkRequestBudget(12);
      for (var i = 0; i < 6; i++) {
        budget.consume();
      }
      final result = await _enhance(service, budget: budget);
      expect(result.isScenic, isTrue);
      expect(service.connectorCalls, greaterThanOrEqualTo(1));
      expect(service.calls, lessThanOrEqualTo(6));
      expect(budget.requests, lessThanOrEqualTo(12));
    },
  );

  test(
    'an assembled exact alternative survives later connector budget exhaustion',
    () async {
      final service = _NativeFake(
        [
          _feature('exact-fallback', 30.004),
          _feature(
            'snapped-higher-score',
            30.006,
            type: ScenicFeatureType.pedestrianStreet,
          ),
        ],
        snapped: {'snapped-higher-score'},
        featureSeconds: {'exact-fallback': 330},
      );
      final budget = NativeWalkRequestBudget(12);
      for (var i = 0; i < 8; i++) {
        budget.consume();
      }
      final result = await _enhance(service, budget: budget);
      expect(result.isScenic, isTrue);
      expect(result.route!.legs.single.scenic!.featureIds, ['exact-fallback']);
      expect(result.fallbackReason, ScenicFallbackReason.none);
      expect(budget.requests, lessThanOrEqualTo(12));
    },
  );

  for (final declaredMeters in [0.0, 1.0]) {
    test('a collapsed native connector cannot become an invented straight link '
        '(declared meters $declaredMeters)', () async {
      final service = _NativeFake(
        [_feature('snapped', 30.004)],
        snapped: {'snapped'},
        connector: _Connector.collapsed,
        collapsedMeters: declaredMeters,
      );
      final result = await _enhance(service);
      expect(service.connectorCalls, 1);
      expect(result.isScenic, isFalse);
      expect(
        ScenicDiagnostics.reports.single.rejectedCandidates.single.detail,
        contains('junctionConnector'),
      );
    });
  }

  test(
    'invalid connector endpoints cannot be hidden by endpoint pinning',
    () async {
      final service = _NativeFake(
        [_feature('snapped', 30.004)],
        snapped: {'snapped'},
        connector: _Connector.invalidEndpoint,
      );
      final result = await _enhance(service);
      expect(result.isScenic, isFalse);
    },
  );

  for (final answer in [
    _Connector.shiftedEndpoint,
    _Connector.farEndpoint,
    _Connector.tooLong,
  ]) {
    test(
      'native connector guard remains enforced for ${answer.name}',
      () async {
        final service = _NativeFake(
          [_feature('snapped', 30.004)],
          snapped: {'snapped'},
          connector: answer,
        );
        final result = await _enhance(service);
        expect(result.isScenic, isFalse);
        final detail =
            ScenicDiagnostics.reports.single.rejectedCandidates.single.detail;
        expect(
          detail,
          contains(
            answer == _Connector.tooLong
                ? 'junctionConnectorTooLong'
                : 'junctionConnectorEndpoints',
          ),
        );
      },
    );
  }

  test('a real native connector retains its duration and distance', () async {
    final service = _NativeFake(
      [_feature('snapped', 30.004)],
      snapped: {'snapped'},
      connectorSeconds: 7,
    );
    final result = await _enhance(service);
    expect(result.isScenic, isTrue);
    expect(result.route!.durationSeconds, 607);
    expect(result.route!.legs.single.visitMinutes, 10);
    expect(service.calls, 3);
  });

  test('combined maneuvers belong to the actual tourist stage index', () {
    final feature = _feature('stage', 30.004);
    final outcome = const ScenicStageBuilder().combineDetailed(
      segments: [
        RouteLegModel(
          fromTitle: 'A',
          toTitle: 'W',
          distanceMeters: 220,
          durationSeconds: 300,
          geometryPoints: [_a, feature.waypoint],
          maneuvers: const [
            PedestrianManeuverModel(
              kind: PedestrianManeuverKind.left,
              segmentIndex: 0,
              segmentPosition: 0.5,
              offsetMeters: 100,
            ),
          ],
        ),
        RouteLegModel(
          fromTitle: 'W',
          toTitle: 'B',
          distanceMeters: 330,
          durationSeconds: 300,
          geometryPoints: [feature.waypoint, _b],
          maneuvers: const [
            PedestrianManeuverModel(
              kind: PedestrianManeuverKind.right,
              segmentIndex: 0,
              segmentPosition: 0.5,
              offsetMeters: 100,
            ),
          ],
        ),
      ],
      legIndex: 2,
      scenic: const ScenicStageInfo(
        featureIds: ['stage'],
        featureNames: ['stage'],
        evidence: ScenicEvidenceLevel.verifiedOnPath,
        coverageShare: 1,
        extraSeconds: 0,
        extraMeters: 0,
        score: 1.61,
        explanation: 'stage',
      ),
      junctionWaypoints: [feature.waypoint],
    );
    expect(outcome.ok, isTrue);
    expect(outcome.leg!.maneuvers.map((maneuver) => maneuver.legIndex), [2, 2]);
  });
}
