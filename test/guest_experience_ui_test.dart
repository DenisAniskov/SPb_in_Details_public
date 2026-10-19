import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/screens/favorites_screen.dart';
import 'package:smart_navigator_spb/ui/screens/guest_onboarding_screen.dart';
import 'package:smart_navigator_spb/ui/screens/guest_settings_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/favorite_button.dart';
import 'package:smart_navigator_spb/ui/widgets/guest_launch_gate.dart';
import 'package:smart_navigator_spb/ui/widgets/place_preview_card.dart';

import 'smart_walk_audit_test.dart' show NativeRouteAdapter;

const _place = PlaceModel(
  id: 1,
  catalogKey: 'test-garden',
  title: 'Сад',
  shortDescription: 'Актуальное описание сада',
  category: PlaceCategoryEnum.nature,
  latitude: 59.94,
  longitude: 30.31,
  address: 'Актуальный адрес',
);

class _MemoryStorage implements GuestKeyValueStore {
  String? value;
  bool rejectWrites = false;
  Completer<String?>? pendingRead;

  @override
  Future<String?> read(String key) async =>
      pendingRead == null ? value : await pendingRead!.future;

  @override
  Future<void> write(String key, String value) async {
    if (rejectWrites) throw StateError('Storage unavailable');
    this.value = value;
  }
}

class _Repository extends PlacesRepository {
  List<PlaceModel> places = [_place];
  bool fail = false;
  int catalogCalls = 0;
  final filters = <(List<PlaceCategoryEnum>?, bool?, String?)>[];

  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async {
    catalogCalls++;
    filters.add((categories, isUnusual, searchQuery));
    if (fail) throw StateError('Network unavailable');
    return places;
  }
}

class _Navigation extends NavigationProvider {
  _Navigation({this.locked = false});
  bool locked;
  @override
  bool get locksPlanning => locked;
  @override
  bool get isActive => locked;
}

GuestExperienceProvider _guest(_MemoryStorage storage, _Repository repository) {
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: storage),
    repository: repository,
    catalogScope: 'https://catalog.example/api/v1',
  );
  addTearDown(guest.dispose);
  return guest;
}

