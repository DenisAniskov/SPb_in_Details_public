import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/services/scenic_stage_builder.dart';

/// Phase C5 §2: combining real MapKit segments into ONE tourist stage with
/// rebased maneuvers. Invariants: exact shared waypoints, no invented
/// connectors, order-preserving rebase, single arrival endpoint.
void main() {
  const builder = ScenicStageBuilder();

  // A → W (north-east), W → B (north-east), sharing the exact waypoint W.
  const a = GeoCoord(60.0, 30.0);
  const w = GeoCoord(60.0002, 30.0005);
  const b = GeoCoord(60.0005, 30.0010);

  maneuver(int segmentIndex, double offsetMeters) => PedestrianManeuverModel(
        kind: PedestrianManeuverKind.right,
        segmentIndex: segmentIndex,
        segmentPosition: 0.5,
        offsetMeters: offsetMeters,
        legIndex: 0,
      );

  RouteLegModel segment({
    required GeoCoord from,
    required GeoCoord to,
    required String toTitle,
    List<PedestrianManeuverModel> maneuvers = const [],
    int durationSeconds = 60,
  }) {
    final mid = GeoCoord(
      (from.latitude + to.latitude) / 2,
      (from.longitude + to.longitude) / 2,
    );
    return RouteLegModel(
      fromTitle: 'Откуда',
      toTitle: toTitle,
      distanceMeters: RouteProjectionUtils.polylineLengthMeters([from, mid, to]),
      durationSeconds: durationSeconds,
      geometryPoints: [from, mid, to],
      maneuvers: maneuvers,
    );
  }

  ScenicStageInfo scenicInfo({List<String> names = const ['Тестовая набережная']}) =>
      ScenicStageInfo(
        featureIds: const ['spb-scenic-test-way-1'],
        featureNames: names,
        evidence: ScenicEvidenceLevel.verifiedOnPath,
        coverageShare: 0.9,
        extraSeconds: 20,
        extraMeters: 15,
        score: 1.3,
        explanation: 'Проходит по Тестовая набережная',
      );

  group('combine(): valid scenic chains', () {
    test('two segments merge into one stage leg', () {
      final leg = builder.combine(
        segments: [
          segment(from: a, to: w, toTitle: 'Набережная', maneuvers: [maneuver(0, 10)]),
          segment(from: w, to: b, toTitle: 'POI 1', maneuvers: [maneuver(0, 10)]),
        ],
        legIndex: 0,
        scenic: scenicInfo(),
      );
      expect(leg, isNotNull);
      expect(leg!.scenic, isNotNull);
      // Combined geometry: 3 + 3 - 1 shared waypoint = 5 points.
      expect(leg.geometryPoints, hasLength(5));
      expect(leg.geometryPoints.first, a);
      expect(leg.geometryPoints.last, b);
      // Shared waypoint present exactly once, in the middle.
      expect(leg.geometryPoints[2], w);
      // Native sums are preserved.
      expect(leg.durationSeconds, 120);
      expect(
        leg.distanceMeters,
        closeTo(
          RouteProjectionUtils.polylineLengthMeters([a, w]) +
              RouteProjectionUtils.polylineLengthMeters([w, b]),
          0.5,
        ),
      );
      // The stage endpoint is the tourist stop: waypoints never arrive.
      expect(leg.toTitle, 'POI 1');
    });

    test('later-segment maneuvers rebase onto the combined geometry', () {
      final seg1 = segment(
        from: a,
        to: w,
        toTitle: 'Набережная',
        maneuvers: [maneuver(0, 10)],
      );
      final seg2 = segment(
        from: w,
        to: b,
        toTitle: 'POI 1',
        maneuvers: [maneuver(0, 12)],
      );
      final leg = builder.combine(
        segments: [seg1, seg2],
        legIndex: 0,
        scenic: scenicInfo(),
      )!;
      expect(leg.maneuvers, hasLength(2));
      final first = leg.maneuvers[0];
      final second = leg.maneuvers[1];
      // First segment keeps its coordinates.
      expect(first.segmentIndex, 0);
      expect(first.offsetMeters, closeTo(10, 0.5));
      // Second segment shifts by the first segment's point count (3-1=2)
      // and length.
      expect(second.segmentIndex, 2);
      expect(
        second.offsetMeters,
        closeTo(12 + RouteProjectionUtils.polylineLengthMeters(seg1.geometryPoints), 0.5),
      );
      // The rebased positions resolve on the combined geometry.
      expect(first.coordinateOnLeg(leg.geometryPoints), isNotNull);
      expect(second.coordinateOnLeg(leg.geometryPoints), isNotNull);
      // Ordering survives the merge.
      expect(second.offsetMeters, greaterThan(first.offsetMeters));
    });

    test('visit minutes come from the stage destination only', () {
      final seg1 = segment(from: a, to: w, toTitle: 'Набережная');
      const seg2 = RouteLegModel(
        fromTitle: 'Набережная',
        toTitle: 'POI 1',
        distanceMeters: 40,
        durationSeconds: 60,
        geometryPoints: [w, b],
        visitMinutes: 30,
      );
      final leg = builder.combine(
        segments: [seg1, seg2],
        legIndex: 0,
        scenic: scenicInfo(),
      )!;
      expect(leg.visitMinutes, 30);
    });
  });

  group('combine(): honest rejections', () {
    test('missing shared waypoint is rejected (no invented connectors)', () {
      const otherWaypoint = GeoCoord(60.0002, 30.0006);
      final leg = builder.combine(
        segments: [
          segment(from: a, to: w, toTitle: 'Набережная'),
          segment(from: otherWaypoint, to: b, toTitle: 'POI 1'),
        ],
        legIndex: 0,
        scenic: scenicInfo(),
      );
      expect(leg, isNull);
    });

    test('degenerate or invalid geometry is rejected', () {
      expect(
        builder.combine(
          segments: [segment(from: a, to: w, toTitle: 'Набережная')],
          legIndex: 0,
          scenic: scenicInfo(),
        ),
        isNotNull,
      );
      expect(
        builder.combine(
          segments: const [],
          legIndex: 0,
          scenic: scenicInfo(),
        ),
        isNull,
      );
      const nanLeg = RouteLegModel(
        fromTitle: 'A',
        toTitle: 'B',
        distanceMeters: 10,
        durationSeconds: 10,
        geometryPoints: [
          a,
          GeoCoord(double.nan, 30.0),
        ],
      );
      expect(
        builder.combine(
          segments: [nanLeg],
          legIndex: 0,
          scenic: scenicInfo(),
        ),
        isNull,
      );
    });

    test('rebase that breaks ordering rejects the whole stage', () {
      // The second segment carries a maneuver that lands BEFORE the first
      // segment's maneuver on the combined geometry.
      final seg1 = segment(
        from: a,
        to: w,
        toTitle: 'Набережная',
        maneuvers: [maneuver(0, 25)],
      );
      final seg2 = segment(
        from: w,
        to: b,
        toTitle: 'POI 1',
        maneuvers: [maneuver(0, -1000)],
      );
      final leg = builder.combine(
        segments: [seg1, seg2],
        legIndex: 0,
        scenic: scenicInfo(),
      );
      expect(leg, isNull);
    });

    test('rebase outside the combined geometry rejects the stage', () {
      final seg1 = segment(from: a, to: w, toTitle: 'Набережная');
      const seg2 = RouteLegModel(
        fromTitle: 'Набережная',
        toTitle: 'POI 1',
        distanceMeters: 40,
        durationSeconds: 60,
        geometryPoints: [w, b],
        maneuvers: [
          PedestrianManeuverModel(
            kind: PedestrianManeuverKind.left,
            segmentIndex: 50,
            segmentPosition: 0.5,
            offsetMeters: 12,
            legIndex: 0,
          ),
        ],
      );
      final leg = builder.combine(
        segments: [seg1, seg2],
        legIndex: 0,
        scenic: scenicInfo(),
      );
      expect(leg, isNull);
    });
  });
}
