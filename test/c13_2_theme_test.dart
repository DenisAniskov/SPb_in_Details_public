import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/theme_provider.dart';
import 'package:smart_navigator_spb/ui/screens/guest_settings_screen.dart';

class _MemoryPreferenceStore implements ThemePreferenceStore {
  _MemoryPreferenceStore({this.value, this.failRead = false});

  AppThemePreference? value;
  bool failRead;
  bool failWrite = false;
  int writes = 0;

  @override
  Future<AppThemePreference?> read() async {
    if (failRead) throw StateError('read failed');
    return value;
  }

  @override
  Future<void> write(AppThemePreference preference) async {
    if (failWrite) throw StateError('write failed');
    writes++;
    value = preference;
  }
}

class _MemoryStorage implements GuestKeyValueStore {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }
}

class _Catalogue extends PlacesRepository {
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async => const [];

  @override
  Future<List<CategoryModel>> getCategories() async => const [];
}

void main() {
  test('defaults to the system theme and applies a stored choice', () async {
    final defaults = ThemeProvider(store: _MemoryPreferenceStore());
    addTearDown(defaults.dispose);
    await pumpEventQueue();
    expect(defaults.preference, AppThemePreference.system);
    expect(defaults.themeMode, ThemeMode.system);

    final store = _MemoryPreferenceStore(value: AppThemePreference.dark);
    final provider = ThemeProvider(store: store);
    addTearDown(provider.dispose);
    await pumpEventQueue();
    expect(provider.preference, AppThemePreference.dark);
    expect(provider.themeMode, ThemeMode.dark);
  });

  test('persists the manual choice and reports a write failure', () async {
    final store = _MemoryPreferenceStore();
    final provider = ThemeProvider(store: store);
    addTearDown(provider.dispose);
    await pumpEventQueue();

    await provider.setPreference(AppThemePreference.light);
    expect(provider.themeMode, ThemeMode.light);
    expect(store.value, AppThemePreference.light);
    expect(provider.persistenceFailed, isFalse);

    store.failWrite = true;
    await provider.setPreference(AppThemePreference.dark);
    expect(provider.themeMode, ThemeMode.dark);
    expect(provider.persistenceFailed, isTrue);
  });

  test('a read failure falls back to system without blocking startup', () async {
    final provider = ThemeProvider(
      store: _MemoryPreferenceStore(failRead: true),
    );
    addTearDown(provider.dispose);
    await pumpEventQueue();
    expect(provider.preference, AppThemePreference.system);
    expect(provider.loading, isFalse);
  });

  test('uses a separate SharedPreferences key and leaves other data intact',
      () async {
    SharedPreferences.setMockInitialValues({
      'smartnavigator.guest': '{"favorites":[1]}',
      'smartnavigator.voice': '{"enabled":true}',
      'smartnavigator.ai_consent.v1': 'accepted',
      'smartnavigator.theme_mode': 'dark',
    });
    final store = SharedPreferencesThemePreferenceStore();
    expect(await store.read(), AppThemePreference.dark);
    await store.write(AppThemePreference.light);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('smartnavigator.theme_mode'), 'light');
    expect(prefs.getString('smartnavigator.guest'), '{"favorites":[1]}');
    expect(prefs.getString('smartnavigator.voice'), '{"enabled":true}');
    expect(prefs.getString('smartnavigator.ai_consent.v1'), 'accepted');
  });

  testWidgets('switch applies immediately without an app restart', (
    tester,
  ) async {
    final provider = ThemeProvider(store: _MemoryPreferenceStore());
    addTearDown(provider.dispose);
    late Brightness brightness;
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>.value(
        value: provider,
        child: Consumer<ThemeProvider>(
          builder: (context, theme, _) => MaterialApp(
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: theme.themeMode,
            home: Builder(
              builder: (context) {
                brightness = Theme.of(context).brightness;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(brightness, Brightness.light);
    await provider.setPreference(AppThemePreference.dark);
    await tester.pumpAndSettle();
    expect(brightness, Brightness.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings expose the three appearance choices', (tester) async {
    final store = _MemoryPreferenceStore();
    final provider = ThemeProvider(store: store);
    addTearDown(provider.dispose);
    final guest = GuestExperienceProvider(
      store: JsonGuestLocalStore(storage: _MemoryStorage()),
      repository: _Catalogue(),
      catalogScope: 'test',
    );
    await guest.initialize();
    addTearDown(guest.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
          ChangeNotifierProvider<ThemeProvider>.value(value: provider),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const GuestSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Оформление'), findsOneWidget);
    expect(find.text('Системная'), findsOneWidget);
    expect(find.text('Светлая'), findsOneWidget);
    expect(find.text('Тёмная'), findsOneWidget);

    await tester.tap(find.text('Тёмная'));
    await tester.pump();
    expect(store.value, AppThemePreference.dark);
    expect(tester.takeException(), isNull);
  });
}
