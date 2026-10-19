import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/scenic/scenic_dataset.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/scenic_diagnostics.dart';
import 'package:smart_navigator_spb/services/scenic_walk_engine.dart';

// Deterministic public-coordinate geometry fixtures, never Android SDK traces.
GeoCoord _at(double east, [double north = 0]) => GeoCoord(
  60 + north / RouteProjectionUtils.earthRadiusMeters * 180 / math.pi,
  30 + east / RouteProjectionUtils.earthRadiusMeters * 180 / math.pi / 0.5,
);

bool _same(GeoCoord a, GeoCoord b) =>
    a.latitude == b.latitude && a.longitude == b.longitude;

PedestrianRouteModel _route(List<GeoCoord> geometry, {int seconds = 120}) {
  final distance = RouteProjectionUtils.polylineLengthMeters(geometry);
  return PedestrianRouteModel(
    distanceMeters: distance,
    durationSeconds: seconds,
    geometryPoints: geometry,
    steps: const [],
    placesCount: 1,
    legs: [
      RouteLegModel(
        fromTitle: 'Public fixture start',
        toTitle: 'Public fixture stop',
        distanceMeters: distance,
        durationSeconds: seconds,
        geometryPoints: geometry,
      ),
    ],
  );
}

/// Returns native-shaped legs along the frozen fixture. Requests for a point
/// absent from it fail, allowing the shortlist representative to be tested.
class _GeometryRouter implements BasePedestrianRouteService {
  _GeometryRouter(this.geometry);
  final List<GeoCoord> geometry;
  int calls = 0;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    calls++;
    final from = geometry.indexWhere(
      (p) =>
          p.latitude == startPoint.latitude &&
          p.longitude == startPoint.longitude,
    );
    final to = geometry.indexWhere(
      (p) =>
          p.latitude == destinationPoint.latitude &&
          p.longitude == destinationPoint.longitude,
    );
    if (from < 0 || to <= from) {
      throw const RouteCalculationFailure(RouteFailureKind.serviceUnavailable);
    }
    return _route(geometry.sublist(from, to + 1), seconds: 60);
  }

  @override
  void cancel() {}
}

ScenicFeature _feature({
  String id = 'coverage-fixture',
  String name = 'Public fixture embankment',
  GeoCoord? waypoint,
  required List<GeoCoord>? line,
}) => ScenicFeature(
  id: id,
  type: ScenicFeatureType.embankment,
  name: name,
  district: 'central',
  districtLabel: 'Центральный район',
  waypoint: waypoint ?? _at(500),
  line: line,
  extentMeters: 400,
  osmUrl: 'https://www.openstreetmap.org/way/1',
  verifiedOn: '2026-10-11',
  accessEvidence: '{"highway":"footway"}',
  confidence: 0.9,
  uncertainty: 'Controlled test fixture',
);

