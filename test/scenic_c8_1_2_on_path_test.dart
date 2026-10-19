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

/// C8.1.2 regression fixtures.
///
/// The Palace Square → Hermitage normal geometry and the bounded candidate
/// legs come from a real OSM pedestrian route (OSRM foot profile,
/// routing.openstreetmap.de, ODbL 1.0). This is an audit proxy for MapKit's
/// geometry, not an on-device MapKit measurement; the engine's inputs are the
/// same kind of native polyline/distance/duration metadata.
const _palaceNormalGeometry = <GeoCoord>[
  GeoCoord(59.939551, 30.315203),
  GeoCoord(59.939516, 30.315107),
  GeoCoord(59.939691, 30.31485),
  GeoCoord(59.939723, 30.314804),
  GeoCoord(59.939774, 30.31473),
  GeoCoord(59.939949, 30.314474),
  GeoCoord(59.940014, 30.314379),
  GeoCoord(59.940117, 30.31423),
  GeoCoord(59.940139, 30.314201),
  GeoCoord(59.940151, 30.314224),
  GeoCoord(59.940166, 30.314235),
  GeoCoord(59.940182, 30.314234),
  GeoCoord(59.940197, 30.31422),
  GeoCoord(59.940252, 30.314141),
  GeoCoord(59.940276, 30.314208),
  GeoCoord(59.940484, 30.313907),
  GeoCoord(59.940476, 30.313885),
  GeoCoord(59.940495, 30.313845),
  GeoCoord(59.940501, 30.31381),
];

/// Nearest verified feature waypoint: «Большая Морская улица».
const _nearestFeatureWaypoint = GeoCoord(59.938165, 30.317133);

const _toNearestFeature = <GeoCoord>[
  GeoCoord(59.939551, 30.315203),
  GeoCoord(59.939565, 30.315241),
  GeoCoord(59.940074, 30.316622),
  GeoCoord(59.93966, 30.317261),
  GeoCoord(59.939583, 30.317339),
  GeoCoord(59.939506, 30.317388),
  GeoCoord(59.939426, 30.317412),
  GeoCoord(59.939307, 30.317412),
  GeoCoord(59.938733, 30.317381),
  GeoCoord(59.938587, 30.317351),
  GeoCoord(59.93847, 30.317272),
  GeoCoord(59.938347, 30.317094),
  GeoCoord(59.93828, 30.316961),
  GeoCoord(59.938165, 30.317133),
];

const _fromNearestFeature = <GeoCoord>[
  GeoCoord(59.938165, 30.317133),
  GeoCoord(59.93828, 30.316961),
  GeoCoord(59.938249, 30.316902),
  GeoCoord(59.938188, 30.316715),
  GeoCoord(59.938164, 30.31651),
  GeoCoord(59.938173, 30.316216),
  GeoCoord(59.938264, 30.315594),
  GeoCoord(59.938295, 30.315383),
  GeoCoord(59.938351, 30.315027),
  GeoCoord(59.938439, 30.314599),
  GeoCoord(59.938561, 30.314286),
  GeoCoord(59.938986, 30.31368),
  GeoCoord(59.939469, 30.314978),
  GeoCoord(59.939643, 30.314718),
  GeoCoord(59.939675, 30.314672),
  GeoCoord(59.939723, 30.314804),
  GeoCoord(59.939774, 30.31473),
  GeoCoord(59.939949, 30.314474),
  GeoCoord(59.940014, 30.314379),
  GeoCoord(59.940117, 30.31423),
  GeoCoord(59.940139, 30.314201),
  GeoCoord(59.940151, 30.314224),
  GeoCoord(59.940166, 30.314235),
  GeoCoord(59.940182, 30.314234),
  GeoCoord(59.940197, 30.31422),
  GeoCoord(59.940252, 30.314141),
  GeoCoord(59.940276, 30.314208),
  GeoCoord(59.940484, 30.313907),
  GeoCoord(59.940476, 30.313885),
  GeoCoord(59.940495, 30.313845),
  GeoCoord(59.940501, 30.31381),
];

const _toNearestFeatureMeters = 335.3;
const _toNearestFeatureSeconds = 268;
const _fromNearestFeatureMeters = 477.3;
const _fromNearestFeatureSeconds = 382;

PedestrianRouteModel _palaceNormalRoute() => const PedestrianRouteModel(
  distanceMeters: 147.3,
  durationSeconds: 118,
  geometryPoints: _palaceNormalGeometry,
  steps: [],
  legs: [
    RouteLegModel(
      fromTitle: 'Дворцовая площадь',
      toTitle: 'Государственный Эрмитаж (Зимний дворец)',
      distanceMeters: 147.3,
      durationSeconds: 118,
      geometryPoints: _palaceNormalGeometry,
      visitMinutes: 50,
    ),
  ],
  placesCount: 1,
);

