import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';

// --------------------------------------------------------------------------
// Phase C7.2: the client model must REFUSE inconsistent payloads instead of
// silently repairing them. Every rejection below is a case where a naive
// parser would either invent a risk level or turn unknown into dry.
// --------------------------------------------------------------------------

/// Distinguishes "omitted on purpose" from a derived default in [_payload].
const _autoSensitivity = Object();

Map<String, dynamic> _payload({
  String status = 'available',
  String risk = 'moderate',
  Object? riskIndex = 0.42,
  double total = 1000,
  double known = 1000,
  double unknown = 0,
  double low = 200,
  double moderate = 600,
  double high = 200,
  double coverage = 1.0,
  bool estimate = true,
  Object? period,
  Object? dataset,
  Object? weather,
  Object? sensitivity = _autoSensitivity,
  Object? reasons = const ['model_precipitation_history'],
  Object? limitations = const ['Ограничение модели.'],
}) {
  final resolvedSensitivity = identical(sensitivity, _autoSensitivity)
      ? (risk == 'unknown'
            ? const <String, dynamic>{}
            : <String, dynamic>{
                'baseline': risk,
                'drying_faster_0_5x': 'low',
                'drying_faster_0_5x_risk_index': 0.1,
                'drying_slower_2x': risk == 'high' ? 'high' : 'moderate',
                'drying_slower_2x_risk_index': 0.77,
                'ponding_sooner_saturation_0_75x': 'high',
                'ponding_sooner_saturation_0_75x_risk_index': 0.8,
                'note': 'Параметры экспериментальные и не калиброваны.',
              })
      : sensitivity;
  return {
    'status': status,
    'method': 'experimental_precipitation_surface_index',
    'method_version': 'c7_2.3',
    'estimate': estimate,
    'risk_level': risk,
    'risk_index': riskIndex,
    'route_length_meters': total,
    'known_meters': known,
    'unknown_meters': unknown,
    'low_meters': low,
    'moderate_meters': moderate,
    'high_meters': high,
    'coverage_share': coverage,
    'confidence': 'low',
    'evaluated_period':
        period ??
        {
          'start': '2026-10-16T12:00:00+03:00',
          'end': '2026-10-16T13:00:00+03:00',
          'timezone': 'MSK',
        },
    'dataset_version': 'c7_2_palace_pilot_v1',
    'dataset_provenance':
        dataset ??
        {'available': true, 'source': 'OpenStreetMap', 'license': 'ODbL-1.0'},
    'weather_provenance':
        weather ??
        {
          'available': true,
          'provider': 'Open-Meteo',
          'model': 'icon_global',
          'kind': 'modeled_forecast_and_recent_archived_forecast',
          'license': 'CC-BY-4.0',
          'attribution': 'Weather data by Open-Meteo.com; DWD ICON model',
          'source_url': 'https://open-meteo.com/en/docs',
          'retrieved_at': '2026-10-16T12:00:00+00:00',
          'valid_until': '2026-10-16T12:15:00+00:00',
          'temporal_resolution_seconds': 3600,
          'spatial_resolution_meters': 11000,
        },
    'reasons': reasons,
    'limitations': limitations,
    'sensitivity': resolvedSensitivity,
  };
}

