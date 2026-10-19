import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/services/guidance_diagnostics.dart';
import 'package:yandex_maps_mapkit/transport.dart' as transport;

/// Detached typed fields from an official pedestrian annotation. No native
/// object or user-visible instruction string is retained by navigation.
class PedestrianAnnotationData {
  final PedestrianManeuverKind? kind;
  final int segmentIndex;
  final double segmentPosition;

  const PedestrianAnnotationData({
    required this.kind,
    required this.segmentIndex,
    required this.segmentPosition,
  });
}

class MapKitPedestrianGuidanceAdapter {
  const MapKitPedestrianGuidanceAdapter();

  /// Native annotation positions are documented only as "on part of route"
  /// (pub.dev binding for `MasstransitAnnotation.position`). Whether that
  /// basis is section-local or parent-route-global is not established by the
  /// installed bindings, and the two readings coincide only when one
  /// pedestrian fitness section covers the complete route. Multi-section
  /// responses therefore keep the honest fallback instead of an assumed
  /// offset basis.
  List<PedestrianManeuverModel> fromNativeRoute(
    transport.MasstransitRoute route,
    List<GeoCoord> geometry, {
    int legIndex = 0,
  }) {
    try {
      final sections = route.sections;
      final typeCounts = <String, int>{};
      var annotationCount = 0;
      final sectionStructures = <SectionStructure>[];
      for (final section in sections) {
        final fitness = section.metadata.data.asFitness();
        final typeName = fitness == null
            ? _nonFitnessTypeName(section)
            : fitness.type.name;
        typeCounts[typeName] = (typeCounts[typeName] ?? 0) + 1;
        var sectionAnnotations = 0;
        int? minIndex;
        int? maxIndex;
        if (fitness != null &&
            fitness.type == transport.MasstransitFitnessType.Pedestrian) {
          annotationCount += fitness.annotations.length;
          for (final annotation in fitness.annotations) {
            sectionAnnotations++;
            final index = annotation.position.segmentIndex;
            minIndex = minIndex == null ? index : (index < minIndex ? index : minIndex);
            maxIndex = maxIndex == null ? index : (index > maxIndex ? index : maxIndex);
          }
        }
        sectionStructures.add(SectionStructure(
          type: typeName,
          beginSegmentIndex: section.geometry.begin.segmentIndex,
          beginSegmentPosition: section.geometry.begin.segmentPosition,
          endSegmentIndex: section.geometry.end.segmentIndex,
          endSegmentPosition: section.geometry.end.segmentPosition,
          annotationCount: sectionAnnotations,
          minAnnotationSegmentIndex: minIndex,
          maxAnnotationSegmentIndex: maxIndex,
        ));
      }
      if (sections.isEmpty) {
        return _rejected(
          legIndex: legIndex,
          sectionCount: 0,
          typeCounts: typeCounts,
          annotationCount: annotationCount,
          sections: sectionStructures,
          geometrySegmentCount: geometry.length,
          reason: GuidanceRejectionReason.noSections,
        );
      }
      if (sections.length != 1) {
        return _rejected(
          legIndex: legIndex,
          sectionCount: sections.length,
          typeCounts: typeCounts,
          annotationCount: annotationCount,
          sections: sectionStructures,
          geometrySegmentCount: geometry.length,
          reason: GuidanceRejectionReason.multipleSections,
        );
      }
      final section = sections.single;
      final fitness = section.metadata.data.asFitness();
      if (fitness == null ||
          fitness.type != transport.MasstransitFitnessType.Pedestrian) {
        return _rejected(
          legIndex: legIndex,
          sectionCount: sections.length,
          typeCounts: typeCounts,
          annotationCount: annotationCount,
          sections: sectionStructures,
          geometrySegmentCount: geometry.length,
          reason: GuidanceRejectionReason.notPedestrianFitness,
        );
      }
      final begin = section.geometry.begin;
      final end = section.geometry.end;
      final annotations = fitness.annotations.map((annotation) {
        final position = annotation.position;
        return PedestrianAnnotationData(
          kind: _kind(annotation.action, annotation.landmark),
          segmentIndex: position.segmentIndex,
          segmentPosition: position.segmentPosition,
        );
      }).toList();
      final outcome = _adaptValidated(
        geometry: geometry,
        sectionBeginIndex: begin.segmentIndex,
        sectionBeginPosition: begin.segmentPosition,
        sectionEndIndex: end.segmentIndex,
        sectionEndPosition: end.segmentPosition,
        annotations: annotations,
        legIndex: legIndex,
      );
      if (outcome.reason != GuidanceRejectionReason.none) {
        return _rejected(
          legIndex: legIndex,
          sectionCount: sections.length,
          typeCounts: typeCounts,
          annotationCount: annotationCount,
          sections: sectionStructures,
          geometrySegmentCount: geometry.length,
          reason: outcome.reason,
        );
      }
      GuidanceDiagnostics.record(GuidanceStructureReport(
        sectionCount: sections.length,
        sectionTypeCounts: typeCounts,
        annotationCount: annotationCount,
        acceptedManeuvers: outcome.maneuvers.length,
        rejectedAnnotationCount: annotationCount - outcome.maneuvers.length,
        rejectionReason: GuidanceRejectionReason.none,
        sectionPositionsMappedReliably: true,
        guidanceMode: outcome.maneuvers.isEmpty
            ? PedestrianGuidanceMode.fallback.name
            : PedestrianGuidanceMode.nativeAnnotations.name,
        geometrySegmentCount: geometry.length,
        sections: sectionStructures,
        // One pedestrian section covers the complete route: the
        // section-local and route-global position readings coincide, so
        // acceptance inferred here does not assume a basis.
        annotationBasis: AnnotationPositionBasis.coincidentFullCoverage,
      ));
      return outcome.maneuvers;
    } catch (_) {
      // Missing/unsupported native metadata must never fail route calculation.
      return _rejected(
        legIndex: legIndex,
        sectionCount: -1,
        typeCounts: const {},
        annotationCount: 0,
        reason: GuidanceRejectionReason.nativeMetadataError,
      );
    }
  }

