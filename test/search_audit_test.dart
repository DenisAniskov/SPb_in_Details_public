import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/suggest_item_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/repositories/search_repository.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/start_point_selector_dialog.dart';

import 'repositories/places_repository_test.dart'
    show FixtureAdapter, fixturePlace;

const pointA = ExternalMapPoint(
  title: 'Адрес A',
  latitude: 59.93,
  longitude: 30.36,
);
const pointB = ExternalMapPoint(
  title: 'Адрес B',
  latitude: 59.95,
  longitude: 30.33,
);
const suggestion = SuggestItemModel(
  title: 'Адрес',
  subtitle: 'Санкт-Петербург',
);
const route = PedestrianRouteModel(
  distanceMeters: 100,
  durationSeconds: 80,
  geometryPoints: [],
  steps: [],
);

class PendingSearch extends SearchRepository {
  final suggestions = <String, Completer<List<SuggestItemModel>>>{};
  final resolutions = <Completer<ExternalMapPoint>>[];
  @override
  Future<List<SuggestItemModel>> getSuggestions(
    String query, {
    int limit = 7,
  }) => (suggestions[query] = Completer<List<SuggestItemModel>>()).future;
  @override
  Future<ExternalMapPoint> resolveGeocode({String? text, String? uri}) {
    final request = Completer<ExternalMapPoint>();
    resolutions.add(request);
    return request.future;
  }
}

class RecordingRouter extends MapKitService {
  final requests = <(RoutePointModel, RoutePointModel)>[];
  final pending = <Completer<PedestrianRouteModel>>[];
  bool wait = false;
  @override
  void cancel() {}
  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    requests.add((startPoint, destinationPoint));
    if (!wait) return route;
    final request = Completer<PedestrianRouteModel>();
    pending.add(request);
    return request.future;
  }
}

