import 'package:smart_navigator_spb/core/constants/api_constants.dart';
import 'package:smart_navigator_spb/core/formatting/pollen_units.dart';

/// Pollen exposure assessment of an existing walk (Phase C7.3).
///
/// The model is deliberately STRICT: every payload the backend sends is
/// cross-checked here, and anything inconsistent is rejected as an invalid
/// response (returned as `null` by [PollenAnalysisModel.tryFromJson]) rather
/// than rendered as half-true numbers.
///
/// Two properties are verified literally because the whole feature depends on
/// them:
///
/// * the model keeps the exact unit the backend stated, while the presentation
///   may add a Russian label for the same physical quantity;
/// * numbers are only ever accepted together with their source attribution
///   (CC-BY-4.0 requires it) and their assumptions — a number without the
///   notes explaining what it does NOT mean is not shown at all.
enum PollenStatus { available, partial, unavailable, outsideCoverage }

enum PollenSpeciesState { available, partial, unknown }

String pollenSpeciesStateLabel(PollenSpeciesState state) {
  switch (state) {
    case PollenSpeciesState.available:
      return 'есть значения';
    case PollenSpeciesState.partial:
      return 'частично';
    case PollenSpeciesState.unknown:
      return 'нет данных';
  }
}

/// One pollen species over the assessed walk.
///
/// `state == unknown` means THIS response publishes no concentration for the
/// species, with all four number fields null. `knownSeconds`/`knownShare` are
/// the source's own coverage of that species and stay truthful either way, so
/// the two very different situations can be told apart: coverage zero is "the
/// source had nothing", while a positive coverage under an `unavailable`
/// answer means the numbers were WITHHELD because no hour of the walk carried
/// the complete six-species panel (ТЗ C7.3.1) — withholding a number is not a
/// claim that the source had none.
class PollenSpeciesModel {
  const PollenSpeciesModel({
    required this.code,
    required this.name,
    required this.unit,
    required this.state,
    required this.knownSeconds,
    required this.totalSeconds,
    required this.knownShare,
    required this.meanConcentration,
    required this.peakConcentration,
    required this.peakAt,
    required this.exposureGrainsHoursPerM3,
  });

  final String code;
  final String name;
  final String unit;
  final PollenSpeciesState state;
  final double knownSeconds;
  final double totalSeconds;
  final double knownShare;
  final double? meanConcentration;
  final double? peakConcentration;
  final String? peakAt;
  final double? exposureGrainsHoursPerM3;

  /// Human-readable concentration, e.g. `12.6 зёрен пыльцы/м³` or a gap
  /// notice. [unit] still carries the exact unit stated by the backend.
  String get concentrationLabel => meanConcentration == null
      ? 'нет данных'
      : '${_formatNumber(meanConcentration!)} ${pollenUnitForDisplay(unit)}';

  String get peakLabel => peakConcentration == null
      ? 'нет данных'
      : '${_formatNumber(peakConcentration!)} ${pollenUnitForDisplay(unit)}';
}

/// Per-leg breakdown, requested explicitly via `include_legs`.
class PollenLegModel {
  const PollenLegModel({
    required this.legIndex,
    required this.lengthMeters,
    required this.knownMeters,
    required this.unknownMeters,
    required this.startsAtSeconds,
    required this.endsAtSeconds,
    required this.insideSourceCell,
    required this.species,
  });

  final int legIndex;
  final double lengthMeters;
  final double knownMeters;
  final double unknownMeters;
  final double startsAtSeconds;
  final double endsAtSeconds;
  final bool insideSourceCell;
  final List<PollenSpeciesModel> species;
}

/// Provenance of the pollen source, including its spatial representativeness.
class PollenSourceModel {
  const PollenSourceModel({
    required this.available,
    required this.provider,
    required this.model,
    required this.modelName,
    required this.kind,
    required this.license,
    required this.attribution,
    required this.sourceUrl,
    required this.retrievedAt,
    required this.validUntil,
    required this.intervalStart,
    required this.intervalEnd,
    required this.temporalResolutionSeconds,
    required this.spatialResolutionMeters,
    required this.gridStepDegrees,
    required this.cellLatitude,
    required this.cellLongitude,
    required this.cellBounds,
    required this.timeSemantics,
    required this.reason,
  });