  String _nonFitnessTypeName(transport.MasstransitSection section) {
    final data = section.metadata.data;
    if (data.asWait() != null) return 'wait';
    if (data.asTransfer() != null) return 'transfer';
    if (data.asTaxi() != null) return 'taxi';
    if (data.asVectorMasstransitTransport() != null) return 'transport';
    return 'unknown';
  }

  List<PedestrianManeuverModel> _rejected({
    required int legIndex,
    required int sectionCount,
    required Map<String, int> typeCounts,
    required int annotationCount,
    required GuidanceRejectionReason reason,
    List<SectionStructure> sections = const [],
    int? geometrySegmentCount,
    int accepted = 0,
  }) {
    GuidanceDiagnostics.record(GuidanceStructureReport(
      sectionCount: sectionCount,
      sectionTypeCounts: typeCounts,
      annotationCount: annotationCount,
      acceptedManeuvers: accepted,
      rejectedAnnotationCount: annotationCount - accepted,
      rejectionReason: reason,
      sectionPositionsMappedReliably: false,
      guidanceMode: PedestrianGuidanceMode.fallback.name,
      geometrySegmentCount: geometrySegmentCount,
      sections: sections,
    ));
    return const [];
  }

  /// Geometry distance in meters matches the GPS projection's distance basis.
  /// Invalid positions/order degrade the complete leg to honest fallback.
  List<PedestrianManeuverModel> adapt({
    required List<GeoCoord> geometry,
    required int sectionBeginIndex,
    required double sectionBeginPosition,
    required int sectionEndIndex,
    required double sectionEndPosition,
    required List<PedestrianAnnotationData> annotations,
    int legIndex = 0,
  }) =>
      _adaptValidated(
        geometry: geometry,
        sectionBeginIndex: sectionBeginIndex,
        sectionBeginPosition: sectionBeginPosition,
        sectionEndIndex: sectionEndIndex,
        sectionEndPosition: sectionEndPosition,
        annotations: annotations,
        legIndex: legIndex,
      ).maneuvers;

