/// C11 quiet-road proxy. The backend returns a bounded relative index and
/// explicit coverage; this model refuses payloads that would turn unknown
/// ground into a quiet claim or present the proxy as dB.
enum QuietStatus { available, partial, unavailable, outsideCoverage }

class QuietLegAnalysisModel {
  const QuietLegAnalysisModel({
    required this.legIndex,
    required this.lengthMeters,
    required this.knownMeters,
    required this.unknownMeters,
    this.roadNoiseExposureIndex,
    this.majorRoadAdjacentMeters,
    this.lowExposureMeters,
  });

  final int legIndex;
  final double lengthMeters;
  final double knownMeters;
  final double unknownMeters;
  final double? roadNoiseExposureIndex;
  final double? majorRoadAdjacentMeters;
  final double? lowExposureMeters;
}

class QuietAnalysisModel {
  const QuietAnalysisModel({
    required this.status,
    required this.estimate,
    required this.confidence,
    required this.method,
    required this.methodVersion,
    required this.evaluatedAt,
    required this.temporalModel,
    required this.trafficTimeModeled,
    required this.routeLengthMeters,
    required this.knownMeters,
    required this.unknownMeters,
    required this.coverageShare,
    required this.roadNoiseExposureIndex,
    required this.lowExposureShare,
    required this.majorRoadAdjacentShare,
    required this.meanNearestRoadDistanceM,
    required this.maxRoadClassNearby,
    required this.legs,
    required this.reasons,
    required this.limitations,
    required this.assumptions,
    required this.sourceProvenance,
    this.datasetVersion,
    this.datasetSha256,
  });

  final QuietStatus status;
  final bool estimate;
  final String confidence;
  final String method;
  final String methodVersion;
  final DateTime evaluatedAt;
  final String temporalModel;
  final bool trafficTimeModeled;
  final double routeLengthMeters;
  final double knownMeters;
  final double unknownMeters;
  final double coverageShare;
  final double? roadNoiseExposureIndex;
  final double? lowExposureShare;
  final double? majorRoadAdjacentShare;
  final double? meanNearestRoadDistanceM;
  final String? maxRoadClassNearby;
  final List<QuietLegAnalysisModel>? legs;
  final List<String> reasons;
  final List<String> limitations;
  final List<String> assumptions;
  final Map<String, dynamic> sourceProvenance;
  final String? datasetVersion;
  final String? datasetSha256;

  bool get hasEstimate =>
      status == QuietStatus.available || status == QuietStatus.partial;

  /// Share of the walk that is at least 120 m from the nearest mapped motor
  /// road. This is a proxy label, never an acoustic percentage.
  String get lowExposureLabel {
    final value = lowExposureShare;
    if (value == null) return 'нет оценки';
    return '${(value * 100).round()}% проверенного пути';
  }

  String get coverageLabel => '${(coverageShare * 100).round()}%';

  /// A deliberately non-acoustic summary. It states what the road network
  /// shows, not what a sound meter would measure.
  String get summary {
    if (!hasEstimate) {
      return switch (status) {
        QuietStatus.outsideCoverage =>
          'Маршрут вне проверенного пилотного района дорожной сети.',
        QuietStatus.unavailable =>
          'Оценка тишины сейчас недоступна для этого маршрута.',
        _ => 'Оценка тишины недоступна.',
      };
    }
    final index = roadNoiseExposureIndex ?? 0;
    if (index >= 0.60) {
      return 'По данным дорожной сети маршрут во многом проходит рядом с '
          'крупными автомобильными дорогами.';
    }
    if (index >= 0.30) {
      return 'По данным дорожной сети маршрут частично проходит рядом с '
          'автомобильными дорогами.';
    }
    if (index >= 0.10) {
      return 'По данным дорожной сети маршрут преимущественно проходит вдали '
          'от крупных автомобильных дорог.';
    }
    return 'По данным дорожной сети маршрут мало проходит рядом с крупными '
        'автомобильными дорогами.';
  }

