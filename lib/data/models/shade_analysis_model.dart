import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';

/// C7.1 shade analysis results as returned by the backend (§11.2).
///
/// Every value here is an ESTIMATE produced by the backend from real
/// OpenStreetMap building geometry with an explicit dataset version. The
/// client never computes, extrapolates or invents shade numbers: it displays
/// what the backend measured and what it could not measure (``unknown``).
enum ShadeStatus {
  available,
  partial,
  unavailable,
  outsideCoverage,
  sunBelowHorizon;

  static ShadeStatus fromWire(String? value) => switch (value) {
    'available' => ShadeStatus.available,
    'partial' => ShadeStatus.partial,
    'outside_coverage' => ShadeStatus.outsideCoverage,
    'sun_below_horizon' => ShadeStatus.sunBelowHorizon,
    _ => ShadeStatus.unavailable,
  };

  String get wireName => switch (this) {
    ShadeStatus.available => 'available',
    ShadeStatus.partial => 'partial',
    ShadeStatus.unavailable => 'unavailable',
    ShadeStatus.outsideCoverage => 'outside_coverage',
    ShadeStatus.sunBelowHorizon => 'sun_below_horizon',
  };

  /// Whether numeric shade values are present and may be shown.
  bool get hasEstimate =>
      this == ShadeStatus.available || this == ShadeStatus.partial;
}

enum ShadeConfidence {
  high,
  medium,
  low,
  unavailable;

  static ShadeConfidence fromWire(String? value) => switch (value) {
    'high' => ShadeConfidence.high,
    'medium' => ShadeConfidence.medium,
    'low' => ShadeConfidence.low,
    _ => ShadeConfidence.unavailable,
  };

  String get label => switch (this) {
    ShadeConfidence.high => 'Высокая',
    ShadeConfidence.medium => 'Средняя',
    ShadeConfidence.low => 'Низкая',
    ShadeConfidence.unavailable => 'Недоступна',
  };
}

enum ShadeSegmentState {
  estimatedShaded,
  estimatedExposed,
  unknown,
  mixed;

  static ShadeSegmentState fromWire(String? value) => switch (value) {
    'estimated_shaded' => ShadeSegmentState.estimatedShaded,
    'estimated_exposed' => ShadeSegmentState.estimatedExposed,
    'mixed' => ShadeSegmentState.mixed,
    _ => ShadeSegmentState.unknown,
  };

  /// Map rendering state: unknown is never drawn as sun.
  bool get isShaded =>
      this == ShadeSegmentState.estimatedShaded ||
      this == ShadeSegmentState.mixed;

  bool get isUnknown => this == ShadeSegmentState.unknown;
}

/// A measured interval along one classified segment, in metres from its start.
///
/// The backend measures WHERE a shadow band starts and ends; a length alone
/// cannot distinguish "the first 20 m are shaded" from "the last 20 m are
/// shaded", and guessing the position client-side would draw an invented
/// boundary (§14.4).
class ShadeSpan {
  final double fromMeters;
  final double toMeters;

  const ShadeSpan(this.fromMeters, this.toMeters);

  double get lengthMeters => toMeters - fromMeters;

  static ShadeSpan? tryFromJson(Object? json) {
    if (json is! List || json.length != 2) return null;
    final from = json[0];
    final to = json[1];
    if (from is! num || to is! num) return null;
    if (to.toDouble() < from.toDouble()) return null;
    return ShadeSpan(from.toDouble(), to.toDouble());
  }
}

class ShadeSegmentModel {
  final int legIndex;

  /// The REAL slice geometry (every interior vertex of the route polyline).
  final List<GeoCoord> geometry;
  final double lengthMeters;
  final double shadedMeters;
  final double unknownMeters;
  final ShadeSegmentState state;
  final double startsAtSeconds;
  final double endsAtSeconds;
  final List<ShadeSpan> shadedSpans;
  final List<ShadeSpan> unknownSpans;

