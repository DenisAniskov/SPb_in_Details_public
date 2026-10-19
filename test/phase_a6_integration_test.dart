import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_navigator_spb/core/constants/api_constants.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/data/repositories/search_repository.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';

// --------------------------------------------------------------------------
// Phase A6 tests: one configured backend for every caller, the shade request
// contract (no silent truncation), its dedicated timeout and the search error
// mapping. Everything is offline: Dio talks to a recording adapter and MapKit
// is a fake, so no Railway request and no Yandex quota are spent.
// --------------------------------------------------------------------------

const String _railwayHost =
    'steadfast-curiosity-production-f250.up.railway.app';
const String _railwayBaseUrl = 'https://$_railwayHost/api/v1';

const GeoCoord _a = GeoCoord(59.9400, 30.3150);
const GeoCoord _b = GeoCoord(59.9410, 30.3160);
const GeoCoord _c = GeoCoord(59.9420, 30.3170);

/// An alternative middle vertex: real geometry for the same leg ends.
const GeoCoord _variantMid = GeoCoord(59.9405, 30.3195);

final DateTime _departure = DateTime(2026, 7, 1, 14, 30);

/// A real backend response (committed pilot fixture), so the client is locked
/// to the server's actual output instead of a hand-written example.
final Map<String, dynamic> _shadeResponse = () {
  final document = jsonDecode(
    File('test/fixtures/c7_1_1_shade_response.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  return document['response'] as Map<String, dynamic>;
}();

RouteLegModel _leg({
  List<GeoCoord>? points,
  int seconds = 600,
  int? visitMinutes,
}) => RouteLegModel(
  fromTitle: 'Старт',
  toTitle: 'POI 1',
  distanceMeters: 800,
  durationSeconds: seconds,
  geometryPoints: points ?? const [_a, _b, _c],
  visitMinutes: visitMinutes,
);

PedestrianRouteModel _route({List<RouteLegModel>? legs}) {
  final routeLegs = legs ?? [_leg()];
  return PedestrianRouteModel(
    distanceMeters: routeLegs.fold(0.0, (sum, leg) => sum + leg.distanceMeters),
    durationSeconds: routeLegs.fold(0, (sum, leg) => sum + leg.durationSeconds),
    geometryPoints: [for (final leg in routeLegs) ...leg.geometryPoints],
    steps: const [],
    legs: routeLegs,
    placesCount: routeLegs.length,
  );
}

/// [count] distinct points along a short northbound line (~1.1 m apart); the
/// walk stays far below 25 km while the point count is what the test varies.
List<GeoCoord> _linePoints(int count) => [
  for (var i = 0; i < count; ++i) GeoCoord(59.9400 + i * 0.00001, 30.3150),
];

ShadeAnalysisModel _analysis({double shaded = 300, double exposed = 700}) {
  final total = shaded + exposed;
  return ShadeAnalysisModel(
    status: ShadeStatus.available,
    method: 'test',
    methodVersion: 'test',
    periodStart: _departure,
    periodEnd: _departure.add(const Duration(hours: 1)),
    timezoneName: 'MSK',
    datasetVersion: 'c7_1_pilot_v1',
    datasetProvenance: 'OpenStreetMap (ODbL).',
    solar: const ShadeSolarSummaryModel(
      minElevationDeg: 40,
      maxElevationDeg: 52,
      minAzimuthDeg: 180,
      maxAzimuthDeg: 220,
      bucketCount: 2,
    ),
    routeLengthMeters: total,
    shadedMeters: shaded,
    exposedMeters: exposed,
    unknownMeters: 0,
    shadeFraction: shaded / total,
    confidence: ShadeConfidence.medium,
    limitations: const ['Тестовое ограничение модели.'],
    segments: const [],
    reason: null,
    datasetZonesTouched: const ['centre_palace'],
    outsideCoverageMeters: 0,
    coverageShare: 1,
    heightProvenance: const ShadeHeightProvenanceModel(),
  );
}

ShadeAnalysisFailure _tooDetailed() => const ShadeAnalysisFailure(
  ShadeAnalysisFailureKind.requestRejected,
  shadeRouteTooDetailedMessage,
);

Matcher _rejection(String message, ShadeAnalysisFailureKind kind) =>
    isA<ShadeAnalysisFailure>()
        .having((failure) => failure.kind, 'failure kind', kind)
        .having((failure) => failure.message, 'user message', message);

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

/// Records what the shade backend would have been asked for, and can fail the
/// next call with a typed failure like the real service does.
class _SpyShadeService implements BaseShadeAnalysisService {
  _SpyShadeService({this.analysis});

  ShadeAnalysisModel? analysis;
  Object? failure;
  int calls = 0;
  final List<List<RouteLegModel>> receivedLegs = [];
  final List<DateTime> departures = [];

  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async {
    calls++;
    departures.add(departure);
    receivedLegs.add(List.of(legs));
    final thrown = failure;
    if (thrown != null) throw thrown;
    return analysis ?? _analysis();
  }
}

/// A MapKit routing stack that returns one real alternative for the leg.
class _AlternativesMapKit extends MapKitService {
  _AlternativesMapKit(this.original, this.alternative);

  final RouteLegModel original;
  final RouteLegModel alternative;
  int variantRequests = 0;

  @override
  Future<List<RouteLegModel>> requestLegVariants({
    required double fromLat,
    required double fromLon,
    required String fromTitle,
    required double toLat,
    required double toLon,
    required String toTitle,
    NativeWalkRequestBudget? requestBudget,
    int legIndex = 0,
    int? visitMinutes,
    int maxVariants = 2,
  }) async {
    variantRequests++;
    return [original, alternative];
  }
}

void main() {
  group('A6.2 единый настроенный ApiClient', () {
    test('the shade service posts to the configured backend host', () async {
      final client = ApiClient(customBaseUrl: _railwayBaseUrl);
      final adapter = _ScriptedAdapter((_) => _json(_shadeResponse));
      client.dio.httpClientAdapter = adapter;
      final service = BackendShadeAnalysisService(apiClient: client);

      final analysis = await service.analyzeWalk(
        departure: _departure,
        legs: [_leg()],
      );

      expect(analysis.status, ShadeStatus.available);
      expect(adapter.lastRequest.uri.host, _railwayHost);
      expect(adapter.lastRequest.uri.path, '/api/v1/environment/shade/analyze');
      expect(
        adapter.lastRequest.uri.toString(),
        isNot(contains('10.0.2.2')),
        reason: 'оценка тени не обращается к локальному backend',
      );
      // A6.5: the dedicated budget travels with this request only.
      expect(
        adapter.lastRequest.receiveTimeout,
        const Duration(milliseconds: 15000),
      );
      final sent = adapter.lastBody;
      expect((sent['legs'] as List).single['geometry'], hasLength(3));
    });

    test(
      'the provider and its engine analyse through one service instance',
      () async {
        final mapKit = _AlternativesMapKit(
          _leg(),
          _leg(points: const [_a, _variantMid, _c]),
        );
        final shade = _SpyShadeService(analysis: _analysis());
        MapKitService.isMapKitInitialized = true;
        addTearDown(() => MapKitService.isMapKitInitialized = false);

        final routing =
            RoutingProvider(mapKitService: mapKit, shadeAnalysisService: shade)
              ..setProposedWalkForScenicTest(
                scenic: false,
                comparison: null,
                walkKind: WalkKind.normal,
                route: _route(),
              );
        addTearDown(routing.dispose);

        await routing.assessShade(
          departure: _departure,
          exploreAlternatives: true,
        );

        expect(
          mapKit.variantRequests,
          1,
          reason: 'альтернатива запрошена нативно',
        );
        expect(
          shade.calls,
          2,
          reason:
              'обычный маршрут и альтернатива оценены одним и тем же сервисом; '
              'второй, самостоятельно созданный сервис сюда бы не попал',
        );
        expect(
          shade.receivedLegs[1].single.geometryPoints[1].latitude,
          _variantMid.latitude,
          reason: 'движок оценивал реальную геометрию варианта MapKit',
        );
        expect(routing.shadeAnalysis, isNotNull);
        expect(routing.shadeDecision, isNotNull);
        expect(routing.currentRoute, isNotNull);
      },
    );
  });

  group('A6.3 лимиты запроса оценки тени', () {
    test(
      'every point of an acceptable walk is sent — nothing is truncated',
      () {
        final points = _linePoints(300);
        final payload = buildShadeAnalyzePayload(
          departure: _departure,
          legs: [_leg(points: points)],
        );
        final geometry = (payload['legs'] as List).single['geometry'] as List;
        expect(geometry, hasLength(points.length));
        expect((geometry.first as Map)['latitude'], points.first.latitude);
        expect((geometry.last as Map)['latitude'], points.last.latitude);
      },
    );

    test('2000 points on the boundary are accepted whole', () {
      // The byte cap is lifted for this check on purpose: it proves the point
      // limits are enforced independently and that the refusal of a real
      // 2000-point walk comes from the backend's documented 16 KB body cap.
      final points = _linePoints(2000);
      final payload = buildShadeAnalyzePayload(
        departure: _departure,
        legs: [_leg(points: points)],
        maxRequestBytes: 1 << 20,
      );
      expect((payload['legs'] as List).single['geometry'], hasLength(2000));
    });

    test('2001 points in one leg are refused, never shortened', () {
      expect(
        () => buildShadeAnalyzePayload(
          departure: _departure,
          legs: [_leg(points: _linePoints(2001))],
        ),
        throwsA(
          _rejection(
            shadeRouteTooDetailedMessage,
            ShadeAnalysisFailureKind.requestRejected,
          ),
        ),
      );
    });

    test('the total point budget refuses a walk of many big legs', () {
      // 3 × 1900 = 5700 points: each leg is inside its own limit, the walk is
      // not. A shortened geometry would describe a walk nobody takes.
      final legs = List.generate(3, (_) => _leg(points: _linePoints(1900)));
      expect(
        () => buildShadeAnalyzePayload(departure: _departure, legs: legs),
        throwsA(
          _rejection(
            shadeRouteTooDetailedMessage,
            ShadeAnalysisFailureKind.requestRejected,
          ),
        ),
      );
    });

    test(
      'an oversized body is refused before the request leaves the app',
      () async {
        // 1900 points are legal per leg and below the total cap, yet their JSON
        // is far larger than REQUEST_MAX_BYTES — the refusal is local.
        final client = ApiClient(customBaseUrl: _railwayBaseUrl);
        final adapter = _ScriptedAdapter((_) => _json(_shadeResponse));
        client.dio.httpClientAdapter = adapter;
        final service = BackendShadeAnalysisService(apiClient: client);

        await expectLater(
          service.analyzeWalk(
            departure: _departure,
            legs: [_leg(points: _linePoints(1900))],
          ),
          throwsA(
            _rejection(
              shadeRouteTooDetailedMessage,
              ShadeAnalysisFailureKind.requestRejected,
            ),
          ),
        );
        expect(
          adapter.requests,
          isEmpty,
          reason:
              'отказ произошёл до отправки: сервер не увидел усечённый маршрут',
        );
      },
    );

    test('the encoded size of an accepted walk fits the backend cap', () {
      final payload = buildShadeAnalyzePayload(
        departure: _departure,
        legs: [_leg(points: _linePoints(300))],
      );
      expect(
        utf8.encode(jsonEncode(payload)).length,
        lessThan(ApiConstants.shadeMaxRequestBytes),
      );
    });

    test('too many legs are refused', () {
      final legs = List.generate(25, (_) => _leg());
      expect(
        () => buildShadeAnalyzePayload(departure: _departure, legs: legs),
        throwsA(
          _rejection(
            'Слишком много этапов для одного расчёта тени.',
            ShadeAnalysisFailureKind.requestRejected,
          ),
        ),
      );
    });

    test('a leg with fewer than two points is refused', () {
      expect(
        () => buildShadeAnalyzePayload(
          departure: _departure,
          legs: [
            _leg(points: const [_a]),
          ],
        ),
        throwsA(
          _rejection(
            'Этап 1: для оценки тени нужны минимум две точки.',
            ShadeAnalysisFailureKind.requestRejected,
          ),
        ),
      );
    });

    test('invalid coordinates are refused', () {
      for (final bad in [
        const GeoCoord(double.nan, 30.3150),
        const GeoCoord(59.9400, double.infinity),
        const GeoCoord(95.0, 30.3150),
        const GeoCoord(59.9400, 200.0),
      ]) {
        expect(
          () => buildShadeAnalyzePayload(
            departure: _departure,
            legs: [
              _leg(points: [_a, bad, _c]),
            ],
          ),
          throwsA(isA<ShadeAnalysisFailure>()),
          reason: 'координата $bad не должна попасть в запрос',
        );
      }
    });

    test('an impossible walking duration or visit time is refused', () {
      expect(
        () => buildShadeAnalyzePayload(
          departure: _departure,
          legs: [_leg(seconds: 0)],
        ),
        throwsA(isA<ShadeAnalysisFailure>()),
      );
      expect(
        () => buildShadeAnalyzePayload(
          departure: _departure,
          legs: [_leg(seconds: 6 * 3600 + 1)],
        ),
        throwsA(isA<ShadeAnalysisFailure>()),
      );
      expect(
        () => buildShadeAnalyzePayload(
          departure: _departure,
          legs: [_leg()],
          visitMinutesAfterLeg: const [-1],
        ),
        throwsA(isA<ShadeAnalysisFailure>()),
      );
      expect(
        () => buildShadeAnalyzePayload(
          departure: _departure,
          legs: [_leg()],
          visitMinutesAfterLeg: const [24 * 60 + 1],
        ),
        throwsA(isA<ShadeAnalysisFailure>()),
      );
    });

    test('a walk longer than 25 km is refused', () {
      expect(
        () => buildShadeAnalyzePayload(
          departure: _departure,
          legs: [
            _leg(
              points: const [
                GeoCoord(59.9000, 30.3000),
                GeoCoord(60.1500, 30.3000),
              ],
            ),
          ],
        ),
        throwsA(isA<ShadeAnalysisFailure>()),
      );
    });

    test('the departure instant keeps its UTC offset', () {
      final payload = buildShadeAnalyzePayload(
        departure: _departure,
        legs: [_leg()],
      );
      expect(payload['departure_at'], iso8601WithOffset(_departure));
      expect(
        payload['departure_at'] as String,
        matches(RegExp(r'[+-]\d{2}:\d{2}$')),
      );
    });

    test('a too-detailed walk keeps the route and normal navigation', () async {
      final shade = _SpyShadeService()..failure = _tooDetailed();
      final routing = RoutingProvider(shadeAnalysisService: shade)
        ..setProposedWalkForScenicTest(
          scenic: false,
          comparison: null,
          walkKind: WalkKind.normal,
          route: _route(),
        );
      addTearDown(routing.dispose);

      await routing.assessShade(departure: _departure);

      expect(
        routing.shadeFailure?.kind,
        ShadeAnalysisFailureKind.requestRejected,
      );
      expect(routing.shadeFailure?.message, shadeRouteTooDetailedMessage);
      expect(
        routing.shadeAnalysis,
        isNull,
        reason: 'проценты тени по неполной геометрии не показываются',
      );
      expect(routing.shadeOverlayEnabled, isFalse);
      expect(routing.currentRoute, isNotNull, reason: 'маршрут сохранён');
      expect(routing.status.name, 'success');
      expect(routing.isAssessingShade, isFalse);
    });
  });

  group('A6.5 отдельный таймаут оценки тени', () {
    test('the global timeouts stay untouched', () {
      expect(ApiConstants.receiveTimeoutMs, 8000);
      expect(ApiConstants.connectTimeoutMs, 8000);
      expect(ApiConstants.shadeReceiveTimeoutMs, 15000);
      final client = ApiClient(customBaseUrl: _railwayBaseUrl);
      expect(
        client.dio.options.receiveTimeout,
        const Duration(milliseconds: ApiConstants.receiveTimeoutMs),
      );
    });

    for (final type in [
      DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.connectionTimeout,
    ]) {
      test('${type.name} becomes the documented shade message', () async {
        final client = ApiClient(customBaseUrl: _railwayBaseUrl);
        client.dio.httpClientAdapter = _ScriptedAdapter(
          (options) => throw DioException(requestOptions: options, type: type),
        );
        final service = BackendShadeAnalysisService(apiClient: client);

        await expectLater(
          service.analyzeWalk(departure: _departure, legs: [_leg()]),
          throwsA(
            _rejection(
              'Сервис оценки тени не ответил вовремя. '
              'Обычный маршрут продолжает работать.',
              ShadeAnalysisFailureKind.serviceUnavailable,
            ),
          ),
        );
      });
    }

    for (final entry in {
      413: shadeRouteTooDetailedMessage,
      422: 'Запрос оценки тени отклонён сервисом.',
      404: 'Запрос оценки тени отклонён сервисом.',
    }.entries) {
      test('HTTP ${entry.key} is reported as a rejection', () async {
        final client = ApiClient(customBaseUrl: _railwayBaseUrl);
        client.dio.httpClientAdapter = _ScriptedAdapter(
          (_) => _json({'detail': 'synthetic rejection'}, status: entry.key),
        );
        final service = BackendShadeAnalysisService(apiClient: client);

        await expectLater(
          service.analyzeWalk(departure: _departure, legs: [_leg()]),
          throwsA(
            _rejection(entry.value, ShadeAnalysisFailureKind.requestRejected),
          ),
        );
      });
    }

    for (final status in [500, 502, 503, 504]) {
      test('HTTP $status is reported as a service problem', () async {
        final client = ApiClient(customBaseUrl: _railwayBaseUrl);
        client.dio.httpClientAdapter = _ScriptedAdapter(
          (_) => _json({'detail': 'synthetic outage'}, status: status),
        );
        final service = BackendShadeAnalysisService(apiClient: client);

        await expectLater(
          service.analyzeWalk(departure: _departure, legs: [_leg()]),
          throwsA(
            _rejection(
              'Сервис оценки тени недоступен. '
              'Обычный маршрут продолжает работать.',
              ShadeAnalysisFailureKind.serviceUnavailable,
            ),
          ),
        );
      });
    }

    test('an offline connection is reported as a service problem', () async {
      final client = ApiClient(customBaseUrl: _railwayBaseUrl);
      client.dio.httpClientAdapter = _ScriptedAdapter(
        (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ),
      );
      final service = BackendShadeAnalysisService(apiClient: client);

      await expectLater(
        service.analyzeWalk(departure: _departure, legs: [_leg()]),
        throwsA(
          isA<ShadeAnalysisFailure>().having(
            (failure) => failure.kind,
            'failure kind',
            ShadeAnalysisFailureKind.serviceUnavailable,
          ),
        ),
      );
    });

    for (final body in [
      <String, dynamic>{},
      {'status': 'available'},
    ]) {
      test('a partial JSON payload is never turned into an estimate', () async {
        final client = ApiClient(customBaseUrl: _railwayBaseUrl);
        client.dio.httpClientAdapter = _ScriptedAdapter((_) => _json(body));
        final service = BackendShadeAnalysisService(apiClient: client);

        await expectLater(
          service.analyzeWalk(departure: _departure, legs: [_leg()]),
          throwsA(
            _rejection(
              'Сервис оценки тени вернул неожиданный ответ.',
              ShadeAnalysisFailureKind.invalidResponse,
            ),
          ),
        );
      });
    }
  });

  group('A6.4 поиск через серверный Geosuggest', () {
    ({SearchRepository repository, _ScriptedAdapter adapter}) searchBackend(
      Object Function(RequestOptions options) respond,
    ) {
      final client = ApiClient(customBaseUrl: _railwayBaseUrl);
      final adapter = _ScriptedAdapter((options) => _json(respond(options)));
      client.dio.httpClientAdapter = adapter;
      return (
        repository: SearchRepository(apiClient: client),
        adapter: adapter,
      );
    }

    test('suggest JSON becomes models and keeps the uri untouched', () async {
      final backend = searchBackend(
        (_) => {
          'results': [
            {
              'title': 'Невский проспект',
              'subtitle': 'Санкт-Петербург, Россия',
              'tags': ['улица'],
              'uri': 'ymapsbm1://geo?ll=30.315%2C59.940&text=Невский',
              'distance_text': '1,2 км',
            },
            {'title': 'Невский проспект, 1'},
          ],
        },
      );

      final results = await backend.repository.getSuggestions(
        'Невский',
        limit: 3,
      );

      expect(backend.adapter.lastRequest.uri.host, _railwayHost);
      expect(backend.adapter.lastRequest.uri.path, '/api/v1/search/suggest');
      expect(backend.adapter.lastRequest.queryParameters, {
        'text': 'Невский',
        'results': 3,
      });
      expect(results, hasLength(2));
      expect(results.first.title, 'Невский проспект');
      expect(results.first.subtitle, 'Санкт-Петербург, Россия');
      expect(results.first.tags, ['улица']);
      expect(
        results.first.uri,
        'ymapsbm1://geo?ll=30.315%2C59.940&text=Невский',
        reason: 'uri передаётся без искажений: по нему идёт геокодирование',
      );
      expect(results.first.distanceText, '1,2 км');
      expect(results.last.uri, isNull);
    });

    test('the chosen suggestion is geocoded by that same uri', () async {
      final backend = searchBackend(
        (_) => {
          'title': 'Невский проспект, 1',
          'subtitle': 'Санкт-Петербург',
          'latitude': 59.9386,
          'longitude': 30.3141,
          'uri': 'ymapsbm1://geo?ll=30.315%2C59.940',
        },
      );

      const uri = 'ymapsbm1://geo?ll=30.315%2C59.940';
      final point = await backend.repository.resolveGeocode(uri: uri);

      expect(backend.adapter.lastRequest.uri.path, '/api/v1/search/geocode');
      expect(backend.adapter.lastRequest.queryParameters, {'uri': uri});
      expect(point.latitude, closeTo(59.9386, 1e-9));
      expect(point.longitude, closeTo(30.3141, 1e-9));
    });

    test('429 is reported as a rate limit', () async {
      final client = ApiClient(customBaseUrl: _railwayBaseUrl);
      client.dio.httpClientAdapter = _ScriptedAdapter(
        (_) => _json({'detail': 'synthetic quota'}, status: 429),
      );
      final provider = SearchProvider(
        repository: SearchRepository(apiClient: client),
      );
      addTearDown(provider.dispose);

      provider.setSearchQuery('Невский');
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        provider.errorMessage,
        'Превышен лимит запросов поиска. Повторите попытку через минуту.',
      );
      expect(provider.suggestResults, isEmpty);
      expect(provider.isLoadingSuggest, isFalse);
    });

    test('a search timeout is reported honestly', () async {
      final client = ApiClient(customBaseUrl: _railwayBaseUrl);
      client.dio.httpClientAdapter = _ScriptedAdapter(
        (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        ),
      );
      final provider = SearchProvider(
        repository: SearchRepository(apiClient: client),
      );
      addTearDown(provider.dispose);

      provider.setSearchQuery('Невский');
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        provider.errorMessage,
        'Время ожидания ответа от сервиса поиска истекло.',
      );
    });

    test('a connection error is reported as a network problem', () async {
      final client = ApiClient(customBaseUrl: _railwayBaseUrl);
      client.dio.httpClientAdapter = _ScriptedAdapter(
        (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ),
      );
      final provider = SearchProvider(
        repository: SearchRepository(apiClient: client),
      );
      addTearDown(provider.dispose);

      provider.setSearchQuery('Невский');
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        provider.errorMessage,
        'Нет связи с сервером поиска. Проверьте сеть.',
      );
    });

    test('a broken search never denies the catalog', () async {
      // One client, two callers: the search endpoint fails while the catalog
      // is served normally — exactly the staging outage this phase guards.
      final client = ApiClient(customBaseUrl: _railwayBaseUrl);
      client.dio.httpClientAdapter = _ScriptedAdapter((options) {
        if (options.uri.path.endsWith('/search/suggest')) {
          return _json({'detail': 'synthetic outage'}, status: 503);
        }
        if (options.uri.path.endsWith('/places')) {
          return _json({
            'total': 1,
            'items': [
              {
                'id': 6,
                'title': 'Русский музей',
                'short_description': 'Музей искусства',
                'category': 'art',
                'is_unusual': false,
                'latitude': 59.93858,
                'longitude': 30.33072,
                'address': 'Инженерная улица, 4',
                'rating': null,
              },
            ],
          });
        }
        return _json({'detail': 'unexpected synthetic path'}, status: 404);
      });
      final search = SearchProvider(
        repository: SearchRepository(apiClient: client),
      );
      addTearDown(search.dispose);

      search.setSearchQuery('Невский');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(search.errorMessage, 'Сервис поиска временно недоступен.');

      final places = PlacesProvider(
        repository: PlacesRepository(apiClient: client),
      );
      await places.loadPlaces();
      expect(places.places, hasLength(1));
      expect(places.errorMessage, isNull);
    });
  });
}
