import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/config/app_version.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/theme_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/guest_settings_screen.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/about_app_section.dart';
import 'package:smart_navigator_spb/ui/widgets/theme_mode_button.dart';

class _MemoryPreferenceStore implements ThemePreferenceStore {
  _MemoryPreferenceStore([this.value]);

  AppThemePreference? value;
  int writes = 0;

  @override
  Future<AppThemePreference?> read() async => value;

  @override
  Future<void> write(AppThemePreference preference) async {
    writes++;
    value = preference;
  }
}

class _MemoryStorage implements GuestKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _Catalog extends PlacesRepository {
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async => const [];

  @override
  Future<List<CategoryModel>> getCategories() async => const [];
}

class _ThemeHost {
  _ThemeHost(this.provider, this.store);

  final ThemeProvider provider;
  final _MemoryPreferenceStore store;
}

Future<_ThemeHost> _mountMap(
  WidgetTester tester, {
  Size size = const Size(360, 640),
  double textScale = 1,
  _MemoryPreferenceStore? store,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  MapKitService.isMapKitInitialized = false;

  final themeStore = store ?? _MemoryPreferenceStore();
  final theme = ThemeProvider(store: themeStore);
  addTearDown(theme.dispose);
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: _MemoryStorage()),
    repository: _Catalog(),
    catalogScope: 'https://catalog.example/api/v1',
  );
  addTearDown(guest.dispose);
  await guest.initialize();
  await guest.completeOnboarding();
  final places = PlacesProvider(repository: _Catalog(), guest: guest);
  final routing = RoutingProvider();
  addTearDown(places.dispose);
  addTearDown(routing.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>.value(value: theme),
        ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
        ChangeNotifierProvider<PlacesProvider>.value(value: places),
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, appearance, _) => MaterialApp(
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: appearance.themeMode,
          themeAnimationDuration: Duration.zero,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const MainMapScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _ThemeHost(theme, themeStore);
}

Future<void> _openThemeMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Тема оформления'));
  await tester.pumpAndSettle();
}

CheckedPopupMenuItem<AppThemePreference> _checkedItem(WidgetTester tester) {
  final items = tester.widgetList<CheckedPopupMenuItem<AppThemePreference>>(
    find.byType(CheckedPopupMenuItem<AppThemePreference>),
  );
  final active = items.where((item) => item.checked).toList(growable: false);
  expect(active, hasLength(1));
  return active.single;
}

Finder _themeOption(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(CheckedPopupMenuItem<AppThemePreference>),
);