  const ShadeSegmentModel({
    required this.legIndex,
    required this.geometry,
    required this.lengthMeters,
    required this.shadedMeters,
    required this.unknownMeters,
    required this.state,
    required this.startsAtSeconds,
    required this.endsAtSeconds,
    this.shadedSpans = const [],
    this.unknownSpans = const [],
  });

  GeoCoord get start => geometry.first;
  GeoCoord get end => geometry.last;

  /// Whether the segment carries measured band positions. When it does not
  /// (an older backend), the whole-segment [state] is the only truth and the
  /// overlay must not split it by a guessed fraction.
  bool get hasMeasuredSpans =>
      shadedSpans.isNotEmpty || unknownSpans.isNotEmpty;

  static ShadeSegmentModel? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final geometry = _geometryFromJson(json['geometry']) ??
        _legacyGeometryFromJson(json['start'], json['end']);
    if (geometry == null) return null;
    return ShadeSegmentModel(
      legIndex: (json['leg_index'] as num?)?.toInt() ?? 0,
      geometry: List.unmodifiable(geometry),
      lengthMeters: (json['length_meters'] as num?)?.toDouble() ?? 0,
      shadedMeters: (json['shaded_meters'] as num?)?.toDouble() ?? 0,
      unknownMeters: (json['unknown_meters'] as num?)?.toDouble() ?? 0,
      state: ShadeSegmentState.fromWire(json['state'] as String?),
      startsAtSeconds: (json['starts_at_seconds'] as num?)?.toDouble() ?? 0,
      endsAtSeconds: (json['ends_at_seconds'] as num?)?.toDouble() ??
          (json['starts_at_seconds'] as num?)?.toDouble() ??
          0,
      shadedSpans: _spansFromJson(json['shaded_spans']),
      unknownSpans: _spansFromJson(json['unknown_spans']),
    );
  }

  static List<GeoCoord>? _geometryFromJson(Object? json) {
    if (json is! List) return null;
    final points = <GeoCoord>[];
    for (final entry in json) {
      if (entry is! Map) continue;
      final lat = entry['latitude'];
      final lon = entry['longitude'];
      if (lat is! num || lon is! num) continue;
      points.add(GeoCoord(lat.toDouble(), lon.toDouble()));
    }
    return points.length >= 2 ? points : null;
  }

  /// Pre-C7.1.1 payloads carried only the segment's endpoints.
  static List<GeoCoord>? _legacyGeometryFromJson(Object? start, Object? end) {
    if (start is! Map || end is! Map) return null;
    final startLat = start['latitude'];
    final startLon = start['longitude'];
    final endLat = end['latitude'];
    final endLon = end['longitude'];
    if (startLat is! num || startLon is! num || endLat is! num || endLon is! num) {
      return null;
    }
    return [
      GeoCoord(startLat.toDouble(), startLon.toDouble()),
      GeoCoord(endLat.toDouble(), endLon.toDouble()),
    ];
  }

  static List<ShadeSpan> _spansFromJson(Object? json) {
    if (json is! List) return const [];
    final spans = <ShadeSpan>[];
    for (final entry in json) {
      final span = ShadeSpan.tryFromJson(entry);
      if (span != null) spans.add(span);
    }
    return List.unmodifiable(spans);
  }
}

class ShadeSolarSummaryModel {
  final double minElevationDeg;
  final double maxElevationDeg;
  final double minAzimuthDeg;
  final double maxAzimuthDeg;
  final int bucketCount;

  const ShadeSolarSummaryModel({
    required this.minElevationDeg,
    required this.maxElevationDeg,
    required this.minAzimuthDeg,
    required this.maxAzimuthDeg,
    required this.bucketCount,
  });

