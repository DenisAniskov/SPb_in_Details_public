import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/scenic/scenic_dataset.dart';

/// Phase C5 §3/§12: dataset integrity — verified sources, access policy,
/// coordinate sanity, no invented entrances, reproducibility.
double _distanceToSegment(GeoCoord p, GeoCoord a, GeoCoord b) {
  final ref = a;
  final pLocal = RouteProjectionUtils.toLocalMeters(p, ref);
  final aLocal = RouteProjectionUtils.toLocalMeters(a, ref);
  final bLocal = RouteProjectionUtils.toLocalMeters(b, ref);
  final dx = bLocal.x - aLocal.x;
  final dy = bLocal.y - aLocal.y;
  final lengthSq = dx * dx + dy * dy;
  var t = 0.0;
  if (lengthSq > 1e-9) {
    t = ((pLocal.x - aLocal.x) * dx + (pLocal.y - aLocal.y) * dy) / lengthSq;
    t = t.clamp(0.0, 1.0);
  }
  final projX = aLocal.x + t * dx;
  final projY = aLocal.y + t * dy;
  return math.sqrt(
    (pLocal.x - projX) * (pLocal.x - projX) +
        (pLocal.y - projY) * (pLocal.y - projY),
  );
}

void main() {
  group('Scenic dataset integrity', () {
    test('non-empty and versioned with provenance', () {
      expect(spbScenicDataset.features, isNotEmpty);
      expect(spbScenicDataset.version, isNotEmpty);
      expect(spbScenicDataset.source, contains('OpenStreetMap'));
      expect(spbScenicDataset.license, 'ODbL 1.0');
      expect(spbScenicDataset.attribution, contains('OpenStreetMap'));
    });

    test('every feature carries valid coordinates inside Saint Petersburg',
        () {
      for (final feature in spbScenicDataset.features) {
        expect(feature.waypoint.latitude, inInclusiveRange(59.7, 60.1),
            reason: '${feature.id} latitude out of range');
        expect(feature.waypoint.longitude, inInclusiveRange(30.0, 30.9),
            reason: '${feature.id} longitude out of range');
        expect(feature.waypoint.latitude.isFinite, isTrue);
        expect(feature.waypoint.longitude.isFinite, isTrue);
      }
    });

    test('feature lines are valid polylines inside the city bounds', () {
      for (final feature in spbScenicDataset.features) {
        final line = feature.line;
        if (line == null) continue;
        expect(line.length, greaterThanOrEqualTo(2),
            reason: '${feature.id} line degenerate');
        for (final point in line) {
          expect(point.latitude, inInclusiveRange(59.7, 60.1),
              reason: '${feature.id} line latitude out of range');
          expect(point.longitude, inInclusiveRange(30.0, 30.9),
              reason: '${feature.id} line longitude out of range');
        }
      }
    });

    test('ids are unique and OSM-sourced', () {
      final ids = spbScenicDataset.features.map((f) => f.id).toSet();
      expect(ids.length, spbScenicDataset.features.length);
      for (final feature in spbScenicDataset.features) {
        expect(feature.id, startsWith('spb-scenic-'));
        expect(feature.osmUrl, startsWith('https://www.openstreetmap.org/'));
      }
    });

    test('access policy: no blocked access evidence', () {
      const blocked = ['private', 'permit', 'no', 'military'];
      for (final feature in spbScenicDataset.features) {
        final evidence = jsonDecode(feature.accessEvidence) as Map<String, dynamic>;
        for (final tag in blocked) {
          expect(evidence['access'], isNot(tag),
              reason: '${feature.id} carries access=$tag');
          expect(evidence['foot'], isNot(tag),
              reason: '${feature.id} carries foot=$tag');
        }
      }
    });

    test('no park or garden waypoints (C3 audit: no verified entrances)',
        () {
      for (final feature in spbScenicDataset.features) {
        // The feature enum itself has no park/garden category: verify the
        // OSM evidence directly.
        final evidence = jsonDecode(feature.accessEvidence) as Map<String, dynamic>;
        // No dataset feature may be a park/garden element.
        expect(evidence['leisure'], anyOf(isNull, isNot('park')),
            reason: '${feature.id} must not be a park waypoint');
        expect(evidence['leisure'], anyOf(isNull, isNot('garden')),
            reason: '${feature.id} must not be a garden waypoint');
        expect(evidence['highway'], isNot('path'),
            reason:
                '${feature.id} paths without street context are excluded');
      }
    });

    test('only documented feature types with sane confidence', () {
      const allowed = ScenicFeatureType.values;
      for (final feature in spbScenicDataset.features) {
        expect(allowed.contains(feature.type), isTrue);
        expect(feature.confidence, inInclusiveRange(0.0, 1.0));
        expect(feature.uncertainty, isNotEmpty);
        expect(feature.districtLabel, isNotEmpty);
        expect(feature.verifiedOn, isNotEmpty);
      }
    });

    test('five target districts are covered', () {
      final districts = spbScenicDataset.features
          .map((f) => f.district)
          .toSet();
      expect(
        districts,
        containsAll([
          'central',
          'petrogradsky',
          'vasileostrovsky',
          'nevsky',
          'primorsky',
        ]),
      );
    });

    test('dataset is usable for corridor pre-filtering (real coordinates)',
        () {
      // A representative feature: the Moika embankment area should exist.
      final names = spbScenicDataset.features.map((f) => f.name).toSet();
      expect(
        names.any((name) => name.contains('абережная')),
        isTrue,
      );
      // The waypoint lies on the original OSM way; the stored line is a
      // ≤12-point reduction, so the waypoint must at least sit inside the
      // engine's proximity band of that line.
      for (final feature in spbScenicDataset.features) {
        final line = feature.line;
        if (line == null || line.length < 2) continue;
        var nearest = double.infinity;
        for (var i = 0; i + 1 < line.length; i++) {
          nearest = math.min(
            nearest,
            _distanceToSegment(feature.waypoint, line[i], line[i + 1]),
          );
        }
        expect(nearest, lessThan(60.0),
            reason: '${feature.id} waypoint outside its own line band');
      }
    });
  });
}
