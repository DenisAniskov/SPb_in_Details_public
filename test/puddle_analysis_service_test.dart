import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/services/puddle_analysis_service.dart';

// --------------------------------------------------------------------------
// Phase C7.2 service contract: the request reuses the validated shade payload
// (no truncation, no invented durations), and every backend answer maps to a
// typed failure whose message tells the user that ORDINARY NAVIGATION STILL
// WORKS. Everything is offline: Dio talks to a scripted adapter.
// --------------------------------------------------------------------------

const GeoCoord _a = GeoCoord(59.9400, 30.3150);
const GeoCoord _b = GeoCoord(59.9410, 30.3160);
const GeoCoord _c = GeoCoord(59.9420, 30.3170);

final DateTime _departure = DateTime(2026, 7, 1, 14, 30);

RouteLegModel _leg({int seconds = 600, List<GeoCoord>? points, int? visit}) =>
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'POI 1',
      distanceMeters: 800,
      durationSeconds: seconds,
      geometryPoints: points ?? const [_a, _b, _c],
      visitMinutes: visit,
    );

Map<String, dynamic> _response({
  String status = 'available',
  String risk = 'moderate',
  Object? riskIndex = 0.42,
  double total = 1000,
  double known = 1000,
  double unknown = 0,
  double low = 200,
  double moderate = 600,
  double high = 200,
  double coverage = 1,
  Object? sensitivity,
}) => {
  'status': status,
  'method': 'experimental_precipitation_surface_index',
  'method_version': 'c7_2.3',
  'estimate': true,
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
  'evaluated_period': {
    'start': '2026-07-01T14:30:00+03:00',
    'end': '2026-07-01T14:40:00+03:00',
    'timezone': 'MSK',
  },
  'dataset_version': 'c7_2_palace_pilot_v1',
  'dataset_provenance': {
    'available': true,
    'source': 'OpenStreetMap',
    'license': 'ODbL-1.0',
  },
  'weather_provenance': {
    'available': true,
    'provider': 'Open-Meteo',
    'model': 'icon_global',
    'kind': 'modeled_forecast_and_recent_archived_forecast',
    'license': 'CC-BY-4.0',
    'attribution': 'Weather data by Open-Meteo.com; DWD ICON model',
    'source_url': 'https://open-meteo.com/en/docs',
    'retrieved_at': '2026-07-01T11:30:00+00:00',
    'valid_until': '2026-07-01T11:45:00+00:00',
    'temporal_resolution_seconds': 3600,
    'spatial_resolution_meters': 11000,
  },
  'reasons': const ['model_precipitation_history', 'experimental_uncalibrated'],
  'limitations': const [
    'Оценка относительная: это не вероятность конкретной лужи.',
  ],
  'sensitivity':
      sensitivity ??
      (risk == 'unknown'
          ? const <String, dynamic>{}
          : <String, dynamic>{
              'baseline': risk,
              'drying_faster_0_5x': 'low',
              'drying_faster_0_5x_risk_index': 0.1,
              'note': 'Параметры экспериментальные и не калиброваны.',
            }),
};

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

/// Answers from a script and records everything that would have gone out.
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

({BackendPuddleAnalysisService service, _ScriptedAdapter adapter}) _service(
  FutureOr<ResponseBody> Function(RequestOptions options) respond,
) {
  final client = ApiClient(customBaseUrl: 'https://example.test/api/v1');
  final adapter = _ScriptedAdapter(respond);
  client.dio.httpClientAdapter = adapter;
  return (
    service: BackendPuddleAnalysisService(apiClient: client),
    adapter: adapter,
  );
}

DioException _httpError(RequestOptions options, int status) => DioException(
  requestOptions: options,
  type: DioExceptionType.badResponse,
  response: Response<dynamic>(requestOptions: options, statusCode: status),
);

Matcher _failure(PuddleAnalysisFailureKind kind, Matcher message) =>
    isA<PuddleAnalysisFailure>()
        .having((failure) => failure.kind, 'failure kind', kind)
        .having((failure) => failure.message, 'user message', message);

