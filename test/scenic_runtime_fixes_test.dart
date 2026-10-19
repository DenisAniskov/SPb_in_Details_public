import 'dart:math' as math;

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

/// Phase C4/C5 runtime fixes: corridor filter over the real polyline (§4),
/// measured junction policy (§5), diagnostics report (§3) and the shared
/// native request budget audit (§7).
///
/// §4 geometry: normal stage A(60.0000, 30.0000) → C(60.0000, 30.0090) →
/// B(60.0045, 30.0000) — east, then north. The verified embankment line sits
/// north-east of the corner with waypoint W 93 m from the real polyline but
/// ~529 m from the straight chord A→B: exactly the class of candidates the
/// pre-fix chord filter dropped before any native request.
const a = GeoCoord(60.0, 30.0);
const c = GeoCoord(60.0, 30.009);
const b = GeoCoord(60.0045, 30.0);
const wCorner = GeoCoord(60.0008, 30.0095);
const embankmentLine = [GeoCoord(60.0008, 30.009), GeoCoord(60.0008, 30.011)];

// Junction fixtures need a genuinely engaged verified way so their native
// connector is reached. The original short line above stays a separate thin-
// coverage fixture: counting its few vertices previously overstated benefit.
const junctionFeatureLine = [
  a,
  GeoCoord(60.0008, 30.009),
  wCorner,
  GeoCoord(60.0008, 30.0105),
  b,
];

/// The same local-meter conversion the fake uses (≈ SPb latitudes), for
/// building realistic projections and connector curves in tests.
GeoCoord _northOf(GeoCoord point, double meters) =>
    GeoCoord(point.latitude + meters / 111320.0, point.longitude);

GeoCoord _westOf(GeoCoord point, double meters) => GeoCoord(
      point.latitude,
      point.longitude -
          meters / (111320.0 * math.cos(point.latitude * math.pi / 180)),
    );

bool _containsPoint(List<GeoCoord> points, GeoCoord expected) => points.any(
      (p) =>
          p.latitude == expected.latitude &&
          p.longitude == expected.longitude,
    );

double _pointToSegmentMeters(GeoCoord p, GeoCoord from, GeoCoord to) {
  final pLocal = RouteProjectionUtils.toLocalMeters(p, from);
  final aLocal = RouteProjectionUtils.toLocalMeters(from, from);
  final bLocal = RouteProjectionUtils.toLocalMeters(to, from);
  final dx = bLocal.x - aLocal.x;
  final dy = bLocal.y - aLocal.y;
  final lengthSq = dx * dx + dy * dy;
  var t = 0.0;
  if (lengthSq > 1e-9) {
    t = ((pLocal.x - aLocal.x) * dx + (pLocal.y - aLocal.y) * dy) / lengthSq;
    t = t.clamp(0.0, 1.0);
  }
  final ex = pLocal.x - (aLocal.x + t * dx);
  final ey = pLocal.y - (aLocal.y + t * dy);
  return math.sqrt(ex * ex + ey * ey);
}

/// One native leg answer: optional endpoint shift (meters north),
/// walking seconds, and optional via points the route passes through (a
/// realistic shape: real MapKit routes follow paths, not chords).
class _LegSpec {
  final double shiftNorthMeters;

  /// Shifts only the first geometry point (a snap of the requested start,
  /// as MapKit may return it).
  final double startShiftNorthMeters;

  /// When true the shift applies to the whole polyline (MapKit snapped the
  /// route away from the requested waypoint); when false only the
  /// destination endpoint moves (the classic «route doesn't reach the
  /// feature» case).
  final bool shiftAllPoints;
  final int seconds;
  final List<GeoCoord> via;

  /// Maneuvers on this leg, positioned on its own geometry exactly like the
  /// real adapter does (native annotation index + position, offset measured
  /// along the leg polyline).
  final List<_ManeuverSpec> maneuvers;

  const _LegSpec({
    this.shiftNorthMeters = 0,
    this.startShiftNorthMeters = 0,
    this.shiftAllPoints = false,
    this.seconds = 60,
    this.via = const [],
    this.maneuvers = const [],
  });
}

/// One native annotation on a leg's own geometry (at a segment start, the
/// usual «turn happens at this vertex» shape).
class _ManeuverSpec {
  final PedestrianManeuverKind kind;
  final int segmentIndex;

  const _ManeuverSpec(this.kind, this.segmentIndex);
}

class _SequencedFake implements BasePedestrianRouteService {
  _SequencedFake(this.specs);

  final List<_LegSpec> specs;
  int calls = 0;
  bool failNext = false;

