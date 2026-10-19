import 'package:shared_preferences/shared_preferences.dart';

/// Local-only record of the accepted AI privacy notice.
///
/// Only the notice version is stored; questions, answers and the access code
/// are never written here. The key namespace is intentionally separate from
/// `smartnavigator.guest` so clearing guest preferences cannot silently grant
/// or revoke AI consent.
abstract class AssistantConsentStore {
  static const String currentVersion = 'smartnavigator.ai_consent.v1';

  Future<String?> readAcceptedVersion();

  Future<void> accept(String version);

  Future<void> revoke();
}

class SharedPreferencesAssistantConsentStore implements AssistantConsentStore {
  static const String _namespace = 'smartnavigator.ai_consent';

  Future<SharedPreferences>? _preferences;

  Future<SharedPreferences> get _instance =>
      _preferences ??= SharedPreferences.getInstance();

  @override
  Future<String?> readAcceptedVersion() async {
    final preferences = await _instance;
    // A stale version is not accepted: material privacy changes must ask again.
    final value = preferences.getString(AssistantConsentStore.currentVersion);
    return value == 'accepted' ? AssistantConsentStore.currentVersion : null;
  }

  @override
  Future<void> accept(String version) async {
    final preferences = await _instance;
    await preferences.setString(version, 'accepted');
  }

  @override
  Future<void> revoke() async {
    final preferences = await _instance;
    final keys = preferences
        .getKeys()
        .where((key) => key.startsWith(_namespace))
        .toList();
    for (final key in keys) {
      await preferences.remove(key);
    }
  }
}
