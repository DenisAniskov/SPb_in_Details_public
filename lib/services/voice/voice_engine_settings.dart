import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persisted consent for the single Android system speech recognizer.
///
/// Android chooses which recognizer implementation to use; this record only
/// says whether the user allowed that service to process speech, including a
/// possible network transfer to the device's speech provider. A missing record
/// is never consent.
///
/// Versions 1 and 2 also stored the now-removed on-device/online engine choice.
/// Only their explicit `onlineConsent` flag is migrated; a former offline
/// selection is never treated as consent to network processing.
class VoiceEngineSettings {
  const VoiceEngineSettings({this.onlineConsent = false});

  static const VoiceEngineSettings defaults = VoiceEngineSettings();

  /// Explicit informed consent for the system recognizer, which may upload
  /// audio to the provider configured on the device. Never enabled by default.
  final bool onlineConsent;

  VoiceEngineSettings copyWith({bool? onlineConsent}) =>
      VoiceEngineSettings(onlineConsent: onlineConsent ?? this.onlineConsent);

  Map<String, Object?> toJson() => {
    'version': 3,
    'onlineConsent': onlineConsent,
  };

  factory VoiceEngineSettings.fromJson(Object? value) {
    if (value is! Map) return defaults;
    final version = value['version'];
    if (version != 1 && version != 2 && version != 3) return defaults;
    return VoiceEngineSettings(onlineConsent: value['onlineConsent'] == true);
  }
}

abstract interface class VoiceEngineSettingsStore {
  Future<VoiceEngineSettings> load();
  Future<void> save(VoiceEngineSettings settings);
}

/// Separate storage key: the guest envelope, favorites, TTS preferences and
/// AI consent remain untouched.
class SharedPreferencesVoiceEngineSettingsStore
    implements VoiceEngineSettingsStore {
  static const String storageKey = 'smartnavigator.voice_search';

  Future<SharedPreferences>? _preferences;

  Future<SharedPreferences> get _instance =>
      _preferences ??= SharedPreferences.getInstance();

  @override
  Future<VoiceEngineSettings> load() async {
    try {
      final preferences = await _instance;
      final raw = preferences.getString(storageKey);
      if (raw == null) return VoiceEngineSettings.defaults;
      final decoded = jsonDecode(raw);
      final settings = VoiceEngineSettings.fromJson(decoded);
      // Persist the canonical record once so the removed engine choice cannot
      // reappear on a later launch. Failure to rewrite does not lose the
      // already-normalized in-memory value.
      final canonical = jsonEncode(settings.toJson());
      final needsRewrite =
          decoded is! Map ||
          decoded['version'] != 3 ||
          decoded['onlineConsent'] != settings.onlineConsent ||
          decoded.containsKey('choice');
      if (needsRewrite) {
        try {
          await preferences.setString(storageKey, canonical);
        } catch (_) {
          // The user still gets the safe value for this session.
        }
      }
      return settings;
    } catch (_) {
      return VoiceEngineSettings.defaults;
    }
  }

  @override
  Future<void> save(VoiceEngineSettings settings) async {
    final saved = await (await _instance).setString(
      storageKey,
      jsonEncode(settings.toJson()),
    );
    if (!saved) {
      throw StateError('Не удалось сохранить согласие на распознавание.');
    }
  }
}
