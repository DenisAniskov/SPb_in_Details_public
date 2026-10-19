import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';

/// Kind of walk the user requested (Phase C5). The kind describes the
/// REQUEST; the actual route snapshot records what was really built
/// (a scenic request can honestly fall back to the normal route). C11 adds a
/// quiet snapshot only after a verified native alternative and a comparable
/// backend proxy, never as an automatic replacement.
enum WalkKind { normal, scenic, quiet }

/// Verified scenic feature categories present in the dataset. Weights and
/// labels live with the scoring model; the enum mirrors the acquisition.
enum ScenicFeatureType { embankment, pedestrianStreet, square }

/// How confidently a built route actually engages the scenic feature
/// (Phase C5 §4.3): geometry is always checked against the verified
/// feature line/point before any scenic claim is made.
enum ScenicEvidenceLevel {
  /// A substantial share of the stage walks along the verified way.
  verifiedOnPath,

  /// The stage passes nearby, but does not follow the way itself.
  verifiedNearby,

  /// Geometry does not meaningfully engage the feature — never claimed
  /// as a scenic benefit.
  ambiguous,
}

/// One verified scenic pedestrian feature from the versioned dataset.
/// Waypoints are points on named public pedestrian ways — never park
/// centroids or claimed entrances (C3 audit lesson).
class ScenicFeature {
  final String id;
  final ScenicFeatureType type;
  final String name;
  final String district;
  final String districtLabel;

  /// A point ON the verified public way, used as a routing waypoint.
  final GeoCoord waypoint;

  /// Reduced polyline of the verified way (≤ 12 points) for line-based
  /// geometry verification; null for point features.
  final List<GeoCoord>? line;

  /// Approximate length of the verified way (context for the audit).
  final double extentMeters;
  final String osmUrl;

  /// Raw OSM access/foot/highway tags captured at verification time.
  final String accessEvidence;

  /// Date the feature was verified against its source (ISO-8601).
  final String verifiedOn;
  final double confidence;
  final String uncertainty;

  const ScenicFeature({
    required this.id,
    required this.type,
    required this.name,
    required this.district,
    required this.districtLabel,
    required this.waypoint,
    required this.line,
    required this.extentMeters,
    required this.osmUrl,
    required this.accessEvidence,
    required this.verifiedOn,
    required this.confidence,
    required this.uncertainty,
  });
}

/// The versioned scenic dataset (embedded, reproducible — regenerated only
/// by the documented acquisition pipeline, never fetched per walk).
class ScenicDataset {
  final String version;
  final String generatedOn;
  final String source;
  final String license;
  final String attribution;
  final List<ScenicFeature> features;

  const ScenicDataset({
    required this.version,
    required this.generatedOn,
    required this.source,
    required this.license,
    required this.attribution,
    required this.features,
  });
}

/// Per-stage scenic metadata attached to a combined scenic leg. A stage is
/// one tourist transition (stop → stop) possibly built from several real
/// MapKit segments through scenic waypoints.
class ScenicStageInfo {
  /// Dataset ids of the features engaged by this stage, in walk order.
  final List<String> featureIds;

  /// Human-readable names of those features.
  final List<String> featureNames;

  final ScenicEvidenceLevel evidence;

  /// Fraction of the stage length within the feature proximity band.
  final double coverageShare;

  /// Extra walking versus the normal (non-scenic) stage.
  final int extraSeconds;
  final double extraMeters;

  /// Explainable net score (see ScenicScoringConfig).
  final double score;

  /// Short user-facing explanation built only from verified facts.
  final String explanation;

  const ScenicStageInfo({
    required this.featureIds,
    required this.featureNames,
    required this.evidence,
    required this.coverageShare,
    required this.extraSeconds,
    required this.extraMeters,
    required this.score,
    required this.explanation,
  });

  ScenicStageInfo immutableSnapshot() => ScenicStageInfo(
    featureIds: List.unmodifiable(featureIds),
    featureNames: List.unmodifiable(featureNames),
    evidence: evidence,
    coverageShare: coverageShare,
    extraSeconds: extraSeconds,
    extraMeters: extraMeters,
    score: score,
    explanation: explanation,
  );
}

/// Comparison of the normal and scenic alternatives for the same tourist
/// stops (Phase C5 §7.2). Built only from native MapKit results — never
/// from geometric estimates.
class RouteComparison {
  final int normalWalkingSeconds;
  final int scenicWalkingSeconds;
  final double normalDistanceMeters;
  final double scenicDistanceMeters;
  final int stopCount;

  /// Verified benefit lines, e.g. «Проходит по набережной реки Мойки».
  final List<String> benefitLines;

  int get extraWalkingSeconds => scenicWalkingSeconds - normalWalkingSeconds;
  double get extraDistanceMeters => scenicDistanceMeters - normalDistanceMeters;

  const RouteComparison({
    required this.normalWalkingSeconds,
    required this.scenicWalkingSeconds,
    required this.normalDistanceMeters,
    required this.scenicDistanceMeters,
    required this.stopCount,
    required this.benefitLines,
  });

  RouteComparison immutableSnapshot() => RouteComparison(
    normalWalkingSeconds: normalWalkingSeconds,
    scenicWalkingSeconds: scenicWalkingSeconds,
    normalDistanceMeters: normalDistanceMeters,
    scenicDistanceMeters: scenicDistanceMeters,
    stopCount: stopCount,
    benefitLines: List.unmodifiable(benefitLines),
  );
}
