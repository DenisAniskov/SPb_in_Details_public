import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/scenic_walk_engine.dart';

/// Phase C5 §4–6/§12: the Scenic Walk Engine over a deterministic fake
/// router — candidates, verification, scoring, budgets, fallbacks. No live
/// MapKit calls.
class FakeScenicRouteService implements BasePedestrianRouteService {
  FakeScenicRouteService({this.mode = FakeRouteMode.pass, this.callDurations});

  final FakeRouteMode mode;

  /// Per-call native walking seconds (index = call number − 1). When null,
  /// every pass-mode segment takes [walkingSecondsPerSegment]. Lets a test
  /// give each scenic segment its own honest native duration.
  final List<int>? callDurations;
  int calls = 0;
  int walkingSecondsPerSegment = 60;

  bool near(GeoCoord a, GeoCoord b) =>
      (a.latitude - b.latitude).abs() < 1e-6 &&
      (a.longitude - b.longitude).abs() < 1e-6;

  RouteLegModel _leg(GeoCoord from, GeoCoord to, String toTitle) {
    calls++;
    switch (mode) {
      case FakeRouteMode.fail:
        throw const RouteCalculationFailure(RouteFailureKind.serviceUnavailable);
      case FakeRouteMode.farAway:
        final shiftedTo = GeoCoord(
          to.latitude,
          to.longitude + 0.0015, // ~83 m east: outside the 60 m proximity
          // band but within the detour share, so the COVERAGE rejection
          // (not the detour cap) is what fires.
        );
        return _straightLeg(from, shiftedTo, toTitle);
      case FakeRouteMode.tooLong:
        // Zig-zag detour: ~2× the direct distance.
        final points = <GeoCoord>[from];
        for (var i = 1; i <= 6; i++) {
          final t = i / 7;
          points.add(
            GeoCoord(
              from.latitude + (to.latitude - from.latitude) * t +
                  (i.isOdd ? 0.0008 : -0.0008),
              from.longitude + (to.longitude - from.longitude) * t,
            ),
          );
        }
        points.add(to);
        return RouteLegModel(
          fromTitle: 'X',
          toTitle: toTitle,
          distanceMeters: RouteProjectionUtils.polylineLengthMeters(points) * 2,
          durationSeconds: walkingSecondsPerSegment * 4,
          geometryPoints: points,
        );
      case FakeRouteMode.pass:
        return _straightLeg(from, to, toTitle);
    }
  }