  static QuietAnalysisModel? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final map = <String, dynamic>{
      for (final entry in json.entries) '${entry.key}': entry.value,
    };
    try {
      final status = switch (_string(map['status'])) {
        'available' => QuietStatus.available,
        'partial' => QuietStatus.partial,
        'unavailable' => QuietStatus.unavailable,
        'outside_coverage' => QuietStatus.outsideCoverage,
        _ => null,
      };
      if (status == null) return null;
      final estimate = _bool(map['estimate']);
      final expectedEstimate =
          status == QuietStatus.available || status == QuietStatus.partial;
      if (estimate != expectedEstimate) return null;
      final evaluatedAt = _date(map['evaluated_at']);
      final temporalModel = _string(map['temporal_model']);
      if (temporalModel != 'static_osm_network') return null;
      if (_bool(map['traffic_time_modeled'])) return null;
      final methodVersion = _string(map['method_version']);
      if (!methodVersion.startsWith('c11')) return null;
      final total = _double(map['route_length_meters']);
      final known = _double(map['known_meters']);
      final unknown = _double(map['unknown_meters']);
      final coverage = _double(map['coverage_share']);
      if (total <= 0 || known < 0 || unknown < 0) return null;
      if ((known + unknown - total).abs() >
          (0.6 > total * 0.001 ? 0.6 : total * 0.001)) {
        return null;
      }
      if (coverage < 0 || coverage > 1) return null;
      if ((coverage - known / total).abs() > 0.01) return null;
      final index = _optionalDouble(map['road_noise_exposure_index']);
      if (expectedEstimate) {
        if (index == null || index < 0 || index > 1) return null;
        if (coverage <= 0) return null;
      } else if (index != null) {
        return null;
      }
      final lowShare = _optionalDouble(map['low_exposure_share']);
      final majorShare = _optionalDouble(map['major_road_adjacent_share']);
      if (lowShare != null && (lowShare < 0 || lowShare > 1)) return null;
      if (majorShare != null && (majorShare < 0 || majorShare > 1)) return null;
      if (!expectedEstimate && (lowShare != null || majorShare != null)) {
        return null;
      }
      final datasetVersion = _optionalString(map['dataset_version']);
      final datasetSha = _optionalString(map['dataset_sha256']);
      if (expectedEstimate && (datasetVersion == null || datasetSha == null)) {
        return null;
      }
      final provenance = map['source_provenance'];
      if (provenance is! Map) return null;
      final legsRaw = map['legs'];
      List<QuietLegAnalysisModel>? legs;
      if (legsRaw != null) {
        if (legsRaw is! List) return null;
        legs = [];
        for (final raw in legsRaw) {
          if (raw is! Map) return null;
          final leg = <String, dynamic>{
            for (final entry in raw.entries) '${entry.key}': entry.value,
          };
          final legIndex = _int(leg['leg_index']);
          final legLength = _double(leg['length_meters']);
          final legKnown = _double(leg['known_meters']);
          final legUnknown = _double(leg['unknown_meters']);
          if (legIndex < 0 || legLength < 0 || legKnown < 0 || legUnknown < 0) {
            return null;
          }
          if ((legKnown + legUnknown - legLength).abs() > 0.6) return null;
          final legIndexValue = _optionalDouble(
            leg['road_noise_exposure_index'],
          );
          if (legIndexValue != null &&
              (legIndexValue < 0 || legIndexValue > 1)) {
            return null;
          }
          legs.add(
            QuietLegAnalysisModel(
              legIndex: legIndex,
              lengthMeters: legLength,
              knownMeters: legKnown,
              unknownMeters: legUnknown,
              roadNoiseExposureIndex: legIndexValue,
              majorRoadAdjacentMeters: _optionalDouble(
                leg['major_road_adjacent_meters'],
              ),
              lowExposureMeters: _optionalDouble(leg['low_exposure_meters']),
            ),
          );
        }
      }
      return QuietAnalysisModel(
        status: status,
        estimate: estimate,
        confidence: _string(map['confidence']),
        method: _string(map['method']),
        methodVersion: methodVersion,
        evaluatedAt: evaluatedAt,
        temporalModel: temporalModel,
        trafficTimeModeled: false,
        routeLengthMeters: total,
        knownMeters: known,
        unknownMeters: unknown,
        coverageShare: coverage,
        roadNoiseExposureIndex: index,
        lowExposureShare: lowShare,
        majorRoadAdjacentShare: majorShare,
        meanNearestRoadDistanceM: _optionalDouble(
          map['mean_nearest_road_distance_m'],
        ),
        maxRoadClassNearby: _optionalString(map['max_road_class_nearby']),
        legs: legs,
        reasons: _strings(map['reasons']),
        limitations: _strings(map['limitations']),
        assumptions: _strings(map['assumptions']),
        sourceProvenance: {
          for (final entry in provenance.entries) '${entry.key}': entry.value,
        },
        datasetVersion: datasetVersion,
        datasetSha256: datasetSha,
      );
    } catch (_) {
      return null;
    }
  }
}

String quietReasonText(String reason) => switch (reason) {
  'quiet_engine_disabled' => 'Оценка тишины ещё не включена на сервере.',
  'quiet_dataset_unavailable' =>
    'Проверенный дорожный снимок недоступен; оценка не выдаётся.',
  'quiet_dataset_not_configured' =>
    'Дорожный снимок не настроен; оценка не выдаётся.',
  'route_outside_pilot' =>
    'Маршрут вне проверенного пилотного района дорожной сети.',
  'route_partially_outside_pilot' =>
    'Часть маршрута вне проверенного пилотного района; оценка только на '
        'покрытой части.',
  _ => reason,
};

String _string(Object? value) {
  if (value is String && value.isNotEmpty) return value;
  throw const FormatException('expected string');
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return value;
  throw const FormatException('expected optional string');
}

bool _bool(Object? value) {
  if (value is bool) return value;
  throw const FormatException('expected bool');
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  throw const FormatException('expected int');
}

double _double(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  throw const FormatException('expected finite number');
}

double? _optionalDouble(Object? value) => value == null ? null : _double(value);

DateTime _date(Object? value) {
  final text = _string(value);
  final parsed = DateTime.tryParse(text);
  if (parsed == null) throw const FormatException('expected date');
  return parsed;
}

List<String> _strings(Object? value) {
  if (value is! List) throw const FormatException('expected list');
  return [for (final item in value) _string(item)];
}
