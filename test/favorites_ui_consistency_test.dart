import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/favorites_screen.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/place_preview_card.dart';

const _scope = 'https://catalog.example/api/v1';

PlaceModel _garden({
  String? key = 'garden-one',
  int id = 1,
  String title = 'Сад',
  String description = 'Актуальное описание сада',
}) => PlaceModel(
  id: id,
  catalogKey: key,
  title: title,
  shortDescription: description,
  category: PlaceCategoryEnum.nature,
  latitude: 59.94,
  longitude: 30.31,
  address: 'Текущий адрес',
);

class _Memory implements GuestKeyValueStore {
  String? value;
  Completer<void>? holdWrites;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String next) async {
    await holdWrites?.future;
    value = next;
  }
}

class _Catalog extends PlacesRepository {
  List<PlaceModel> places = [];
  int calls = 0;
  int detailCalls = 0;
  bool delayed = false;
  final pending = <Completer<List<PlaceModel>>>[];

  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) {
    ++calls;
    expect((categories, isUnusual, searchQuery), (null, null, null));
    if (!delayed) return Future.value(places);
    final completion = Completer<List<PlaceModel>>();
    pending.add(completion);
    return completion.future;
  }

  @override
  Future<PlaceModel?> getPlaceDetail(int id) async {
    ++detailCalls;
    final matches = places.where((item) => item.id == id);
    return matches.length == 1 ? matches.single : null;
  }
}

class _Native extends MapKitService {
  int calls = 0;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    ++calls;
    throw StateError('Favorites must not request a native route');
  }

  @override
  Future<PedestrianRouteModel> calculateWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
  }) async {
    ++calls;
    throw StateError('Favorites must not request a native walk');
  }
}

GuestExperienceProvider _guest(_Memory memory, _Catalog catalog) {
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: memory),
    repository: catalog,
    catalogScope: _scope,
  );
  addTearDown(guest.dispose);
  return guest;
}

RoutingProvider _routing(_Native native) {
  final routing = RoutingProvider(mapKitService: native);
  addTearDown(routing.dispose);
  return routing;
}

