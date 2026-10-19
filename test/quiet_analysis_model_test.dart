import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';

Map<String, dynamic> _response({
  String status = 'available',
  bool estimate = true,
  double total = 1000,
  double known = 1000,
  double unknown = 0,
  double coverage = 1,
  double? index = 0.42,
  double? lowShare = 0.55,
  double? majorShare = 0.2,
  bool trafficTimeModeled = false,
  String temporalModel = 'static_osm_network',
  bool includeDataset = true,
}) => {
  'status': status,
  'estimate': estimate,
  'confidence': estimate ? 'low' : 'unavailable',
  'method': 'relative_road_noise_exposure_proxy',
  'method_version': 'c11_1',
  'dataset_version': includeDataset ? 'c11_quiet_spb_central_v1' : null,
  'dataset_sha256': includeDataset ? 'a' * 64 : null,
  'evaluated_at': '2026-10-17T12:00:00+03:00',
  'temporal_model': temporalModel,
  'traffic_time_modeled': trafficTimeModeled,
  'time_context_note': 'Время только для отчёта.',
  'route_length_meters': total,
  'known_meters': known,
  'unknown_meters': unknown,
  'coverage_share': coverage,
  'road_noise_exposure_index': index,
  'index_scale': '0..1, не дБ',
  'low_exposure_share': lowShare,
  'major_road_adjacent_share': majorShare,
  'mean_nearest_road_distance_m': 42.0,
  'max_road_class_nearby': 'primary',
  'legs': null,
  'reasons': const <String>[],
  'limitations': const ['Не дБ и не измерение шума.'],
  'assumptions': const ['Прокси по карте дорог.'],
  'source_provenance': const {
    'license': 'ODbL-1.0',
    'attribution': '© OpenStreetMap contributors',
  },
  'diagnostics': const {'road_count': 3595},
};

void main() {
  test('available payload preserves the relative proxy and coverage', () {
    final model = QuietAnalysisModel.tryFromJson(_response());
    expect(model, isNotNull);
    expect(model!.status, QuietStatus.available);
    expect(model.hasEstimate, isTrue);
    expect(model.roadNoiseExposureIndex, 0.42);
    expect(model.coverageShare, 1);
    expect(model.lowExposureShare, 0.55);
    expect(model.trafficTimeModeled, isFalse);
    expect(model.temporalModel, 'static_osm_network');
    expect(model.summary, contains('частично проходит рядом'));
    expect(model.lowExposureLabel, '55% проверенного пути');
    expect(model.datasetVersion, 'c11_quiet_spb_central_v1');
    expect(model.limitations, isNotEmpty);
  });

  test('partial coverage keeps a number only on the known part', () {
    final model = QuietAnalysisModel.tryFromJson(
      _response(
        status: 'partial',
        total: 1000,
        known: 600,
        unknown: 400,
        coverage: 0.6,
        index: 0.3,
      ),
    );
    expect(model, isNotNull);
    expect(model!.status, QuietStatus.partial);
    expect(model.coverageShare, 0.6);
    expect(model.unknownMeters, 400);
  });

  test('unavailable and outside coverage never carry an index', () {
    for (final status in ['unavailable', 'outside_coverage']) {
      final model = QuietAnalysisModel.tryFromJson(
        _response(
          status: status,
          estimate: false,
          total: 1000,
          known: 0,
          unknown: 1000,
          coverage: 0,
          index: null,
          lowShare: null,
          majorShare: null,
          includeDataset: false,
        ),
      );
      expect(model, isNotNull, reason: status);
      expect(model!.hasEstimate, isFalse);
      expect(model.roadNoiseExposureIndex, isNull);
      expect(model.lowExposureShare, isNull);
    }
  });

  test(
    'the parser refuses claims that would turn the proxy into acoustics',
    () {
      expect(
        QuietAnalysisModel.tryFromJson(_response(trafficTimeModeled: true)),
        isNull,
      );
      expect(
        QuietAnalysisModel.tryFromJson(_response(temporalModel: 'hourly')),
        isNull,
      );
      expect(QuietAnalysisModel.tryFromJson(_response(index: 1.5)), isNull);
      expect(QuietAnalysisModel.tryFromJson(_response(index: -0.1)), isNull);
      expect(
        QuietAnalysisModel.tryFromJson(
          _response(known: 700, unknown: 100, coverage: 0.7),
        ),
        isNull,
      );
      expect(
        QuietAnalysisModel.tryFromJson(
          _response(coverage: 0.8, known: 1000, unknown: 0),
        ),
        isNull,
      );
      expect(
        QuietAnalysisModel.tryFromJson(
          _response(estimate: false, index: 0.2, coverage: 1),
        ),
        isNull,
      );
      expect(
        QuietAnalysisModel.tryFromJson(_response(includeDataset: false)),
        isNull,
      );
      expect(QuietAnalysisModel.tryFromJson('not a map'), isNull);
    },
  );

  test('reason text is human and never invents a positive state', () {
    expect(quietReasonText('quiet_engine_disabled'), contains('не включена'));
    expect(
      quietReasonText('route_outside_pilot'),
      contains('вне проверенного'),
    );
    expect(
      quietReasonText('route_partially_outside_pilot'),
      contains('только на покрытой'),
    );
  });
}