void main() {
  test('a consistent payload parses into a full model', () {
    final model = PuddleAnalysisModel.tryFromJson(_payload())!;
    expect(model.status, PuddleStatus.available);
    expect(model.risk, PuddleRisk.moderate);
    expect(model.riskIndex, 0.42);
    expect(model.routeLengthMeters, 1000);
    expect(model.knownMeters, 1000);
    expect(model.coverageShare, 1.0);
    expect(model.confidence, 'low');
    expect(model.datasetVersion, 'c7_2_palace_pilot_v1');
    expect(model.datasetSource, 'OpenStreetMap');
    expect(model.datasetLicense, 'ODbL-1.0');
    expect(model.weather.available, isTrue);
    expect(model.weather.provider, 'Open-Meteo');
    expect(model.weather.retrievedAt, isNotNull);
    expect(model.weather.temporalResolutionSeconds, 3600);
    expect(model.hasEstimate, isTrue);
    expect(model.reasons, ['model_precipitation_history']);
    expect(model.limitations, ['Ограничение модели.']);
  });

  test('the sensitivity block is preserved for display, not dropped', () {
    final model = PuddleAnalysisModel.tryFromJson(_payload())!;
    final sensitivity = model.sensitivity!;
    expect(sensitivity.baseline, PuddleRisk.moderate);
    expect(sensitivity.variants.keys, contains('drying_faster_0_5x'));
    expect(sensitivity.variants['drying_faster_0_5x'], PuddleRisk.low);
    expect(sensitivity.variantIndexes['drying_faster_0_5x'], 0.1);
    expect(sensitivity.variantIndexes['drying_slower_2x'], 0.77);
    expect(sensitivity.note, contains('не калиброваны'));
    expect(puddleSensitivityLabel('drying_slower_2x'), contains('медленнее'));
    expect(
      puddleSensitivityLabel('unexpected_future_variant'),
      'unexpected_future_variant',
      reason: 'неизвестный вариант показывается как есть, не скрывается',
    );
  });

  test('the weather attribution and licence survive parsing', () {
    final model = PuddleAnalysisModel.tryFromJson(_payload())!;
    expect(model.weather.model, 'icon_global');
    expect(model.weather.attribution, contains('Open-Meteo.com'));
    expect(model.weather.license, 'CC-BY-4.0');
    expect(model.weather.sourceUrl, contains('open-meteo.com'));
  });

  test('an unavailable payload keeps unknown and carries no numbers', () {
    final model = PuddleAnalysisModel.tryFromJson(
      _payload(
        status: 'unavailable',
        risk: 'unknown',
        riskIndex: null,
        known: 0,
        unknown: 1000,
        low: 0,
        moderate: 0,
        high: 0,
        coverage: 0,
        weather: {
          'available': false,
          'provider': 'Open-Meteo',
          'kind': 'modeled_forecast_and_recent_archived_forecast',
          'license': 'CC-BY-4.0',
          'reason': 'weather_not_configured',
        },
        reasons: const ['weather_not_configured'],
      ),
    )!;
    expect(model.status, PuddleStatus.unavailable);
    expect(model.risk, PuddleRisk.unknown);
    expect(model.riskIndex, isNull);
    expect(model.knownMeters, 0);
    expect(model.unknownMeters, 1000);
    expect(model.hasEstimate, isFalse);
    expect(model.weather.available, isFalse);
    expect(
      model.sensitivity,
      isNull,
      reason: 'без чисел нет и блока прозрачности параметров',
    );
  });

  test('a partial payload keeps the unknown share explicit', () {
    final model = PuddleAnalysisModel.tryFromJson(
      _payload(
        status: 'partial',
        risk: 'high',
        riskIndex: 0.8,
        total: 1000,
        known: 600,
        unknown: 400,
        low: 0,
        moderate: 100,
        high: 500,
        coverage: 0.6,
        reasons: const ['unmatched_osm_way', 'model_precipitation_history'],
      ),
    )!;
    expect(model.status, PuddleStatus.partial);
    expect(model.knownMeters, 600);
    expect(model.unknownMeters, 400);
    expect(model.coverageShare, 0.6);
    expect(model.risk, PuddleRisk.high);
  });

  group('inconsistent payloads are refused', () {
    final rejected = <String, Map<String, dynamic>>{
      'unknown status': _payload(status: 'probably_wet'),
      'unknown risk level': _payload(risk: 'slightly_wet'),
      'lengths do not add up': _payload(known: 900, unknown: 50),
      'class buckets do not add up': _payload(
        low: 100,
        moderate: 600,
        high: 200,
      ),
      'coverage disagrees with the lengths': _payload(coverage: 0.5),
      'risk estimate without an index': _payload(riskIndex: null),
      'unknown risk with an index': _payload(risk: 'unknown'),
      'unavailable with known metres': _payload(
        status: 'unavailable',
        risk: 'unknown',
        riskIndex: null,
        known: 500,
        unknown: 500,
        low: 0,
        moderate: 500,
        high: 0,
        coverage: 0.5,
      ),
      'estimate flag missing': _payload(estimate: false),
      'negative metres': _payload(
        total: -1,
        known: -1,
        unknown: 0,
        low: 0,
        moderate: -1,
        high: 0,
        coverage: 0,
      ),
      'coverage above one': _payload(coverage: 1.5),
      'index above one': _payload(riskIndex: 1.4),
      'naive period start': _payload(
        period: {
          'start': '2026-10-16T12:00:00',
          'end': '2026-10-16T13:00:00+03:00',
          'timezone': 'MSK',
        },
      ),
      'period ends before it starts': _payload(
        period: {
          'start': '2026-10-16T13:00:00+03:00',
          'end': '2026-10-16T12:00:00+03:00',
          'timezone': 'MSK',
        },
      ),
      'weather retrieved_at is not a timestamp': _payload(
        weather: {
          'available': true,
          'retrieved_at': 'yesterday',
          'valid_until': null,
        },
      ),
      'weather validity precedes retrieval': _payload(
        weather: {
          'available': true,
          'retrieved_at': '2026-10-16T12:00:00+00:00',
          'valid_until': '2026-10-16T11:00:00+00:00',
        },
      ),
      'reasons contain non-strings': _payload(reasons: const [1, 2]),
      'confidence outside the vocabulary': _payload()
        ..['confidence'] = 'strong',
      'missing dataset provenance': _payload(dataset: 'OpenStreetMap'),
      'numbers without the sensitivity block': _payload()
        ..remove('sensitivity'),
      'sensitivity baseline disagrees with the level': _payload(
        sensitivity: {'baseline': 'low', 'note': 'n'},
      ),
      'sensitivity without the explaining note': _payload(
        sensitivity: {'baseline': 'moderate'},
      ),
      'sensitivity baseline outside the vocabulary': _payload(
        sensitivity: {'baseline': 'slightly_wet', 'note': 'n'},
      ),
      'sensitivity index out of range': _payload(
        sensitivity: {
          'baseline': 'moderate',
          'note': 'n',
          'drying_faster_0_5x': 'low',
          'drying_faster_0_5x_risk_index': 1.5,
        },
      ),
      'sensitivity index is not a number': _payload(
        sensitivity: {
          'baseline': 'moderate',
          'note': 'n',
          'drying_faster_0_5x': 'low',
          'drying_faster_0_5x_risk_index': 'wet',
        },
      ),
      'sensitivity is not a map': _payload(sensitivity: 'low'),
      'a transparency block without any numbers': _payload(
        risk: 'unknown',
        riskIndex: null,
        sensitivity: {'baseline': 'low', 'note': 'n'},
      ),
      'a transparency block on an unavailable answer': _payload(
        status: 'unavailable',
        risk: 'unknown',
        riskIndex: null,
        known: 0,
        unknown: 1000,
        low: 0,
        moderate: 0,
        high: 0,
        coverage: 0,
        sensitivity: {'baseline': 'moderate', 'note': 'n'},
      ),
    };
    rejected.forEach((name, payload) {
      test(name, () {
        expect(PuddleAnalysisModel.tryFromJson(payload), isNull, reason: name);
      });
    });
  });

  test('non-maps and short payloads are refused without throwing', () {
    expect(PuddleAnalysisModel.tryFromJson(null), isNull);
    expect(PuddleAnalysisModel.tryFromJson('{}'), isNull);
    expect(PuddleAnalysisModel.tryFromJson(<String, dynamic>{}), isNull);
  });

  test(
    'risk labels and reason texts are honest Russian, not probabilities',
    () {
      expect(PuddleRisk.unknown.label, contains('недостаточно данных'));
      expect(PuddleRisk.low.label, contains('риск'));
      expect(
        puddleReasonText('weather_not_configured'),
        'Погодный источник пока не подключён.',
      );
      expect(puddleReasonText('outside_pilot'), contains('пилотной зоны'));
      expect(
        puddleReasonText('unmatched_osm_way'),
        'Для части пути не подтверждены сведения о покрытии.',
      );
      expect(puddleReasonText('made_up_code'), contains('ограничена'));
    },
  );
}