Future<ScenicEnhancementResult> _enhance(
  List<GeoCoord> geometry,
  List<ScenicFeature> features, {
  ScenicScoringConfig config = const ScenicScoringConfig(
    maxWaypointsPerStage: 1,
  ),
  _GeometryRouter? router,
}) =>
    ScenicWalkEngine(
      routeService: router ?? _GeometryRouter(geometry),
      datasetFeatures: features,
      config: config,
    ).enhance(
      normalRoute: _route(geometry),
      walkBudgetSeconds: 3600,
      requestBudget: NativeWalkRequestBudget(12),
      diagnosticsContext: ScenicAttemptContext(
        visitSeconds: 0,
        presetBudgetSeconds: 3600,
        datasetVersion: 'public-geometry-fixtures',
        datasetFeaturesCount: features.length,
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

  group('A6.1 length coverage', () {
    final feature = _feature(line: [_at(300), _at(700)]);

    test(
      'sparse geometry measures the covered length, including band ends',
      () async {
        final result = await _enhance([_at(0), _at(500), _at(1000)], [feature]);
        expect(result.isScenic, isTrue);
        // 400 m verified segment + a 60 m proximity band at each end.
        final scenic = result.route!.legs.single.scenic!;
        expect(scenic.coverageShare, closeTo(0.52, 0.00001));
        expect(scenic.evidence, ScenicEvidenceLevel.verifiedOnPath);
      },
    );

    test(
      'densifying only uncovered geometry preserves coverage and decision',
      () async {
        final sparse = [_at(0), _at(500), _at(1000)];
        final dense = [
          for (var i = 0; i < 100; i++) _at(i.toDouble()),
          _at(500),
          _at(1000),
        ];
        final first = await _enhance(sparse, [feature]);
        final second = await _enhance(dense, [feature]);
        expect(second.isScenic, isTrue);
        expect(
          second.route!.legs.single.scenic!.coverageShare,
          closeTo(first.route!.legs.single.scenic!.coverageShare, 0.00001),
        );
        expect(
          second.route!.legs.single.scenic!.score,
          closeTo(first.route!.legs.single.scenic!.score, 0.00001),
        );
      },
    );

    test(
      'densifying only covered geometry cannot create a scenic benefit',
      () async {
        final sparse = [_at(0), _at(500), _at(1000)];
        final dense = [
          _at(0),
          for (var i = 450; i <= 550; i++) _at(i.toDouble()),
          _at(1000),
        ];
        final pointFeature = _feature(line: null);
        for (final geometry in [sparse, dense]) {
          final result = await _enhance(geometry, [pointFeature]);
          expect(result.isScenic, isFalse);
          final rejection =
              ScenicDiagnostics.reports.last.rejectedCandidates.single;
          expect(rejection.category, ScenicRejectionCategory.coverage);
          expect(rejection.coverageShare, closeTo(0.12, 0.00001));
        }
      },
    );

    test(
      'overlapping feature segments and duplicate route vertices count once',
      () async {
        final result = await _enhance(
          [_at(0), _at(0), _at(500), _at(500), _at(1000)],
          [
            _feature(line: [_at(300), _at(700), _at(300), _at(700)]),
          ],
        );
        expect(result.isScenic, isTrue);
        expect(
          result.route!.legs.single.scenic!.coverageShare,
          closeTo(0.52, 0.00001),
        );
      },
    );

    test('a point tangent to the band has zero covered length', () async {
      final result = await _enhance(
        [_at(0), _at(500), _at(1000)],
        [
          _feature(line: [_at(500, 60), _at(500, 60)]),
        ],
      );
      expect(result.isScenic, isFalse);
      expect(
        ScenicDiagnostics.reports.last.rejectedCandidates.single.coverageShare,
        closeTo(0, 0.00001),
      );
    });

    test(
      'a parallel line just outside the band never covers route length',
      () async {
        final result = await _enhance(
          [_at(0), _at(500), _at(1000)],
          [
            _feature(line: [_at(0, 60.1), _at(1000, 60.1)]),
          ],
        );
        expect(result.isScenic, isFalse);
        expect(
          ScenicDiagnostics
              .reports
              .last
              .rejectedCandidates
              .single
              .coverageShare,
          0,
        );
      },
    );

    test(
      'short 320 m stage can engage a nearby verified way without retuning',
      () async {
        final result = await _enhance(
          [_at(0), _at(160), _at(320)],
          [
            _feature(waypoint: _at(160), line: [_at(120), _at(200)]),
          ],
        );
        expect(result.isScenic, isTrue);
        expect(
          result.route!.legs.single.scenic!.coverageShare,
          closeTo(0.625, 0.00001),
        );
      },
    );
  });

  group('A6.1 same-name shortlist representative', () {
    test(
      'nearest ranked representative wins regardless of dataset order',
      () async {
        final geometry = [_at(0), _at(500), _at(1000)];
        final close = _feature(id: 'close', line: [_at(300), _at(700)]);
        final far = _feature(
          id: 'far',
          waypoint: _at(500, 150),
          line: [_at(300, 150), _at(700, 150)],
        );
        for (final features in [
          [far, close],
          [close, far],
        ]) {
          final router = _GeometryRouter(geometry);
          final result = await _enhance(geometry, features, router: router);
          expect(result.isScenic, isTrue);
          expect(result.route!.legs.single.scenic!.featureIds, ['close']);
          expect(result.stats.candidatesConsidered, 1);
          expect(router.calls, 2);
          final report = ScenicDiagnostics.reports.last;
          expect(report.candidatesInCorridor, 2);
          expect(report.candidatesShortlisted, 1);
          expect(report.candidatesEndpointExcluded, 0);
          expect(report.candidatesNameDeduplicated, 1);
        }
      },
    );
  });

  group('A6.1 embedded public dataset scenarios', () {
    for (final id in [
      'spb-scenic-petrogradsky-way-189743484', // Карповка embankment.
      'spb-scenic-central-way-80166918', // 6-я линия В.О. pedestrian street.
      'spb-scenic-central-way-638200751', // площадь Ленина perimeter.
    ]) {
      test(
        '$id is accepted on controlled geometry along its verified way',
        () async {
          final feature = spbScenicDataset.features.singleWhere(
            (f) => f.id == id,
          );
          final line = feature.line!;
          final geometry = _same(line.first, line.last)
              ? line.sublist(0, line.length - 1)
              : line;
          expect(geometry.any((p) => _same(p, feature.waypoint)), isTrue);
          final result = await _enhance(geometry, [feature]);
          expect(result.isScenic, isTrue);
          final scenic = result.route!.legs.single.scenic!;
          expect(scenic.featureIds, [id]);
          expect(scenic.evidence, ScenicEvidenceLevel.verifiedOnPath);
          expect(scenic.coverageShare, closeTo(1, 0.00001));
        },
      );
    }

    test(
      '158 m Малая Садовая fixture is excluded by preserved separation',
      () async {
        final feature = spbScenicDataset.features.singleWhere(
          (f) => f.id == 'spb-scenic-central-way-4461253',
        );
        final router = _GeometryRouter(feature.line!);
        final result = await _enhance(feature.line!, [feature], router: router);
        expect(result.isScenic, isFalse);
        expect(result.fallbackReason, ScenicFallbackReason.noCandidates);
        expect(router.calls, 0);
        final report = ScenicDiagnostics.reports.last;
        expect(report.candidatesInCorridor, 1);
        expect(report.candidatesShortlisted, 0);
        expect(report.candidatesEndpointExcluded, 1);
        expect(report.candidatesNameDeduplicated, 0);
      },
    );
  });
}
