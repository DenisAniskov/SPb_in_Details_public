import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';

const _a = GeoCoord(59.9400, 30.3150);
const _b = GeoCoord(59.9410, 30.3160);
const _c = GeoCoord(59.9420, 30.3170);

RouteLegModel _leg({int points = 3, int seconds = 600}) => RouteLegModel(
  fromTitle: 'Старт',
  toTitle: 'Финиш',
  distanceMeters: 800,
  durationSeconds: seconds,
  geometryPoints: points == 3
      ? const [_a, _b, _c]
      : [for (var i = 0; i < points; i++) GeoCoord(59.94 + i * 0.00001, 30.31)],
  visitMinutes: 10,
);

Map<String, dynamic> _response() => {
  'status': 'available',
  'estimate': true,
  'confidence': 'low',
  'method': 'relative_road_noise_exposure_proxy',
  'method_version': 'c11_1',
  'dataset_version': 'c11_quiet_spb_central_v1',
  'dataset_sha256': 'a' * 64,
  'evaluated_at': '2026-10-17T12:00:00+03:00',
  'temporal_model': 'static_osm_network',
  'traffic_time_modeled': false,
  'time_context_note': 'Время только для отчёта.',
  'route_length_meters': 1000,
  'known_meters': 1000,
  'unknown_meters': 0,
  'coverage_share': 1,
  'road_noise_exposure_index': 0.42,
  'index_scale': '0..1',
  'low_exposure_share': 0.5,
  'major_road_adjacent_share': 0.2,
  'mean_nearest_road_distance_m': 40,
  'max_road_class_nearby': 'primary',
  'legs': null,
  'reasons': const <String>[],
  'limitations': const ['Не дБ.'],
  'assumptions': const ['Прокси.'],
  'source_provenance': const {'license': 'ODbL-1.0'},
  'diagnostics': const {},
};

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions options) respond;
  final List<RequestOptions> requests = [];
  final List<String> bodies = [];
  RequestOptions get lastRequest => requests.last;
  Map<String, dynamic> get lastBody =>
      jsonDecode(bodies.last) as Map<String, dynamic>;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final chunks = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        chunks.addAll(chunk);
      }
    }
    bodies.add(utf8.decode(chunks));
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

({BackendQuietAnalysisService service, _ScriptedAdapter adapter}) _service(
  FutureOr<ResponseBody> Function(RequestOptions options) respond,
) {
  final client = ApiClient(customBaseUrl: 'https://example.test/api/v1');
  final adapter = _ScriptedAdapter(respond);
  client.dio.httpClientAdapter = adapter;
  return (
    service: BackendQuietAnalysisService(apiClient: client),
    adapter: adapter,
  );
}

void main() {
  test('payload uses real geometry, offset-tagged time and no durations', () {
    final payload = buildQuietAnalyzePayload(
      assessedAt: DateTime(2026, 10, 17, 12, 30),
      legs: [_leg()],
      visitMinutesAfterLeg: const [10],
      includeLegs: true,
    );
    expect(payload['assessed_at'], '2026-10-17T12:30:00.000+03:00');
    expect(payload['include_legs'], isTrue);
    final legs = payload['legs'] as List;
    final geometry = (legs.single as Map)['geometry'] as List;
    expect(geometry, hasLength(3));
    expect(geometry.first, {'latitude': 59.94, 'longitude': 30.315});
    expect(
      (legs.single as Map).containsKey('walking_duration_seconds'),
      isFalse,
    );
  });

  test('oversized or invalid geometry is refused before sending', () {
    expect(
      () => buildQuietAnalyzePayload(
        assessedAt: DateTime(2026, 10, 17, 12),
        legs: [_leg(points: 2001)],
      ),
      throwsA(
        isA<QuietAnalysisFailure>().having(
          (failure) => failure.kind,
          'kind',
          QuietAnalysisFailureKind.requestRejected,
        ),
      ),
    );
    expect(
      () => buildQuietAnalyzePayload(
        assessedAt: DateTime(2026, 10, 17, 12),
        legs: [_leg(seconds: 0)],
      ),
      throwsA(isA<QuietAnalysisFailure>()),
    );
  });

  test('valid backend response is parsed', () async {
    final scripted = _service((_) => _json(_response()));
    final model = await scripted.service.analyzeWalk(
      assessedAt: DateTime(2026, 10, 17, 12),
      legs: [_leg()],
    );
    expect(model.roadNoiseExposureIndex, 0.42);
    expect(scripted.adapter.requests.single.path, '/environment/quiet/analyze');
    expect(scripted.adapter.lastBody['assessed_at'], isNotNull);
  });

  test(
    '413 and 422 are request rejections; 404 and 500 are availability',
    () async {
      for (final status in [413, 422]) {
        final scripted = _service(
          (_) => _json({'detail': 'rejected'}, status: status),
        );
        await expectLater(
          scripted.service.analyzeWalk(
            assessedAt: DateTime(2026, 10, 17, 12),
            legs: [_leg()],
          ),
          throwsA(
            isA<QuietAnalysisFailure>().having(
              (failure) => failure.kind,
              'kind',
              QuietAnalysisFailureKind.requestRejected,
            ),
          ),
        );
      }
      for (final status in [404, 500, 503]) {
        final scripted = _service(
          (_) => _json({'detail': 'down'}, status: status),
        );
        await expectLater(
          scripted.service.analyzeWalk(
            assessedAt: DateTime(2026, 10, 17, 12),
            legs: [_leg()],
          ),
          throwsA(
            isA<QuietAnalysisFailure>().having(
              (failure) => failure.kind,
              'kind',
              QuietAnalysisFailureKind.serviceUnavailable,
            ),
          ),
        );
      }
    },
  );

  test(
    'an incomplete or acoustically overclaiming payload is invalid',
    () async {
      final broken = _response()..remove('known_meters');
      final scripted = _service((_) => _json(broken));
      await expectLater(
        scripted.service.analyzeWalk(
          assessedAt: DateTime(2026, 10, 17, 12),
          legs: [_leg()],
        ),
        throwsA(
          isA<QuietAnalysisFailure>().having(
            (failure) => failure.kind,
            'kind',
            QuietAnalysisFailureKind.invalidResponse,
          ),
        ),
      );
      final overclaim = _response()..['traffic_time_modeled'] = true;
      final scripted2 = _service((_) => _json(overclaim));
      await expectLater(
        scripted2.service.analyzeWalk(
          assessedAt: DateTime(2026, 10, 17, 12),
          legs: [_leg()],
        ),
        throwsA(
          isA<QuietAnalysisFailure>().having(
            (failure) => failure.kind,
            'kind',
            QuietAnalysisFailureKind.invalidResponse,
          ),
        ),
      );
    },
  );
}
