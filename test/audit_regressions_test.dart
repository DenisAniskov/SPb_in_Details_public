import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/widgets/place_preview_card.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/start_point_selector_dialog.dart';

import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';

import 'repositories/places_repository_test.dart'
    show FixtureAdapter, fixturePlace;

import 'package:smart_navigator_spb/core/network/api_client.dart';

const place = PlaceModel(
  id: 1,
  title: 'Историческое место',
  shortDescription: 'Описание',
  category: PlaceCategoryEnum.historyArchitecture,
  isUnusual: true,
  latitude: 59.94,
  longitude: 30.31,
  address: 'Адрес',
);

class PendingRepository extends PlacesRepository {
  final requests = <Completer<List<PlaceModel>>>[];
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) {
    final c = Completer<List<PlaceModel>>();
    requests.add(c);
    return c.future;
  }

  @override
  Future<List<CategoryModel>> getCategories() async => [];
}

class PendingRouter extends MapKitService {
  final request = Completer<PedestrianRouteModel>();
  @override
  void cancel() {}
  @override
  Future<PedestrianRouteModel> calculatePedestrianRoute({
    required RoutePointModel startPoint,
    required PlaceModel destination,
  }) => request.future;

  @override
  Future<PedestrianRouteModel> calculateWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
  }) => request.future;
}

class DetailRepository extends PlacesRepository {
  @override
  Future<PlaceModel?> getPlaceDetail(int id) async => PlaceModel(
    id: id,
    title: place.title,
    shortDescription: place.shortDescription,
    fullDescription: 'Полное описание из detail API',
    category: place.category,
    isUnusual: true,
    latitude: place.latitude,
    longitude: place.longitude,
    address: place.address,
  );
}