void main() {
  test(
    'reverse A/B and reverse versus preset cannot rename a newer start',
    () async {
      final routing = RoutingProvider(mapKitService: RecordingRouter());
      final a = Completer<ExternalMapPoint?>();
      final b = Completer<ExternalMapPoint?>();
      final first = routing.setMapStartPoint(
        pointA.latitude,
        pointA.longitude,
        reverseGeocode: (_, __) => a.future,
      );
      expect(
        routing.startPoint.latitude,
        pointA.latitude,
      ); // Immediate coordinates.
      final second = routing.setMapStartPoint(
        pointB.latitude,
        pointB.longitude,
        reverseGeocode: (_, __) => b.future,
      );
      b.complete(pointB);
      await second;
      a.complete(pointA);
      await first;
      expect(routing.startPoint.title, pointB.title);
      final late = Completer<ExternalMapPoint?>();
      final reverse = routing.setMapStartPoint(
        pointA.latitude,
        pointA.longitude,
        reverseGeocode: (_, __) => late.future,
      );
      routing.setStartPoint(RoutePointModel.defaultStart);
      late.complete(pointA);
      await reverse;
      expect(routing.startPoint.id, RoutePointModel.defaultStart.id);
      routing.dispose();
    },
  );

  test('geocode A/B accepts only latest selection and clear rejects pending geocode', () async {
    final repo = PendingSearch();
    final search = SearchProvider(repository: repo);
    final first = search.resolveSuggestion(suggestion);
    final second = search.resolveSuggestion(suggestion);
    repo.resolutions[1].complete(pointB);
    await second;
    repo.resolutions[0].complete(pointA);
    expect(await first, isNull);
    expect(search.selectedExternalPoint, pointB);
    final clearing = search.resolveSuggestion(suggestion);
    search.clearSearch();
    repo.resolutions[2].complete(pointA);
    expect(await clearing, isNull);
    expect(search.selectedExternalPoint, isNull);
    search.dispose();
  });

  testWidgets(
    'Suggest B/A, duplicate text, short input and disposed debounce',
    (tester) async {
      final repo = PendingSearch();
      final search = SearchProvider(repository: repo);
      search.setSearchQuery('A');
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.suggestions, isEmpty);
      search.setSearchQuery('Запрос A');
      await tester.pump(const Duration(milliseconds: 351));
      search.setSearchQuery('Запрос B');
      await tester.pump(const Duration(milliseconds: 351));
      repo.suggestions['Запрос B']!.complete([
        const SuggestItemModel(title: 'B'),
      ]);
      await tester.pump();
      repo.suggestions['Запрос A']!.complete([
        const SuggestItemModel(title: 'A'),
      ]);
      await tester.pump();
      expect(search.suggestResults.single.title, 'B');
      search.setSearchQuery('Запрос B');
      await tester.pump(const Duration(milliseconds: 351));
      expect(repo.suggestions.length, 2);
      search.setSearchQuery(List.filled(151, 'x').join());
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.suggestions.length, 2);
      expect(search.errorMessage, contains('150'));
      search.setSearchQuery('Запрос C');
      search.dispose();
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.suggestions.containsKey('Запрос C'), false);
    },
  );

  for (final externalStart in [false, true]) {
    for (final externalDestination in [false, true]) {
      test(
        'route coordinates: externalStart=$externalStart externalDestination=$externalDestination',
        () async {
          final router = RecordingRouter();
          final routing = RoutingProvider(mapKitService: router);
          final poi = PlaceModel.fromJson(fixturePlace);
          if (externalStart) {
            routing.setExternalStartPoint(pointA);
          } else {
            routing.setStartPoint(
              RoutePointModel(
                id: 'poi',
                title: poi.title,
                subtitle: poi.address,
                latitude: poi.latitude,
                longitude: poi.longitude,
                isPreset: false,
              ),
            );
          }
          if (externalDestination) {
            await routing.buildRouteToExternalPoint(pointB);
          } else {
            await routing.buildRouteTo(poi);
          }
          final request = router.requests.single;
          expect(
            request.$1.latitude,
            externalStart ? pointA.latitude : poi.latitude,
          );
          expect(
            request.$1.longitude,
            externalStart ? pointA.longitude : poi.longitude,
          );
          expect(
            request.$2.latitude,
            externalDestination ? pointB.latitude : poi.latitude,
          );
          expect(
            request.$2.longitude,
            externalDestination ? pointB.longitude : poi.longitude,
          );
          expect(routing.hasRoute, true);
          expect(routing.isWalkRoute, false);
          routing.dispose();
        },
      );
    }
  }

  test('changing start during routing ignores the old result and preserves plan classification', () async {
    final router = RecordingRouter()..wait = true;
    final routing = RoutingProvider(mapKitService: router);
    final poi = PlaceModel.fromJson(fixturePlace);
    routing.addPlaceToWalk(poi);
    final initial = routing.buildRouteTo(poi);
    expect(routing.destinationTitle, poi.title);
    routing.setExternalStartPoint(pointA);
    expect(router.requests.length, 2);
    router.pending[0].complete(route);
    await initial;
    expect(routing.hasRoute, false);
    router.pending[1].complete(route);
    await Future<void>.delayed(Duration.zero);
    expect(routing.hasRoute, true);
    expect(routing.isWalkRoute, false);
    routing.dispose();
  });

  test(
    'external models have no tourist fields and reject nonfinite coordinates',
    () {
      expect(pointA.toJson().keys, isNot(contains('category')));
      for (final field in [
        'rating',
        'working_hours',
        'is_unusual',
        'description',
      ]) {
        expect(pointA.toJson().containsKey(field), false);
      }
      expect(
        () => ExternalMapPoint.fromJson({
          'latitude': double.nan,
          'longitude': 30,
        }),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'local results survive unavailable Suggest, keyboard and long query',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final localClient = ApiClient(customBaseUrl: 'http://test/api/v1');
      localClient.dio.httpClientAdapter = FixtureAdapter(
        (options) => options.uri.path.endsWith('/categories')
            ? []
            : {
                'total': 1,
                'items': [fixturePlace],
              },
      );
      final externalClient = ApiClient(customBaseUrl: 'http://test/api/v1');
      externalClient.dio.httpClientAdapter = FixtureAdapter(
        (_) => throw StateError('unavailable'),
      );
      final places = PlacesProvider(
        repository: PlacesRepository(apiClient: localClient),
      );
      final search = SearchProvider(
        repository: SearchRepository(apiClient: externalClient),
      );
      final routing = RoutingProvider(mapKitService: RecordingRouter());
      MapKitService.isMapKitInitialized = false;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlacesProvider>.value(value: places),
            ChangeNotifierProvider<SearchProvider>.value(value: search),
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
          ],
          child: const MaterialApp(home: MainMapScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Московский вокзал');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(places.places.single.title, 'Русский музей');
      expect(search.errorMessage, isNotNull);
      expect(find.textContaining('Места в каталоге'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Очистить поиск'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(search.searchQuery, '');
      expect(search.suggestResults, isEmpty);
      await tester.pumpWidget(const SizedBox());
      places.dispose();
      search.dispose();
      routing.dispose();
    },
  );

  testWidgets('start dialog cancel invalidates pending geocode', (
    tester,
  ) async {
    final repo = PendingSearch();
    final routing = RoutingProvider(mapKitService: RecordingRouter());
    await tester.pumpWidget(
      ChangeNotifierProvider<RoutingProvider>.value(
        value: routing,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => StartPointSelectorDialog(repository: repo),
                ),
                child: const Text('Старт'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Старт'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Найти адрес'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Вокзал');
    await tester.pump(const Duration(milliseconds: 351));
    repo.suggestions['Вокзал']!.complete([suggestion]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Адрес'));
    await tester.pump();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    repo.resolutions.single.complete(pointA);
    await tester.pumpAndSettle();
    expect(routing.startPoint.id, RoutePointModel.defaultStart.id);
    await tester.pumpWidget(const SizedBox());
    routing.dispose();
  });
}