Future<void> _mount(
  WidgetTester tester,
  GuestExperienceProvider guest,
  _Catalog catalog,
  RoutingProvider routing,
) => tester.pumpWidget(
  MultiProvider(
    providers: [
      ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
      Provider<PlacesRepository>.value(value: catalog),
      ChangeNotifierProvider<RoutingProvider>.value(value: routing),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const FavoritesScreen()),
            ),
            child: const Text('Открыть избранное'),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester, {bool settle = true}) async {
  await tester.tap(find.text('Открыть избранное'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _preview(WidgetTester tester) async {
  await tester.tap(find.byType(ListTile).first);
  await tester.pumpAndSettle();
  expect(find.byType(PlacePreviewCard), findsOneWidget);
}

Future<void> _toggleOffOn(WidgetTester tester, String title) async {
  await tester.tap(find.byTooltip('Удалить «$title» из избранного'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Добавить «$title» в избранное'));
  await tester.pumpAndSettle();
}

void _noRoute(_Native native, RoutingProvider routing) {
  expect(native.calls, 0);
  expect(routing.hasRoute, isFalse);
  expect(routing.walkPlaces, isEmpty);
}

void main() {
  for (final legacy in [false, true]) {
    testWidgets(
      'open, card, remove/re-add, return and restart stay resolved legacy=$legacy',
      (tester) async {
        final place = _garden(key: legacy ? null : 'garden-one');
        final memory = _Memory();
        final catalog = _Catalog()..places = [place];
        final guest = _guest(memory, catalog);
        await guest.addFavorite(place);
        final original = guest.favorites.single;
        final native = _Native();
        final routing = _routing(native);
        await _mount(tester, guest, catalog, routing);
        expect(catalog.calls, 0);
        await _open(tester);
        expect(catalog.calls, 1);
        await _preview(tester);
        expect(find.text(place.shortDescription), findsOneWidget);
        await tester.tap(find.text('Подробнее'));
        await tester.pumpAndSettle();
        expect(find.byType(PlaceDetailScreen), findsOneWidget);
        expect(catalog.detailCalls, 1);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await _toggleOffOn(tester, place.title);
        expect(identical(guest.favorites.single, original), isFalse);
        expect(guest.favorites.single.identity, original.identity);
        await tester.tap(find.byTooltip('Закрыть карточку'));
        await tester.pumpAndSettle();
        expect(find.byType(FavoritesScreen), findsOneWidget);
        expect(find.text('Не удалось обновить сведения о месте'), findsNothing);
        expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNotNull);
        expect(catalog.calls, 2);
        _noRoute(native, routing);

        await tester.pumpWidget(const SizedBox());
        final restored = _guest(memory, catalog);
        await restored.initialize();
        expect(restored.favorites.single.identity, original.identity);
        await _mount(tester, restored, catalog, routing);
        await _open(tester);
        expect(find.byKey(ValueKey(original.identity)), findsOneWidget);
        await _preview(tester);
        expect(
          tester.widget<PlacePreviewCard>(find.byType(PlacePreviewCard)).place,
          same(place),
        );
        expect(catalog.calls, 3);
        _noRoute(native, routing);
      },
    );
  }

  final substitutions = <String, (PlaceModel, PlaceModel)>{
    'changed key with reused ID': (
      _garden(),
      _garden(key: 'different-garden', title: 'Другое место'),
    ),
    'legacy changed ID': (_garden(key: null), _garden(key: null, id: 2)),
  };
  for (final entry in substitutions.entries) {
    testWidgets('return/restart cannot substitute ${entry.key}', (
      tester,
    ) async {
      final (saved, replacement) = entry.value;
      final memory = _Memory();
      final catalog = _Catalog()..places = [saved];
      final guest = _guest(memory, catalog);
      await guest.addFavorite(saved);
      final identity = guest.favorites.single.identity;
      final native = _Native();
      final routing = _routing(native);
      await _mount(tester, guest, catalog, routing);
      await _open(tester);
      await _preview(tester);
      catalog.places = [replacement];
      await _toggleOffOn(tester, saved.title);
      await tester.tap(find.byTooltip('Закрыть карточку'));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось обновить сведения о месте'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
      expect(guest.favorites.single.identity, identity);
      await tester.tap(find.text(saved.title));
      await tester.pumpAndSettle();
      expect(find.byType(PlacePreviewCard), findsNothing);

      await tester.pumpWidget(const SizedBox());
      final restored = _guest(memory, catalog);
      await restored.initialize();
      await _mount(tester, restored, catalog, routing);
      await _open(tester);
      expect(find.text('Не удалось обновить сведения о месте'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
      expect(restored.favorites.single.identity, identity);
      _noRoute(native, routing);
    });
  }

  testWidgets('stable key follows current ID and card after remove/re-add', (
    tester,
  ) async {
    final saved = _garden();
    final current = _garden(id: 42, title: 'Обновлённый сад');
    final memory = _Memory();
    final catalog = _Catalog()..places = [saved];
    final guest = _guest(memory, catalog);
    await guest.addFavorite(saved);
    final native = _Native();
    final routing = _routing(native);
    await _mount(tester, guest, catalog, routing);
    await _open(tester);
    await _preview(tester);
    catalog.places = [current];
    await _toggleOffOn(tester, saved.title);
    await tester.tap(find.byTooltip('Закрыть карточку'));
    await tester.pumpAndSettle();
    expect(find.text(current.title), findsOneWidget);
    await _preview(tester);
    expect(
      tester.widget<PlacePreviewCard>(find.byType(PlacePreviewCard)).place,
      same(current),
    );
    expect(guest.favorites.single.catalogKey, saved.catalogKey);
    _noRoute(native, routing);
  });

  testWidgets('legacy migration resolves once, survives re-add and restart', (
    tester,
  ) async {
    final memory = _Memory();
    final current = _garden();
    final catalog = _Catalog()..places = [current];
    final guest = _guest(memory, catalog);
    await guest.addFavorite(_garden(key: null));
    final native = _Native();
    final routing = _routing(native);
    await _mount(tester, guest, catalog, routing);
    await _open(tester);
    expect(guest.favorites.single.identity, 'catalog:garden-one');
    expect(
      catalog.calls,
      1,
      reason: 'Migration reuses its resolved current card',
    );
    await _preview(tester);
    await _toggleOffOn(tester, current.title);
    await tester.tap(find.byTooltip('Закрыть карточку'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось обновить сведения о месте'), findsNothing);
    expect(catalog.calls, 2);

    await tester.pumpWidget(const SizedBox());
    final restored = _guest(memory, catalog);
    await restored.initialize();
    expect(restored.favorites.single.catalogKey, 'garden-one');
    catalog.places = [_garden(id: 99, title: 'Сад в новом каталоге')];
    await _mount(tester, restored, catalog, routing);
    await _open(tester);
    expect(find.text('Сад в новом каталоге'), findsOneWidget);
    expect(catalog.calls, 3);
    _noRoute(native, routing);
  });

  testWidgets('pending remove/re-add discards stale facts and refreshes once', (
    tester,
  ) async {
    final memory = _Memory();
    final catalog = _Catalog()..delayed = true;
    final guest = _guest(memory, catalog);
    await guest.addFavorite(_garden());
    final native = _Native();
    final routing = _routing(native);
    await _mount(tester, guest, catalog, routing);
    await _open(tester, settle: false);
    expect(catalog.pending, hasLength(1));
    await guest.removeFavorite(guest.favorites.single);
    await guest.addFavorite(_garden());
    await tester.pump();
    expect(
      catalog.calls,
      1,
      reason: 'Changes coalesce while a read is pending',
    );
    catalog.pending.first.complete([_garden(title: 'Устаревшие сведения')]);
    await tester.pump();
    expect(catalog.pending, hasLength(2));
    expect(find.text('Устаревшие сведения'), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final current = _garden(title: 'Текущие сведения');
    catalog.pending.last.complete([current]);
    await tester.pumpAndSettle();
    expect(find.text(current.title), findsOneWidget);
    await _preview(tester);
    expect(
      tester.widget<PlacePreviewCard>(find.byType(PlacePreviewCard)).place,
      same(current),
    );
    expect(catalog.calls, 2);
    _noRoute(native, routing);
  });

  testWidgets('mutation during migration persistence cannot reuse its card', (
    tester,
  ) async {
    final memory = _Memory();
    final catalog = _Catalog()..delayed = true;
    final guest = _guest(memory, catalog);
    await guest.addFavorite(_garden(key: null));
    final native = _Native();
    final routing = _routing(native);
    await _mount(tester, guest, catalog, routing);
    await _open(tester, settle: false);
    memory.holdWrites = Completer<void>();
    catalog.pending.first.complete([_garden()]);
    await tester.pump();
    expect(guest.favorites.single.catalogKey, 'garden-one');
    expect(find.byType(ListTile), findsNothing);
    final removing = guest.removeFavorite(guest.favorites.single);
    await tester.pump();
    final replacement = _garden(key: 'different-garden', title: 'Новое место');
    final adding = guest.addFavorite(replacement);
    await tester.pump();
    expect(guest.favorites.single.catalogKey, 'different-garden');
    expect(find.byType(ListTile), findsNothing);
    memory.holdWrites!.complete();
    await Future.wait([removing, adding]);
    await tester.pump();
    expect(catalog.pending, hasLength(2));
    expect(find.text('Сад'), findsNothing);
    catalog.pending.last.complete([replacement]);
    await tester.pumpAndSettle();
    expect(find.text(replacement.title), findsOneWidget);
    await _preview(tester);
    expect(
      tester.widget<PlacePreviewCard>(find.byType(PlacePreviewCard)).place,
      same(replacement),
    );
    expect(catalog.calls, 2);
    expect(
      GuestLocalSnapshot.decode(memory.value!).favorites.single.catalogKey,
      'different-garden',
    );
    _noRoute(native, routing);
  });

  testWidgets(
    'replacing the guest ignores its outstanding catalog completion',
    (tester) async {
      final previousCatalog = _Catalog()..delayed = true;
      final previous = _guest(_Memory(), previousCatalog);
      await previous.addFavorite(_garden());
      final native = _Native();
      final routing = _routing(native);
      await _mount(tester, previous, previousCatalog, routing);
      await _open(tester, settle: false);
      final current = _garden(title: 'Текущий гость');
      final currentCatalog = _Catalog()..places = [current];
      final currentGuest = _guest(_Memory(), currentCatalog);
      await currentGuest.addFavorite(current);
      await _mount(tester, currentGuest, currentCatalog, routing);
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesScreen), findsOneWidget);
      expect(find.text(current.title), findsOneWidget);
      previousCatalog.pending.single.complete([
        _garden(title: 'Данные прошлого гостя'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Данные прошлого гостя'), findsNothing);
      expect(find.text(current.title), findsOneWidget);
      await _preview(tester);
      expect(
        tester.widget<PlacePreviewCard>(find.byType(PlacePreviewCard)).place,
        same(current),
      );
      expect(previousCatalog.calls, 1);
      expect(currentCatalog.calls, 1);
      _noRoute(native, routing);
    },
  );

  testWidgets(
    'changed composition clears existing cards until refresh finishes',
    (tester) async {
      final memory = _Memory();
      final catalog = _Catalog()..places = [_garden()];
      final guest = _guest(memory, catalog);
      await guest.addFavorite(_garden());
      final native = _Native();
      final routing = _routing(native);
      await _mount(tester, guest, catalog, routing);
      await _open(tester);
      expect(find.byType(ListTile), findsOneWidget);
      await guest.setPreferUnusual(true);
      await tester.pumpAndSettle();
      expect(
        catalog.calls,
        1,
        reason: 'Preferences do not change favorite identity',
      );
      catalog.delayed = true;
      await guest.removeFavorite(guest.favorites.single);
      await guest.addFavorite(_garden(key: 'new-garden', title: 'Новое место'));
      await tester.pump();
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      catalog.pending.single.complete([_garden()]);
      await tester.pumpAndSettle();
      expect(find.text('Не удалось обновить сведения о месте'), findsOneWidget);
      expect(find.text('Сад'), findsNothing);
      expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
      _noRoute(native, routing);
    },
  );
}