void main() {
  testWidgets(
    'search debounces, sends Cyrillic query, and clear resets API results',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final queries = <String?>[];
      final client = ApiClient(customBaseUrl: 'http://test/api/v1');
      client.dio.httpClientAdapter = FixtureAdapter((options) {
        if (options.uri.path.endsWith('/categories')) return [];
        final q = options.queryParameters['q'] as String?;
        queries.add(q);
        return {
          'items': q == 'нет такого места' ? [] : [fixturePlace],
          'total': q == 'нет такого места' ? 0 : 1,
        };
      });
      final places = PlacesProvider(
        repository: PlacesRepository(apiClient: client),
      );
      final routing = RoutingProvider(mapKitService: PendingRouter());
      MapKitService.isMapKitInitialized = false;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlacesProvider>.value(value: places),
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
          ],
          child: const MaterialApp(home: MainMapScreen()),
        ),
      );
      await tester.pumpAndSettle();
      queries.clear();
      await tester.enterText(find.byType(TextField), 'Рус');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'Русский музей');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(queries, ['Русский музей']);
      expect(find.text('Найдено мест: 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'нет такого места');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(find.text('По выбранным фильтрам мест нет'), findsOneWidget);
      await tester.tap(find.byTooltip('Очистить поиск'));
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(queries.last, isNull);
      expect(find.text('Найдено мест: 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      places.dispose();
      routing.dispose();
    },
  );

  testWidgets(
    'all six category chips and unusual filter reach the API and reset',
    (tester) async {
      final requests = <Map<String, dynamic>>[];
      final client = ApiClient(customBaseUrl: 'http://test/api/v1');
      client.dio.httpClientAdapter = FixtureAdapter((options) {
        if (options.uri.path.endsWith('/categories')) return [];
        requests.add(Map.of(options.queryParameters));
        return {
          'items': [fixturePlace],
          'total': 1,
        };
      });
      final places = PlacesProvider(
        repository: PlacesRepository(apiClient: client),
      );
      final routing = RoutingProvider(mapKitService: PendingRouter());
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlacesProvider>.value(value: places),
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
          ],
          child: const MaterialApp(home: MainMapScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'музей');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      // C13.2: category filters are collapsed by default to keep the map
      // visible; expand them before interacting with the chips.
      await tester.tap(find.byKey(const Key('categories_toggle')));
      await tester.pumpAndSettle();
      for (final category in PlaceCategoryEnum.values) {
        final chip = find.widgetWithText(FilterChip, category.displayName);
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(requests.last['category'], contains(category.key));
        expect(requests.last['q'], 'музей');
      }
      final unusual = find.byType(FilterChip).first;
      await tester.ensureVisible(unusual);
      await tester.tap(unusual);
      await tester.pumpAndSettle();
      expect(requests.last['is_unusual'], true);
      final reset = find.widgetWithText(ActionChip, 'Сброс');
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(requests.last, {'limit': 200, 'offset': 0});
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      places.dispose();
      routing.dispose();
    },
  );

  testWidgets(
    'map start choice is explicit and accepts arbitrary coordinates',
    (tester) async {
      final routing = RoutingProvider(mapKitService: PendingRouter());
      await tester.pumpWidget(
        ChangeNotifierProvider<RoutingProvider>.value(
          value: routing,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const StartPointSelectorDialog(),
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
      await tester.tap(find.text('Выбрать на карте'));
      await tester.pumpAndSettle();
      expect(routing.isChoosingStart, true);
      expect(find.byType(StartPointSelectorDialog), findsNothing);
      routing.setCustomStartPoint(59.956789, 30.345678);
      expect(routing.startPoint.latitude, 59.956789);
      expect(routing.startPoint.longitude, 30.345678);
      expect(routing.startPoint.isPreset, false);
      expect(routing.isChoosingStart, false);
      routing.beginStartSelection();
      routing.cancelStartSelection();
      expect(routing.startPoint.latitude, 59.956789);
      await tester.pumpWidget(const SizedBox());
      routing.dispose();
    },
  );
  test(
    'without a MapKit key routing fails and creates no invented geometry',
    () async {
      MapKitService.isMapKitInitialized = false;
      await MapKitService.initializeMapKit(apiKey: '');
      await expectLater(
        MapKitService().calculatePedestrianRoute(
          startPoint: RoutePointModel.defaultStart,
          destination: place,
        ),
        throwsStateError,
      );
    },
  );

  test('older place request cannot overwrite newer filters', () async {
    final repo = PendingRepository();
    final provider = PlacesProvider(repository: repo);
    final latest = provider.loadPlaces();
    repo.requests[1].complete([place]);
    await latest;
    repo.requests[0].complete([]);
    await Future<void>.delayed(Duration.zero);
    expect(provider.places.single.id, 1);
    provider.dispose();
  });

  test('cleared route cannot reappear after a late SDK response', () async {
    final router = PendingRouter();
    final provider = RoutingProvider(mapKitService: router);
    final building = provider.buildRouteTo(place);
    provider.clearRoute();
    router.request.complete(
      const PedestrianRouteModel(
        distanceMeters: 100,
        durationSeconds: 80,
        geometryPoints: [],
        steps: [],
      ),
    );
    await building;
    expect(provider.hasRoute, isFalse);
    expect(provider.currentRoute, isNull);
    provider.dispose();
  });

  testWidgets(
    'preview and API detail render without overflow on a narrow phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final routing = RoutingProvider(mapKitService: PendingRouter());
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<PlacesRepository>(create: (_) => DetailRepository()),
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const Scaffold(
              body: Center(child: PlacePreviewCard(place: place)),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Подробнее'));
      await tester.pumpAndSettle();
      expect(find.text('Полное описание из detail API'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      routing.dispose();
    },
  );

  test('walk planning manages places up to limit of 6 and reorders correctly', () {
    final routing = RoutingProvider();
    expect(routing.walkPlaces, isEmpty);
    expect(RoutingProvider.maxWalkPlaces, 6);

    const p1 = PlaceModel(
      id: 1,
      title: 'П1',
      shortDescription: '',
      category: PlaceCategoryEnum.art,
      isUnusual: false,
      latitude: 59.93,
      longitude: 30.31,
      address: '',
    );
    const p2 = PlaceModel(
      id: 2,
      title: 'П2',
      shortDescription: '',
      category: PlaceCategoryEnum.historyArchitecture,
      isUnusual: true,
      latitude: 59.94,
      longitude: 30.32,
      address: '',
    );

    expect(routing.addPlaceToWalk(p1), isTrue);
    expect(routing.addPlaceToWalk(p1), isFalse); // Нельзя дублировать
    expect(routing.walkPlaces.length, 1);
    expect(routing.isInWalk(p1), isTrue);

    expect(routing.addPlaceToWalk(p2), isTrue);
    expect(routing.walkPlaces.length, 2);

    // Добавляем до лимита 6
    for (int i = 3; i <= 6; i++) {
      final p = PlaceModel(
        id: i,
        title: 'П$i',
        shortDescription: '',
        category: PlaceCategoryEnum.nature,
        isUnusual: false,
        latitude: 59.90 + i * 0.01,
        longitude: 30.30 + i * 0.01,
        address: '',
      );
      expect(routing.addPlaceToWalk(p), isTrue);
    }
    expect(routing.walkPlaces.length, 6);

    // 7-е место отклоняется
    const p7 = PlaceModel(
      id: 7,
      title: 'П7',
      shortDescription: '',
      category: PlaceCategoryEnum.scienceTechnology,
      isUnusual: false,
      latitude: 59.99,
      longitude: 30.39,
      address: '',
    );
    expect(routing.addPlaceToWalk(p7), isFalse);
    expect(routing.walkPlaces.length, 6);

    // Изменение порядка (reorder)
    // Текущий список: [1, 2, 3, 4, 5, 6]
    routing.reorderWalkPlaces(0, 2); // перемещаем 1 на позицию 1
    expect(routing.walkPlaces.first.id, 2);

    // Удаление
    routing.removePlaceFromWalk(2);
    expect(routing.walkPlaces.length, 5);
    expect(routing.isInWalk(p2), isFalse);

    routing.clearWalk();
    expect(routing.walkPlaces, isEmpty);
    routing.dispose();
  });

  testWidgets(
    'RouteDetailsSheet renders without overflow on compact screen and long titles',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = PendingRouter();
      final routing = RoutingProvider(mapKitService: router);

      const walkRoute = PedestrianRouteModel(
        distanceMeters: 4200,
        durationSeconds: 3200,
        geometryPoints: [
          GeoCoord(59.939, 30.315),
          GeoCoord(59.940, 30.320),
        ],
        steps: [],
        legs: [
          RouteLegModel(
            fromTitle: 'Дворцовая площадь с длинным описанием точки старта',
            toTitle: 'Государственный академический Мариинский театр историческое здание',
            distanceMeters: 2100,
            durationSeconds: 1600,
            geometryPoints: [],
          ),
          RouteLegModel(
            fromTitle: 'Государственный академический Мариинский театр историческое здание',
            toTitle: 'Центральный военно-морской музей имени императора Петра Великого',
            distanceMeters: 2100,
            durationSeconds: 1600,
            geometryPoints: [],
          ),
        ],
        placesCount: 2,
      );

      // Имитируем успешную построенную прогулку
      const p1 = PlaceModel(
        id: 10,
        title: 'Государственный академический Мариинский театр историческое здание',
        shortDescription: '',
        category: PlaceCategoryEnum.art,
        isUnusual: false,
        latitude: 59.925,
        longitude: 30.296,
        address: '',
      );
      const p2 = PlaceModel(
        id: 11,
        title: 'Центральный военно-морской музей имени императора Петра Великого',
        shortDescription: '',
        category: PlaceCategoryEnum.historyArchitecture,
        isUnusual: false,
        latitude: 59.930,
        longitude: 30.295,
        address: '',
      );
      routing.addPlaceToWalk(p1);
      routing.addPlaceToWalk(p2);

      final future = routing.buildWalkRoute();
      router.request.complete(walkRoute);
      await future;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const Scaffold(
              body: SizedBox(
                height: 350,
                child: RouteDetailsSheet(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Маршрут прогулки (2 места)'), findsOneWidget);
      expect(find.text('4.2 км'), findsOneWidget);
      expect(find.text('ходьба ~53 мин'), findsOneWidget);
      expect(find.textContaining('без учёта времени посещения объектов'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      routing.dispose();
    },
  );
}