  final bool available;
  final String provider;
  final String model;
  final String modelName;
  final String kind;
  final String license;
  final String attribution;
  final String sourceUrl;
  final DateTime? retrievedAt;
  final DateTime? validUntil;
  final DateTime? intervalStart;
  final DateTime? intervalEnd;
  final int? temporalResolutionSeconds;
  final int? spatialResolutionMeters;
  final double? gridStepDegrees;
  final double? cellLatitude;
  final double? cellLongitude;
  final List<double>? cellBounds;
  final String? timeSemantics;
  final String? reason;
}

/// A parsed, validated pollen assessment.
class PollenAnalysisModel {
  const PollenAnalysisModel({
    required this.status,
    required this.method,
    required this.methodVersion,
    required this.confidence,
    required this.periodStart,
    required this.periodEnd,
    required this.timezoneName,
    required this.routeLengthMeters,
    required this.knownMeters,
    required this.unknownMeters,
    required this.coverageShare,
    required this.walkingDurationSeconds,
    required this.elapsedDurationSeconds,
    required this.concentrationUnit,
    required this.species,
    required this.legs,
    required this.reasons,
    required this.limitations,
    required this.assumptions,
    required this.source,
  });

  final PollenStatus status;
  final String method;
  final String methodVersion;
  final String confidence;
  final DateTime periodStart;
  final DateTime periodEnd;
  final String timezoneName;
  final double routeLengthMeters;
  final double knownMeters;
  final double unknownMeters;
  final double coverageShare;
  final double walkingDurationSeconds;
  final double elapsedDurationSeconds;
  final String concentrationUnit;
  final List<PollenSpeciesModel> species;
  final List<PollenLegModel>? legs;
  final List<String> reasons;
  final List<String> limitations;
  final List<String> assumptions;
  final PollenSourceModel source;

  /// True only when at least part of the walk carries actual concentrations.
  bool get hasEstimate =>
      (status == PollenStatus.available || status == PollenStatus.partial) &&
      knownMeters > 0;

  /// Species that actually carry a value — the rest are shown as gaps.
  List<PollenSpeciesModel> get speciesWithValues =>
      species.where((item) => item.meanConcentration != null).toList();

  /// True when the source HAD values for some species and this answer
  /// publishes none of them, because no hour of the walk carried the complete
  /// six-species panel (ТЗ C7.3.1).
  ///
  /// Only an `unavailable` answer can be in this state: every other
  /// no-numbers answer — source off, unavailable, stale, outside the cell or
  /// past the horizon — carries zero coverage for every species, which the
  /// backend asserts and the tests pin on both sides.
  bool get hasWithheldNumbers =>
      status == PollenStatus.unavailable &&
      species.any((item) => item.knownShare > 0);

  /// The species the source had values for while the answer withholds them —
  /// what the card names instead of claiming nothing was known.
  List<PollenSpeciesModel> get speciesWithSourceValues => hasWithheldNumbers
      ? species.where((item) => item.knownShare > 0).toList()
      : const [];

  static const double _tolerance = 1e-6;

