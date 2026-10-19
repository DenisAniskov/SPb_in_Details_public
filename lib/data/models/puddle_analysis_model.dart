/// The backend's experimental relative wet-surface risk, never a probability
/// that a puddle exists. Unknown information is preserved explicitly.
enum PuddleStatus { available, partial, unavailable, outsideCoverage }

enum PuddleRisk {
  low,
  moderate,
  high,
  unknown;

  String get label => switch (this) {
    low => 'Низкий относительный риск',
    moderate => 'Умеренный относительный риск',
    high => 'Высокий относительный риск',
    unknown => 'Риск неизвестен: недостаточно данных',
  };

  /// In-line form for the model's parameter variants.
  String get shortLabel => switch (this) {
    low => 'низкий',
    moderate => 'умеренный',
    high => 'высокий',
    unknown => 'неизвестно',
  };

  static PuddleRisk? fromCode(Object? value) => switch (value) {
    'low' => PuddleRisk.low,
    'moderate' => PuddleRisk.moderate,
    'high' => PuddleRisk.high,
    'unknown' => PuddleRisk.unknown,
    _ => null,
  };
}

/// The experimental parameters' influence on the answer, as reported BY THE
/// BACKEND (thresholds and drying rates are not calibrated, so the spread of
/// the variants shows how much the answer depends on parameter choice rather
/// than on data). Displayed, never recomputed client-side.
class PuddleSensitivity {
  final PuddleRisk baseline;
  final Map<String, PuddleRisk> variants;
  final Map<String, double> variantIndexes;
  final String note;

  const PuddleSensitivity({
    required this.baseline,
    required this.variants,
    required this.variantIndexes,
    required this.note,
  });
}

/// Russian display names for the documented variants; an unknown variant key
/// is shown verbatim instead of being hidden.
String puddleSensitivityLabel(String key) => switch (key) {
  'drying_faster_0_5x' => 'высыхание вдвое быстрее',
  'drying_slower_2x' => 'высыхание вдвое медленнее',
  'ponding_sooner_saturation_0_75x' => 'насыщение раньше (порог −25%)',
  _ => key,
};

class PuddleWeatherSource {
  final String provider;
  final String kind;
  final String model;
  final String license;
  final String attribution;
  final String sourceUrl;
  final bool available;
  final DateTime? retrievedAt;
  final DateTime? validUntil;
  final int? temporalResolutionSeconds;
  final double? spatialResolutionMeters;

  const PuddleWeatherSource({
    required this.provider,
    required this.kind,
    required this.license,
    required this.available,
    this.model = '',
    this.attribution = '',
    this.sourceUrl = '',
    this.retrievedAt,
    this.validUntil,
    this.temporalResolutionSeconds,
    this.spatialResolutionMeters,
  });
}

class PuddleAnalysisModel {
  final PuddleStatus status;
  final String method;
  final String methodVersion;
  final PuddleRisk risk;
  final double? riskIndex;
  final double routeLengthMeters;
  final double knownMeters;
  final double unknownMeters;
  final double lowMeters;
  final double moderateMeters;
  final double highMeters;
  final double coverageShare;
  final String confidence;
  final DateTime periodStart;
  final DateTime periodEnd;
  final String timezoneName;
  final String? datasetVersion;
  final String datasetSource;
  final String datasetLicense;
  final PuddleWeatherSource weather;
  final List<String> reasons;
  final List<String> limitations;

  /// The backend's parameter-sensitivity block. Present exactly when the
  /// backend states numbers (see [tryFromJson]); null otherwise.
  final PuddleSensitivity? sensitivity;

  const PuddleAnalysisModel({
    required this.status,
    required this.method,
    required this.methodVersion,
    required this.risk,
    required this.riskIndex,
    required this.routeLengthMeters,
    required this.knownMeters,
    required this.unknownMeters,
    required this.lowMeters,
    required this.moderateMeters,
    required this.highMeters,
    required this.coverageShare,
    required this.confidence,
    required this.periodStart,
    required this.periodEnd,
    required this.timezoneName,
    required this.datasetVersion,
    required this.datasetSource,
    required this.datasetLicense,
    required this.weather,
    required this.reasons,
    required this.limitations,
    this.sensitivity,
  });