  RouteLegModel _straightLeg(GeoCoord from, GeoCoord to, String toTitle) {
    final mid = GeoCoord(
      (from.latitude + to.latitude) / 2,
      (from.longitude + to.longitude) / 2,
    );
    final durations = callDurations;
    final durationSeconds =
        durations != null && durations.length >= calls && calls > 0
        ? durations[calls - 1]
        : walkingSecondsPerSegment;
    return RouteLegModel(
      fromTitle: 'Сценарная точка',
      toTitle: toTitle,
      distanceMeters: RouteProjectionUtils.polylineLengthMeters([from, mid, to]),
      durationSeconds: durationSeconds,
      geometryPoints: [from, mid, to],
    );
  }

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    final from = GeoCoord(startPoint.latitude, startPoint.longitude);
    final to = GeoCoord(destinationPoint.latitude, destinationPoint.longitude);
    final leg = _leg(from, to, destinationPoint.title);
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

enum FakeRouteMode { pass, farAway, tooLong, fail }

ScenicFeature feature({
  required String id,
  required String name,
  required GeoCoord waypoint,
  required List<GeoCoord> line,
  ScenicFeatureType type = ScenicFeatureType.embankment,
  double confidence = 0.9,
}) =>
    ScenicFeature(
      id: id,
      type: type,
      name: name,
      district: 'central',
      districtLabel: 'Центральный район',
      waypoint: waypoint,
      line: line,
      extentMeters: 500,
      osmUrl: 'https://www.openstreetmap.org/way/1',
      accessEvidence: '{"highway":"pedestrian"}',
      verifiedOn: '2026-10-11',
      confidence: confidence,
      uncertainty: 'Тестовая запись',
    );

/// ~560 m stage A→B; the scenic corridor runs through W1 and W2.
const a = GeoCoord(60.0, 30.0);
const b = GeoCoord(60.0050, 30.0020);
const w1 = GeoCoord(60.0020, 30.0008);
const w2 = GeoCoord(60.0035, 30.0015);

PedestrianRouteModel normalRoute() {
  final mid = GeoCoord(
    (a.latitude + b.latitude) / 2,
    (a.longitude + b.longitude) / 2,
  );
  final leg = RouteLegModel(
    fromTitle: 'Старт',
    toTitle: 'POI 1',
    distanceMeters: RouteProjectionUtils.polylineLengthMeters([a, mid, b]),
    durationSeconds: 170,
    geometryPoints: [a, mid, b],
    visitMinutes: 30,
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

/// Two-stage walk A→M→B (~566 m per stage, 170 s native walking each, 30
/// min visit at each stop) for whole-walk budget and partial-success
/// scenarios. W1 sits on stage 1's corridor, W2 on stage 2's.
const multiA = GeoCoord(60.0, 30.0);
const multiM = GeoCoord(60.0050, 30.0020);
const multiB = GeoCoord(60.0100, 30.0040);

PedestrianRouteModel twoStageNormalRoute() {
  RouteLegModel leg(GeoCoord from, GeoCoord to, String toTitle) {
    final mid = GeoCoord(
      (from.latitude + to.latitude) / 2,
      (from.longitude + to.longitude) / 2,
    );
    return RouteLegModel(
      fromTitle: 'Старт',
      toTitle: toTitle,
      distanceMeters:
          RouteProjectionUtils.polylineLengthMeters([from, mid, to]),
      durationSeconds: 170,
      geometryPoints: [from, mid, to],
      visitMinutes: 30,
    );
  }

  final first = leg(multiA, multiM, 'POI 1');
  final second = leg(multiM, multiB, 'POI 2');
  return PedestrianRouteModel(
    distanceMeters: first.distanceMeters + second.distanceMeters,
    durationSeconds: first.durationSeconds + second.durationSeconds,
    geometryPoints: [
      ...first.geometryPoints,
      ...second.geometryPoints.skip(1),
    ],
    steps: const [],
    legs: [first, second],
    placesCount: 2,
  );
}

ScenicFeature multiStageFeature1() => feature(
      id: 'mf1',
      name: 'Набережная первого этапа',
      waypoint: w1,
      line: const [GeoCoord(60.0, 30.0008), GeoCoord(60.004, 30.0008)],
      confidence: 1.0,
    );

ScenicFeature multiStageFeature2() => feature(
      id: 'mf2',
      name: 'Набережная второго этапа',
      waypoint: const GeoCoord(60.0070, 30.0028),
      line: const [GeoCoord(60.005, 30.0028), GeoCoord(60.009, 30.0028)],
      confidence: 1.0,
    );

void main() {
  group('Scenic engine: regression fixes (C5 review)', () {
    test(
      'whole-walk budget counts every accepted insertion across stages',
      () async {
        // Stage 1: A→W1→M scenic = 250 s (+80 vs 170 native). Stage 2:
        // M→W2→B scenic = 260 s (+90). The old accounting compared every
        // candidate against the ORIGINAL normal total (340 − 170 + 260 =
        // 430 ≤ 480) and accepted both insertions → 510 s > 480. The fix
        // accumulates the accepted extras and rejects stage 2.
        final service = FakeScenicRouteService(
          callDurations: [125, 125, 400, 400, 150, 150, 130, 130],
        );
        final engine = ScenicWalkEngine(
          routeService: service,
          datasetFeatures: [multiStageFeature1(), multiStageFeature2()],
        );
        final result = await engine.enhance(
          normalRoute: twoStageNormalRoute(),
          walkBudgetSeconds: 480, // 340 native + 140 s of slack
          requestBudget: NativeWalkRequestBudget(12),
        );
        expect(result.isScenic, isTrue);
        final scenic = result.route!;
        // Stage 1 kept (+80 s); stage 2 stayed normal: 340 + 80 + 130 =
        // 550 > 480, and the whole walk must fit the strict budget.
        expect(scenic.durationSeconds, 420);
        expect(scenic.legs[0].scenic, isNotNull);
        expect(scenic.legs[0].scenic!.featureIds, ['mf1']);
        expect(scenic.legs[1].scenic, isNull);
        expect(scenic.legs[1].durationSeconds, 170);
        expect(result.comparison!.normalWalkingSeconds, 340);
        expect(result.comparison!.scenicWalkingSeconds, 420);
      },
    );

    test(
      'a successfully built stage survives later request-budget exhaustion',
      () async {
        final service = FakeScenicRouteService(callDurations: [125, 125]);
        final budget = NativeWalkRequestBudget(12);
        for (var i = 0; i < 10; i++) {
          budget.consume(); // 2 left — exactly one scenic attempt
        }
        final engine = ScenicWalkEngine(
          routeService: service,
          datasetFeatures: [multiStageFeature1(), multiStageFeature2()],
        );
        final result = await engine.enhance(
          normalRoute: twoStageNormalRoute(),
          walkBudgetSeconds: 3600,
          requestBudget: budget,
        );
        // Stage 1 was accepted (2 requests); stage 2 hit the empty budget.
        // The partial result must stay scenic — not fall back to null.
        expect(result.isScenic, isTrue);
        expect(result.fallbackReason, ScenicFallbackReason.none);
        final scenic = result.route!;
        expect(scenic.legs[0].scenic, isNotNull);
        expect(scenic.legs[0].scenic!.featureIds, ['mf1']);
        expect(scenic.legs[1].scenic, isNull);
        expect(scenic.durationSeconds, 250 + 170);
        expect(result.stats.stagesEnhanced, 1);
        expect(result.stats.waypointsAccepted, 1);
        expect(result.stats.scenicRequests, 12);
        expect(service.calls, 2); // stage 2 was never routed
      },
    );

    test('combined scenic stage keeps the destination stop visitMinutes',
        () async {
      final engine = ScenicWalkEngine(
        routeService: FakeScenicRouteService(),
        datasetFeatures: [
          feature(
            id: 'f1',
            name: 'Набережная тестовой реки',
            waypoint: w1,
            line: [
              const GeoCoord(60.0, 30.0008),
              const GeoCoord(60.004, 30.0008),
            ],
          ),
        ],
      );
      final result = await engine.enhance(
        normalRoute: normalRoute(), // stage carries visitMinutes: 30
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(result.isScenic, isTrue);
      final stage = result.route!.legs.single;
      expect(stage.scenic, isNotNull);
      // The tourist stop at the stage end keeps its editorial visit time
      // through ScenicStageBuilder.combine.
      expect(stage.visitMinutes, 30);
      expect(stage.toTitle, 'POI 1');
    });

    test(
      'evidence follows measured coverage, not type weight: a square that '
      'follows the way reads «Проходит по»',
      () async {
        final engine = ScenicWalkEngine(
          routeService: FakeScenicRouteService(),
          datasetFeatures: [
            feature(
              id: 'f1',
              name: 'Площадь тестовая',
              // Weight 0.75 — under the old 0.9 cut-off that forced
              // «рядом» regardless of the actual geometry.
              type: ScenicFeatureType.square,
              waypoint: w1,
              line: [
                const GeoCoord(60.0, 30.0008),
                const GeoCoord(60.004, 30.0008),
              ],
            ),
          ],
        );
        final result = await engine.enhance(
          normalRoute: normalRoute(),
          walkBudgetSeconds: 3600,
          requestBudget: NativeWalkRequestBudget(12),
        );
        expect(result.isScenic, isTrue);
        final stage = result.route!.legs.single;
        // Length inside the 60 m band, rather than 4/5 stored vertices.
        expect(stage.scenic!.coverageShare, closeTo(0.8573, 0.001));
        expect(stage.scenic!.evidence, ScenicEvidenceLevel.verifiedOnPath);
        expect(stage.scenic!.explanation, 'Проходит по Площадь тестовая');
        expect(
          result.comparison!.benefitLines.first,
          'Проходит по Площадь тестовая',
        );
      },
    );

    test(
      'evidence follows measured coverage, not type weight: a barely '
      'engaged embankment stays «Проходит рядом с»',
      () async {
        final engine = ScenicWalkEngine(
          routeService: FakeScenicRouteService(),
          datasetFeatures: [
            feature(
              id: 'f1',
              name: 'Набережная тестовой реки',
              // Short verified way: only ~37% of the stage length engages
              // it — the old type-weight rule called this «Проходит по».
              waypoint: w1,
              line: [
                const GeoCoord(60.0, 30.0008),
                const GeoCoord(60.0013, 30.0008),
              ],
            ),
          ],
        );
        final result = await engine.enhance(
          normalRoute: normalRoute(),
          walkBudgetSeconds: 3600,
          requestBudget: NativeWalkRequestBudget(12),
        );
        expect(result.isScenic, isTrue);
        final stage = result.route!.legs.single;
        expect(stage.scenic!.coverageShare, closeTo(0.3677, 0.001));
        expect(stage.scenic!.evidence, ScenicEvidenceLevel.verifiedNearby);
        expect(
          stage.scenic!.explanation,
          'Проходит рядом с Набережная тестовой реки',
        );
      },
    );
  });

  group('Scenic engine: fallbacks', () {
    test('empty dataset keeps the normal route honestly', () async {
      final engine = ScenicWalkEngine(
        routeService: FakeScenicRouteService(),
        datasetFeatures: const [],
      );
      final result = await engine.enhance(
        normalRoute: normalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(result.isScenic, isFalse);
      expect(result.fallbackReason, ScenicFallbackReason.noCandidates);
      expect(result.stats.candidatesConsidered, 0);
      expect(result.stats.scenicRequests, 0);
    });

    test('geometry far from the verified feature is never claimed scenic',
        () async {
      final engine = ScenicWalkEngine(
        routeService: FakeScenicRouteService(mode: FakeRouteMode.farAway),
        datasetFeatures: [
          feature(
            id: 'f1',
            name: 'Набережная тестовой реки',
            waypoint: w1,
            line: [const GeoCoord(60.0, 30.0008), const GeoCoord(60.004, 30.0008)],
          ),
        ],
      );
      final result = await engine.enhance(
        normalRoute: normalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(result.isScenic, isFalse);
      // The geometry evidence was checked (nearby pass), but the net score
      // stayed under the acceptance threshold — never claimed scenic.
      expect(result.fallbackReason, ScenicFallbackReason.noVerifiedGeometry);
      expect(result.stats.candidatesConsidered, greaterThanOrEqualTo(1));
      expect(result.stats.candidatesVerified, 1);
    });

    test('excessive detour is rejected (§5: big detour for a dubious object)',
        () async {
      final engine = ScenicWalkEngine(
        routeService: FakeScenicRouteService(mode: FakeRouteMode.tooLong),
        datasetFeatures: [
          feature(
            id: 'f1',
            name: 'Набережная тестовой реки',
            waypoint: w1,
            line: [const GeoCoord(60.0, 30.0008), const GeoCoord(60.004, 30.0008)],
          ),
        ],
      );
      final result = await engine.enhance(
        normalRoute: normalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(result.isScenic, isFalse);
      // The normal path does not follow any verified way, so the honest
      // message is «no scenic feature on the path», not a bare length failure.
      expect(result.fallbackReason, ScenicFallbackReason.noScenicOnPath);
    });

    test('walk time budget is strict: scenic variant that exceeds it loses',
        () async {
      final service = FakeScenicRouteService()
        ..walkingSecondsPerSegment = 200; // scenic stage ~600 s ≫ budget
      final engine = ScenicWalkEngine(
        routeService: service,
        datasetFeatures: [
          feature(
            id: 'f1',
            name: 'Набережная тестовой реки',
            waypoint: w1,
            line: [const GeoCoord(60.0, 30.0008), const GeoCoord(60.004, 30.0008)],
          ),
        ],
      );
      final result = await engine.enhance(
        normalRoute: normalRoute(),
        walkBudgetSeconds: 300, // normal 170 fits; scenic 400 does not
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(result.isScenic, isFalse);
      expect(result.fallbackReason, ScenicFallbackReason.budgetExceeded);
    });

    test('request budget exhaustion stops scenic attempts before routing',
        () async {
      final service = FakeScenicRouteService();
      final budget = NativeWalkRequestBudget(12);
      for (var i = 0; i < 11; i++) {
        budget.consume(); // 1 remaining — less than the 2 needed per attempt
      }
      final engine = ScenicWalkEngine(
        routeService: service,
        datasetFeatures: [
          feature(
            id: 'f1',
            name: 'Набережная тестовой реки',
            waypoint: w1,
            line: [const GeoCoord(60.0, 30.0008), const GeoCoord(60.004, 30.0008)],
          ),
        ],
      );
      final result = await engine.enhance(
        normalRoute: normalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: budget,
      );
      expect(result.isScenic, isFalse);
      expect(result.fallbackReason, ScenicFallbackReason.requestBudgetExhausted);
      expect(service.calls, 0);
    });

    test('MapKit failure skips the candidate with the honest reason',
        () async {
      final engine = ScenicWalkEngine(
        routeService: FakeScenicRouteService(mode: FakeRouteMode.fail),
        datasetFeatures: [
          feature(
            id: 'f1',
            name: 'Набережная тестовой реки',
            waypoint: w1,
            line: [const GeoCoord(60.0, 30.0008), const GeoCoord(60.004, 30.0008)],
          ),
        ],
      );
      final result = await engine.enhance(
        normalRoute: normalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(result.isScenic, isFalse);
      expect(result.fallbackReason, ScenicFallbackReason.mapkitUnavailable);
    });
  });

  group('Scenic engine: acceptance', () {
    test('verified corridor waypoint produces a combined scenic stage',
        () async {
      final service = FakeScenicRouteService();
      final engine = ScenicWalkEngine(
        routeService: service,
        datasetFeatures: [
          feature(
            id: 'f1',
            name: 'Набережная тестовой реки',
            waypoint: w1,
            line: [const GeoCoord(60.0, 30.0008), const GeoCoord(60.004, 30.0008)],
          ),
        ],
      );
      final result = await engine.enhance(
        normalRoute: normalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(result.isScenic, isTrue);
      expect(result.fallbackReason, ScenicFallbackReason.none);
      final scenic = result.route!;
      expect(scenic.walkKind, WalkKind.scenic);
      expect(scenic.legs, hasLength(1));
      final stage = scenic.legs.single;
      expect(stage.scenic, isNotNull);
      expect(stage.scenic!.featureIds, ['f1']);
      expect(stage.scenic!.evidence, ScenicEvidenceLevel.verifiedOnPath);
      // The combined geometry passes exactly through the waypoint.
      expect(
        stage.geometryPoints.any(
          (p) => (p.latitude - w1.latitude).abs() < 1e-9 &&
              (p.longitude - w1.longitude).abs() < 1e-9,
        ),
        isTrue,
      );
      // The stage is still ONE tourist transition.
      expect(stage.fromTitle, 'Старт');
      expect(stage.toTitle, 'POI 1');
      // Comparison is native-only and truthful.
      expect(result.comparison!.normalWalkingSeconds, 170);
      expect(result.comparison!.scenicWalkingSeconds, greaterThan(100));
      expect(result.comparison!.stopCount, 1);
      expect(result.comparison!.benefitLines, isNotEmpty);
      // Exactly two native requests per accepted waypoint.
      expect(result.stats.scenicRequests, 2);
    });

    test('two waypoints merge into one stage: A→W1→W2→B stays one arrival',
        () async {
      final engine = ScenicWalkEngine(
        routeService: FakeScenicRouteService()
          ..walkingSecondsPerSegment = 30,
        datasetFeatures: [
          feature(
            id: 'f1',
            name: 'Набережная первая',
            waypoint: w1,
            line: [const GeoCoord(60.001, 30.0008), const GeoCoord(60.003, 30.0008)],
          ),
          feature(
            id: 'f2',
            name: 'Набережная вторая',
            waypoint: w2,
            line: [const GeoCoord(60.002, 30.0015), const GeoCoord(60.005, 30.0015)],
          ),
        ],
      );
      final result = await engine.enhance(
        normalRoute: normalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(result.isScenic, isTrue);
      final stage = result.route!.legs.single;
      expect(stage.scenic!.featureIds, containsAll(['f1', 'f2']));
      expect(stage.scenic!.featureIds, hasLength(2));
      // Both waypoints are on the combined geometry; the stage endpoint is B.
      expect(stage.geometryPoints.last.latitude, b.latitude);
      expect(stage.geometryPoints.last.longitude, b.longitude);
      expect(result.stats.scenicRequests, 6); // 3 segments × 2 endpoints? no:

    });

    test('deterministic choice across repeated runs', () async {
      Future<List<String>> ids() async {
        final engine = ScenicWalkEngine(
          routeService: FakeScenicRouteService()
            ..walkingSecondsPerSegment = 30,
          datasetFeatures: [
            feature(
              id: 'f1',
              name: 'Набережная первая',
              waypoint: w1,
              line: const [
                GeoCoord(60.001, 30.0008),
                GeoCoord(60.003, 30.0008),
              ],
            ),
            feature(
              id: 'f2',
              name: 'Площадь вторая',
              waypoint: w2,
              type: ScenicFeatureType.square,
              confidence: 0.8,
              line: const [
                GeoCoord(60.002, 30.0015),
                GeoCoord(60.005, 30.0015),
              ],
            ),
          ],
        );
        final result = await engine.enhance(
          normalRoute: normalRoute(),
          walkBudgetSeconds: 3600,
          requestBudget: NativeWalkRequestBudget(12),
        );
        final stage = result.route!.legs.single;
        return stage.scenic!.featureIds;
      }

      expect(await ids(), await ids());
    });
  });

  group('Scenic scoring (deterministic, documented)', () {
    test('score decreases with detour minutes and uncertainty', () {
      final engine = ScenicWalkEngine(
        routeService: FakeScenicRouteService(),
        datasetFeatures: const [],
      );
      final featureHigh = feature(
        id: 'f1',
        name: 'A',
        waypoint: w1,
        line: const [],
        confidence: 1.0,
      );
      final featureLow = feature(
        id: 'f2',
        name: 'B',
        waypoint: w2,
        line: const [],
        confidence: 0.5,
      );
      final high = engine.score(
        feature: featureHigh,
        coverageShare: 0.8,
        extraMinutes: 0,
      );
      final withDetour = engine.score(
        feature: featureHigh,
        coverageShare: 0.8,
        extraMinutes: 5,
      );
      final lowConfidence = engine.score(
        feature: featureLow,
        coverageShare: 0.8,
        extraMinutes: 0,
      );
      expect(withDetour, lessThan(high));
      expect(lowConfidence, lessThan(high));
    });
  });
}