void main() {
  test('reads the installed version from package metadata', () async {
    PackageInfo.setMockInitialValues(
      appName: 'SmartNavigator SPb',
      packageName: 'ru.smartnavigator.spb',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    expect(await readInstalledAppVersion(), '1.0.0 (сборка 1)');
  });

  testWidgets('about section shows authorship and the installed version', (
    tester,
  ) async {
    for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: AboutAppSection(
                loadVersion: () async => '1.0.0 (сборка 1)',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('О приложении'), findsOneWidget);
      expect(find.text(AppStrings.appTitle), findsOneWidget);
      expect(find.text(AppStrings.appCreator), findsOneWidget);
      expect(find.text(AppStrings.appTagline), findsOneWidget);
      expect(find.text('Версия 1.0.0 (сборка 1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('about section omits an unavailable version', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(body: AboutAppSection(loadVersion: () async => null)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Версия'), findsNothing);
    expect(find.text(AppStrings.appCreator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system theme follows Android brightness until overridden', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final store = _MemoryPreferenceStore(AppThemePreference.system);
    final provider = ThemeProvider(store: store);
    addTearDown(provider.dispose);
    late Brightness brightness;

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>.value(
        value: provider,
        child: Consumer<ThemeProvider>(
          builder: (context, appearance, _) => MaterialApp(
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: appearance.themeMode,
            themeAnimationDuration: Duration.zero,
            home: Builder(
              builder: (context) {
                brightness = Theme.of(context).brightness;
                return Scaffold(
                  appBar: AppBar(
                    title: const Text('Тема'),
                    actions: const [ThemeModeButton()],
                  ),
                  body: const SizedBox(),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(brightness, Brightness.light);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightness, Brightness.dark);

    await provider.setPreference(AppThemePreference.light);
    await tester.pumpAndSettle();
    expect(brightness, Brightness.light);
    expect(store.value, AppThemePreference.light);

    await provider.setPreference(AppThemePreference.system);
    await tester.pumpAndSettle();
    expect(brightness, Brightness.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'map AppBar switches theme, marks the active choice and persists',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final store = _MemoryPreferenceStore();
      final host = await _mountMap(tester, store: store);
      try {
        expect(find.byKey(const Key('theme_mode_button')), findsOneWidget);
        expect(find.byIcon(Icons.brightness_auto_outlined), findsOneWidget);
        expect(find.byTooltip('Тема оформления'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Тема оформления. Сейчас: Системная'),
          findsOneWidget,
        );

        await _openThemeMenu(tester);
        expect(find.text('Системная'), findsOneWidget);
        expect(find.text('Светлая'), findsOneWidget);
        expect(find.text('Тёмная'), findsOneWidget);
        expect(_checkedItem(tester).value, AppThemePreference.system);

        await tester.tap(_themeOption('Тёмная'));
        await tester.pumpAndSettle();
        expect(host.provider.preference, AppThemePreference.dark);
        expect(store.value, AppThemePreference.dark);
        expect(store.writes, 1);
        expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);
        expect(
          find.bySemanticsLabel('Тема оформления. Сейчас: Тёмная'),
          findsOneWidget,
        );

        await _openThemeMenu(tester);
        expect(_checkedItem(tester).value, AppThemePreference.dark);
        await tester.tap(_themeOption('Светлая'));
        await tester.pumpAndSettle();
        expect(host.provider.preference, AppThemePreference.light);
        expect(store.value, AppThemePreference.light);
        expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);
        expect(tester.takeException(), isNull);

        final restored = ThemeProvider(store: store);
        addTearDown(restored.dispose);
        await tester.pump();
        expect(restored.preference, AppThemePreference.light);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('quick theme menu and settings stay synchronized both ways', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'SmartNavigator SPb',
      packageName: 'ru.smartnavigator.spb',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final store = _MemoryPreferenceStore();
    final host = await _mountMap(tester, store: store);

    await _openThemeMenu(tester);
    await tester.tap(_themeOption('Тёмная'));
    await tester.pumpAndSettle();
    expect(host.provider.preference, AppThemePreference.dark);

    await tester.tap(find.byTooltip('Дополнительные действия'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(find.byType(GuestSettingsScreen), findsOneWidget);
    expect(find.text('Оформление'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Тёмная'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(ChoiceChip), findsNWidgets(3));

    ChoiceChip chip(String label) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));
    expect(chip('Тёмная').selected, isTrue);
    expect(chip('Светлая').selected, isFalse);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Светлая'));
    await tester.pumpAndSettle();
    expect(host.provider.preference, AppThemePreference.light);
    expect(store.value, AppThemePreference.light);
    expect(chip('Светлая').selected, isTrue);

    await tester.scrollUntilVisible(
      find.text('О приложении'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('О приложении'), findsOneWidget);
    expect(find.text(AppStrings.appTitle), findsOneWidget);
    expect(find.text(AppStrings.appCreator), findsOneWidget);
    expect(find.text(AppStrings.appTagline), findsOneWidget);
    expect(find.text('Версия 1.0.0 (сборка 1)'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(MainMapScreen), findsOneWidget);
    expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);
    await _openThemeMenu(tester);
    expect(_checkedItem(tester).value, AppThemePreference.light);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact map keeps a 48 dp theme target without overlap', (
    tester,
  ) async {
    await _mountMap(tester, size: const Size(320, 480), textScale: 1.6);

    final themeButton = tester.getRect(
      find.byKey(const Key('theme_mode_button')),
    );
    expect(themeButton.width, greaterThanOrEqualTo(48));
    expect(themeButton.height, greaterThanOrEqualTo(48));
    expect(find.byTooltip('Тема оформления'), findsOneWidget);
    expect(find.byTooltip('Выбрать старт'), findsOneWidget);
    expect(find.byTooltip('Прогулка'), findsOneWidget);
    expect(find.byTooltip('Дополнительные действия'), findsOneWidget);

    final title = tester.getRect(find.text(AppStrings.appTitle));
    expect(title.right, lessThanOrEqualTo(themeButton.left));
    expect(find.text(AppStrings.appCreator), findsOneWidget);

    await _openThemeMenu(tester);
    expect(find.text('Тёмная'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
