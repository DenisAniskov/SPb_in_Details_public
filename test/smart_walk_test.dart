import 'guided_walk_test_helpers.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';

PlaceModel createTestPlace({
  required int id,
  required String title,
  required PlaceCategoryEnum category,
  bool isUnusual = false,
  int visitMinutes = 30,
}) {
  return PlaceModel(
    id: id,
    title: title,
    shortDescription: 'Описание для $title',
    category: category,
    isUnusual: isUnusual,
    latitude: 59.93 + (id * 0.001),
    longitude: 30.31 + (id * 0.001),
    address: 'ул. Тестовая, д. $id',
    recommendedVisitMinutes: visitMinutes,
  );
}

void main() {
  group('Smart Walk Wizard Sheet Tests', () {
    testWidgets(
      'renders wizard sheet controls on narrow 320px screen without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final routingProvider = RoutingProvider();
        final placesProvider = PlacesProvider();

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<RoutingProvider>.value(
                value: routingProvider,
              ),
              ChangeNotifierProvider<PlacesProvider>.value(
                value: placesProvider,
              ),
            ],
            child: const MaterialApp(
              home: Scaffold(body: SmartWalkWizardSheet()),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Проверяем наличие ключевых элементов визарда
        expect(find.text('Точка отправления'), findsOneWidget);
        expect(find.textContaining('Добро пожаловать!'), findsOneWidget);
        expect(find.text('Сформировать прогулку'), findsNothing);
        await guidedToInterests(tester, preset: 'Быстрая прогулка');
        expect(find.text('Ваши интересы'), findsOneWidget);
        expect(find.text('Сформировать прогулку'), findsOneWidget);

        // Проверяем выбор интереса
        expect(find.text('История и архитектура'), findsOneWidget);
        await tester.ensureVisible(find.text('История и архитектура'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('История и архитектура'));
        await tester.pumpAndSettle();

        expect(find.byType(Switch), findsNothing);
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.text('Да, мне интересно открывать новое'), findsOneWidget);

        // Проверка отсутствия ошибок переполнения Flutter
        expect(tester.takeException(), isNull);
      },
    );

    test(
      'RoutingProvider setProposedWalk correctly stores places and reasons',
      () {
        final routing = RoutingProvider();
        final p1 = createTestPlace(
          id: 1,
          title: 'Место 1',
          category: PlaceCategoryEnum.historyArchitecture,
        );
        final p2 = createTestPlace(
          id: 2,
          title: 'Место 2',
          category: PlaceCategoryEnum.art,
          isUnusual: true,
        );

        final reasons = {
          1: [
            'Соответствует интересу: История и архитектура',
            'В пешей доступности',
          ],
          2: ['Необычное место', 'Разнообразие: новая категория'],
        };

        routing.setProposedWalk([p1, p2], reasons: reasons);

        expect(routing.walkPlaces.length, 2);
        expect(routing.walkPlaces[0].id, 1);
        expect(routing.walkPlaces[1].id, 2);
        expect(routing.placeReasons[1], contains('В пешей доступности'));
        expect(routing.placeReasons[2], contains('Необычное место'));

        routing.clearWalk();
        expect(routing.walkPlaces.isEmpty, isTrue);
        expect(routing.placeReasons.isEmpty, isTrue);
      },
    );

    test('AutoWalkProposalResponseModel deserializes JSON correctly', () {
      final json = {
        'status': 'success',
        'message': 'Подобрана прогулка из 2 мест на ~85 мин.',
        'time_budget_minutes': 90,
        'estimated_walking_duration_seconds': 1500,
        'estimated_visit_duration_minutes': 60,
        'estimated_total_duration_minutes': 85,
        'estimated_total_distance_meters': 1875.0,
        'suggested_places_sequence': [1, 2],
        'items': [
          {
            'place': {
              'id': 1,
              'title': 'Дворцовая площадь',
              'short_description': 'Главная площадь СПб',
              'category': 'history_architecture',
              'is_unusual': false,
              'latitude': 59.939,
              'longitude': 30.315,
              'address': 'Дворцовая пл.',
              'recommended_visit_minutes': 30,
            },
            'visit_duration_minutes': 30,
            'reasons': ['Соответствует интересу: История и архитектура'],
          },
          {
            'place': {
              'id': 2,
              'title': 'Эрмитаж',
              'short_description': 'Музей',
              'category': 'art',
              'is_unusual': false,
              'latitude': 59.940,
              'longitude': 30.314,
              'address': 'Дворцовая наб., 34',
              'recommended_visit_minutes': 30,
            },
            'visit_duration_minutes': 30,
            'reasons': ['В пешей доступности (120 м)'],
          },
        ],
      };

      final model = AutoWalkProposalResponseModel.fromJson(json);
      expect(model.status, 'success');
      expect(model.timeBudgetMinutes, 90);
      expect(model.estimatedTotalDurationMinutes, 85);
      expect(model.items.length, 2);
      expect(model.items[0].place.title, 'Дворцовая площадь');
      expect(
        model.items[0].reasons,
        contains('Соответствует интересу: История и архитектура'),
      );
      expect(model.items[1].visitDurationMinutes, 30);
    });
  });
}