  static ShadeSolarSummaryModel? tryFromJson(Object? json) {
    if (json is! Map) return null;
    double? value(String key) => (json[key] as num?)?.toDouble();
    final minElevation = value('min_elevation_deg');
    final maxElevation = value('max_elevation_deg');
    final minAzimuth = value('min_azimuth_deg');
    final maxAzimuth = value('max_azimuth_deg');
    if (minElevation == null ||
        maxElevation == null ||
        minAzimuth == null ||
        maxAzimuth == null) {
      return null;
    }
    return ShadeSolarSummaryModel(
      minElevationDeg: minElevation,
      maxElevationDeg: maxElevation,
      minAzimuthDeg: minAzimuth,
      maxAzimuthDeg: maxAzimuth,
      bucketCount: (json['bucket_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class ShadeHeightProvenanceModel {
  final int externallyVerified;
  final int osmDeclared;
  final int levelsEstimate;
  final int unavailable;
  final int buildingsConsidered;

  const ShadeHeightProvenanceModel({
    this.externallyVerified = 0,
    this.osmDeclared = 0,
    this.levelsEstimate = 0,
    this.unavailable = 0,
    this.buildingsConsidered = 0,
  });

  static ShadeHeightProvenanceModel fromJson(Object? json) {
    if (json is! Map) return const ShadeHeightProvenanceModel();
    int value(String key) => (json[key] as num?)?.toInt() ?? 0;
    return ShadeHeightProvenanceModel(
      externallyVerified: value('externally_verified'),
      osmDeclared: value('osm_declared'),
      levelsEstimate: value('levels_estimate'),
      unavailable: value('unavailable'),
      buildingsConsidered: value('buildings_considered'),
    );
  }

  /// Share of considered buildings whose height is unknown (0..1).
  double get unknownShare => buildingsConsidered <= 0
      ? 1.0
      : unavailable / buildingsConsidered;
}

class ShadeAnalysisModel {
  final ShadeStatus status;
  final String method;
  final String methodVersion;
  final DateTime periodStart;
  final DateTime periodEnd;
  final String timezoneName;
  final String? datasetVersion;
  final String datasetProvenance;
  final ShadeSolarSummaryModel? solar;
  final double routeLengthMeters;

  /// Present only when [status] has an estimate; null means "no number was
  /// produced" and the UI must show an honest unavailable state.
  final double? shadedMeters;
  final double? exposedMeters;
  final double? unknownMeters;
  final double? shadeFraction;
  final ShadeConfidence confidence;
  final List<String> limitations;
  final List<ShadeSegmentModel> segments;
  final String? reason;

  /// Coverage bookkeeping.
  final List<String> datasetZonesTouched;
  final double outsideCoverageMeters;
  final double coverageShare;
  final ShadeHeightProvenanceModel heightProvenance;

  const ShadeAnalysisModel({
    required this.status,
    required this.method,
    required this.methodVersion,
    required this.periodStart,
    required this.periodEnd,
    required this.timezoneName,
    required this.datasetVersion,
    required this.datasetProvenance,
    required this.solar,
    required this.routeLengthMeters,
    required this.shadedMeters,
    required this.exposedMeters,
    required this.unknownMeters,
    required this.shadeFraction,
    required this.confidence,
    required this.limitations,
    required this.segments,
    required this.reason,
    required this.datasetZonesTouched,
    required this.outsideCoverageMeters,
    required this.coverageShare,
    required this.heightProvenance,
  });

  bool get hasEstimate => status.hasEstimate && shadeFraction != null;

  /// Length for which the model produced a definite verdict (shade or sun).
  double get knownMeters => (shadedMeters ?? 0) + (exposedMeters ?? 0);

  /// Share of the route the model could actually classify (shade or sun).
  ///
  /// Two routes may both lie fully inside the mapped zones and still know very
  /// different amounts: the remainder is `unknown` (envelopes of buildings
  /// without heights). Comparing their shade shares while ignoring this would
  /// let the route that knows LESS win (§13).
  double get classifiedShare {
    if (routeLengthMeters <= 0) return 0;
    return (knownMeters / routeLengthMeters).clamp(0.0, 1.0);
  }

  /// Shade share among the ground the model could actually classify.
  ///
  /// Comparing raw [shadeFraction] across routes with different unknown shares
  /// would let a route win by knowing less (§13: a smaller known-lit length
  /// must not be mistaken for quality). Route comparison therefore uses this
  /// value, and only between routes with comparable coverage.
  double? get comparableShadeFraction {
    final known = knownMeters;
    if (known <= 0) return null;
    return (shadedMeters ?? 0) / known;
  }

  /// Documented comparison tolerance (±10 percentage points), applied to every
  /// comparability dimension.
  static const double comparableDelta = 0.10;

  /// True when two analyses can be compared without the unknown share deciding
  /// the outcome (§13). BOTH dimensions must match:
  ///
  /// * the share of the route inside the mapped coverage, and
  /// * the share of the route the model could classify at all —
  ///   otherwise a route with much more `unknown` ground enters the comparison
  ///   with an unfairly small known base.
  bool isCoverageComparableTo(ShadeAnalysisModel other) =>
      (coverageShare - other.coverageShare).abs() <= comparableDelta &&
      (classifiedShare - other.classifiedShare).abs() <= comparableDelta;

  static ShadeAnalysisModel? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final start = DateTime.tryParse(
      ((json['evaluated_period'] as Map?)?['start'] as String?) ?? '',
    );
    final end = DateTime.tryParse(
      ((json['evaluated_period'] as Map?)?['end'] as String?) ?? '',
    );
    final routeLength = (json['route_length_meters'] as num?)?.toDouble();
    if (start == null || end == null || routeLength == null) return null;
    final coverage = json['coverage_metrics'];
    final coverageMap = coverage is Map ? coverage : const {};
    final segmentsJson = json['classified_segments'];
    final segments = <ShadeSegmentModel>[];
    if (segmentsJson is List) {
      for (final entry in segmentsJson) {
        final parsed = ShadeSegmentModel.tryFromJson(entry);
        if (parsed != null) segments.add(parsed);
      }
    }
    final limitationsJson = json['limitations'];
    return ShadeAnalysisModel(
      status: ShadeStatus.fromWire(json['status'] as String?),
      method: (json['method'] as String?) ?? '',
      methodVersion: (json['method_version'] as String?) ?? '',
      periodStart: start,
      periodEnd: end,
      timezoneName: ((json['evaluated_period'] as Map?)?['timezone'] as String?) ?? '',
      datasetVersion: json['dataset_version'] as String?,
      datasetProvenance: (json['dataset_provenance'] as String?) ?? '',
      solar: ShadeSolarSummaryModel.tryFromJson(json['solar_summary']),
      routeLengthMeters: routeLength,
      shadedMeters: (json['estimated_shaded_meters'] as num?)?.toDouble(),
      exposedMeters: (json['estimated_exposed_meters'] as num?)?.toDouble(),
      unknownMeters: (json['unknown_meters'] as num?)?.toDouble(),
      shadeFraction: (json['shade_fraction'] as num?)?.toDouble(),
      confidence: ShadeConfidence.fromWire(json['confidence'] as String?),
      limitations: limitationsJson is List
          ? limitationsJson.whereType<String>().toList(growable: false)
          : const [],
      segments: List.unmodifiable(segments),
      reason: json['reason'] as String?,
      datasetZonesTouched: (coverageMap['dataset_zones_touched'] as List?)
              ?.whereType<String>()
              .toList(growable: false) ??
          const [],
      outsideCoverageMeters:
          (coverageMap['outside_coverage_meters'] as num?)?.toDouble() ?? 0,
      coverageShare: (coverageMap['coverage_share'] as num?)?.toDouble() ?? 0,
      heightProvenance: ShadeHeightProvenanceModel.fromJson(
        json['height_provenance_metrics'],
      ),
    );
  }

  /// Human-readable status line for the UI (never shows technical codes).
  String get statusMessage => switch (status) {
    ShadeStatus.available => 'Оценка тени рассчитана.',
    ShadeStatus.partial =>
      'Оценка рассчитана частично: часть маршрута вне покрытия данных и отмечена как «неизвестно».',
    ShadeStatus.outsideCoverage =>
      'Для этого маршрута нет проверенных данных о зданиях: оценка тени недоступна.',
    ShadeStatus.sunBelowHorizon =>
      'Солнце ниже горизонта в это время: прямые тени отсутствуют, доля тени не рассчитывается.',
    ShadeStatus.unavailable =>
      'Оценка тени недоступна: ${reason ?? 'нет проверенных данных о зданиях.'}',
  };
}
