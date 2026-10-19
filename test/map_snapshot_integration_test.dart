import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/suggest_item_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/data/repositories/search_repository.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';

import 'repositories/places_repository_test.dart'
    show FixtureAdapter, fixturePlace;

class _MutableCatalog extends PlacesRepository {
  final items = [PlaceModel.fromJson(fixturePlace)];

  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async => items;

  @override
  Future<List<CategoryModel>> getCategories() async => [];
}

class _MutableRoutes extends MapKitService {
  final geometry = [const GeoCoord(59.93, 30.31), const GeoCoord(59.94, 30.32)];
  final steps = <RouteStepModel>[];
  late final legs = [
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'Место',
      distanceMeters: 100,
      durationSeconds: 80,
      geometryPoints: geometry,
    ),
  ];

  PedestrianRouteModel result(int count) => PedestrianRouteModel(
    distanceMeters: 100,
    durationSeconds: 80,
    geometryPoints: geometry,
    steps: steps,
    legs: legs,
    placesCount: count,
  );

  @override
  void cancel() {}

  @override
  Future<PedestrianRouteModel> calculatePedestrianRoute({
    required RoutePointModel startPoint,
    required PlaceModel destination,
  }) async => result(1);

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async => result(1);

  @override
  Future<PedestrianRouteModel> calculateWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
  }) async => result(places.length);
}

class _PendingSearch extends SearchRepository {
  final suggestion = Completer<List<SuggestItemModel>>();
  final resolution = Completer<ExternalMapPoint>();

  @override
  Future<List<SuggestItemModel>> getSuggestions(
    String query, {
    int limit = 7,
  }) => suggestion.future;

  @override
  Future<ExternalMapPoint> resolveGeocode({String? text, String? uri}) =>
      resolution.future;
}

void main() {
  test(
    'catalog map snapshots reject mutation and isolate repository aliases',
    () async {
      final repository = _MutableCatalog();
      final places = PlacesProvider(repository: repository);
      addTearDown(places.dispose);
      await Future<void>.delayed(Duration.zero);
      final snapshot = places.places;
      expect(snapshot, hasLength(1));
      expect(places.places, same(snapshot));
      expect(() => snapshot.clear(), throwsUnsupportedError);
      repository.items.clear();
      expect(snapshot, hasLength(1));
      await places.loadPlaces();
      expect(places.places, isEmpty);
      expect(places.places, isNot(same(snapshot)));
      expect(snapshot, hasLength(1));
    },
  );

  for (final kind in ['catalog', 'external', 'walk']) {
    test('$kind route map snapshot freezes every nested collection', () async {
      final service = _MutableRoutes();
      final routing = RoutingProvider(mapKitService: service);
      addTearDown(routing.dispose);
      final place = PlaceModel.fromJson(fixturePlace);
      if (kind == 'catalog') {
        await routing.buildRouteTo(place);
      } else if (kind == 'external') {
        await routing.buildRouteToExternalPoint(
          const ExternalMapPoint(
            title: 'Внешний адрес',
            latitude: 59.94,
            longitude: 30.32,
          ),
        );
      } else {
        routing.addPlaceToWalk(place);
        await routing.buildWalkRoute();
      }
      final snapshot = routing.currentRoute!;
      expect(routing.currentRoute, same(snapshot));
      expect(() => snapshot.geometryPoints.clear(), throwsUnsupportedError);
      expect(() => snapshot.legs.clear(), throwsUnsupportedError);
      expect(
        () => snapshot.legs.single.geometryPoints.clear(),
        throwsUnsupportedError,
      );
      expect(() => snapshot.steps.clear(), throwsUnsupportedError);
      service.geometry.clear();
      service.legs.clear();
      service.steps.add(
        const RouteStepModel(
          instruction: 'Поздно',
          distanceMeters: 1,
          durationSeconds: 1,
        ),
      );
      expect(snapshot.geometryPoints, hasLength(2));
      expect(snapshot.legs, hasLength(1));
      expect(snapshot.steps, isEmpty);
      expect(routePolylineGeometries(snapshot).single, hasLength(2));
    });
  }

  test(
    'unsupported category produces controlled load failure and can recover',
    () async {
      var category = 'unknown';
      final client = ApiClient(customBaseUrl: 'http://test/api/v1');
      client.dio.httpClientAdapter = FixtureAdapter(
        (request) => request.uri.path.endsWith('/categories')
            ? []
            : {
                'items': [
                  {...fixturePlace, 'category': category},
                ],
                'total': 1,
              },
      );
      final places = PlacesProvider(
        repository: PlacesRepository(apiClient: client),
      );
      addTearDown(places.dispose);
      await places.loadPlaces();
      expect(places.status, PlacesStatus.error);
      expect(places.places, isEmpty);
      expect(places.errorMessage, isNot(contains('StateError')));
      category = 'art';
      await places.loadPlaces();
      expect(places.status, PlacesStatus.success);
      expect(places.places.single.category, PlaceCategoryEnum.art);
      expect(places.errorMessage, isNull);
    },
  );

  testWidgets('disposed search ignores late suggestion failure', (
    tester,
  ) async {
    final repository = _PendingSearch();
    final search = SearchProvider(repository: repository);
    var notifications = 0;
    search.addListener(() => notifications++);
    search.setSearchQuery('Невский');
    await tester.pump(const Duration(milliseconds: 351));
    final before = notifications;
    search.dispose();
    repository.suggestion.completeError(StateError('Late upstream failure'));
    await tester.pump();
    expect(notifications, before);
    expect(search.errorMessage, isNull);
    expect(tester.takeException(), isNull);
  });

  test('disposed search ignores late geocode failure', () async {
    final repository = _PendingSearch();
    final search = SearchProvider(repository: repository);
    final pending = search.resolveSuggestion(
      const SuggestItemModel(title: 'Невский'),
    );
    search.dispose();
    repository.resolution.completeError(StateError('Late upstream failure'));
    expect(await pending, isNull);
    expect(search.errorMessage, isNull);
    expect(search.selectedExternalPoint, isNull);
  });
}