Future<void> _mount(
  WidgetTester tester,
  GuestExperienceProvider guest,
  Widget home, {
  NavigationProvider? navigation,
  RoutingProvider? routing,
  ContextRecommendationProvider? recommendations,
  bool dark = false,
  double fontScale = 1,
}) => tester.pumpWidget(
  MultiProvider(
    providers: [
      ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
      if (navigation != null)
        ChangeNotifierProvider<NavigationProvider>.value(value: navigation),
      if (routing != null)
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
      if (recommendations != null)
        ChangeNotifierProvider<ContextRecommendationProvider>.value(
          value: recommendations,
        ),
    ],
    child: MaterialApp(
      theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(fontScale)),
        child: child!,
      ),
      home: home,
    ),
  ),
);

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: scrollable,
      maxScrolls: 30,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('startup awaits local state without constructing the map', (
    tester,
  ) async {
    final storage = _MemoryStorage()..pendingRead = Completer<String?>();
    final repository = _Repository();
    final guest = _guest(storage, repository);
    final initialization = guest.initialize();
    var mapBuilds = 0;
    await _mount(
      tester,
      guest,
      GuestLaunchGate(
        homeBuilder: (_) {
          mapBuilds++;
          return const Text('Карта');
        },
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(mapBuilds, 0);
    storage.pendingRead!.complete(null);
    await initialization;
    await tester.pumpAndSettle();
    expect(find.byType(GuestOnboardingScreen), findsOneWidget);
    expect(mapBuilds, 0);
    expect(repository.catalogCalls, 0);
  });

  for (final action in ['Подобрать прогулку', 'Перейти к карте']) {
    testWidgets('$action persists completion across provider recreation', (
      tester,
    ) async {
      final storage = _MemoryStorage();
      final repository = _Repository();
      final guest = _guest(storage, repository);
      await guest.initialize();
      var mapBuilds = 0;
      final gate = GuestLaunchGate(
        homeBuilder: (_) {
          mapBuilds++;
          return const Scaffold(body: Text('Каталог, поиск и прогулки'));
        },
      );
      await _mount(tester, guest, gate);
      expect(find.text(AppStrings.appTitle), findsOneWidget);
      expect(mapBuilds, 0);
      await _tapVisible(tester, find.text(action));
      expect(find.text('Каталог, поиск и прогулки'), findsOneWidget);
      final restored = _guest(storage, repository);
      await restored.initialize();
      await _mount(tester, restored, gate);
      await tester.pumpAndSettle();
      expect(find.byType(GuestOnboardingScreen), findsNothing);
      expect(restored.onboardingCompleted, isTrue);
      expect(repository.catalogCalls, 0);
    });
  }

  testWidgets('system Back skips first introduction and persists it', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final repository = _Repository();
    final guest = _guest(storage, repository);
    await guest.initialize();
    await _mount(
      tester,
      guest,
      GuestLaunchGate(homeBuilder: (_) => const Text('Карта')),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Карта'), findsOneWidget);
    final restored = _guest(storage, repository);
    await restored.initialize();
    expect(restored.onboardingCompleted, isTrue);
  });

  testWidgets('settings reopen introduction and Back returns to settings', (
    tester,
  ) async {
    final guest = _guest(_MemoryStorage(), _Repository());
    await guest.initialize();
    await guest.completeOnboarding();
    await _mount(tester, guest, const GuestSettingsScreen());
    await _tapVisible(tester, find.text('Повторить знакомство'));
    expect(find.byType(GuestOnboardingScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(GuestOnboardingScreen), findsNothing);
    expect(find.byType(GuestSettingsScreen), findsOneWidget);
    expect(guest.onboardingCompleted, isTrue);
  });

  testWidgets('running navigation suppresses fullscreen introduction', (
    tester,
  ) async {
    final guest = _guest(_MemoryStorage(), _Repository());
    await guest.initialize();
    final navigation = _Navigation(locked: true);
    addTearDown(navigation.dispose);
    await _mount(
      tester,
      guest,
      GuestLaunchGate(homeBuilder: (_) => const Text('Активная прогулка')),
      navigation: navigation,
    );
    expect(find.text('Активная прогулка'), findsOneWidget);
    expect(find.byType(GuestOnboardingScreen), findsNothing);
    expect(guest.onboardingCompleted, isFalse);
  });

  testWidgets('favorite button exposes label and selected state', (
    tester,
  ) async {
    final guest = _guest(_MemoryStorage(), _Repository());
    await guest.initialize();
    final semantics = tester.ensureSemantics();
    await _mount(
      tester,
      guest,
      const Scaffold(body: FavoriteButton(place: _place)),
    );
    final add = find.byTooltip('Добавить «Сад» в избранное');
    expect(add, findsOneWidget);
    expect(tester.getSize(add).width, greaterThanOrEqualTo(48));
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(guest.favorites, hasLength(1));
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.bySemanticsLabel('Удалить «Сад» из избранного'), findsWidgets);
    await tester.tap(find.byTooltip('Удалить «Сад» из избранного'));
    await tester.pumpAndSettle();
    expect(guest.favorites, isEmpty);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('favorite save failure is explained beside the current UI', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final guest = _guest(storage, _Repository());
    await guest.initialize();
    storage.rejectWrites = true;
    await _mount(
      tester,
      guest,
      const Scaffold(body: FavoriteButton(place: _place)),
    );
    await tester.tap(find.byTooltip('Добавить «Сад» в избранное'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.textContaining('Не удалось сохранить избранное'),
      findsOneWidget,
    );
    expect(guest.isFavorite(_place), isTrue);
  });

  testWidgets('unreadable favorites explain local data failure', (
    tester,
  ) async {
    final storage = _MemoryStorage()..value = '{broken';
    final repository = _Repository();
    final guest = _guest(storage, repository);
    await guest.initialize();
    await _mount(tester, guest, const FavoritesScreen());
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Не удалось сохранить или восстановить избранное'),
      findsOneWidget,
    );
    expect(find.textContaining('Пока нет избранных мест'), findsNothing);
    expect(repository.catalogCalls, 0);
    expect(storage.value, '{broken');
  });

  testWidgets('existing place preview offers favorite without route requests', (
    tester,
  ) async {
    final repository = _Repository();
    final guest = _guest(_MemoryStorage(), repository);
    await guest.initialize();
    final native = NativeRouteAdapter();
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    await _mount(
      tester,
      guest,
      Scaffold(
        body: SingleChildScrollView(
          child: PlacePreviewCard(place: _place, onClose: () {}),
        ),
      ),
      routing: routing,
    );
    await tester.tap(find.byTooltip('Добавить «Сад» в избранное'));
    await tester.pumpAndSettle();
    expect(guest.isFavorite(_place), isTrue);
    expect(native.calls, isEmpty);
    expect(repository.catalogCalls, 0);
    expect(routing.hasRoute, isFalse);
  });

  testWidgets('empty favorites explain how to save places without a request', (
    tester,
  ) async {
    final repository = _Repository();
    final guest = _guest(_MemoryStorage(), repository);
    await guest.initialize();
    await _mount(tester, guest, const FavoritesScreen());
    await tester.pumpAndSettle();
    expect(find.textContaining('Пока нет избранных мест'), findsOneWidget);
    expect(repository.catalogCalls, 0);
  });

  testWidgets(
    'favorites use unfiltered current catalog and open without routing',
    (tester) async {
      final repository = _Repository();
      final guest = _guest(_MemoryStorage(), repository);
      await guest.initialize();
      await guest.addFavorite(_place);
      await guest.setCategories({PlaceCategoryEnum.art});
      await guest.setPreferUnusual(true);
      final native = NativeRouteAdapter();
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      await _mount(tester, guest, const FavoritesScreen(), routing: routing);
      await tester.pumpAndSettle();
      expect(repository.catalogCalls, 1);
      expect(repository.filters.single, (null, null, null));
      await tester.tap(find.text('Сад'));
      await tester.pumpAndSettle();
      expect(find.byType(PlacePreviewCard), findsOneWidget);
      expect(find.text(_place.shortDescription), findsOneWidget);
      expect(native.calls, isEmpty);
      expect(routing.hasRoute, isFalse);
      expect(repository.catalogCalls, 1);
    },
  );

  testWidgets(
    'offline favorites keep references and retry fetches current facts',
    (tester) async {
      final repository = _Repository()..fail = true;
      final guest = _guest(_MemoryStorage(), repository);
      await guest.initialize();
      await guest.addFavorite(_place);
      await _mount(tester, guest, const FavoritesScreen());
      await tester.pumpAndSettle();
      expect(find.text('Не удалось обновить сведения о месте'), findsOneWidget);
      expect(find.text(_place.address), findsNothing);
      expect(find.text(_place.shortDescription), findsNothing);
      expect(guest.favorites, hasLength(1));
      await tester.tap(find.text('Сад'));
      await tester.pumpAndSettle();
      expect(find.byType(PlacePreviewCard), findsNothing);
      repository.fail = false;
      await tester.tap(find.byTooltip('Обновить избранное'));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось обновить сведения о месте'), findsNothing);
      expect(repository.catalogCalls, 2);
      expect(guest.favorites, hasLength(1));
    },
  );

  testWidgets(
    'unavailable favorite can be removed without another catalog call',
    (tester) async {
      final repository = _Repository()..places = [];
      final storage = _MemoryStorage();
      final guest = _guest(storage, repository);
      await guest.initialize();
      await guest.addFavorite(_place);
      await _mount(tester, guest, const FavoritesScreen());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Удалить «Сад» из избранного'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Пока нет избранных мест'), findsOneWidget);
      expect(repository.catalogCalls, 1);
      final restored = _guest(storage, repository);
      await restored.initialize();
      expect(restored.favorites, isEmpty);
    },
  );

  testWidgets(
    'settings save chosen categories, unusual and recommendation options',
    (tester) async {
      final storage = _MemoryStorage();
      final repository = _Repository();
      final guest = _guest(storage, repository);
      await guest.initialize();
      await _mount(tester, guest, const GuestSettingsScreen());
      await _tapVisible(
        tester,
        find.text(PlaceCategoryEnum.nature.displayName),
      );
      await _tapVisible(tester, find.text('Предпочитать необычные места'));
      await _tapVisible(tester, find.text('Показывать рекомендации'));
      await _tapVisible(
        tester,
        find.byType(DropdownButton<RecommendationPreference>),
      );
      await tester.tap(find.text('Больше живописности').last);
      await tester.pumpAndSettle();
      final restored = _guest(storage, repository);
      await restored.initialize();
      expect(restored.categories, {PlaceCategoryEnum.nature});
      expect(restored.preferUnusual, isTrue);
      expect(restored.showRecommendations, isFalse);
      expect(
        restored.recommendationPreference,
        RecommendationPreference.scenic,
      );
      expect(repository.catalogCalls, 0);
    },
  );

  testWidgets(
    'reset settings preserves favorites and introduction completion',
    (tester) async {
      final guest = _guest(_MemoryStorage(), _Repository());
      await guest.initialize();
      await guest.completeOnboarding();
      await guest.addFavorite(_place);
      await guest.setCategories({PlaceCategoryEnum.art});
      await guest.setShowRecommendations(false);
      await _mount(tester, guest, const GuestSettingsScreen());
      await _tapVisible(tester, find.text('Сбросить настройки'));
      expect(guest.categories, isEmpty);
      expect(guest.showRecommendations, isTrue);
      expect(guest.favorites, hasLength(1));
      expect(guest.onboardingCompleted, isTrue);
    },
  );

  testWidgets('navigation settings preserve planning lock and route state', (
    tester,
  ) async {
    final repository = _Repository();
    final guest = _guest(_MemoryStorage(), repository);
    await guest.initialize();
    final navigation = _Navigation(locked: true);
    final native = NativeRouteAdapter();
    final routing = RoutingProvider(mapKitService: native);
    routing.setNavigationLocked(true);
    addTearDown(navigation.dispose);
    addTearDown(routing.dispose);
    await _mount(
      tester,
      guest,
      const GuestSettingsScreen(),
      navigation: navigation,
      routing: routing,
    );
    expect(
      tester.widget<FilterChip>(find.byType(FilterChip).first).onSelected,
      isNull,
    );
    for (final label in ['Сбросить настройки', 'Повторить знакомство']) {
      await _reveal(tester, find.text(label));
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
            .onPressed,
        isNull,
      );
    }
    await _tapVisible(tester, find.text('Показывать рекомендации'));
    expect(guest.showRecommendations, isFalse);
    expect(navigation.locksPlanning, isTrue);
    expect(routing.navigationLocked, isTrue);
    expect(native.calls, isEmpty);
    expect(repository.catalogCalls, 0);
  });

  testWidgets('settings reveal temporarily hidden recommendations explicitly', (
    tester,
  ) async {
    final guest = _guest(_MemoryStorage(), _Repository());
    await guest.initialize();
    final native = NativeRouteAdapter();
    final routing = RoutingProvider(mapKitService: native);
    final navigation = _Navigation();
    final recommendations = ContextRecommendationProvider(
      routing: routing,
      navigation: navigation,
    );
    recommendations.hideForCurrentWalk();
    addTearDown(recommendations.dispose);
    addTearDown(navigation.dispose);
    addTearDown(routing.dispose);
    await _mount(
      tester,
      guest,
      const GuestSettingsScreen(),
      routing: routing,
      navigation: navigation,
      recommendations: recommendations,
    );
    await _tapVisible(tester, find.text('Показать в текущей прогулке'));
    expect(recommendations.panelVisible, isTrue);
    expect(guest.showRecommendations, isTrue);
    expect(native.calls, isEmpty);
  });

  testWidgets('storage errors remain visible while settings stay usable', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    final guest = _guest(storage, _Repository());
    await guest.initialize();
    storage.rejectWrites = true;
    await guest.setShowRecommendations(false);
    await _mount(tester, guest, const GuestSettingsScreen());
    expect(
      find.textContaining('Не удалось сохранить или восстановить'),
      findsOneWidget,
    );
    await _tapVisible(tester, find.text('Показывать рекомендации'));
    expect(guest.showRecommendations, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('guest screens fit 320x480 font 1.6 dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository();
      final guest = _guest(_MemoryStorage(), repository);
      await guest.initialize();
      await guest.addFavorite(_place);
      final native = NativeRouteAdapter();
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      for (final screen in const [
        GuestOnboardingScreen(),
        GuestSettingsScreen(),
        FavoritesScreen(),
      ]) {
        await _mount(
          tester,
          guest,
          screen,
          routing: routing,
          dark: dark,
          fontScale: 1.6,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '${screen.runtimeType}');
        if (screen is GuestOnboardingScreen) {
          await _reveal(tester, find.text('Подобрать прогулку'));
        } else if (screen is GuestSettingsScreen) {
          await _reveal(tester, find.text('Сбросить настройки'));
        } else {
          await tester.tap(find.text('Сад'));
        }
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '${screen.runtimeType} scrolled',
        );
        // Remove pushed routes before mounting the next screen.
        await tester.pumpWidget(const SizedBox());
      }
      expect(native.calls, isEmpty);
    });
  }
}
