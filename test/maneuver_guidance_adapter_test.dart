import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/services/guidance_diagnostics.dart';
import 'package:smart_navigator_spb/services/mapkit_pedestrian_guidance_adapter.dart';

/// Phase C4 Part A/H: conservative geometry association and diagnostics.
/// `adapt()` is the pure validation core of the native adapter; the native
/// traversal (`fromNativeRoute`) requires live SDK objects and is exercised
/// by the device checklist instead of unit tests.
void main() {
  // ~55.6 m northward leg.
  const geometry = [
    GeoCoord(60.0, 30.0),
    GeoCoord(60.0005, 30.0),
  ];
  const completeSection = (
    beginIndex: 0,
    beginPosition: 0.0,
    endIndex: 1,
    endPosition: 0.0,
  );

  PedestrianAnnotationData annotation(
    PedestrianManeuverKind kind,
    int segmentIndex,
    double segmentPosition,
  ) =>
      PedestrianAnnotationData(
        kind: kind,
        segmentIndex: segmentIndex,
        segmentPosition: segmentPosition,
      );

  group('Adapter geometry association (Part A2)', () {
    test('single complete section with annotations is accepted', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: geometry,
        sectionBeginIndex: completeSection.beginIndex,
        sectionBeginPosition: completeSection.beginPosition,
        sectionEndIndex: completeSection.endIndex,
        sectionEndPosition: completeSection.endPosition,
        annotations: [
          annotation(PedestrianManeuverKind.right, 0, 0.5),
          annotation(PedestrianManeuverKind.crosswalk, 0, 0.9),
        ],
      );
      expect(maneuvers, hasLength(2));
      expect(maneuvers[0].kind, PedestrianManeuverKind.right);
      expect(maneuvers[0].offsetMeters, closeTo(27.8, 0.2));
      expect(maneuvers[0].legIndex, 0);
      expect(maneuvers[0].source, PedestrianManeuverSource.nativeAnnotation);
    });

    test('section not starting at the route start is rejected', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: geometry,
        sectionBeginIndex: 0,
        sectionBeginPosition: 0.4,
        sectionEndIndex: 1,
        sectionEndPosition: 0.0,
        annotations: [annotation(PedestrianManeuverKind.right, 0, 0.5)],
      );
      expect(maneuvers, isEmpty);
    });

    test('section not ending at the route endpoint is rejected', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: geometry,
        sectionBeginIndex: 0,
        sectionBeginPosition: 0.0,
        sectionEndIndex: 0,
        sectionEndPosition: 0.5,
        annotations: [annotation(PedestrianManeuverKind.right, 0, 0.5)],
      );
      expect(maneuvers, isEmpty);
    });

    test('invalid geometry degrades the whole leg to fallback', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: const [GeoCoord(60.0, 30.0), GeoCoord(double.nan, 30.0)],
        sectionBeginIndex: 0,
        sectionBeginPosition: 0.0,
        sectionEndIndex: 1,
        sectionEndPosition: 0.0,
        annotations: const [],
      );
      expect(maneuvers, isEmpty);
    });

    test('degenerate zero-length geometry is rejected', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: const [GeoCoord(60.0, 30.0), GeoCoord(60.0, 30.0)],
        sectionBeginIndex: 0,
        sectionBeginPosition: 0.0,
        sectionEndIndex: 1,
        sectionEndPosition: 0.0,
        annotations: const [],
      );
      expect(maneuvers, isEmpty);
    });
  });

  group('Annotation position validation', () {
    test('out-of-range segment index rejects the whole leg', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: geometry,
        sectionBeginIndex: completeSection.beginIndex,
        sectionBeginPosition: completeSection.beginPosition,
        sectionEndIndex: completeSection.endIndex,
        sectionEndPosition: completeSection.endPosition,
        annotations: [annotation(PedestrianManeuverKind.left, 5, 0.5)],
      );
      expect(maneuvers, isEmpty);
    });

    test('fraction outside 0..1 rejects the whole leg', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: geometry,
        sectionBeginIndex: completeSection.beginIndex,
        sectionBeginPosition: completeSection.beginPosition,
        sectionEndIndex: completeSection.endIndex,
        sectionEndPosition: completeSection.endPosition,
        annotations: [annotation(PedestrianManeuverKind.left, 0, 1.4)],
      );
      expect(maneuvers, isEmpty);
    });

    test('unsorted annotation offsets reject the whole leg', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: geometry,
        sectionBeginIndex: completeSection.beginIndex,
        sectionBeginPosition: completeSection.beginPosition,
        sectionEndIndex: completeSection.endIndex,
        sectionEndPosition: completeSection.endPosition,
        annotations: [
          annotation(PedestrianManeuverKind.right, 0, 0.7),
          annotation(PedestrianManeuverKind.left, 0, 0.3),
        ],
      );
      expect(maneuvers, isEmpty);
    });

    test('absent annotations are a valid fallback, not an error', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: geometry,
        sectionBeginIndex: completeSection.beginIndex,
        sectionBeginPosition: completeSection.beginPosition,
        sectionEndIndex: completeSection.endIndex,
        sectionEndPosition: completeSection.endPosition,
        annotations: const [],
      );
      expect(maneuvers, isEmpty);
    });

    test('unsupported kinds (bicycle Dismount) are skipped without error', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: geometry,
        sectionBeginIndex: completeSection.beginIndex,
        sectionBeginPosition: completeSection.beginPosition,
        sectionEndIndex: completeSection.endIndex,
        sectionEndPosition: completeSection.endPosition,
        annotations: [
          const PedestrianAnnotationData(
            kind: null,
            segmentIndex: 0,
            segmentPosition: 0.5,
          ),
          annotation(PedestrianManeuverKind.straight, 0, 0.8),
        ],
      );
      expect(maneuvers, hasLength(1));
      expect(maneuvers.first.kind, PedestrianManeuverKind.straight);
    });

    test('terminal event at the route endpoint maps to the full offset', () {
      final maneuvers = const MapKitPedestrianGuidanceAdapter().adapt(
        geometry: geometry,
        sectionBeginIndex: completeSection.beginIndex,
        sectionBeginPosition: completeSection.beginPosition,
        sectionEndIndex: completeSection.endIndex,
        sectionEndPosition: completeSection.endPosition,
        annotations: [annotation(PedestrianManeuverKind.crosswalk, 1, 0.0)],
      );
      expect(maneuvers, hasLength(1));
      expect(maneuvers.first.offsetMeters, closeTo(55.6, 0.2));
    });
  });

  group('Verified map coordinates', () {
    test('coordinateOnLeg interpolates the validated position', () {
      const maneuver = PedestrianManeuverModel(
        kind: PedestrianManeuverKind.right,
        segmentIndex: 0,
        segmentPosition: 0.5,
        offsetMeters: 27.8,
      );
      final point = maneuver.coordinateOnLeg(geometry);
      expect(point, isNotNull);
      expect(point!.latitude, closeTo(60.00025, 0.00001));
      expect(point.longitude, 30.0);
    });

    test('coordinateOnLeg refuses positions outside the geometry', () {
      const stale = PedestrianManeuverModel(
        kind: PedestrianManeuverKind.right,
        segmentIndex: 9,
        segmentPosition: 0.5,
        offsetMeters: 27.8,
      );
      expect(stale.coordinateOnLeg(geometry), isNull);

      const badFraction = PedestrianManeuverModel(
        kind: PedestrianManeuverKind.right,
        segmentIndex: 0,
        segmentPosition: 1.5,
        offsetMeters: 27.8,
      );
      expect(badFraction.coordinateOnLeg(geometry), isNull);
      expect(
        stale.coordinateOnLeg(const []),
        isNull,
      );
    });
  });

  group('Guidance diagnostics (Part A3)', () {
    tearDown(GuidanceDiagnostics.clear);

    test('recording is opt-in and disabled by default', () {
      GuidanceDiagnostics.enabled = false;
      GuidanceDiagnostics.record(const GuidanceStructureReport(
        sectionCount: 1,
        sectionTypeCounts: {'Pedestrian': 1},
        annotationCount: 2,
        acceptedManeuvers: 2,
        rejectedAnnotationCount: 0,
        rejectionReason: GuidanceRejectionReason.none,
        sectionPositionsMappedReliably: true,
        guidanceMode: 'nativeAnnotations',
      ));
      expect(GuidanceDiagnostics.reports, isEmpty);
    });

    test('enabled recording keeps only the bounded newest window', () {
      GuidanceDiagnostics.enabled = true;
      addTearDown(() => GuidanceDiagnostics.enabled = false);
      for (var i = 0; i < GuidanceDiagnostics.maxReports + 3; i++) {
        GuidanceDiagnostics.record(GuidanceStructureReport(
          sectionCount: i,
          sectionTypeCounts: const {'Pedestrian': 1},
          annotationCount: 0,
          acceptedManeuvers: 0,
          rejectedAnnotationCount: 0,
          rejectionReason: GuidanceRejectionReason.none,
          sectionPositionsMappedReliably: true,
          guidanceMode: 'fallback',
        ));
      }
      expect(
        GuidanceDiagnostics.reports.length,
        GuidanceDiagnostics.maxReports,
      );
      // Oldest dropped, newest retained.
      expect(GuidanceDiagnostics.reports.last.sectionCount,
          GuidanceDiagnostics.maxReports + 2);
      expect(GuidanceDiagnostics.reports.first.sectionCount, 3);
    });

    test('debug map carries only structural, non-sensitive fields', () {
      const report = GuidanceStructureReport(
        sectionCount: 2,
        sectionTypeCounts: {'Pedestrian': 1, 'wait': 1},
        annotationCount: 3,
        acceptedManeuvers: 1,
        rejectedAnnotationCount: 2,
        rejectionReason: GuidanceRejectionReason.multipleSections,
        sectionPositionsMappedReliably: false,
        guidanceMode: 'fallback',
      );
      final map = report.toDebugMap();
      expect(map['sections'], 2);
      expect(map['sectionTypes'], {'Pedestrian': 1, 'wait': 1});
      expect(map['annotations'], 3);
      expect(map['acceptedManeuvers'], 1);
      expect(map['rejectedAnnotations'], 2);
      expect(map['rejectionReason'], 'multipleSections');
      expect(map['positionsMapped'], false);
      expect(map['mode'], 'fallback');
      // No coordinates, keys or route data.
      expect(
        map.values.whereType<String>().where(
              (v) => v.contains('60.') || v.contains('30.'),
            ),
        isEmpty,
      );
    });
  });
}
