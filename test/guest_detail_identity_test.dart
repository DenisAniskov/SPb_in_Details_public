import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';

const _selected = PlaceModel(
  id: 42,
  catalogKey: 'summer-garden',
  title: 'Исходный сад',
  shortDescription: 'Исходное описание',
  category: PlaceCategoryEnum.nature,
  latitude: 59.94,
  longitude: 30.31,
  address: 'Исходный адрес',
);

PlaceModel _changed(Map<String, dynamic> updates) =>
    PlaceModel.fromJson({..._selected.toJson(), ...updates});

class _DetailRepository extends PlacesRepository {
  PlaceModel? response = _selected;
  bool fail = false;
  final requestedIds = <int>[];

  @override
  Future<PlaceModel?> getPlaceDetail(int placeId) async {
    requestedIds.add(placeId);
    if (fail) throw StateError('Network unavailable');
    return response;
  }
}

class _NativeRequests extends MapKitService {
  int calls = 0;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    calls++;
    throw StateError('Unexpected automatic native route request');
  }

  @override
  Future<PedestrianRouteModel> calculateWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
  }) async {
    calls++;
    throw StateError('Unexpected automatic native walk request');
  }
}

Future<void> _mount(
  WidgetTester tester,
  _DetailRepository repository,
  RoutingProvider routing, {
  PlaceModel selected = _selected,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<PlacesRepository>.value(value: repository),
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: PlaceDetailScreen(place: selected),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectNoRoute(_NativeRequests native, RoutingProvider routing) {
  expect(native.calls, 0);
  expect(routing.currentRoute, isNull);
  expect(routing.status, RoutingStatus.idle);
}

void main() {
  late _DetailRepository repository;
  late _NativeRequests native;
  late RoutingProvider routing;

  setUp(() {
    repository = _DetailRepository();
    native = _NativeRequests();
    routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
  });

  testWidgets('C8.1 reused id with a different catalog key refuses details', (
    tester,
  ) async {
    repository.response = _changed({
      'catalog_key': 'different-place',
      'title': 'Другой объект',
      'short_description': 'Чужие сведения',
      'address': 'Чужой адрес',
    });
    await _mount(tester, repository, routing);

    expect(find.text('Не удалось обновить сведения о месте'), findsOneWidget);
    expect(find.text('Другой объект'), findsNothing);
    expect(find.text('Чужие сведения'), findsNothing);
    expect(find.text('Чужой адрес'), findsNothing);
    expect(repository.requestedIds, [42]);
    _expectNoRoute(native, routing);
  });

  final legacyChanges = <String, Map<String, dynamic>>{
    'title': {'title': 'Другой объект'},
    'category': {'category': 'art'},
    'latitude': {'latitude': 59.95},
    'longitude': {'longitude': 30.32},
  };
  for (final change in legacyChanges.entries) {
    testWidgets('C8.1 legacy detail refuses changed ${change.key}', (
      tester,
    ) async {
      final legacy = _changed({'catalog_key': null});
      repository.response = _changed({
        'catalog_key': null,
        'address': 'Чужой адрес',
        ...change.value,
      });
      await _mount(tester, repository, routing, selected: legacy);

      expect(find.text('Не удалось обновить сведения о месте'), findsOneWidget);
      expect(find.text('Чужой адрес'), findsNothing);
      expect(find.text('Исходный адрес'), findsNothing);
      expect(repository.requestedIds, [42]);
      _expectNoRoute(native, routing);
    });
  }

  testWidgets('C8.1 stable key displays fresh title address and description', (
    tester,
  ) async {
    repository.response = _changed({
      'title': 'Уточнённое название сада',
      'address': 'Актуальный адрес',
      'short_description': 'Новые сведения',
      'full_description': 'Полный новый текст',
    });
    await _mount(tester, repository, routing);

    expect(find.text('Не удалось обновить сведения о месте'), findsNothing);
    expect(find.text('Уточнённое название сада'), findsOneWidget);
    expect(find.text('Актуальный адрес'), findsOneWidget);
    expect(find.text('Полный новый текст'), findsOneWidget);
    expect(find.text('Исходный адрес'), findsNothing);
    expect(find.text('Исходное описание'), findsNothing);
    _expectNoRoute(native, routing);
  });

  testWidgets('C8.1 exact legacy identity accepts updated address', (
    tester,
  ) async {
    final legacy = _changed({'catalog_key': null});
    repository.response = _changed({
      'catalog_key': null,
      'address': 'Актуальный адрес',
    });
    await _mount(tester, repository, routing, selected: legacy);

    expect(find.text('Не удалось обновить сведения о месте'), findsNothing);
    expect(find.text('Актуальный адрес'), findsOneWidget);
    expect(find.text('Исходный адрес'), findsNothing);
    _expectNoRoute(native, routing);
  });

  testWidgets('C8.1 network failure shows unavailable and explicit retry', (
    tester,
  ) async {
    repository.fail = true;
    await _mount(tester, repository, routing);

    expect(find.text('Не удалось обновить сведения о месте'), findsOneWidget);
    expect(find.text('Исходный адрес'), findsNothing);
    expect(find.text('Исходное описание'), findsNothing);
    expect(repository.requestedIds, [42]);
    _expectNoRoute(native, routing);

    repository.fail = false;
    repository.response = _changed({'address': 'Адрес после восстановления'});
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();

    expect(repository.requestedIds, [42, 42]);
    expect(find.text('Не удалось обновить сведения о месте'), findsNothing);
    expect(find.text('Адрес после восстановления'), findsOneWidget);
    _expectNoRoute(native, routing);
  });

  testWidgets('C8.1 removed detail shows unavailable without stale facts', (
    tester,
  ) async {
    repository.response = null;
    await _mount(tester, repository, routing);

    expect(find.text('Не удалось обновить сведения о месте'), findsOneWidget);
    expect(find.text('Исходный адрес'), findsNothing);
    expect(find.text('Исходное описание'), findsNothing);
    _expectNoRoute(native, routing);
  });
}
