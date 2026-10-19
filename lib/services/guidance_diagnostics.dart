import 'package:flutter/foundation.dart';

/// Development-only diagnostics for native MapKit pedestrian guidance
/// availability (Phase C4, Part A3).
///
/// Records only non-sensitive structural information about a route response:
/// section cardinality and types, annotation counts, adapter acceptance and
/// rejection reasons, and the final guidance mode. No coordinates, no API
/// keys, no user routes and no GPS history are recorded.
///
/// Opt-in: nothing is computed or stored unless [GuidanceDiagnostics.enabled]
/// is set before the route response arrives. In release builds recording is
/// hard-disabled regardless of the flag. The buffer is bounded; the oldest
/// report is dropped when [maxReports] is exceeded.
class GuidanceDiagnostics {
  GuidanceDiagnostics._();

  /// Set explicitly (debug tooling, `--dart-define` wiring or tests). Never
  /// enabled by production defaults.
  static bool enabled = false;

  /// Bounded memory: at most this many most-recent reports are retained.
  static const int maxReports = 8;

  static final List<GuidanceStructureReport> _reports = [];

  /// Unmodifiable view of captured reports, newest last.
  static List<GuidanceStructureReport> get reports =>
      List.unmodifiable(_reports);

  static void record(GuidanceStructureReport report) {
    if (!enabled || kReleaseMode) return;
    _reports.add(report);
    while (_reports.length > maxReports) {
      _reports.removeAt(0);
    }
    // Development console visibility for device walkthroughs; never reached
    // in release builds. Structural fields only (see toDebugMap).
    debugPrint('GuidanceDiagnostics: ${report.toDebugMap()}');
  }

  @visibleForTesting
  static void clear() => _reports.clear();
}

/// Why the adapter rejected native metadata for a route. Coarse categories
/// only — never coordinates or user data.
enum GuidanceRejectionReason {
  none,
  noSections,
  multipleSections,
  notPedestrianFitness,
  sectionNotCoveringRoute,
  invalidGeometry,
  invalidAnnotationPosition,
  annotationOrderAmbiguous,
  nativeMetadataError,
}

/// Coordinate basis the adapter used for annotation positions in this
/// report. Recorded so device reports stay self-describing when a
/// multi-section response is investigated.
enum AnnotationPositionBasis {
  /// Basis not established (the installed bindings never document it);
  /// annotation data was not used for presentation.
  unestablished,

  /// One pedestrian section completely covers the route, so the section-local
  /// and route-global readings of the same position coincide — the accepted
  /// case needs no basis assumption.
  coincidentFullCoverage,
}

/// Non-sensitive structural description of one native route section
/// (segment indices and fractions only — never coordinates).
class SectionStructure {
  final String type;
  final int beginSegmentIndex;
  final double beginSegmentPosition;
  final int endSegmentIndex;
  final double endSegmentPosition;
  final int annotationCount;
  final int? minAnnotationSegmentIndex;
  final int? maxAnnotationSegmentIndex;

  const SectionStructure({
    required this.type,
    required this.beginSegmentIndex,
    required this.beginSegmentPosition,
    required this.endSegmentIndex,
    required this.endSegmentPosition,
    required this.annotationCount,
    this.minAnnotationSegmentIndex,
    this.maxAnnotationSegmentIndex,
  });

  Map<String, Object> toDebugMap() => {
        'type': type,
        'begin': '$beginSegmentIndex:$beginSegmentPosition',
        'end': '$endSegmentIndex:$endSegmentPosition',
        'annotations': annotationCount,
        if (minAnnotationSegmentIndex != null)
          'annotationSegments': '$minAnnotationSegmentIndex..'
              '${maxAnnotationSegmentIndex ?? minAnnotationSegmentIndex}',
      };
}

/// Non-sensitive structural summary of one native route adaptation.
class GuidanceStructureReport {
  final int sectionCount;
  final Map<String, int> sectionTypeCounts;
  final int annotationCount;
  final int acceptedManeuvers;
  final int rejectedAnnotationCount;
  final GuidanceRejectionReason rejectionReason;
  final bool sectionPositionsMappedReliably;
  final String guidanceMode;

  /// Route geometry segment count (the position space section spans and
  /// annotations are expressed in — the key datum for the basis question).
  final int? geometrySegmentCount;

  /// Per-section structural spans, in route order.
  final List<SectionStructure> sections;

  /// Which coordinate basis the adaptation rested on (see the enum docs).
  final AnnotationPositionBasis annotationBasis;

  const GuidanceStructureReport({
    required this.sectionCount,
    required this.sectionTypeCounts,
    required this.annotationCount,
    required this.acceptedManeuvers,
    required this.rejectedAnnotationCount,
    required this.rejectionReason,
    required this.sectionPositionsMappedReliably,
    required this.guidanceMode,
    this.geometrySegmentCount,
    this.sections = const [],
    this.annotationBasis = AnnotationPositionBasis.unestablished,
  });

  Map<String, Object> toDebugMap() => {
        'sections': sectionCount,
        'sectionTypes': sectionTypeCounts,
        'annotations': annotationCount,
        'acceptedManeuvers': acceptedManeuvers,
        'rejectedAnnotations': rejectedAnnotationCount,
        'rejectionReason': rejectionReason.name,
        'positionsMapped': sectionPositionsMappedReliably,
        'mode': guidanceMode,
        'positionBasis': annotationBasis.name,
        if (geometrySegmentCount != null)
          'geometrySegments': geometrySegmentCount!,
        if (sections.isNotEmpty)
          'sectionSpans': [
            for (final section in sections) section.toDebugMap(),
          ],
      };
}
