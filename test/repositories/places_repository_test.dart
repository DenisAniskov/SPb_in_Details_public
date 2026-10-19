import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/core/network/ui_error.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';

class FixtureAdapter implements HttpClientAdapter {
  final dynamic Function(RequestOptions) respond;
  RequestOptions? lastRequest;
  FixtureAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      jsonEncode(respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const fixturePlace = {
  'id': 6,
  'title': 'Русский музей',
  'short_description': 'Музей искусства',
  'category': 'art',
  'is_unusual': false,
  'latitude': 59.93858,
  'longitude': 30.33072,
  'address': 'Инженерная улица, 4',
  'rating': null,
};

void main() {
  test('known catalog corruption has a data error message rather than a network claim', () {
    final message = placesUiError(
      const FormatException('synthetic malformed page'),
    );
    expect(message, contains('некорректный каталог'));
    expect(message, isNot(contains('соединение')));
    expect(message, isNot(contains('сеть')));
    expect(message, isNot(contains('synthetic malformed page')));
    expect(
      placesUiError(
        DioException(
          requestOptions: RequestOptions(path: '/synthetic'),
          type: DioExceptionType.unknown,
          error: const FormatException('synthetic JSON decode'),
        ),
      ),
      message,
    );
  });
  List<Map<String, dynamic>> syntheticCatalog(int count) => List.generate(
    count,
    (i) => {
      ...fixturePlace,
      'id': 1000 + i * 3,
      'title': i == count - 1
          ? 'Synthetic user record'
          : 'Synthetic catalog place $i',
    },
  );

  ({PlacesRepository repository, ApiClient client}) repositoryFor(
    FixtureAdapter adapter,
  ) {
    final client = ApiClient(customBaseUrl: 'http://synthetic.test/api/v1');
    client.dio.httpClientAdapter = adapter;
    addTearDown(() => client.dio.close(force: true));
    return (repository: PlacesRepository(apiClient: client), client: client);
  }

  test('126 catalog records all load using explicit limit 200 rather than the API default 100', () async {
    final catalog = syntheticCatalog(126);
    var requests = 0;
    final adapter = FixtureAdapter((options) {
      ++requests;
      expect(options.queryParameters['limit'], 200);
      expect(options.queryParameters['offset'], 0);
      return {'total': catalog.length, 'items': catalog};
    });
    final backend = repositoryFor(adapter);
    final places = await backend.repository.getPlaces();
    expect(requests, 1);
    expect(places.map((p) => p.id), catalog.map((p) => p['id']));
    expect(places, hasLength(126));
  });

  test('225 records including user rows paginate completely with unchanged filters and ordered IDs', () async {
    final catalog = syntheticCatalog(225);
    final offsets = <int>[];
    final categories = [PlaceCategoryEnum.art, PlaceCategoryEnum.nature];
    final adapter = FixtureAdapter((options) {
      expect(options.uri.queryParametersAll['category'], ['art', 'nature']);
      expect(options.uri.queryParameters['is_unusual'], 'true');
      expect(options.uri.queryParameters['q'], 'музей');
      expect(options.queryParameters['limit'], 200);
      final offset = options.queryParameters['offset'] as int;
      offsets.add(offset);
      categories
          .clear(); // The caller cannot change an in-flight load's filters.
      return {
        'total': catalog.length,
        'items': catalog.skip(offset).take(200).toList(),
      };
    });
    final backend = repositoryFor(adapter);
    final places = await backend.repository.getPlaces(
      categories: categories,
      isUnusual: true,
      searchQuery: ' музей ',
    );
    expect(offsets, [0, 200]);
    expect(places.map((p) => p.id), catalog.map((p) => p['id']));
    expect(places.last.title, 'Synthetic user record');
    expect(places.length, 225);
  });

  test('an empty complete catalog is a valid single-page response', () async {
    var requests = 0;
    final backend = repositoryFor(
      FixtureAdapter((_) {
        ++requests;
        return {'total': 0, 'items': []};
      }),
    );
    expect(await backend.repository.getPlaces(), isEmpty);
    expect(requests, 1);
  });

  for (final corruption in [
    'duplicate',
    'empty',
    'changed total',
    'malformed',
  ]) {
    test(
      '$corruption second page rejects the whole load without returning 200 partial records',
      () async {
        final catalog = syntheticCatalog(225);
        var requests = 0;
        final backend = repositoryFor(
          FixtureAdapter((options) {
            ++requests;
            if (options.queryParameters['offset'] == 0) {
              return {'total': 225, 'items': catalog.take(200).toList()};
            }
            return switch (corruption) {
              'duplicate' => {
                'total': 225,
                'items': [catalog.first, ...catalog.skip(201)],
              },
              'empty' => {'total': 225, 'items': []},
              'changed total' => {
                'total': 226,
                'items': catalog.skip(200).toList(),
              },
              _ => {
                'total': 225,
                'items': ['malformed place'],
              },
            };
          }),
        );
        await expectLater(
          backend.repository.getPlaces(),
          throwsFormatException,
        );
        expect(requests, 2);
      },
    );
  }

  for (final malformed in <Map<String, dynamic>>[
    {'items': []},
    {
      'total': 1.0,
      'items': [fixturePlace],
    },
    {'total': -1, 'items': []},
    {'total': 1, 'items': 'invalid'},
  ]) {
    test(
      'malformed page envelope $malformed is rejected immediately',
      () async {
        var requests = 0;
        final backend = repositoryFor(
          FixtureAdapter((_) {
            ++requests;
            return malformed;
          }),
        );
        await expectLater(
          backend.repository.getPlaces(),
          throwsFormatException,
        );
        expect(requests, 1);
      },
    );
  }

  test('advertised catalog beyond the explicit cap fails rather than silently truncating', () async {
    var requests = 0;
    final backend = repositoryFor(
      FixtureAdapter((_) {
        ++requests;
        return {'total': PlacesRepository.maxLoadedPlaces + 1, 'items': []};
      }),
    );
    await expectLater(backend.repository.getPlaces(), throwsFormatException);
    expect(requests, 1);
  });

  test('short progressing pages respect the request cap and never publish an incomplete catalog', () async {
    final offsets = <int>[];
    final backend = repositoryFor(
      FixtureAdapter((options) {
        final offset = options.queryParameters['offset'] as int;
        offsets.add(offset);
        return {
          'total': PlacesRepository.maxPlacesPages + 1,
          'items': [
            {...fixturePlace, 'id': offset + 1},
          ],
        };
      }),
    );
    await expectLater(backend.repository.getPlaces(), throwsFormatException);
    expect(offsets, List.generate(PlacesRepository.maxPlacesPages, (i) => i));
  });

  test(
    'mid-pagination network failure publishes no partial map catalog',
    () async {
      final catalog = syntheticCatalog(225);
      var catalogRequests = 0;
      final backend = repositoryFor(
        FixtureAdapter((options) {
          if (options.uri.path.endsWith('/categories')) return [];
          ++catalogRequests;
          if (options.queryParameters['offset'] == 0) {
            return {'total': 225, 'items': catalog.take(200).toList()};
          }
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          );
        }),
      );
      final provider = PlacesProvider(repository: backend.repository);
      addTearDown(provider.dispose);
      final failed = Completer<void>();
      provider.addListener(() {
        if (provider.status == PlacesStatus.error && !failed.isCompleted) {
          failed.complete();
        }
      });
      await failed.future;
      expect(catalogRequests, 2);
      expect(provider.status, PlacesStatus.error);
      expect(provider.places, isEmpty);
      expect(provider.selectedPlace, isNull);
      expect(provider.isEmpty, isFalse);
    },
  );

  test(
    'API filters use repeated category parameters and preserve response IDs',
    () async {
      final adapter = FixtureAdapter(
        (_) => {
          'total': 1,
          'items': [fixturePlace],
        },
      );
      final client = ApiClient(customBaseUrl: 'http://10.0.2.2:8000/api/v1');
      client.dio.httpClientAdapter = adapter;
      final places = await PlacesRepository(apiClient: client).getPlaces(
        categories: [PlaceCategoryEnum.art, PlaceCategoryEnum.nature],
        isUnusual: true,
        searchQuery: ' музей ',
      );
      expect(places.single.id, 6);
      expect(places.single.rating, isNull);
      expect(adapter.lastRequest!.uri.path, '/api/v1/places');
      expect(adapter.lastRequest!.uri.queryParametersAll['category'], [
        'art',
        'nature',
      ]);
      expect(adapter.lastRequest!.uri.queryParameters['q'], 'музей');
      expect(adapter.lastRequest!.uri.queryParameters['is_unusual'], 'true');
    },
  );

  test('detail endpoint supplies full description', () async {
    final adapter = FixtureAdapter(
      (_) => {...fixturePlace, 'full_description': 'Данные detail API'},
    );
    final client = ApiClient(customBaseUrl: 'http://test/api/v1');
    client.dio.httpClientAdapter = adapter;
    final place = await PlacesRepository(apiClient: client).getPlaceDetail(6);
    expect(adapter.lastRequest!.uri.path, '/api/v1/places/6');
    expect(place!.fullDescription, 'Данные detail API');
  });

  test(
    'network failure remains an error and never substitutes a second catalogue',
    () async {
      final client = ApiClient(customBaseUrl: 'http://test/api/v1');
      client.dio.httpClientAdapter = FixtureAdapter(
        (options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ),
      );
      expect(
        PlacesRepository(apiClient: client).getPlaces(),
        throwsA(isA<DioException>()),
      );
    },
  );

  test('unknown category is rejected instead of silently becoming history', () {
    expect(
      () => PlaceModel.fromJson({...fixturePlace, 'category': 'unknown'}),
      throwsStateError,
    );
  });
}