  ({List<PedestrianManeuverModel> maneuvers, GuidanceRejectionReason reason})
      _adaptValidated({
    required List<GeoCoord> geometry,
    required int sectionBeginIndex,
    required double sectionBeginPosition,
    required int sectionEndIndex,
    required double sectionEndPosition,
    required List<PedestrianAnnotationData> annotations,
    required int legIndex,
  }) {
    if (geometry.length < 2 ||
        sectionBeginIndex != 0 ||
        sectionBeginPosition != 0 ||
        !_isEndpoint(geometry.length, sectionEndIndex, sectionEndPosition) ||
        geometry.any((p) =>
            !p.latitude.isFinite || !p.longitude.isFinite ||
            p.latitude.abs() > 90 || p.longitude.abs() > 180)) {
      return (
        maneuvers: const [],
        reason: GuidanceRejectionReason.sectionNotCoveringRoute,
      );
    }
    final cumulative = <double>[0];
    for (var i = 1; i < geometry.length; i++) {
      cumulative.add(cumulative.last +
          RouteProjectionUtils.distanceBetween(geometry[i - 1], geometry[i]));
    }
    if (!cumulative.last.isFinite || cumulative.last <= 0) {
      return (
        maneuvers: const [],
        reason: GuidanceRejectionReason.invalidGeometry,
      );
    }
    final maneuvers = <PedestrianManeuverModel>[];
    var previous = -1.0;
    for (final annotation in annotations) {
      final index = annotation.segmentIndex;
      final fraction = annotation.segmentPosition;
      final terminal = index == geometry.length - 1 && fraction == 0;
      if (index < 0 || index >= geometry.length ||
          (!terminal && index >= geometry.length - 1) ||
          !fraction.isFinite || fraction < 0 || fraction > 1) {
        return (
          maneuvers: const [],
          reason: GuidanceRejectionReason.invalidAnnotationPosition,
        );
      }
      final offset = terminal ? cumulative.last : cumulative[index] +
          (cumulative[index + 1] - cumulative[index]) * fraction;
      if (offset < previous) {
        return (
          maneuvers: const [],
          reason: GuidanceRejectionReason.annotationOrderAmbiguous,
        );
      }
      previous = offset;
      final kind = annotation.kind;
      if (kind == null) continue; // e.g. bicycle-only Dismount.
      maneuvers.add(PedestrianManeuverModel(
        kind: kind,
        segmentIndex: index,
        segmentPosition: fraction,
        offsetMeters: offset,
        legIndex: legIndex,
      ));
    }
    return (maneuvers: List.unmodifiable(maneuvers), reason: GuidanceRejectionReason.none);
  }

  bool _isEndpoint(int count, int index, double fraction) =>
      (index == count - 2 && fraction == 1) ||
      (index == count - 1 && fraction == 0);

  PedestrianManeuverKind? _kind(
    transport.MasstransitActionID? action,
    transport.MasstransitLandmarkID? landmark,
  ) {
    if (action != null) {
      return switch (action) {
        transport.MasstransitActionID.Straight => PedestrianManeuverKind.straight,
        transport.MasstransitActionID.Left => PedestrianManeuverKind.left,
        transport.MasstransitActionID.Right => PedestrianManeuverKind.right,
        transport.MasstransitActionID.Dismount => null,
      };
    }
    return switch (landmark) {
      transport.MasstransitLandmarkID.Crosswalk => PedestrianManeuverKind.crosswalk,
      transport.MasstransitLandmarkID.StairsToUnderpass =>
        PedestrianManeuverKind.stairsToUnderpass,
      transport.MasstransitLandmarkID.StairsToOverpass =>
        PedestrianManeuverKind.stairsToOverpass,
      transport.MasstransitLandmarkID.Stairs => PedestrianManeuverKind.stairs,
      transport.MasstransitLandmarkID.StairsDown => PedestrianManeuverKind.stairsDown,
      transport.MasstransitLandmarkID.StairsUp => PedestrianManeuverKind.stairsUp,
      null => null,
    };
  }
}
