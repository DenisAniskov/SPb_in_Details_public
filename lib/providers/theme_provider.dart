import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-visible appearance preference. It is deliberately independent of the
/// guest, favorites, voice and AI-consent preferences.
enum AppThemePreference { system, light, dark }

extension AppThemePreferenceX on AppThemePreference {
  ThemeMode get themeMode => switch (this) {
    AppThemePreference.system => ThemeMode.system,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };

  String get storageValue => switch (this) {
    AppThemePreference.system => 'system',
    AppThemePreference.light => 'light',
    AppThemePreference.dark => 'dark',
  };

  String get label => switch (this) {
    AppThemePreference.system => 'Системная',
    AppThemePreference.light => 'Светлая',
    AppThemePreference.dark => 'Тёмная',
  };

  static AppThemePreference? fromStorage(String? value) => switch (value) {
    'system' => AppThemePreference.system,
    'light' => AppThemePreference.light,
    'dark' => AppThemePreference.dark,
    _ => null,
  };
}

/// Small, non-sensitive preference store. The key is separate from
/// `smartnavigator.guest`, favorites, voice settings and AI consent.
abstract interface class ThemePreferenceStore {
  Future<AppThemePreference?> read();
  Future<void> write(AppThemePreference preference);
}

class SharedPreferencesThemePreferenceStore implements ThemePreferenceStore {
  static const String storageKey = 'smartnavigator.theme_mode';

  @override
  Future<AppThemePreference?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return AppThemePreferenceX.fromStorage(prefs.getString(storageKey));
  }

  @override
  Future<void> write(AppThemePreference preference) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, preference.storageValue);
  }
}

/// Applies a manually selected theme immediately. The default is the system
/// theme, exactly like the previous `ThemeMode.system` behavior.
class ThemeProvider extends ChangeNotifier {
  ThemeProvider({ThemePreferenceStore? store})
    : _store = store ?? SharedPreferencesThemePreferenceStore() {
    _load();
  }

  final ThemePreferenceStore _store;
  AppThemePreference _preference = AppThemePreference.system;
  bool _loading = true;
  bool _persistenceFailed = false;
  bool _disposed = false;

  AppThemePreference get preference => _preference;
  ThemeMode get themeMode => _preference.themeMode;
  bool get loading => _loading;
  bool get persistenceFailed => _persistenceFailed;

  Future<void> _load() async {
    AppThemePreference? stored;
    try {
      stored = await _store.read();
    } catch (_) {
      // A broken local store falls back to the system theme.
      stored = null;
    }
    if (_disposed) return;
    if (stored != null) _preference = stored;
    _loading = false;
    notifyListeners();
  }

  Future<void> setPreference(AppThemePreference preference) async {
    if (_disposed || preference == _preference) return;
    _preference = preference;
    _persistenceFailed = false;
    notifyListeners();
    try {
      await _store.write(preference);
    } catch (_) {
      if (_disposed) return;
      _persistenceFailed = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