  bool get hasEstimate =>
      (status == PuddleStatus.available || status == PuddleStatus.partial) &&
      risk != PuddleRisk.unknown;

  /// Reject inconsistent numbers instead of converting absent data to low.
  /// The tolerance below handles serialization of length sums only; it is not
  /// a threshold in the environmental model.
  static PuddleAnalysisModel? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final status = switch (value['status']) {
      'available' => PuddleStatus.available,
      'partial' => PuddleStatus.partial,
      'unavailable' => PuddleStatus.unavailable,
      'outside_coverage' => PuddleStatus.outsideCoverage,
      _ => null,
    };
    final risk = PuddleRisk.fromCode(value['risk_level']);
    double? number(String key) {
      final result = value[key];
      if (result is! num || !result.isFinite || result < 0) return null;
      return result.toDouble();
    }

    final total = number('route_length_meters');
    final known = number('known_meters');
    final unknown = number('unknown_meters');
    final low = number('low_meters');
    final moderate = number('moderate_meters');
    final high = number('high_meters');
    final coverage = number('coverage_share');
    final rawIndex = value['risk_index'];
    final index = rawIndex == null ? null : number('risk_index');
    final period = value['evaluated_period'];
    final dataset = value['dataset_provenance'];
    final weather = value['weather_provenance'];
    final method = value['method'];
    final version = value['method_version'];
    final confidence = value['confidence'];
    final reasons = _strings(value['reasons']);
    final limitations = _strings(value['limitations']);
    if (status == null ||
        risk == null ||
        total == null ||
        total <= 0 ||
        known == null ||
        unknown == null ||
        low == null ||
        moderate == null ||
        high == null ||
        coverage == null ||
        coverage > 1 ||
        (rawIndex != null && (index == null || index > 1)) ||
        period is! Map ||
        dataset is! Map ||
        weather is! Map ||
        method is! String ||
        method.isEmpty ||
        version is! String ||
        version.isEmpty ||
        (confidence != 'low' && confidence != 'unavailable') ||
        value['estimate'] != true ||
        reasons == null ||
        limitations == null) {
      return null;
    }
    final tolerance = total * 1e-6 + 1e-6;
    if ((known + unknown - total).abs() > tolerance ||
        (low + moderate + high - known).abs() > tolerance ||
        (coverage - known / total).abs() > 1e-6) {
      return null;
    }
    if (risk == PuddleRisk.unknown
        ? index != null
        : index == null || known == 0) {
      return null;
    }
    if ((status == PuddleStatus.unavailable ||
            status == PuddleStatus.outsideCoverage) &&
        (risk != PuddleRisk.unknown || known != 0)) {
      return null;
    }
    // Transparency is part of the contract: an answer WITH numbers must carry
    // the parameter-sensitivity block, its baseline must agree with the
    // headline level, and an answer WITHOUT numbers must not pretend to have
    // one (the backend sends an empty block there).
    final PuddleSensitivity? sensitivity;
    try {
      sensitivity = _sensitivity(value['sensitivity']);
    } on FormatException {
      return null;
    }
    if (risk == PuddleRisk.unknown) {
      if (sensitivity != null) return null;
    } else if (sensitivity == null || sensitivity.baseline != risk) {
      return null;
    }
    final start = _instant(period['start']);
    final end = _instant(period['end']);
    final timezone = period['timezone'];
    if (start == null ||
        end == null ||
        end.isBefore(start) ||
        timezone is! String ||
        timezone.isEmpty) {
      return null;
    }
    final retrieved = _instant(weather['retrieved_at']);
    final valid = _instant(weather['valid_until']);
    if ((weather['retrieved_at'] != null && retrieved == null) ||
        (weather['valid_until'] != null && valid == null) ||
        (retrieved != null && valid != null && valid.isBefore(retrieved))) {
      return null;
    }
    final temporal = weather['temporal_resolution_seconds'];
    final spatial = weather['spatial_resolution_meters'];
    return PuddleAnalysisModel(
      status: status,
      method: method,
      methodVersion: version,
      risk: risk,
      riskIndex: index,
      routeLengthMeters: total,
      knownMeters: known,
      unknownMeters: unknown,
      lowMeters: low,
      moderateMeters: moderate,
      highMeters: high,
      coverageShare: coverage,
      confidence: confidence as String,
      periodStart: start,
      periodEnd: end,
      timezoneName: timezone,
      datasetVersion: value['dataset_version'] is String
          ? value['dataset_version'] as String
          : null,
      datasetSource: dataset['source'] is String
          ? dataset['source'] as String
          : '',
      datasetLicense: dataset['license'] is String
          ? dataset['license'] as String
          : '',
      weather: PuddleWeatherSource(
        provider: weather['provider'] is String
            ? weather['provider'] as String
            : '',
        kind: weather['kind'] is String ? weather['kind'] as String : '',
        model: weather['model'] is String ? weather['model'] as String : '',
        license: weather['license'] is String
            ? weather['license'] as String
            : '',
        attribution: weather['attribution'] is String
            ? weather['attribution'] as String
            : '',
        sourceUrl: weather['source_url'] is String
            ? weather['source_url'] as String
            : '',
        available: weather['available'] == true,
        retrievedAt: retrieved,
        validUntil: valid,
        temporalResolutionSeconds: temporal is int && temporal > 0
            ? temporal
            : null,
        spatialResolutionMeters:
            spatial is num && spatial.isFinite && spatial > 0
            ? spatial.toDouble()
            : null,
      ),
      reasons: List.unmodifiable(reasons),
      limitations: List.unmodifiable(limitations),
      sensitivity: sensitivity,
    );
  }

  /// Parses the backend's sensitivity block. Throws [FormatException] when
  /// the block exists but its documented structure is malformed — a broken
  /// transparency claim is refused, not shown half-computed.
  static PuddleSensitivity? _sensitivity(Object? value) {
    if (value == null) return null;
    if (value is! Map) throw const FormatException('sensitivity is not a map');
    if (value.isEmpty) return null;
    final baseline = PuddleRisk.fromCode(value['baseline']);
    final note = value['note'];
    if (baseline == null || note is! String) {
      throw const FormatException('sensitivity baseline/note malformed');
    }
    final variants = <String, PuddleRisk>{};
    final indexes = <String, double>{};
    const indexSuffix = '_risk_index';
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String || key == 'baseline' || key == 'note') continue;
      if (key.endsWith(indexSuffix)) {
        final index = entry.value;
        if (index is! num || !index.isFinite || index < 0 || index > 1) {
          throw const FormatException('sensitivity index out of range');
        }
        indexes[key.substring(0, key.length - indexSuffix.length)] = index
            .toDouble();
        continue;
      }
      final level = PuddleRisk.fromCode(entry.value);
      if (level != null) variants[key] = level;
    }
    return PuddleSensitivity(
      baseline: baseline,
      variants: Map.unmodifiable(variants),
      variantIndexes: Map.unmodifiable(indexes),
      note: note,
    );
  }

  static DateTime? _instant(Object? value) {
    if (value is! String || !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  static List<String>? _strings(Object? value) =>
      value is List && value.every((item) => item is String)
      ? value.cast<String>()
      : null;
}

String puddleReasonText(String code) => switch (code) {
  'weather_not_configured' => 'Погодный источник пока не подключён.',
  'weather_unavailable' => 'Погодный источник недоступен.',
  'weather_stale' => 'Погодные данные устарели.',
  'weather_incomplete' =>
    'История осадков неполная: затронутые участки не оценены.',
  'weather_outside_window' => 'Время прогулки вне доступного прогноза.',
  'weather_snow_or_freezing' =>
    'Снег или мороз: модель мокрого покрытия неприменима.',
  'dataset_unavailable' => 'Географические данные недоступны.',
  'outside_pilot' => 'Маршрут вне проверенной пилотной зоны.',
  'unmatched_osm_way' => 'Для части пути не подтверждены сведения о покрытии.',
  'ambiguous_osm_way' => 'Соседние дорожки нельзя надёжно различить.',
  'surface_unknown' => 'Тип покрытия неизвестен.',
  'surface_not_supported' => 'Для этого покрытия модель не определена.',
  'model_precipitation_history' =>
    'Использована расчётная история осадков, не наблюдение луж.',
  'covered_not_waterproof' => 'Крытый проход не гарантирует сухого покрытия.',
  'experimental_uncalibrated' =>
    'Экспериментальная модель пока не проверена на местности.',
  _ => 'Оценка ограничена качеством исходных данных.',
};
