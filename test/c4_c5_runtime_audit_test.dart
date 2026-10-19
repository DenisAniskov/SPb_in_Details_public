import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/services/guidance_diagnostics.dart';
import 'package:smart_navigator_spb/services/scenic_diagnostics.dart';
import 'package:smart_navigator_spb/services/scenic_stage_builder.dart';
import 'package:smart_navigator_spb/services/scenic_walk_engine.dart';

/// Phase C4/C5 runtime fixes — audit of the cross-cutting invariants that the
/// phase's other suites verify behaviourally:
///  - diagnostics are opt-in, bounded, release-gated and non-sensitive (§3/§10);
///  - user-facing fallback texts are per-reason, honest and code-free (§8);
///  - the documented junction thresholds are frozen constants (§5);
///  - scenic + turn-by-turn integration boundaries stay owned by the C4/C5
///    suites in this repository (§12).
void main() {
  group('§3/§10 diagnostics hygiene', () {
    setUp(() {
      ScenicDiagnostics.enabled = false;
      GuidanceDiagnostics.enabled = false;
      ScenicDiagnostics.clear();
      GuidanceDiagnostics.clear();
    });
    tearDown(() {
      ScenicDiagnostics.enabled = false;
      GuidanceDiagnostics.enabled = false;
      ScenicDiagnostics.clear();
      GuidanceDiagnostics.clear();
    });

    test('both diagnostics services default to disabled and require opt-in',
        () {
      expect(ScenicDiagnostics.enabled, isFalse,
          reason: 'release builds stay silent unless a dart-define opts in');
      expect(GuidanceDiagnostics.enabled, isFalse);
      expect(ScenicDiagnostics.maxReports,
          lessThanOrEqualTo(16)); // bounded memory
      expect(GuidanceDiagnostics.maxReports,
          lessThanOrEqualTo(16));
    });

    test('a recorded scenic report carries no coordinates and no keys', () {
      // Build the report map from a fixed structural sample (the engine-level
      // values are covered in scenic_runtime_fixes_test.dart).
      const report = ScenicAttemptReport(
        requestedWalkKind: 'scenic',
        datasetVersion: '2026.10.11+1',
        datasetFeaturesCount: 187,
        routeLegsCount: 2,
        normalWalkingSeconds: 900,
        visitSeconds: 1800,
        selectedPresetBudgetSeconds: 3600,
        nativeRequestsUsedBeforeScenic: 2,
        nativeRequestsRemainingBeforeScenic: 10,
        candidatesInCorridor: 4,
        candidatesConsidered: 3,
        candidatesNativeRouted: 2,
        rejectionCounts: {ScenicRejectionCategory.coverage: 1},
        rejectedCandidates: [
          ScenicCandidateRejection(
            featureId: 'osm-way-1',
            featureType: 'embankment',
            coverageShare: 0.05,
            score: null,
            extraMinutes: 1.5,
            extraMeters: 120,
            category: ScenicRejectionCategory.coverage,
            nativeRequests: 2,
          ),
        ],
        junctionMeasurements: [
          ScenicJunctionMeasurement(
            gapMeters: 0.42,
            accepted: true,
            bothWithinSnapRadius: true,
          ),
        ],
        scenicStagesAccepted: 1,
        scenicWaypointsAccepted: 1,
        nativeRequestsUsedAfterScenic: 4,
        finalFallbackReason: 'none',
        finalWalkKind: 'scenic',
      );
      final map = report.toDebugMap();
      final flat = map.toString();
      expect(flat.toLowerCase(), isNot(contains('latitude')));
      expect(flat.toLowerCase(), isNot(contains('longitude')));
      expect(flat.toLowerCase(), isNot(contains('api_key')));
      expect(flat.toLowerCase(), isNot(contains('token')));
      // Feature ids are public dataset ids, never coordinates.
      expect(flat, contains('osm-way-1'));
      expect(map['requestedWalkKind'], 'scenic');
    });

    test('a guidance report with section spans still exposes indices only',
        () {
      const report = GuidanceStructureReport(
        sectionCount: 2,
        sectionTypeCounts: {'Pedestrian': 2},
        annotationCount: 5,
        acceptedManeuvers: 0,
        rejectedAnnotationCount: 5,
        rejectionReason: GuidanceRejectionReason.multipleSections,
        sectionPositionsMappedReliably: false,
        guidanceMode: 'fallback',
        geometrySegmentCount: 120,
        sections: [
          SectionStructure(
            type: 'Pedestrian',
            beginSegmentIndex: 0,
            beginSegmentPosition: 0,
            endSegmentIndex: 48,
            endSegmentPosition: 0.9,
            annotationCount: 3,
            minAnnotationSegmentIndex: 4,
            maxAnnotationSegmentIndex: 41,
          ),
          SectionStructure(
            type: 'Pedestrian',
            beginSegmentIndex: 49,
            beginSegmentPosition: 0,
            endSegmentIndex: 119,
            endSegmentPosition: 0,
            annotationCount: 2,
            minAnnotationSegmentIndex: 60,
            maxAnnotationSegmentIndex: 100,
          ),
        ],
        annotationBasis: AnnotationPositionBasis.unestablished,
      );
      final map = report.toDebugMap();
      expect(map['positionBasis'], 'unestablished');
      expect(map['geometrySegments'], 120);
      final spans = map['sectionSpans'] as List;
      expect(spans, hasLength(2));
      final flat = flatMap(spans);
      // No coordinate-like numbers (two digits before a ≥3-decimal fraction)
      // and no coordinate keys anywhere in the structural spans.
      expect(RegExp(r'\b\d{2}\.\d{3,}').hasMatch(flat), isFalse);
      expect(flat.toLowerCase(), isNot(contains('lat')));
      expect(flat.toLowerCase(), isNot(contains('lon')));
    });
  });

  group('§8 fallback wording', () {
    test('every reason has its own honest, code-free message', () {
      final messages = {
        for (final reason in ScenicFallbackReason.values)
          reason: scenicFallbackReasonText(reason),
      };
      // Distinct wording per reason (no single generic text).
      expect(messages.values.toSet(), hasLength(ScenicFallbackReason.values.length));
      for (final entry in messages.entries) {
        final text = entry.value;
        final lower = text.toLowerCase();
        expect(text, isNotEmpty);
        // The ordinary route stays available in every fallback message.
        if (entry.key != ScenicFallbackReason.none) {
          expect(lower, contains('обычный пешеходный маршрут'),
              reason: '${entry.key}: fallback must offer the normal route');
          expect(text, endsWith('.'));
        }
        // No technical codes or English identifiers leak into user text.
        expect(lower, isNot(contains('scenic')));
        expect(lower, isNot(contains('mapkit')));
        expect(lower, isNot(contains('_exhausted')));
        expect(text, isNot(contains('ScenicFallbackReason')));
      }
      // The four §8 scenarios map to the four documented messages.
      expect(messages[ScenicFallbackReason.noCandidates],
          contains('нет подтверждённых живописных участков'));
      expect(messages[ScenicFallbackReason.budgetExceeded],
          contains('слишком длинным'));
      expect(messages[ScenicFallbackReason.mapkitUnavailable],
          contains('Не удалось проверить пешеходный проход'));
      expect(messages[ScenicFallbackReason.noVerifiedGeometry],
          contains('не удалось достаточно надёжно подтвердить'));
    });
  });

  group('§5 frozen junction thresholds', () {
    test('documented constants are pinned', () {
      expect(ScenicStageBuilder.endpointToleranceDegrees, 1e-9);
      expect(ScenicStageBuilder.maxJoinGapMeters, 2.0);
      expect(ScenicStageBuilder.maxSnapFromWaypointMeters, 15.0);
      // The junction fix: the band only decides ELIGIBILITY for native
      // confirmation; acceptance is bit-identical exactness in the builder and
      // the engine's confirmed connector geometry in the route.
      expect(ScenicStageBuilder.connectorDetourFactor, 2.0);
      expect(ScenicStageBuilder.connectorExtraMeters, 5.0);
      expect(ScenicStageBuilder.maxConnectorMeters(1.3), closeTo(6.3, 1e-9));
      expect(ScenicStageBuilder.maxConnectorMeters(10.0), closeTo(20.0, 1e-9));
      // A gap of exactly the cap is eligible for confirmation; above it is
      // not. Eligibility is never acceptance (see the builder-level guard in
      // scenic_runtime_fixes_test.dart).
      expect(
        ScenicStageBuilder.junctionEligibleForConfirmation(
          gapMeters: 2.0,
          snapFromEndMeters: 1.0,
          snapFromStartMeters: 1.0,
        ),
        isTrue,
      );
      expect(
        ScenicStageBuilder.junctionEligibleForConfirmation(
          gapMeters: 2.0000001,
          snapFromEndMeters: 1.0,
          snapFromStartMeters: 1.0,
        ),
        isFalse,
      );
      expect(
        ScenicStageBuilder.junctionEligibleForConfirmation(
          gapMeters: 1.0,
          snapFromEndMeters: 15.0000001,
          snapFromStartMeters: 1.0,
        ),
        isFalse,
      );
      // Exactness is the shared coordinate rule used by engine and builder.
      expect(
        ScenicStageBuilder.sameCoordinate(
          const GeoCoord(60.0, 30.0),
          const GeoCoord(60.0, 30.0),
        ),
        isTrue,
      );
      expect(
        ScenicStageBuilder.sameCoordinate(
          const GeoCoord(60.0, 30.0),
          const GeoCoord(60.0000001, 30.0),
        ),
        isFalse,
      );
    });

    test('invalid measurements are never eligible', () {
      expect(
        ScenicStageBuilder.junctionEligibleForConfirmation(
          gapMeters: double.nan,
          snapFromEndMeters: 0,
          snapFromStartMeters: 0,
        ),
        isFalse,
      );
      expect(
        ScenicStageBuilder.junctionEligibleForConfirmation(
          gapMeters: double.infinity,
          snapFromEndMeters: 0,
          snapFromStartMeters: 0,
        ),
        isFalse,
      );
    });
  });
}

String flatMap(Object? value) {
  final buffer = StringBuffer();
  void walk(Object? node) {
    if (node is Map) {
      node.forEach((key, item) {
        buffer.write('$key:');
        walk(item);
        buffer.write(' ');
      });
    } else if (node is Iterable) {
      for (final item in node) {
        walk(item);
      }
    } else {
      buffer.write('$node');
    }
  }

  walk(value);
  return buffer.toString();
}
