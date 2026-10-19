import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';

// --------------------------------------------------------------------------
// Phase C7.3 service contract: the request reuses the validated geometry and
// time contract (no truncation, no invented durations, offset-tagged time),
// asks for no overlay data, and every backend answer maps to a typed failure
// whose message tells the user that ORDINARY NAVIGATION STILL WORKS.
// Everything is offline: Dio talks to a scripted adapter.
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

const _speciesCodes = <String, String>{
  'alder_pollen': 'Ольха',
  'birch_pollen': 'Берёза',
  'grass_pollen': 'Злаки',
  'mugwort_pollen': 'Полынь',
  'ragweed_pollen': 'Амброзия',
  'olive_pollen': 'Маслина',
};

List<Map<String, dynamic>> _species({double value = 12.6}) => _speciesCodes
    .entries
    .map(
      (entry) => {
        'code': entry.key,
        'name': entry.value,
        'unit': 'grains/m³',
        'status': 'available',
        'known_seconds': 600,
        'total_seconds': 600,
        'known_share': 1.0,
        'mean_concentration': value,
        'peak_concentration': value,
        'peak_at': '2026-07-01T11:00:00+00:00',
        'exposure_grains_hours_per_m3': value / 6,
      },
    )
    .toList();

Map<String, dynamic> _response({
  String status = 'available',
  Object? species,
  double total = 1000,
  double known = 1000,
  double unknown = 0,
  double coverage = 1,
  Object? source,
  List<String>? reasons,
}) => {
  'status': status,
  'method': 'experimental_pollen_exposure',
  'method_version': 'c7_3.1',
  'estimate': true,
  'confidence': status == 'available' || status == 'partial'
      ? 'low'
      : 'unavailable',
  'evaluated_period': {
    'start': '2026-07-01T14:30:00+03:00',
    'end': '2026-07-01T14:40:00+03:00',
    'timezone': '+03:00',
  },
  'route_length_meters': total,
  'known_meters': known,
  'unknown_meters': unknown,
  'coverage_share': coverage,
  'walking_duration_seconds': 600,
  'elapsed_duration_seconds': 600,
  'concentration_unit': 'grains/m³',
  'species': species ?? _species(),
  'legs': null,
  'reasons':
      reasons ??
      const ['modeled_pollen_concentration', 'experimental_uncalibrated'],
  'limitations': const ['Это концентрации, а не прогноз симптомов.'],
  'assumptions': const [
    'Концентрация считается постоянной внутри часа [t, t+1h).',
  ],
  'source_provenance':
      source ??
      {
        'available': true,
        'provider': 'Open-Meteo',
        'model': 'cams_europe',
        'model_name': 'CAMS European Air Quality Forecast (CAMS ENSEMBLE)',
        'kind': 'modeled_forecast_and_recent_archived_forecast',
        'license': 'CC-BY-4.0',
        'attribution': 'Pollen data by Open-Meteo.com; CAMS ENSEMBLE (Copernicus Atmosphere Monitoring Service) model',
        'source_url': 'https://open-meteo.com/en/docs/air-quality-api',
        'retrieved_at': '2026-07-01T11:00:00+00:00',
        'valid_until': '2026-07-01T12:00:00+00:00',
        'interval_start': '2026-06-30T00:00:00+00:00',
        'interval_end': '2026-07-05T00:00:00+00:00',
        'temporal_resolution_seconds': 3600,
        'spatial_resolution_meters': 11000,
        'grid_step_degrees': 0.1,
        'cell_latitude': 59.9,
        'cell_longitude': 30.3,
        'cell_bounds': [59.85, 30.25, 59.95, 30.35],
        'time_semantics': 'instantaneous concentration valid for the indicated hour [t, t+1h); null is a gap, not zero',
      },
  'diagnostics': const {'legs': 1},
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

({BackendPollenAnalysisService service, _ScriptedAdapter adapter}) _service(
  FutureOr<ResponseBody> Function(RequestOptions options) respond,
) {
  final client = ApiClient(customBaseUrl: 'https://example.test/api/v1');
  final adapter = _ScriptedAdapter(respond);
  client.dio.httpClientAdapter = adapter;
  return (
    service: BackendPollenAnalysisService(apiClient: client),
    adapter: adapter,
  );
}

DioException _httpError(RequestOptions options, int status) => DioException(
  requestOptions: options,
  response: Response<dynamic>(
    requestOptions: options,
    statusCode: status,
    data: const {'detail': 'ошибка'},
  ),
);

Matcher _failure(PollenAnalysisFailureKind kind) => predicate<Object>(
  (error) => error is PollenAnalysisFailure && error.kind == kind,
  'a $kind failure whose message explains ordinary navigation still works',
);

void main() {
  test(
    'the request carries the validated geometry and asks for no overlay',
    () async {
      final scripted = _service((_) => _json(_response()));
      final service = scripted.service;
      final adapter = scripted.adapter;
      await service.analyzeWalk(
        departure: _departure,
        legs: [_leg()],
        // The visit after a leg is passed explicitly, exactly as the provider
        // does it from the real route.
        visitMinutesAfterLeg: const [10],
      );

      expect(adapter.lastRequest.path, '/environment/pollen/analyze');
      expect(adapter.lastRequest.method, 'POST');
      expect(adapter.lastRequest.receiveTimeout, const Duration(seconds: 15));
      final body = adapter.lastBody;
      // Pollen asks for a per-leg breakdown, never for a map overlay.
      expect(body.containsKey('include_segments'), isFalse);
      expect(body.containsKey('include_legs'), isFalse);
      expect(body['departure_at'], endsWith('+03:00'));
      final legs = body['legs'] as List<dynamic>;
      expect(legs, hasLength(1));
      final geometry =
          (legs.first as Map<String, dynamic>)['geometry'] as List<dynamic>;
      // The native polyline is NOT shortened or resampled.
      expect(geometry, hasLength(3));
      expect(
        (legs.first as Map<String, dynamic>)['walking_duration_seconds'],
        600,
      );
      expect(
        (legs.first
            as Map<String, dynamic>)['visit_duration_seconds_after_leg'],
        600,
      );
    },
  );

  test('a valid answer parses into the analysis model', () async {
    final service = _service((_) => _json(_response())).service;
    final analysis = await service.analyzeWalk(
      departure: _departure,
      legs: [_leg()],
    );
    expect(analysis.status, PollenStatus.available);
    expect(analysis.concentrationUnit, 'grains/m³');
    expect(analysis.species, hasLength(6));
    expect(analysis.species.first.name, 'Ольха');
    expect(analysis.source.license, 'CC-BY-4.0');
    expect(analysis.hasEstimate, isTrue);
  });

  test('404 means an old deployment, never a broken walk', () async {
    final service = _service((options) async => throw _httpError(options, 404))
        .service;
    expect(
      () => service.analyzeWalk(departure: _departure, legs: [_leg()]),
      throwsA(_failure(PollenAnalysisFailureKind.serviceUnavailable)),
    );
  });

  test('413 is a too-detailed walk, not a service outage', () async {
    final service = _service((options) async => throw _httpError(options, 413))
        .service;
    await expectLater(
      service.analyzeWalk(departure: _departure, legs: [_leg()]),
      throwsA(
        isA<PollenAnalysisFailure>()
            .having(
              (error) => error.kind,
              'kind',
              PollenAnalysisFailureKind.requestRejected,
            )
            .having(
              (error) => error.message,
              'message',
              contains('слишком подробный'),
            ),
      ),
    );
  });

  test('422 is a rejected walk with an explicit message', () async {
    final service = _service((options) async => throw _httpError(options, 422))
        .service;
    expect(
      () => service.analyzeWalk(departure: _departure, legs: [_leg()]),
      throwsA(_failure(PollenAnalysisFailureKind.requestRejected)),
    );
  });

  test('server errors are service unavailability', () async {
    final service = _service((options) async => throw _httpError(options, 503))
        .service;
    await expectLater(
      service.analyzeWalk(departure: _departure, legs: [_leg()]),
      throwsA(
        isA<PollenAnalysisFailure>()
            .having(
              (error) => error.kind,
              'kind',
              PollenAnalysisFailureKind.serviceUnavailable,
            )
            .having(
              (error) => error.message,
              'message',
              contains('Обычная навигация работает'),
            ),
      ),
    );
  });

  test('a receive timeout never surfaces as a route problem', () async {
    final service = _service(
      (options) async => throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      ),
    ).service;
    expect(
      () => service.analyzeWalk(departure: _departure, legs: [_leg()]),
      throwsA(_failure(PollenAnalysisFailureKind.serviceUnavailable)),
    );
  });

  test('a locally invalid walk is refused before anything is sent', () async {
    final scripted = _service((_) => _json(_response()));
    final service = scripted.service;
    final adapter = scripted.adapter;
    await expectLater(
      service.analyzeWalk(
        departure: _departure,
        legs: [
          _leg(points: const [_a]),
        ],
      ),
      throwsA(_failure(PollenAnalysisFailureKind.requestRejected)),
    );
    // Nothing left the device: no request means no geometry was transmitted.
    expect(adapter.requests, isEmpty);
  });

  test(
    'an inconsistent payload is an invalid response, not an estimate',
    () async {
      // A species that carries a number while the panel says it is unknown.
      final species = <Map<String, dynamic>>[
        // A species that carries a number while the panel calls it unknown.
        {..._species().first, 'status': 'unknown'},
        ..._species().skip(1),
      ];
      final service = _service((_) => _json(_response(species: species)))
          .service;
      expect(
        () => service.analyzeWalk(departure: _departure, legs: [_leg()]),
        throwsA(_failure(PollenAnalysisFailureKind.invalidResponse)),
      );
    },
  );

  test('an unavailable answer is a normal result, not a failure', () async {
    final unknownPanel = _speciesCodes.entries
        .map(
          (entry) => {
            'code': entry.key,
            'name': entry.value,
            'unit': 'grains/m³',
            'status': 'unknown',
            'known_seconds': 0,
            'total_seconds': 600,
            'known_share': 0.0,
            'mean_concentration': null,
            'peak_concentration': null,
            'peak_at': null,
            'exposure_grains_hours_per_m3': null,
          },
        )
        .toList();
    final service = _service(
      (_) => _json(
        _response(
          status: 'unavailable',
          known: 0,
          unknown: 1000,
          coverage: 0,
          species: unknownPanel,
          reasons: const ['pollen_not_configured'],
          source: {
            'available': false,
            'provider': 'Open-Meteo',
            'model': 'cams_europe',
            'license': 'CC-BY-4.0',
            'attribution': 'Pollen data by Open-Meteo.com; CAMS ENSEMBLE model',
            'reason': 'pollen_not_configured',
          },
        ),
      ),
    ).service;
    final analysis = await service.analyzeWalk(
      departure: _departure,
      legs: [_leg()],
    );
    expect(analysis.status, PollenStatus.unavailable);
    expect(analysis.hasEstimate, isFalse);
    expect(analysis.knownMeters, 0);
    expect(analysis.reasons, contains('pollen_not_configured'));
    // The gap is shown as a gap, never as clean air.
    expect(analysis.speciesWithValues, isEmpty);
  });
}