  /// Parses a payload, or returns `null` when ANY invariant is violated.
  /// Never throws for payload problems: a strange answer is not an estimate.
  static PollenAnalysisModel? tryFromJson(Object? value) {
    if (value is! Map) return null;
    try {
      return _parse(value.cast<String, dynamic>());
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static PollenAnalysisModel? _parse(Map<String, dynamic> json) {
    final status = _status(json['status']);
    if (status == null) return null;
    final method = _nonEmptyString(json['method']);
    final methodVersion = _nonEmptyString(json['method_version']);
    if (method == null || methodVersion == null) return null;
    if (json['estimate'] != true) return null;
    final confidence = json['confidence'];
    if (confidence is! String ||
        !const {'low', 'unavailable'}.contains(confidence)) {
      return null;
    }

    final routeLength = _number(json['route_length_meters']);
    final known = _number(json['known_meters']);
    final unknown = _number(json['unknown_meters']);
    final coverage = _number(json['coverage_share']);
    final walking = _number(json['walking_duration_seconds']);
    final elapsed = _number(json['elapsed_duration_seconds']);
    if (routeLength == null ||
        routeLength <= 0 ||
        known == null ||
        unknown == null ||
        coverage == null ||
        walking == null ||
        elapsed == null) {
      return null;
    }
    if (coverage > 1 + _tolerance) return null;
    // The same invariants the backend promises, checked independently.
    if ((known + unknown - routeLength).abs() >
        routeLength * _tolerance + 0.05) {
      return null;
    }
    if ((coverage - known / routeLength).abs() > _tolerance) return null;
    if (elapsed < walking - _tolerance) return null;

    // The rendered unit must be the unit the source used.
    final unit = _nonEmptyString(json['concentration_unit']) ?? '';
    if (unit != ApiConstants.pollenConcentrationUnit) return null;

    final period = json['evaluated_period'];
    if (period is! Map) return null;
    final periodStart = _instant(period['start']);
    final periodEnd = _instant(period['end']);
    final timezoneName = _nonEmptyString(period['timezone']);
    if (periodStart == null ||
        periodEnd == null ||
        timezoneName == null ||
        periodEnd.isBefore(periodStart)) {
      return null;
    }

    final source = _source(json['source_provenance']);
    if (source == null) return null;
    final reasons = _strings(json['reasons']);
    final limitations = _strings(json['limitations']);
    final assumptions = _strings(json['assumptions']);
    if (reasons == null || limitations == null || assumptions == null) {
      return null;
    }

    final rawSpecies = json['species'];
    if (rawSpecies is! List || rawSpecies.isEmpty) return null;
    final species = <PollenSpeciesModel>[];
    for (final item in rawSpecies) {
      final parsed = _species(item, unit);
      if (parsed == null) return null;
      species.add(parsed);
    }
    final codes = species.map((item) => item.code).toSet();
    if (codes.length != species.length) return null;

    final hasNumbers =
        (status == PollenStatus.available || status == PollenStatus.partial) &&
        known > 0;
    if (hasNumbers) {
      // No numbers without their attribution and their caveats.
      if (!source.available ||
          source.attribution.isEmpty ||
          source.license.isEmpty ||
          source.provider.isEmpty) {
        return null;
      }
      if (assumptions.isEmpty || limitations.isEmpty) return null;
      if (confidence != 'low') return null;
    }
    if (!hasNumbers && confidence != 'unavailable') return null;

    // Status must agree with the coverage it claims.
    if (status == PollenStatus.unavailable ||
        status == PollenStatus.outsideCoverage) {
      if (known > _tolerance) return null;
      if (species.any((item) => item.state != PollenSpeciesState.unknown)) {
        return null;
      }
    }
    if (status == PollenStatus.available) {
      if (unknown > 0.05) return null;
      if (species.any((item) => item.state != PollenSpeciesState.available)) {
        return null;
      }
    }
    if (status == PollenStatus.partial && unknown <= 0) return null;

    final legs = _legs(json['legs'], unit);

    return PollenAnalysisModel(
      status: status,
      method: method,
      methodVersion: methodVersion,
      confidence: confidence,
      periodStart: periodStart,
      periodEnd: periodEnd,
      timezoneName: timezoneName,
      routeLengthMeters: routeLength,
      knownMeters: known,
      unknownMeters: unknown,
      coverageShare: coverage,
      walkingDurationSeconds: walking,
      elapsedDurationSeconds: elapsed,
      concentrationUnit: unit,
      species: species,
      legs: legs,
      reasons: reasons,
      limitations: limitations,
      assumptions: assumptions,
      source: source,
    );
  }

  static PollenStatus? _status(Object? value) {
    switch (value) {
      case 'available':
        return PollenStatus.available;
      case 'partial':
        return PollenStatus.partial;
      case 'unavailable':
        return PollenStatus.unavailable;
      case 'outside_coverage':
        return PollenStatus.outsideCoverage;
      default:
        return null;
    }
  }

  static PollenSpeciesState? _speciesState(Object? value) {
    switch (value) {
      case 'available':
        return PollenSpeciesState.available;
      case 'partial':
        return PollenSpeciesState.partial;
      case 'unknown':
        return PollenSpeciesState.unknown;
      default:
        return null;
    }
  }

  static PollenSpeciesModel? _species(Object? value, String unit) {
    if (value is! Map) return null;
    final json = value.cast<String, dynamic>();
    final code = _nonEmptyString(json['code']);
    final name = _nonEmptyString(json['name']);
    if (code == null || name == null) return null;
    if (json['unit'] != unit) return null;
    final state = _speciesState(json['status']);
    if (state == null) return null;
    final knownSeconds = _number(json['known_seconds']);
    final totalSeconds = _number(json['total_seconds']);
    final knownShare = _number(json['known_share']);
    if (knownSeconds == null ||
        totalSeconds == null ||
        totalSeconds <= 0 ||
        knownShare == null) {
      return null;
    }
    if (knownSeconds > totalSeconds + 1.0) return null;
    if (knownShare < 0 || knownShare > 1 + _tolerance) return null;
    final mean = _number(json['mean_concentration']);
    final peak = _number(json['peak_concentration']);
    final exposure = _number(json['exposure_grains_hours_per_m3']);
    final peakAt = json['peak_at'];
    if (state == PollenSpeciesState.unknown) {
      if (mean != null || peak != null || exposure != null || peakAt != null) {
        return null;
      }
    } else {
      if (mean == null || peak == null || exposure == null) return null;
      if (peakAt == null || _instant(peakAt) == null) return null;
      if (mean < 0 || peak < 0 || exposure < 0) return null;
      if (mean > peak + _tolerance) return null;
    }
    return PollenSpeciesModel(
      code: code,
      name: name,
      unit: unit,
      state: state,
      knownSeconds: knownSeconds,
      totalSeconds: totalSeconds,
      knownShare: knownShare,
      meanConcentration: mean,
      peakConcentration: peak,
      peakAt: peakAt is String ? peakAt : null,
      exposureGrainsHoursPerM3: exposure,
    );
  }

  static List<PollenLegModel>? _legs(Object? value, String unit) {
    if (value == null) return null;
    if (value is! List) throw const FormatException('legs must be a list');
    final legs = <PollenLegModel>[];
    for (final item in value) {
      if (item is! Map) throw const FormatException('leg must be an object');
      final json = item.cast<String, dynamic>();
      final index = json['leg_index'];
      final length = _number(json['length_meters']);
      final known = _number(json['known_meters']);
      final unknown = _number(json['unknown_meters']);
      final starts = _number(json['starts_at_seconds']);
      final ends = _number(json['ends_at_seconds']);
      final inside = json['inside_source_cell'];
      if (index is! int ||
          length == null ||
          known == null ||
          unknown == null ||
          starts == null ||
          ends == null ||
          inside is! bool ||
          ends < starts) {
        throw const FormatException('leg fields are inconsistent');
      }
      if ((known + unknown - length).abs() > 0.2) {
        throw const FormatException('leg sums disagree');
      }
      if (!inside && known > _tolerance) {
        throw const FormatException('a leg outside the cell has known metres');
      }
      final rawSpecies = json['species'];
      if (!inside) {
        if (rawSpecies is List && rawSpecies.isNotEmpty) {
          throw const FormatException('a leg outside the cell carries species');
        }
      } else if (rawSpecies is! List || rawSpecies.isEmpty) {
        throw const FormatException('a known leg must carry species');
      }
      final species = <PollenSpeciesModel>[];
      if (inside) {
        for (final entry in rawSpecies as List) {
          final parsed = _species(entry, unit);
          if (parsed == null) {
            throw const FormatException('leg species is inconsistent');
          }
          species.add(parsed);
        }
      }
      legs.add(
        PollenLegModel(
          legIndex: index,
          lengthMeters: length,
          knownMeters: known,
          unknownMeters: unknown,
          startsAtSeconds: starts,
          endsAtSeconds: ends,
          insideSourceCell: inside,
          species: species,
        ),
      );
    }
    return legs;
  }

  static PollenSourceModel? _source(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<String, dynamic>();
    final available = json['available'];
    if (available is! bool) return null;
    return PollenSourceModel(
      available: available,
      provider: _stringOr(json['provider'], ''),
      model: _stringOr(json['model'], ''),
      modelName: _stringOr(json['model_name'], ''),
      kind: _stringOr(json['kind'], ''),
      license: _stringOr(json['license'], ''),
      attribution: _stringOr(json['attribution'], ''),
      sourceUrl: _stringOr(json['source_url'], ''),
      retrievedAt: _instant(json['retrieved_at']),
      validUntil: _instant(json['valid_until']),
      intervalStart: _instant(json['interval_start']),
      intervalEnd: _instant(json['interval_end']),
      temporalResolutionSeconds: _integer(json['temporal_resolution_seconds']),
      spatialResolutionMeters: _integer(json['spatial_resolution_meters']),
      gridStepDegrees: _number(json['grid_step_degrees']),
      cellLatitude: _number(json['cell_latitude']),
      cellLongitude: _number(json['cell_longitude']),
      cellBounds: _cells(json['cell_bounds']),
      timeSemantics: json['time_semantics'] is String
          ? json['time_semantics'] as String
          : null,
      reason: json['reason'] is String ? json['reason'] as String : null,
    );
  }

  static List<double>? _cells(Object? value) {
    if (value == null) return null;
    if (value is! List || value.length != 4) return null;
    final bounds = <double>[];
    for (final item in value) {
      final number = _number(item);
      if (number == null) return null;
      bounds.add(number);
    }
    return bounds;
  }

  static double? _number(Object? value) {
    if (value is! num || value is bool) return null;
    final result = value.toDouble();
    return result.isFinite ? result : null;
  }

  static int? _integer(Object? value) {
    if (value is! int || value is bool) return null;
    return value;
  }

  static String _stringOr(Object? value, String fallback) =>
      value is String && value.isNotEmpty ? value : fallback;

  static String? _nonEmptyString(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  static List<String>? _strings(Object? value) {
    if (value is! List) return null;
    final result = <String>[];
    for (final item in value) {
      if (item is! String || item.trim().isEmpty) return null;
      result.add(item);
    }
    return result;
  }

  /// An offset-tagged instant. A naive timestamp is rejected on purpose: an
  /// assumed zone would be an invented value.
  static DateTime? _instant(Object? value) {
    if (value is! String || value.isEmpty) return null;
    if (!RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) return null;
    return DateTime.tryParse(value);
  }
}

String _formatNumber(double value) {
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

/// Russian wording for every reason code the C7.3 backend may return.
String pollenReasonText(String code) {
  switch (code) {
    case 'pollen_not_configured':
      return 'Источник пыльцы не подключён: это необязательная функция, '
          'включаемая оператором сервера.';
    case 'pollen_unavailable':
      return 'Источник прогноза пыльцы сейчас недоступен.';
    case 'pollen_source_invalid':
      return 'Ответ источника не прошёл проверку и не был использован.';
    case 'pollen_stale':
      return 'Данные источника устарели и не были использованы.';
    case 'pollen_outside_window':
      return 'Время прогулки вне доступного интервала прогноза пыльцы.';
    case 'pollen_no_data':
      return 'Для этого времени в источнике нет значений пыльцы.';
    case 'pollen_no_complete_panel':
      return 'Ни на одном часе прогулки нет значений по всем шести видам '
          'сразу: неполные значения не публикуются, чтобы часть не была '
          'показана как целое.';
    case 'outside_source_cell':
      return 'Часть маршрута вне ячейки источника (шаг сетки около 11 км): '
          'на неё значения не переносятся.';
    case 'pollen_incomplete':
      return 'Для части прогулки значения пыльцы отсутствуют — это время '
          'осталось неизвестным.';
    case 'modeled_pollen_concentration':
      return 'Числа — модельный прогноз пыльцы (CAMS), а не измерения.';
    case 'experimental_uncalibrated':
      return 'Экспериментальная оценка: без калибровки и без порогов опасности.';
    default:
      return code;
  }
}