PedestrianRouteModel _asRoute(
  List<GeoCoord> geometry,
  double meters,
  int seconds,
  String toTitle,
) {
  final leg = RouteLegModel(
    fromTitle: 'Сценарная точка',
    toTitle: toTitle,
    distanceMeters: meters,
    durationSeconds: seconds,
    geometryPoints: geometry,
  );
  return PedestrianRouteModel(
    distanceMeters: meters,
    durationSeconds: seconds,
    geometryPoints: geometry,
    steps: const [],
    legs: [leg],
    placesCount: 1,
  );
}

class _NoCalls implements BasePedestrianRouteService {
  int calls = 0;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    calls++;
    throw StateError('unexpected native route request');
  }

  @override
  void cancel() {}
}

class _NearestFeatureRoutes implements BasePedestrianRouteService {
  int calls = 0;

  bool _is(GeoCoord a, RoutePointModel point) =>
      a.latitude == point.latitude && a.longitude == point.longitude;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    calls++;
    if (_is(_nearestFeatureWaypoint, destinationPoint)) {
      return _asRoute(
        _toNearestFeature,
        _toNearestFeatureMeters,
        _toNearestFeatureSeconds,
        'Большая Морская улица',
      );
    }
    if (_is(_palaceNormalGeometry.last, destinationPoint)) {
      return _asRoute(
        _fromNearestFeature,
        _fromNearestFeatureMeters,
        _fromNearestFeatureSeconds,
        'Государственный Эрмитаж (Зимний дворец)',
      );
    }
    throw StateError(
      'unexpected native destination '
      '${destinationPoint.latitude},${destinationPoint.longitude}',
    );
  }

  @override
  void cancel() {}
}

ScenicFeature _feature({
  required String id,
  required String name,
  required List<GeoCoord> line,
  ScenicFeatureType type = ScenicFeatureType.embankment,
  double confidence = 0.9,
}) => ScenicFeature(
  id: id,
  type: type,
  name: name,
  district: 'test',
  districtLabel: 'Контрольный район',
  waypoint: line[line.length ~/ 2],
  line: line,
  extentMeters: RouteProjectionUtils.polylineLengthMeters(line),
  osmUrl: 'https://www.openstreetmap.org/way/1',
  accessEvidence: '{"highway":"pedestrian"}',
  verifiedOn: '2026-10-11',
  confidence: confidence,
  uncertainty: 'Детерминированная тестовая геометрия',
);

class _Harness {
  final ScenicWalkEngine engine;
  final BasePedestrianRouteService service;

  const _Harness(this.engine, this.service);
}

_Harness _harness(
  BasePedestrianRouteService service,
  List<ScenicFeature> featureSet, {
  int maxCandidatesPerStep = 0,
}) => _Harness(
  ScenicWalkEngine(
    routeService: service,
    datasetFeatures: featureSet,
    config: ScenicScoringConfig(maxCandidatesPerStep: maxCandidatesPerStep),
  ),
  service,
);

