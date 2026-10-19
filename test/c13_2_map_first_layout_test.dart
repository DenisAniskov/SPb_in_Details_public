import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/category_filter_chips.dart';

const _place = PlaceModel(
  id: 1,
  title: 'Исаакиевский собор',
  shortDescription: 'Собор',
  category: PlaceCategoryEnum.historyArchitecture,
  latitude: 59.934,
  longitude: 30.306,
  address: 'Исаакиевская площадь, 4',
);

class _SearchCatalogue extends PlacesRepository {
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async =>
      (searchQuery ?? '').trim().isEmpty ? const [] : const [_place];

  @override
  Future<List<CategoryModel>> getCategories() async => const [];
}

Future<void> _mount(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  MapKitService.isMapKitInitialized = false;

  final places = PlacesProvider(repository: _SearchCatalogue());
  final routing = RoutingProvider();
  addTearDown(places.dispose);
  addTearDown(routing.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlacesProvider>.value(value: places),
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const MainMapScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the map fills the body and overlays stay above it', (
    tester,
  ) async {
    await _mount(tester, size: const Size(360, 640));

    final map = tester.getRect(find.byKey(const Key('map_surface')));
    final top = tester.getRect(find.byKey(const Key('map_top_overlay')));
    // The 48 px app bar is the only reserved chrome: everything else is map.
    expect(map.height, greaterThanOrEqualTo(640 * 0.85));
    expect(map.width, 360);
    expect(top.top, map.top);
    // Closed top panel never consumes more than 36% of the map column.
    expect(top.height, lessThanOrEqualTo((map.height * 0.36) + 1));
    expect(top.bottom, lessThan(map.bottom));
    // Categories are compact by default, so the map-first area stays usable.
    expect(find.byType(CategoryFilterChips), findsNothing);
    expect(find.byKey(const Key('categories_toggle')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search results overlay the map without shrinking it', (
    tester,
  ) async {
    await _mount(tester, size: const Size(360, 640));
    final before = tester.getRect(find.byKey(const Key('map_surface')));

    await tester.enterText(find.byType(TextField), 'собор');
    await tester.pumpAndSettle();

    expect(find.text('Места в каталоге (1)'), findsOneWidget);
    final after = tester.getRect(find.byKey(const Key('map_surface')));
    final top = tester.getRect(find.byKey(const Key('map_top_overlay')));
    expect(after, before);
    expect(top.height, lessThanOrEqualTo((after.height * 0.62) + 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('small screen at textScale 1.6 keeps the map and controls', (
    tester,
  ) async {
    await _mount(tester, size: const Size(320, 480), textScale: 1.6);

    final map = tester.getRect(find.byKey(const Key('map_surface')));
    final top = tester.getRect(find.byKey(const Key('map_top_overlay')));
    expect(map.height, greaterThanOrEqualTo(480 * 0.82));
    expect(top.height, lessThanOrEqualTo((map.height * 0.36) + 1));
    expect(find.byKey(const Key('categories_toggle')), findsOneWidget);
    expect(find.byKey(const Key('smart_walk_entry')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanding categories stays inside the bounded overlay', (
    tester,
  ) async {
    await _mount(tester, size: const Size(360, 640));
    final map = tester.getRect(find.byKey(const Key('map_surface')));

    await tester.tap(find.byKey(const Key('categories_toggle')));
    await tester.pumpAndSettle();

    expect(find.byType(CategoryFilterChips), findsOneWidget);
    final top = tester.getRect(find.byKey(const Key('map_top_overlay')));
    expect(top.height, lessThanOrEqualTo((map.height * 0.36) + 1));
    // The map is still laid out underneath and not compressed by the panel.
    expect(tester.getRect(find.byKey(const Key('map_surface'))), map);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system Back dismisses the search keyboard first', (
    tester,
  ) async {
    await _mount(tester, size: const Size(360, 640));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    EditableText editor() => tester.widget<EditableText>(
      find.descendant(
        of: find.byType(TextField),
        matching: find.byType(EditableText),
      ),
    );
    expect(editor().focusNode.hasFocus, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(MainMapScreen), findsOneWidget);
    expect(editor().focusNode.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
  });
}