  /// 1-based call number that throws instead of answering (for failure
  /// injection on a specific request, e.g. the junction connector).
  int? failOnCall;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    final callNumber = ++calls;
    if (failNext || callNumber == failOnCall) {
      throw const RouteCalculationFailure(RouteFailureKind.serviceUnavailable);
    }
    final spec = specs[(callNumber - 1).clamp(0, specs.length - 1)];
    final from = GeoCoord(startPoint.latitude, startPoint.longitude);
    const metersPerDegreeLat = 111320.0;
    GeoCoord shifted(GeoCoord point) => GeoCoord(
          point.latitude + spec.shiftNorthMeters / metersPerDegreeLat,
          point.longitude,
        );
    final requestedTo = GeoCoord(
      destinationPoint.latitude,
      destinationPoint.longitude,
    );
    final to = spec.shiftAllPoints
        ? shifted(requestedTo)
        : GeoCoord(
            requestedTo.latitude +
                spec.shiftNorthMeters / metersPerDegreeLat,
            requestedTo.longitude,
          );
    final start = spec.shiftAllPoints
        ? shifted(from)
        : GeoCoord(
            from.latitude +
                spec.startShiftNorthMeters / metersPerDegreeLat,
            from.longitude,
          );
    final steps = <GeoCoord>[start, ...spec.via, to];
    // Offsets exactly like the real adapter: native distance along the leg
    // polyline up to (segmentIndex + segmentPosition).
    final cumulative = <double>[0];
    for (var i = 1; i < steps.length; i++) {
      cumulative.add(
        cumulative.last + RouteProjectionUtils.distanceBetween(steps[i - 1], steps[i]),
      );
    }
    final leg = RouteLegModel(
      fromTitle: startPoint.title,
      toTitle: destinationPoint.title,
      distanceMeters: RouteProjectionUtils.polylineLengthMeters(steps),
      durationSeconds: spec.seconds,
      geometryPoints: steps,
      maneuvers: [
        for (final maneuver in spec.maneuvers)
          PedestrianManeuverModel(
            kind: maneuver.kind,
            segmentIndex: maneuver.segmentIndex,
            segmentPosition: 0,
            offsetMeters: cumulative[maneuver.segmentIndex],
          ),
      ],
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

RouteLegModel _leg(
  List<GeoCoord> steps, {
  required int seconds,
  String from = 'Старт',
  String to = 'POI',
  int? visitMinutes,
}) =>
    RouteLegModel(
      fromTitle: from,
      toTitle: to,
      distanceMeters: RouteProjectionUtils.polylineLengthMeters(steps),
      durationSeconds: seconds,
      geometryPoints: steps,
      visitMinutes: visitMinutes,
    );

PedestrianRouteModel _route(List<RouteLegModel> legs) => PedestrianRouteModel(
      distanceMeters: legs.fold(0.0, (sum, l) => sum + l.distanceMeters),
      durationSeconds: legs.fold(0, (sum, l) => sum + l.durationSeconds),
      geometryPoints: legs.expand((l) => l.geometryPoints).toList(),
      steps: const [],
      legs: legs,
      placesCount: legs.length,
    );

/// The §4 L-shaped single-stage normal route (~1106 m: 501 m east, then
/// 500 m north) ending at a tourist stop with 30 editorial visit minutes.
PedestrianRouteModel lShapedNormalRoute() => _route([
      _leg(
        [a, const GeoCoord(60.0, 30.0045), c, const GeoCoord(60.00225, 30.0045), b],
        seconds: 600,
        to: 'POI 1',
        visitMinutes: 30,
      ),
    ]);

ScenicFeature feature({
  String id = 'emb-1',
  String name = 'Набережная контрольной реки',
  required GeoCoord waypoint,
  List<GeoCoord>? line,
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
      line: line ?? embankmentLine,
      extentMeters: 200,
      osmUrl: 'https://www.openstreetmap.org/way/$id',
      accessEvidence: '{"highway":"footway"}',
      verifiedOn: '2026-10-11',
      confidence: confidence,
      uncertainty: 'Тестовая запись',
    );

ScenicAttemptContext context() => const ScenicAttemptContext(
      visitSeconds: 1800,
      presetBudgetSeconds: 3600,
      datasetVersion: 'test-version',
      datasetFeaturesCount: 4,
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

  group('§4 corridor: candidates on a bend of the real polyline', () {
    test('a feature near the bend is measured against the polyline, not the '
        'chord — the reproduced pre-fix loss', () async {
      final service = _SequencedFake(const [
        _LegSpec(
          seconds: 350,
          via: [GeoCoord(60.0008, 30.009)],
        ),
        _LegSpec(
          seconds: 350,
          via: [GeoCoord(60.0008, 30.0105)],
        ),
      ]);
      final engine = ScenicWalkEngine(
        routeService: service,
        datasetFeatures: [
          feature(waypoint: wCorner),
        ],
      );
      final result = await engine.enhance(
        normalRoute: lShapedNormalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
        diagnosticsContext: context(),
      );
      // The chord criterion of the old filter: waypoint ~529 m from A→B.
      final chordDistance = _pointToSegmentMeters(wCorner, a, b);
      expect(chordDistance, greaterThan(400),
          reason: 'the old straight-line filter would have dropped it');
      // The real polyline criterion: waypoint 93 m from the corner.
      final polylineDistance = math.min(
        _pointToSegmentMeters(wCorner, a, c),
        _pointToSegmentMeters(wCorner, c, b),
      );
      expect(polylineDistance, lessThan(120));
      // The corridor admits it to native routing. Length-weighted coverage
      // honestly rejects this short feature's weak benefit (~19% coverage),
      // while the old 3/5 vertex count incorrectly claimed «Проходит по».
      expect(result.isScenic, isFalse);
      expect(result.fallbackReason, ScenicFallbackReason.insufficientBenefit);
      expect(result.stats.candidatesConsidered, 1);
      expect(service.calls, 2);
      expect(ScenicDiagnostics.reports.single.rejectedCandidates.single.coverageShare,
          closeTo(0.19, 0.001));
    });

    test('the corridor width is unchanged: a feature truly far from the '
        'polyline is still pre-filtered without native requests', () async {
      final service = _SequencedFake(const [_LegSpec()]);
      final engine = ScenicWalkEngine(
        routeService: service,
        datasetFeatures: [
          feature(
            id: 'far',
            waypoint: const GeoCoord(60.004, 30.02),
            line: const [
              GeoCoord(60.004, 30.0195),
              GeoCoord(60.004, 30.0205),
            ],
          ),
        ],
      );
      final result = await engine.enhance(
        normalRoute: lShapedNormalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(result.isScenic, isFalse);
      expect(result.fallbackReason, ScenicFallbackReason.noCandidates);
      expect(service.calls, 0);
    });

    test('same-name features are deduplicated to one candidate', () async {
      final service = _SequencedFake(const [
        _LegSpec(seconds: 350, via: [GeoCoord(60.0008, 30.009)]),
        _LegSpec(seconds: 350, via: [GeoCoord(60.0008, 30.0105)]),
      ]);
      final engine = ScenicWalkEngine(
        routeService: service,
        datasetFeatures: [
          feature(waypoint: wCorner),
          feature(
            id: 'emb-2',
            waypoint: const GeoCoord(60.0008, 30.0102),
          ),
        ],
      );
      final result = await engine.enhance(
        normalRoute: lShapedNormalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(result.isScenic, isFalse);
      expect(result.fallbackReason, ScenicFallbackReason.insufficientBenefit);
      expect(result.stats.candidatesConsidered, 1);
      expect(service.calls, 2);
    });
  });

  group('§5 junction policy: measured, never assumed', () {
    RouteLegModel builderLeg(List<GeoCoord> points) => _leg(
          points,
          seconds: 60,
        );

    ScenicStageInfo info() => const ScenicStageInfo(
          featureIds: ['emb-1'],
          featureNames: ['Набережная'],
          evidence: ScenicEvidenceLevel.verifiedOnPath,
          coverageShare: 0.6,
          extraSeconds: 10,
          extraMeters: 15,
          score: 0.5,
          explanation: 'Проходит по набережной',
        );

    const w = GeoCoord(60.002, 30.0005);
    List<GeoCoord> straight(GeoCoord from, GeoCoord to) => [
          from,
          GeoCoord(
            (from.latitude + to.latitude) / 2,
            (from.longitude + to.longitude) / 2,
          ),
          to,
        ];
    // Second segment starts ~1.3 m east/north of the first segment's end:
    // sub-cap jitter of two projections of the same verified waypoint.
    const jitteredStart = GeoCoord(60.0020012, 30.0005233);

    test('exact shared coordinate joins (bit-identical waypoint)', () {
      final outcome = const ScenicStageBuilder().combineDetailed(
        segments: [
          builderLeg(straight(a, w)),
          builderLeg(straight(w, b)),
        ],
        legIndex: 0,
        scenic: info(),
        junctionWaypoints: const [w],
      );
      expect(outcome.ok, isTrue);
      expect(outcome.junctions.single.gapMeters, lessThan(0.001));
      expect(outcome.junctions.single.accepted, isTrue);
    });

    test('a direct builder call never joins an inexact junction: the measured '
        '1.3 m jitter is rejected, not tolerated', () {
      final first = straight(a, w);
      final second = straight(jitteredStart, b);
      final outcome = const ScenicStageBuilder().combineDetailed(
        segments: [
          builderLeg(first),
          builderLeg(second),
        ],
        legIndex: 0,
        scenic: info(),
        junctionWaypoints: const [w],
      );
      // Measured and reported, but never accepted: acceptance is exactness.
      expect(outcome.ok, isFalse);
      expect(outcome.failure, ScenicStageFailure.junctionNotContinuous);
      expect(outcome.leg, isNull);
      final junction = outcome.junctions.single;
      expect(junction.gapMeters, greaterThan(1.0));
      expect(
        junction.gapMeters,
        lessThanOrEqualTo(ScenicStageBuilder.maxJoinGapMeters),
      );
      expect(junction.bothWithinSnapRadius, isTrue,
          reason: 'a junction MapKit snapped apart; the engine confirms it');
      expect(junction.accepted, isFalse,
          reason: 'the tolerance band must never grant a join in the builder');
      // The same measurement IS eligible for engine-side confirmation.
      expect(
        ScenicStageBuilder.junctionEligibleForConfirmation(
          gapMeters: junction.gapMeters,
          snapFromEndMeters: 0,
          snapFromStartMeters: 0,
        ),
        isTrue,
      );
    });

    test('an engine-produced chain (bit-identical junctions) still builds',
        () {
      // What the engine hands over after confirming junctions: exactly
      // continuous pieces, the confirmed connector among them.
      const shared = GeoCoord(60.002, 30.0005);
      const connectorMid = GeoCoord(60.0020006, 30.0005117);
      final outcome = const ScenicStageBuilder().combineDetailed(
        segments: [
          builderLeg(straight(a, shared)),
          builderLeg(const [shared, connectorMid, jitteredStart]),
          builderLeg(straight(jitteredStart, b)),
        ],
        legIndex: 0,
        scenic: info(),
        junctionWaypoints: const [shared, shared],
      );
      expect(outcome.ok, isTrue);
      expect(outcome.junctions, hasLength(2));
      expect(outcome.junctions.every((j) => j.accepted), isTrue);
      expect(
        outcome.leg!.geometryPoints.any(
          (p) => p.latitude == connectorMid.latitude &&
              p.longitude == connectorMid.longitude,
        ),
        isTrue,
        reason: 'the connector\u2019s own geometry is part of the stage',
      );
    });

    test('a gap above the cap is rejected with the measured value and no '
        'leg built', () {
      const farStart = GeoCoord(60.002, 30.0006); // ~5.6 m east
      final outcome = const ScenicStageBuilder().combineDetailed(
        segments: [
          builderLeg(straight(a, w)),
          builderLeg(straight(farStart, b)),
        ],
        legIndex: 0,
        scenic: info(),
        junctionWaypoints: const [w],
      );
      expect(outcome.ok, isFalse);
      expect(outcome.failure, ScenicStageFailure.junctionNotContinuous);
      expect(outcome.junctions.single.accepted, isFalse);
      expect(outcome.junctions.single.gapMeters, greaterThan(5));
      expect(outcome.leg, isNull);
    });

    test('a small gap is still rejected when a projection is far from the '
        'verified waypoint (different walkway guard)', () {
      // ~1.2 m gap between the two projections, but both sit ~25 m from the
      // verified waypoint — not the same physical place.
      final shifted = GeoCoord(
        jitteredStart.latitude + 0.00022,
        jitteredStart.longitude,
      );
      final outcome = const ScenicStageBuilder().combineDetailed(
        segments: [
          builderLeg(straight(a, w)),
          builderLeg(straight(shifted, b)),
        ],
        legIndex: 0,
        scenic: info(),
        junctionWaypoints: const [w],
      );
      expect(outcome.failure, ScenicStageFailure.junctionNotContinuous);
      expect(outcome.junctions.single.bothWithinSnapRadius, isFalse);
    });

    test('without junction waypoints the exactness band is unchanged '
        '(legacy callers, no policy)', () {
      final outcome = const ScenicStageBuilder().combineDetailed(
        segments: [
          builderLeg(straight(a, w)),
          builderLeg(straight(jitteredStart, b)),
        ],
        legIndex: 0,
        scenic: info(),
      );
      expect(outcome.ok, isFalse);
      expect(outcome.failure, ScenicStageFailure.junctionNotContinuous);
    });

    test('the legacy combine() still returns the leg or null', () {
      expect(
        const ScenicStageBuilder().combine(
          segments: [builderLeg(straight(a, w)), builderLeg(straight(w, b))],
          legIndex: 0,
          scenic: info(),
          junctionWaypoints: const [w],
        ),
        isNotNull,
      );
      expect(
        const ScenicStageBuilder().combine(
          segments: [builderLeg(straight(a, w))],
          legIndex: 0,
          scenic: info(),
        ),
        isNotNull,
      );
    });
  });

  group('§5 hotfix: native junction confirmation (no tolerance-only joins)',
      () {
    /// Route whose second leg starts 1.3 m north of the first leg's end —
    /// two projections of the same waypoint.
    _SequencedFake jitterService({double jitterMeters = 1.3}) =>
        _SequencedFake([
          const _LegSpec(seconds: 350, via: [GeoCoord(60.0008, 30.009)]),
          _LegSpec(
            seconds: 350,
            via: const [GeoCoord(60.0008, 30.0105)],
            startShiftNorthMeters: jitterMeters,
          ),
          // Junction connector answer (junction is near the corner).
          const _LegSpec(seconds: 2),
        ]);

    Future<ScenicEnhancementResult> run(
      _SequencedFake service, {
      NativeWalkRequestBudget? budget,
    }) =>
        ScenicWalkEngine(
          routeService: service,
          datasetFeatures: [
            feature(waypoint: wCorner, line: junctionFeatureLine),
          ],
        ).enhance(
          normalRoute: lShapedNormalRoute(),
          walkBudgetSeconds: 3600,
          requestBudget: budget ?? NativeWalkRequestBudget(12),
          diagnosticsContext: context(),
        );

    test('a jittered junction is confirmed by one native connector, joined '
        'exactly, and counted into the stage metrics', () async {
      final service = jitterService();
      final result = await run(service);
      // Two scenic legs + one junction confirmation.
      expect(service.calls, 3);
      expect(result.isScenic, isTrue);
      final scenic = result.route!.legs.single.scenic!;
      // The connector's native seconds/meters are part of the stage totals.
      expect(scenic.extraSeconds, 350 + 350 + 2 - 600);
      final report = ScenicDiagnostics.reports.single;
      final confirmed = report.junctionMeasurements
          .where((m) => m.connectorMeters > 0)
          .toList();
      expect(confirmed, hasLength(1));
      expect(confirmed.single.gapMeters, greaterThan(1.0));
      expect(confirmed.single.connectorMeters, lessThan(5.0));
      // The join is verified — no rejection recorded.
      expect(report.rejectionCounts[ScenicRejectionCategory.continuity],
          isNull);
      // The assembled geometry is exactly continuous at the junction: the
      // normalized coordinate appears once (skip(1) dedup of the shared
      // point), and the stage has one visit-carrying endpoint.
      final stage = result.route!.legs.single;
      expect(stage.maneuvers, isEmpty);
      expect(stage.visitMinutes, 30);
    });

    test('a gap beyond the confirmation band rejects without a connector '
        'request', () async {
      final service = jitterService(jitterMeters: 5.6);
      final result = await run(service);
      expect(service.calls, 2, reason: 'no confirmation was attempted');
      expect(result.isScenic, isFalse);
      final report = ScenicDiagnostics.reports.single;
      expect(report.rejectionCounts[ScenicRejectionCategory.continuity], 1);
      expect(
        report.rejectedCandidates.single.detail,
        contains('junctionNotContinuous'),
      );
      expect(report.rejectedCandidates.single.detail, contains('snap=ok'));
    });

    test('a small gap far from the verified waypoint rejects without a '
        'connector request (different walkway guard)', () async {
      final service = _SequencedFake(const [
        _LegSpec(
          seconds: 350,
          via: [GeoCoord(60.0008, 30.009)],
          shiftNorthMeters: 25,
        ),
        _LegSpec(
          seconds: 350,
          via: [GeoCoord(60.0008, 30.0105)],
          startShiftNorthMeters: 26.3,
        ),
      ]);
      final result = await run(service);
      expect(service.calls, 2);
      expect(result.isScenic, isFalse);
      expect(
        ScenicDiagnostics.reports.single.rejectedCandidates.single.detail,
        contains('snap=far'),
      );
    });

    test('a connector that has to go around something rejects the candidate',
        () async {
      // Calls 1–2: the scenic legs (junction jitter 1.3 m). Call 3: the
      // connector — routed 3 km around, far beyond max(gap×2, gap+5 m).
      final detour = _SequencedFake(const [
        _LegSpec(seconds: 350, via: [GeoCoord(60.0008, 30.009)]),
        _LegSpec(
          seconds: 350,
          via: [GeoCoord(60.0008, 30.0105)],
          startShiftNorthMeters: 1.3,
        ),
        _LegSpec(
          seconds: 900,
          via: [
            GeoCoord(60.028, 30.0005),
            GeoCoord(60.028, 30.0095),
          ],
        ),
      ]);
      final result = await ScenicWalkEngine(
        routeService: detour,
        datasetFeatures: [feature(waypoint: wCorner, line: junctionFeatureLine)],
      ).enhance(
        normalRoute: lShapedNormalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
        diagnosticsContext: context(),
      );
      expect(detour.calls, 3);
      expect(result.isScenic, isFalse);
      expect(
        ScenicDiagnostics.reports.single.rejectedCandidates.single.detail,
        contains('junctionConnectorTooLong'),
      );
    });

    test('a failed confirmation request rejects as an unavailable native '
        'route', () async {
      final service = jitterService();
      service.failOnCall = 3;
      final result = await run(service);
      expect(service.calls, 3);
      expect(result.isScenic, isFalse);
      final report = ScenicDiagnostics.reports.single;
      expect(report.rejectionCounts[ScenicRejectionCategory.mapkitUnavailable],
          1);
      expect(
        report.rejectedCandidates.single.detail,
        contains('junctionConnector'),
      );
    });

    test('no request budget for the confirmation rejects honestly', () async {
      final budget = NativeWalkRequestBudget(12);
      for (var i = 0; i < 10; i++) {
        budget.consume(); // exactly two requests left for the two legs
      }
      final service = jitterService();
      final result = await run(service, budget: budget);
      expect(service.calls, 2);
      expect(result.isScenic, isFalse);
      final report = ScenicDiagnostics.reports.single;
      expect(report.rejectionCounts[ScenicRejectionCategory.requestBudget], 1);
      expect(
        report.rejectedCandidates.single.detail,
        contains('junctionConfirmation'),
      );
      expect(budget.requests, 12);
    });
  });

  group('§5 final fix: the confirmed connector’s own geometry is in the '
      'route and every limit is re-checked', () {
    /// Junction design: leg1 ends exactly at the verified waypoint, leg2
    /// starts 1.3 m north of it (two projections of the same waypoint).
    final startProjection = _northOf(wCorner, 1.3);

    /// The confirmed connector is a real CURVE: one interior point ~2 m west
    /// of the 1.3 m step, so its geometry cannot be mistaken for the straight
    /// jump between the projections.
    final connectorMid = _westOf(_northOf(wCorner, 0.65), 2.0);
    final leg1Geometry = [a, const GeoCoord(60.0008, 30.009), wCorner];
    final leg2Geometry = [startProjection, const GeoCoord(60.0008, 30.0105), b];
    final leg1Meters = RouteProjectionUtils.polylineLengthMeters(leg1Geometry);
    final leg2Meters = RouteProjectionUtils.polylineLengthMeters(leg2Geometry);
    final connectorMeters = RouteProjectionUtils.polylineLengthMeters(
      [wCorner, connectorMid, startProjection],
    );

    /// Two native scenic legs (with native maneuvers) and the junction
    /// confirmation answer, in request order.
    _SequencedFake scenicService({int connectorSeconds = 10}) =>
        _SequencedFake([
          const _LegSpec(
            seconds: 350,
            via: [GeoCoord(60.0008, 30.009)],
            maneuvers: [
              _ManeuverSpec(PedestrianManeuverKind.right, 1),
            ],
          ),
          const _LegSpec(
            seconds: 250,
            via: [GeoCoord(60.0008, 30.0105)],
            startShiftNorthMeters: 1.3,
            maneuvers: [
              _ManeuverSpec(PedestrianManeuverKind.left, 1),
            ],
          ),
          _LegSpec(
            seconds: connectorSeconds,
            via: [connectorMid],
            maneuvers: const [
              _ManeuverSpec(PedestrianManeuverKind.crosswalk, 1),
            ],
          ),
        ]);

    Future<ScenicEnhancementResult> run(
      _SequencedFake service, {
      required int walkBudgetSeconds,
      ScenicScoringConfig? config,
    }) =>
        ScenicWalkEngine(
          routeService: service,
          datasetFeatures: [feature(waypoint: wCorner, line: junctionFeatureLine)],
          config: config ?? const ScenicScoringConfig(),
        ).enhance(
          normalRoute: lShapedNormalRoute(),
          walkBudgetSeconds: walkBudgetSeconds,
          requestBudget: NativeWalkRequestBudget(12),
          diagnosticsContext: context(),
        );

    test('the connector is spliced with its real curve, bit-identical '
        'junctions and its own metrics — maneuver indices and offsets stay '
        'correct', () async {
      final service = scenicService();
      final result = await run(service, walkBudgetSeconds: 3600);
      expect(service.calls, 3, reason: 'legs + one junction confirmation');
      expect(result.isScenic, isTrue);
      final stage = result.route!.legs.single;

      // The walked geometry is the real chain: every native point, the
      // connector's curve among them, shared points exactly once.
      expect(stage.geometryPoints, hasLength(7));
      expect(_containsPoint(stage.geometryPoints, connectorMid), isTrue);
      expect(_containsPoint(stage.geometryPoints, startProjection), isTrue);
      expect(stage.distanceMeters, closeTo(
        leg1Meters + connectorMeters + leg2Meters,
        1e-6,
      ));
      expect(stage.durationSeconds, 350 + 10 + 250);
      expect(stage.visitMinutes, 30);
      expect(stage.scenic!.evidence.name, 'verifiedOnPath');

      // Native maneuvers are preserved in order, and every index/offset is
      // rebased onto the combined geometry: the connector owns its own points
      // and its own native time/distance.
      expect(
        stage.maneuvers.map((m) => m.kind),
        [
          PedestrianManeuverKind.right,
          PedestrianManeuverKind.crosswalk,
          PedestrianManeuverKind.left,
        ],
      );
      expect(stage.maneuvers.map((m) => m.segmentIndex), [1, 3, 5]);
      //   leg1 point 1 | connector point 1 | leg2 point 1 of the 7.
      final expectedOffsets = [
        RouteProjectionUtils.polylineLengthMeters([a, leg1Geometry[1]]),
        leg1Meters +
            RouteProjectionUtils.polylineLengthMeters([wCorner, connectorMid]),
        leg1Meters +
            connectorMeters +
            RouteProjectionUtils.polylineLengthMeters(
              [startProjection, leg2Geometry[1]],
            ),
      ];
      for (var i = 0; i < expectedOffsets.length; i++) {
        expect(stage.maneuvers[i].offsetMeters,
            closeTo(expectedOffsets[i], 1e-6));
      }
      // Every maneuver still resolves on the walked geometry, at its real
      // native location — the connector's own maneuver included.
      final resolved = [
        for (final m in stage.maneuvers)
          m.coordinateOnLeg(stage.geometryPoints)!,
      ];
      expect(_containsPoint([resolved[0]], leg1Geometry[1]), isTrue);
      expect(_containsPoint([resolved[1]], connectorMid), isTrue);
      expect(_containsPoint([resolved[2]], leg2Geometry[1]), isTrue);

      // The junction measurement shows the confirmed connector's own meters.
      final confirmed = ScenicDiagnostics.reports.single.junctionMeasurements
          .where((m) => m.connectorMeters > 0)
          .toList();
      expect(confirmed, hasLength(1));
      expect(confirmed.single.connectorMeters, closeTo(connectorMeters, 1e-6));
      expect(
        confirmed.single.connectorMeters,
        lessThanOrEqualTo(
          ScenicStageBuilder.maxConnectorMeters(confirmed.single.gapMeters),
        ),
      );
      expect(
        ScenicDiagnostics.reports.single
            .rejectionCounts[ScenicRejectionCategory.continuity],
        isNull,
      );
    });

    test('the spliced connector is the real curve, not the straight jump: '
        'its neighbours in the walked geometry are the exact projections',
        () async {
      final service = scenicService();
      final result = await run(service, walkBudgetSeconds: 3600);
      final points = result.route!.legs.single.geometryPoints;
      final midIndex = points.indexWhere(
        (p) => p.latitude == connectorMid.latitude &&
            p.longitude == connectorMid.longitude,
      );
      expect(midIndex, greaterThan(0));
      expect(midIndex, lessThan(points.length - 1));
      // Exactly continuous: the end of the first leg and the start of the
      // second are bit-identical to the connector's pinned endpoints.
      expect(_containsPoint([points[midIndex - 1]], wCorner), isTrue);
      expect(_containsPoint([points[midIndex + 1]], startProjection), isTrue);
    });

    test('a confirmed connector that pushes the whole-walk time budget over '
        'the preset is rejected after confirmation', () async {
      // The plan fits with 5 s of slack (350 + 250 = 600 ≤ 605); the
      // confirmation is requested, and the connector's own 10 s then exceed
      // the boundary — the re-check must reject, not the pre-filter.
      final service = scenicService();
      final result = await run(service, walkBudgetSeconds: 605);
      expect(service.calls, 3, reason: 'the confirmation was requested');
      expect(result.isScenic, isFalse);
      expect(result.fallbackReason, ScenicFallbackReason.budgetExceeded);
      final report = ScenicDiagnostics.reports.single;
      expect(report.rejectionCounts[ScenicRejectionCategory.walkingBudget], 1);
      final rejected = report.rejectedCandidates.single;
      expect(rejected.detail, 'junctionRecheck');
      expect(rejected.extraMinutes, closeTo(10 / 60, 1e-9),
          reason: 'measured on POST-confirmation totals (pre was 0)');
    });

    test('a confirmed connector that crosses the detour share is rejected '
        'after confirmation', () async {
      final normalMeters = lShapedNormalRoute().legs.single.distanceMeters;
      // A share the pre-confirmation plan passes with a millimetre of slack:
      // only the connector's own meters can cross it.
      final share = (leg1Meters + leg2Meters) / normalMeters + 1e-6;
      expect(
        leg1Meters + leg2Meters,
        lessThanOrEqualTo(normalMeters * share),
        reason: 'the pre-confirmation plan passes the share gate',
      );
      final service = scenicService();
      final result = await run(
        service,
        walkBudgetSeconds: 3600,
        config: ScenicScoringConfig(maxDetourShare: share),
      );
      expect(service.calls, 3);
      expect(result.isScenic, isFalse);
      final report = ScenicDiagnostics.reports.single;
      expect(report.rejectionCounts[ScenicRejectionCategory.detour], 1);
      final rejected = report.rejectedCandidates.single;
      expect(rejected.detail, 'junctionRecheck');
      // extraMeters is measured against the normal route; the connector's own
      // distance is exactly what pushed it past `share`.
      expect(
        rejected.extraMeters,
        closeTo(leg1Meters + leg2Meters - normalMeters + connectorMeters, 1e-6),
      );
    });

    test('a connector whose native seconds cost more than the score can pay '
        'is rejected after confirmation', () async {
      // Synthetic stress: an artificially slow connector (10 native minutes
      // for a few metres). The point is the gate, not MapKit realism — the
      // score penalty must be applied to the POST-confirmation totals.
      final service = scenicService(connectorSeconds: 600);
      final result = await run(service, walkBudgetSeconds: 3600);
      expect(service.calls, 3);
      expect(result.isScenic, isFalse);
      final report = ScenicDiagnostics.reports.single;
      expect(report.rejectionCounts[ScenicRejectionCategory.score], 1);
      final rejected = report.rejectedCandidates.single;
      expect(rejected.detail, 'junctionRecheck');
      expect(rejected.extraMinutes, closeTo(10, 1e-9));
      expect(rejected.score, lessThan(0.25));
    });
  });

  group('§3 diagnostics: bounded, opt-in, distribution-complete', () {
    test('recording is a no-op while disabled', () async {
      ScenicDiagnostics.enabled = false;
      final engine = ScenicWalkEngine(
        routeService: _SequencedFake(const [_LegSpec(), _LegSpec()]),
        datasetFeatures: [feature(id: 'far', waypoint: const GeoCoord(60.004, 30.02))],
      );
      await engine.enhance(
        normalRoute: lShapedNormalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
        diagnosticsContext: context(),
      );
      expect(ScenicDiagnostics.reports, isEmpty);
    });

    test('no context supplied means no report even when enabled', () async {
      final engine = ScenicWalkEngine(
        routeService: _SequencedFake(const [_LegSpec(), _LegSpec()]),
        datasetFeatures: [feature(id: 'far', waypoint: const GeoCoord(60.004, 30.02))],
      );
      await engine.enhance(
        normalRoute: lShapedNormalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
      );
      expect(ScenicDiagnostics.reports, isEmpty);
    });

    test('a mixed attempt records the funnel, the rejection distribution, '
        'the junction measurements and the outcome', () async {
      // Three independent stages, one interesting candidate each:
      //  calls 1–2: a via-following embankment detour → accepted;
      //  calls 3–4: the whole native route snapped ~200 m north of its
      //             verified line → coverage rejection;
      //  calls 5–6: 900 s per leg → +20 minutes → walking-budget rejection.
      final service = _SequencedFake(const [
        _LegSpec(seconds: 250, via: [GeoCoord(60.0012, 30.003)]),
        _LegSpec(seconds: 250, via: [GeoCoord(60.0012, 30.006)]),
        _LegSpec(seconds: 300, shiftNorthMeters: 200, shiftAllPoints: true),
        _LegSpec(seconds: 300, shiftNorthMeters: 200, shiftAllPoints: true),
        _LegSpec(seconds: 900),
        _LegSpec(seconds: 900),
      ]);
      final f1 = feature(
        id: 'f-emb',
        name: 'Набережная Первая',
        waypoint: const GeoCoord(60.0012, 30.0045),
        line: const [GeoCoord(60.0012, 30.003), GeoCoord(60.0012, 30.006)],
      );
      final f2 = feature(
        id: 'f-shifted',
        name: 'Набережная Вторая',
        waypoint: const GeoCoord(60.02, 30.0045),
        line: const [GeoCoord(60.02, 30.003), GeoCoord(60.02, 30.006)],
      );
      final f3 = feature(
        id: 'f-expensive',
        name: 'Набережная Третья',
        waypoint: const GeoCoord(60.04, 30.0045),
        line: const [GeoCoord(60.04, 30.003), GeoCoord(60.04, 30.006)],
      );
      final normal = _route([
        _leg(const [GeoCoord(60.0, 30.0), GeoCoord(60.0, 30.008)],
            seconds: 400, to: 'POI 1'),
        _leg(const [GeoCoord(60.02, 30.0), GeoCoord(60.02, 30.008)],
            seconds: 400, to: 'POI 2'),
        _leg(const [GeoCoord(60.04, 30.0), GeoCoord(60.04, 30.008)],
            seconds: 400, to: 'POI 3'),
      ]);
      final engine = ScenicWalkEngine(
        routeService: service,
        datasetFeatures: [f1, f2, f3],
      );
      final result = await engine.enhance(
        normalRoute: normal,
        walkBudgetSeconds: 1800,
        requestBudget: NativeWalkRequestBudget(12),
        diagnosticsContext: context(),
      );
      expect(service.calls, 6);
      expect(result.isScenic, isTrue);
      expect(ScenicDiagnostics.reports, hasLength(1));
      final report = ScenicDiagnostics.reports.single;
      expect(report.requestedWalkKind, 'scenic');
      expect(report.datasetVersion, 'test-version');
      expect(report.datasetFeaturesCount, 4);
      expect(report.routeLegsCount, 3);
      expect(report.normalWalkingSeconds, 1200);
      expect(report.visitSeconds, 1800);
      expect(report.selectedPresetBudgetSeconds, 3600);
      expect(report.nativeRequestsUsedBeforeScenic, 0);
      expect(report.nativeRequestsRemainingBeforeScenic, 12);
      expect(report.candidatesInCorridor, 3);
      expect(report.candidatesConsidered, 3);
      expect(report.candidatesNativeRouted, 3);
      expect(report.rejectionCounts[ScenicRejectionCategory.coverage], 1);
      expect(report.rejectionCounts[ScenicRejectionCategory.walkingBudget], 1);
      expect(report.rejectedCandidates, hasLength(2));
      expect(
        report.rejectedCandidates
            .map((r) => r.category)
            .toSet(),
        {ScenicRejectionCategory.coverage, ScenicRejectionCategory.walkingBudget},
      );
      // Junction measurements recorded for every evaluated candidate (one
      // junction each) — the §5 measurement instrument.
      expect(report.junctionMeasurements, hasLength(3));
      expect(
        report.junctionMeasurements.every((m) => m.gapMeters < 0.001),
        isTrue,
        reason: 'the fake returns the requested waypoint exactly',
      );
      expect(report.scenicStagesAccepted, 1);
      expect(report.scenicWaypointsAccepted, 1);
      expect(report.nativeRequestsUsedAfterScenic, 6);
      expect(report.finalFallbackReason, 'none');
      expect(report.finalWalkKind, 'scenic');
      // Non-sensitive: the debug map carries ids and numbers only.
      final map = report.toDebugMap();
      expect(map.containsKey('junctions'), isTrue);
      expect(map.toString(), isNot(contains('latitude')));
    });

    test('the buffer is bounded to the newest reports', () async {
      for (var i = 0; i < ScenicDiagnostics.maxReports + 3; i++) {
        final engine = ScenicWalkEngine(
          routeService: _SequencedFake(const [
            _LegSpec(seconds: 350, via: [GeoCoord(60.0008, 30.009)]),
            _LegSpec(seconds: 350, via: [GeoCoord(60.0008, 30.0105)]),
          ]),
          datasetFeatures: [feature(waypoint: wCorner)],
        );
        await engine.enhance(
          normalRoute: lShapedNormalRoute(),
          walkBudgetSeconds: 3600,
          requestBudget: NativeWalkRequestBudget(12),
          diagnosticsContext: context(),
        );
      }
      expect(
        ScenicDiagnostics.reports,
        hasLength(ScenicDiagnostics.maxReports),
      );
    });

    test('a failed attempt reports the honest final reason', () async {
      final service = _SequencedFake(const [_LegSpec()])..failNext = true;
      final engine = ScenicWalkEngine(
        routeService: service,
        datasetFeatures: [feature(waypoint: wCorner)],
      );
      final result = await engine.enhance(
        normalRoute: lShapedNormalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: NativeWalkRequestBudget(12),
        diagnosticsContext: context(),
      );
      expect(result.isScenic, isFalse);
      final report = ScenicDiagnostics.reports.single;
      expect(report.finalFallbackReason, 'mapkitUnavailable');
      expect(report.finalWalkKind, 'normal');
      expect(
        report.rejectionCounts[ScenicRejectionCategory.mapkitUnavailable],
        1,
      );
    });
  });

  group('§7 request budget audit', () {
    test('every evaluated candidate consumes exactly two requests and the '
        'cap is never exceeded', () async {
      // Four acceptable embankment candidates near the corner; the walk
      // build already used 6 of the 12 requests.
      final service = _SequencedFake(const [
        _LegSpec(seconds: 350, via: [GeoCoord(60.0008, 30.009)]),
        _LegSpec(seconds: 350, via: [GeoCoord(60.0008, 30.0105)]),
        _LegSpec(seconds: 350),
        _LegSpec(seconds: 350),
        _LegSpec(seconds: 350),
        _LegSpec(seconds: 350),
      ]);
      final features = [
        for (var i = 0; i < 4; i++)
          feature(
            id: 'e${i + 1}',
            name: 'Набережная ${i + 1}',
            waypoint: GeoCoord(
              60.0008,
              // e1–e3 close together; e4 stays >150 m from ALL of their
              // waypoints after any one wins, reaching the budget gate at
              // the next level regardless of the corrected coverage order.
              i < 3 ? 30.0095 + 0.0008 * i : 30.0155,
            ),
            line: const [
              a,
              GeoCoord(60.0008, 30.009),
              GeoCoord(60.0008, 30.016),
              b,
            ],
          ),
      ];
      final engine = ScenicWalkEngine(
        routeService: service,
        datasetFeatures: features,
      );
      final budget = NativeWalkRequestBudget(12);
      for (var i = 0; i < 6; i++) {
        budget.consume(); // 6 legacy native leg requests
      }
      final result = await engine.enhance(
        normalRoute: lShapedNormalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: budget,
        diagnosticsContext: context(),
      );
      // maxCandidatesPerStep = 3 → 6 requests, leaving 0; the remaining
      // candidate is honestly rejected by the request budget without a call.
      expect(service.calls, 6);
      expect(budget.requests, 12);
      expect(result.isScenic, isTrue,
          reason: 'an accepted earlier stage survives later starvation');
      final report = ScenicDiagnostics.reports.single;
      expect(report.rejectionCounts[ScenicRejectionCategory.requestBudget], 1);
      expect(report.nativeRequestsUsedAfterScenic, 12);
      expect(report.nativeRequestsRemainingBeforeScenic, 6);
      expect(report.candidatesConsidered, 3);
    });

    test('with fewer than two requests left the engine makes no calls at all',
        () async {
      final service = _SequencedFake(const [_LegSpec()]);
      final engine = ScenicWalkEngine(
        routeService: service,
        datasetFeatures: [feature(waypoint: wCorner)],
      );
      final budget = NativeWalkRequestBudget(12);
      for (var i = 0; i < 11; i++) {
        budget.consume();
      }
      final result = await engine.enhance(
        normalRoute: lShapedNormalRoute(),
        walkBudgetSeconds: 3600,
        requestBudget: budget,
        diagnosticsContext: context(),
      );
      expect(service.calls, 0);
      expect(
        result.fallbackReason,
        ScenicFallbackReason.requestBudgetExhausted,
      );
      expect(
        ScenicDiagnostics.reports.single
            .rejectionCounts[ScenicRejectionCategory.requestBudget],
        1,
      );
    });
  });
}