void main() {
  test(
    'the request reuses the validated payload with overlay data disabled',
    () async {
      final setup = _service((_) => _json(_response()));
      final model = await setup.service.analyzeWalk(
        departure: _departure,
        legs: [_leg()],
        visitMinutesAfterLeg: const [10],
      );
      expect(model.risk, isNotNull);
      final request = setup.adapter.lastRequest;
      expect(request.path, '/environment/puddle/analyze');
      expect(request.method, 'POST');
      expect(
        request.receiveTimeout,
        const Duration(milliseconds: 15000),
        reason: 'отдельный бюджет оценки, не глобальный таймаут',
      );
      final body = setup.adapter.lastBody;
      expect(
        body['include_segments'],
        isFalse,
        reason: 'v1 не рисует оверлей: клиент не запрашивает классификацию',
      );
      final legs = body['legs'] as List;
      expect(legs, hasLength(1));
      final geometry = (legs.single as Map)['geometry'] as List;
      expect(
        geometry,
        hasLength(3),
        reason: 'геометрия отправляется как есть, без обрезки',
      );
      expect((legs.single as Map)['walking_duration_seconds'], 600);
      expect((legs.single as Map)['visit_duration_seconds_after_leg'], 600);
      expect(
        (body['departure_at'] as String),
        contains('+03:00'),
        reason: 'время с явным смещением, без наивного пояса',
      );
    },
  );

  test('a valid answer parses into the analysis model', () async {
    final setup = _service((_) => _json(_response()));
    final model = await setup.service.analyzeWalk(
      departure: _departure,
      legs: [_leg()],
    );
    expect(model.routeLengthMeters, 1000);
    expect(model.hasEstimate, isTrue);
    expect(model.reasons, contains('model_precipitation_history'));
  });

  test('404 means an old deployment, never a broken walk', () async {
    final setup = _service((options) => throw _httpError(options, 404));
    await expectLater(
      setup.service.analyzeWalk(departure: _departure, legs: [_leg()]),
      throwsA(
        _failure(
          PuddleAnalysisFailureKind.serviceUnavailable,
          contains('навигация работает'),
        ),
      ),
    );
  });

  test('413 is a too-detailed walk, not a service outage', () async {
    final setup = _service((options) => throw _httpError(options, 413));
    await expectLater(
      setup.service.analyzeWalk(departure: _departure, legs: [_leg()]),
      throwsA(
        _failure(
          PuddleAnalysisFailureKind.requestRejected,
          contains('слишком подробный'),
        ),
      ),
    );
  });

  test('422 is a rejected walk with an explicit message', () async {
    final setup = _service((options) => throw _httpError(options, 422));
    await expectLater(
      setup.service.analyzeWalk(departure: _departure, legs: [_leg()]),
      throwsA(
        _failure(
          PuddleAnalysisFailureKind.requestRejected,
          contains('Обычная навигация работает'),
        ),
      ),
    );
  });

  test('server errors are service unavailability', () async {
    final setup = _service((options) => throw _httpError(options, 500));
    await expectLater(
      setup.service.analyzeWalk(departure: _departure, legs: [_leg()]),
      throwsA(
        _failure(
          PuddleAnalysisFailureKind.serviceUnavailable,
          contains('недоступна'),
        ),
      ),
    );
  });

  test('a receive timeout never surfaces as a route problem', () async {
    final setup = _service(
      (options) => throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      ),
    );
    await expectLater(
      setup.service.analyzeWalk(departure: _departure, legs: [_leg()]),
      throwsA(
        _failure(
          PuddleAnalysisFailureKind.serviceUnavailable,
          contains('навигация работает'),
        ),
      ),
    );
  });

  test('a locally invalid walk is refused before anything is sent', () async {
    final setup = _service((_) => _json(_response()));
    // ~27.9 km in one leg: beyond the shared 25 km analysis contract.
    final tooLong = _leg(
      points: const [GeoCoord(59.9, 30.0), GeoCoord(59.9, 30.5)],
    );
    await expectLater(
      setup.service.analyzeWalk(departure: _departure, legs: [tooLong]),
      throwsA(
        _failure(
          PuddleAnalysisFailureKind.requestRejected,
          contains('Обычная навигация работает'),
        ),
      ),
    );
    expect(
      setup.adapter.requests,
      isEmpty,
      reason: 'некорректная геометрия не отправляется и не укорачивается',
    );
  });

  test(
    'an inconsistent payload is an invalid response, not an estimate',
    () async {
      final setup = _service((_) => _json(_response(known: 900, unknown: 0)));
      await expectLater(
        setup.service.analyzeWalk(departure: _departure, legs: [_leg()]),
        throwsA(
          _failure(
            PuddleAnalysisFailureKind.invalidResponse,
            contains('неполную оценку'),
          ),
        ),
      );
    },
  );

  test('an unavailable answer is a normal result, not a failure', () async {
    final setup = _service(
      (_) => _json(
        _response(
          status: 'unavailable',
          risk: 'unknown',
          riskIndex: null,
          known: 0,
          unknown: 1000,
          low: 0,
          moderate: 0,
          high: 0,
          coverage: 0,
        ),
      ),
    );
    final model = await setup.service.analyzeWalk(
      departure: _departure,
      legs: [_leg()],
    );
    expect(model.hasEstimate, isFalse);
    expect(model.unknownMeters, 1000);
  });
}