ScenicAttemptContext _context({
  int visitSeconds = 3000,
  int presetBudgetSeconds = 3600,
}) => ScenicAttemptContext(
  visitSeconds: visitSeconds,
  presetBudgetSeconds: presetBudgetSeconds,
  datasetVersion: spbScenicDataset.version,
  datasetFeaturesCount: spbScenicDataset.features.length,
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

  group('C8.1.2 Palace Square → Hermitage', () {
    for (final preset in const [60, 120, 240]) {
      test('preset $preset min: the short route stays normal for a concrete '
          'reason, without inventing a scenic detour', () async {
        final service = _NearestFeatureRoutes();
        final harness = _harness(
          service,
          spbScenicDataset.features,
          maxCandidatesPerStep: 1,
        );
        final budget = NativeWalkRequestBudget(12)..consume();
        final result = await harness.engine.enhance(
          normalRoute: _palaceNormalRoute(),
          walkBudgetSeconds: preset * 60 - 3000,
          requestBudget: budget,
          recognizeOnPath: true,
          diagnosticsContext: _context(presetBudgetSeconds: preset * 60),
        );

        expect(result.isScenic, isFalse);
        expect(result.comparison, isNull);
        expect(result.fallbackReason, ScenicFallbackReason.noScenicOnPath);
        expect(result.stats.waypointsAccepted, 0);
        expect(result.stats.zeroDetourCandidates, 0);
        expect(result.stats.zeroDetourFeaturesAccepted, 0);
        expect(result.stats.scenicRequests, 3);
        expect(service.calls, 2);
        final text = scenicFallbackReasonText(result.fallbackReason);
        expect(text, contains('не проходит по подтверждённым'));
        expect(text, contains('объезд'));
        expect(text, contains('обычный пешеходный маршрут'));

        final report = ScenicDiagnostics.reports.single;
        expect(report.normalWalkingSeconds, 118);
        expect(report.normalDistanceMeters, 147.3);
        expect(report.visitSeconds, 3000);
        expect(report.remainingWalkBudgetSeconds, preset * 60 - 3000 - 118);
        expect(report.zeroDetourCandidates, 0);
        expect(report.zeroDetourFeaturesAccepted, 0);
        expect(report.nativeRequestsUsedBeforeScenic, 1);
        expect(report.nativeRequestsUsedAfterScenic, 3);
        expect(report.candidatesNativeRouted, 1);
        expect(report.rejectionCounts, {ScenicRejectionCategory.detour: 1});
        expect(report.finalFallbackReason, 'noScenicOnPath');
        expect(report.finalWalkKind, 'normal');
      });
    }

    test('direct A→B without an editorial visit is also correctly normal: '
        'the detour cap, not the visit time, is the blocking limit', () async {
      final service = _NearestFeatureRoutes();
      final harness = _harness(
        service,
        spbScenicDataset.features,
        maxCandidatesPerStep: 1,
      );
      final result = await harness.engine.enhance(
        normalRoute: _palaceNormalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12)..consume(),
        recognizeOnPath: true,
        diagnosticsContext: _context(visitSeconds: 0),
      );

      expect(result.isScenic, isFalse);
      expect(result.fallbackReason, ScenicFallbackReason.noScenicOnPath);
      expect(service.calls, 2);
      final report = ScenicDiagnostics.reports.single;
      expect(report.visitSeconds, 0);
      expect(report.remainingWalkBudgetSeconds, 3600 - 118);
      expect(report.rejectionCounts, {ScenicRejectionCategory.detour: 1});
      expect(report.rejectedCandidates.single.extraMeters, greaterThan(600));
      expect(report.rejectedCandidates.single.extraMinutes, greaterThan(8));
    });

    test('the nearest verified feature is measured, not guessed', () async {
      final feature = spbScenicDataset.features.firstWhere(
        (candidate) =>
            candidate.name == 'Большая Морская улица' &&
            candidate.waypoint.latitude == _nearestFeatureWaypoint.latitude &&
            candidate.waypoint.longitude == _nearestFeatureWaypoint.longitude,
      );
      expect(feature.osmUrl, contains('openstreetmap.org'));
      expect(
        RouteProjectionUtils.distanceBetween(
          feature.waypoint,
          _palaceNormalGeometry.first,
        ),
        greaterThan(100),
      );
    });
  });

  group('C8.1.2 zero-detour recognition', () {
    test(
      'a normal route already on a verified feature becomes scenic with '
      'the same geometry, zero extra time and zero native requests',
      () async {
        final feature = spbScenicDataset.features.firstWhere(
          (candidate) =>
              candidate.name == 'набережная Зимней канавки' &&
              (candidate.line?.length ?? 0) >= 5,
        );
        final geometry = feature.line!;
        final normal = _asRoute(
          geometry,
          RouteProjectionUtils.polylineLengthMeters(geometry),
          100,
          'Набережная',
        );
        final service = _NoCalls();
        final harness = _harness(service, [feature]);

        final result = await harness.engine.enhance(
          normalRoute: normal,
          walkBudgetSeconds: 3600,
          requestBudget: NativeWalkRequestBudget(12),
          recognizeOnPath: true,
          diagnosticsContext: _context(),
        );

        expect(result.isScenic, isTrue);
        expect(service.calls, 0);
        final route = result.route!;
        expect(route.walkKind, WalkKind.scenic);
        expect(route.distanceMeters, normal.distanceMeters);
        expect(route.durationSeconds, normal.durationSeconds);
        expect(route.geometryPoints, equals(geometry));
        final scenic = route.legs.single.scenic!;
        expect(scenic.featureNames, [feature.name]);
        expect(scenic.evidence, ScenicEvidenceLevel.verifiedOnPath);
        expect(scenic.coverageShare, greaterThanOrEqualTo(0.5));
        expect(scenic.extraSeconds, 0);
        expect(scenic.extraMeters, 0);
        expect(scenic.explanation, contains('Проходит по'));
        final comparison = result.comparison!;
        expect(comparison.extraWalkingSeconds, 0);
        expect(comparison.extraDistanceMeters, 0);
        expect(comparison.scenicWalkingSeconds, 100);
        expect(result.stats.zeroDetourFeaturesAccepted, 1);
        expect(result.stats.waypointsAccepted, 0);
        expect(result.stats.scenicRequests, 0);

        final report = ScenicDiagnostics.reports.single;
        expect(report.zeroDetourFeaturesAccepted, 1);
        expect(report.scenicStagesAccepted, 1);
        expect(report.finalWalkKind, 'scenic');
        expect(report.nativeRequestsUsedAfterScenic, 0);
      },
    );

    test('a partial nearby share is accepted only above the unchanged score '
        'threshold and never claimed as on-path', () async {
      final route = <GeoCoord>[
        const GeoCoord(60.0, 30.0),
        const GeoCoord(60.0045, 30.0),
      ];
      final line = <GeoCoord>[
        const GeoCoord(60.0018, 30.0003),
        const GeoCoord(60.00234, 30.0003),
      ];
      final feature = _feature(
        id: 'nearby',
        name: 'Контрольная набережная',
        line: line,
      );
      final normal = _asRoute(route, 500, 360, 'Финиш');
      final service = _NoCalls();
      final harness = _harness(service, [feature]);

      final result = await harness.engine.enhance(
        normalRoute: normal,
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
        recognizeOnPath: true,
      );

      expect(result.isScenic, isTrue);
      expect(service.calls, 0);
      final scenic = result.route!.legs.single.scenic!;
      expect(scenic.evidence, ScenicEvidenceLevel.verifiedNearby);
      expect(scenic.coverageShare, greaterThan(0.15));
      expect(scenic.coverageShare, lessThan(0.5));
      expect(scenic.extraSeconds, 0);
      expect(scenic.explanation, contains('Проходит рядом с'));
      expect(result.stats.zeroDetourFeaturesAccepted, 1);
    });

    test('crossing a feature does not turn the walk scenic', () async {
      final route = <GeoCoord>[
        const GeoCoord(60.0, 30.0),
        const GeoCoord(60.009, 30.0),
      ];
      final line = <GeoCoord>[
        const GeoCoord(60.0045, 29.995),
        const GeoCoord(60.0045, 30.005),
      ];
      final feature = _feature(
        id: 'crossing',
        name: 'Контрольная площадь',
        line: line,
      );
      final service = _NoCalls();
      final harness = _harness(service, [feature]);

      final result = await harness.engine.enhance(
        normalRoute: _asRoute(route, 1000, 720, 'Финиш'),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
        recognizeOnPath: true,
      );

      expect(result.isScenic, isFalse);
      expect(result.stats.zeroDetourCandidates, greaterThan(0));
      expect(result.stats.zeroDetourFeaturesAccepted, 0);
      expect(service.calls, 0);
    });

    test('one on-path stage and one normal stage: only the first is scenic, '
        'with no request on either', () async {
      final feature = spbScenicDataset.features.firstWhere(
        (candidate) =>
            candidate.name == 'набережная Зимней канавки' &&
            (candidate.line?.length ?? 0) >= 5,
      );
      final onPath = feature.line!;
      final normalAfter = <GeoCoord>[
        const GeoCoord(59.937, 30.31),
        const GeoCoord(59.938, 30.31),
      ];
      final normal = PedestrianRouteModel(
        distanceMeters: 500,
        durationSeconds: 400,
        geometryPoints: [...onPath, ...normalAfter],
        steps: const [],
        legs: [
          RouteLegModel(
            fromTitle: 'Старт',
            toTitle: 'Набережная',
            distanceMeters: RouteProjectionUtils.polylineLengthMeters(onPath),
            durationSeconds: 100,
            geometryPoints: onPath,
          ),
          RouteLegModel(
            fromTitle: 'Набережная',
            toTitle: 'Финиш',
            distanceMeters: 300,
            durationSeconds: 300,
            geometryPoints: normalAfter,
            visitMinutes: 20,
          ),
        ],
        placesCount: 2,
      );
      final service = _NoCalls();
      final harness = _harness(service, [feature]);

      final result = await harness.engine.enhance(
        normalRoute: normal,
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
        recognizeOnPath: true,
      );

      expect(result.isScenic, isTrue);
      expect(service.calls, 0);
      expect(result.route!.legs[0].scenic, isNotNull);
      expect(result.route!.legs[1].scenic, isNull);
      expect(
        result.route!.legs[0].distanceMeters,
        normal.legs[0].distanceMeters,
      );
      expect(
        result.route!.legs[0].durationSeconds,
        normal.legs[0].durationSeconds,
      );
      expect(result.route!.legs[1].visitMinutes, 20);
      expect(result.stats.stagesEnhanced, 1);
      expect(result.stats.zeroDetourFeaturesAccepted, 1);
      expect(result.comparison!.extraWalkingSeconds, 0);
    });
  });
}
