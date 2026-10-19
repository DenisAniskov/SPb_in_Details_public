import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/suggest_item_model.dart';
import 'package:smart_navigator_spb/data/repositories/search_repository.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/widgets/external_point_preview_card.dart';
import 'package:provider/provider.dart';

class MockSearchRepository extends SearchRepository {
  final Completer<List<SuggestItemModel>>? pendingSuggest;
  final List<String> receivedQueries = [];
  List<SuggestItemModel> suggestItemsToReturn = [];
  ExternalMapPoint? geocodeToReturn;

  MockSearchRepository({
    this.pendingSuggest,
    List<SuggestItemModel>? initialSuggest,
    this.geocodeToReturn,
  }) {
    if (initialSuggest != null) {
      suggestItemsToReturn = initialSuggest;
    }
  }

  @override
  Future<List<SuggestItemModel>> getSuggestions(String query, {int limit = 7}) async {
    receivedQueries.add(query);
    if (pendingSuggest != null) {
      return pendingSuggest!.future;
    }
    return suggestItemsToReturn;
  }

  @override
  Future<ExternalMapPoint> resolveGeocode({String? text, String? uri}) async {
    if (geocodeToReturn != null) {
      return geocodeToReturn!;
    }
    return ExternalMapPoint(
      title: text ?? 'Геокодированная точка',
      subtitle: 'Адрес точки',
      latitude: 59.93,
      longitude: 30.36,
      source: 'yandex_geocode',
      uri: uri,
    );
  }

  @override
  Future<ExternalMapPoint> reverseGeocode({
    required double latitude,
    required double longitude,
  }) async {
    return ExternalMapPoint(
      title: 'Невский проспект, 1',
      address: 'Россия, Санкт-Петербург, Невский проспект, 1',
      latitude: latitude,
      longitude: longitude,
      source: 'map_tap',
    );
  }
}

class FakeMapKitService extends MapKitService {
  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    return const PedestrianRouteModel(
      distanceMeters: 1000,
      durationSeconds: 600,
      geometryPoints: [],
      steps: [],
    );
  }
}

void main() {
  group('SearchProvider unit tests', () {
    test('search debounces and executes query after 350ms', () async {
      final mockRepo = MockSearchRepository(
        initialSuggest: [
          const SuggestItemModel(title: 'Московский вокзал', uri: 'ymapsbm1://org'),
        ],
      );
      final searchProvider = SearchProvider(repository: mockRepo);

      // Rapidly type characters
      searchProvider.setSearchQuery('М');
      searchProvider.setSearchQuery('Мо');
      searchProvider.setSearchQuery('Мос');

      // Less than debounce duration: no query sent yet
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(mockRepo.receivedQueries, isEmpty);

      // Wait past 350ms debounce
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(mockRepo.receivedQueries, ['Мос']);
      expect(searchProvider.suggestResults.length, 1);
      expect(searchProvider.suggestResults.first.title, 'Московский вокзал');

      searchProvider.dispose();
    });

    test('stale async response from previous query does not overwrite newer query', () async {
      final completer1 = Completer<List<SuggestItemModel>>();
      final mockRepo = MockSearchRepository(pendingSuggest: completer1);
      final searchProvider = SearchProvider(repository: mockRepo);

      searchProvider.setSearchQuery('Запрос1');
      await Future<void>.delayed(const Duration(milliseconds: 360));
      expect(mockRepo.receivedQueries, ['Запрос1']);

      // User changes query to 'Запрос2'
      searchProvider.setSearchQuery('Запрос2');

      // Old request completes late
      completer1.complete([
        const SuggestItemModel(title: 'Старый результат'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Results must not show old results
      expect(
        searchProvider.suggestResults.any((r) => r.title == 'Старый результат'),
        isFalse,
      );

      searchProvider.dispose();
    });

    test('clearSearch immediately clears query, results, and selected point', () async {
      final mockRepo = MockSearchRepository(
        initialSuggest: [
          const SuggestItemModel(title: 'Невский проспект'),
        ],
      );
      final searchProvider = SearchProvider(repository: mockRepo);

      searchProvider.setSearchQuery('Невский');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(searchProvider.suggestResults.isNotEmpty, isTrue);

      searchProvider.clearSearch();
      expect(searchProvider.searchQuery, '');
      expect(searchProvider.suggestResults, isEmpty);
      expect(searchProvider.selectedExternalPoint, isNull);

      searchProvider.dispose();
    });
  });

  group('RoutingProvider with ExternalMapPoint', () {
    test('setting external point as start updates startPoint with proper title and coords', () {
      final routing = RoutingProvider();
      const externalPoint = ExternalMapPoint(
        title: 'Московский вокзал',
        address: 'Невский просп., 85',
        latitude: 59.9298,
        longitude: 30.3621,
      );

      routing.setExternalStartPoint(externalPoint);
      expect(routing.startPoint.title, 'Московский вокзал');
      expect(routing.startPoint.latitude, 59.9298);
      expect(routing.startPoint.longitude, 30.3621);
      expect(routing.startPoint.isPreset, isFalse);

      routing.dispose();
    });

    test('destinationExternalPoint sets destination title and clears local place destination', () {
      final routing = RoutingProvider();
      const externalPoint = ExternalMapPoint(
        title: 'Гостиница Астория',
        address: 'Большая Морская ул., 39',
        latitude: 59.9328,
        longitude: 30.3096,
      );

      routing.buildRouteToExternalPoint(externalPoint);
      expect(routing.destinationTitle, 'Гостиница Астория');
      expect(routing.destinationExternalPoint?.title, 'Гостиница Астория');
      expect(routing.destinationPlace, isNull);

      routing.clearRoute();
      expect(routing.destinationExternalPoint, isNull);

      routing.dispose();
    });

    test('updateStartPointTitle updates title and preserves coordinates', () {
      final routing = RoutingProvider();
      routing.setCustomStartPoint(59.939, 30.315, title: 'Выбранная точка');
      expect(routing.startPoint.title, 'Выбранная точка');

      routing.updateStartPointTitle('Дворцовая наб., 10', subtitle: 'Санкт-Петербург');
      expect(routing.startPoint.title, 'Дворцовая наб., 10');
      expect(routing.startPoint.subtitle, 'Санкт-Петербург');
      expect(routing.startPoint.latitude, 59.939);

      routing.dispose();
    });
  });

  group('ExternalPointPreviewCard widget tests', () {
    testWidgets('renders external point card distinctly without overflow on narrow 320px screen', (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const point = ExternalMapPoint(
        title: 'Очень длинное название внешнего адреса или организации на Невском проспекте',
        address: 'Санкт-Петербург, Центральный район, Невский проспект, дом 85, литера А',
        latitude: 59.9298,
        longitude: 30.3621,
      );

      final routing = RoutingProvider();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
            ChangeNotifierProvider<SearchProvider>.value(value: SearchProvider()),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: ExternalPointPreviewCard(point: point),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify distinction badge
      expect(find.text('Адрес на карте'), findsOneWidget);
      // Verify actions
      expect(find.text('Маршрут сюда'), findsOneWidget);
      expect(find.text('Старт'), findsOneWidget);
      expect(tester.takeException(), isNull);

      routing.dispose();
    });
  });
}
