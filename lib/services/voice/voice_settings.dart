import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Local-only TTS preferences. They live under a separate SharedPreferences
/// key, so the existing `smartnavigator.guest` envelope, favorites and
/// onboarding state remain byte-for-byte compatible.
class VoiceSettings {
  const VoiceSettings({
    this.enabled = false,
    this.rate = 0.5,
    this.voiceName,
    this.voiceLocale,
  });

  static const double minRate = 0.35;
  static const double maxRate = 0.75;
  static const VoiceSettings defaults = VoiceSettings();

  final bool enabled;
  final double rate;
  final String? voiceName;
  final String? voiceLocale;

  VoiceSettings copyWith({
    bool? enabled,
    double? rate,
    String? voiceName,
    String? voiceLocale,
    bool clearVoice = false,
  }) => VoiceSettings(
    enabled: enabled ?? this.enabled,
    rate: rate ?? this.rate,
    voiceName: clearVoice ? null : (voiceName ?? this.voiceName),
    voiceLocale: clearVoice ? null : (voiceLocale ?? this.voiceLocale),
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'enabled': enabled,
    'rate': rate,
    'voiceName': voiceName,
    'voiceLocale': voiceLocale,
  };

  factory VoiceSettings.fromJson(Object? value) {
    if (value is! Map) return defaults;
    if (value['version'] != 1) return defaults;
    final enabled = value['enabled'];
    final rate = value['rate'];
    final voiceName = value['voiceName'];
    final voiceLocale = value['voiceLocale'];
    if (enabled is! bool ||
        rate is! num ||
        !rate.isFinite ||
        (voiceName != null && voiceName is! String) ||
        (voiceLocale != null && voiceLocale is! String)) {
      return defaults;
    }
    final safeRate = rate.toDouble();
    return VoiceSettings(
      enabled: enabled,
      rate: safeRate.clamp(minRate, maxRate),
      voiceName: (voiceName as String?)?.trim().isEmpty ?? true
          ? null
          : (voiceName as String).trim(),
      voiceLocale: (voiceLocale as String?)?.trim().isEmpty ?? true
          ? null
          : (voiceLocale as String).trim(),
    );
  }
}

abstract interface class VoiceSettingsStore {
  Future<VoiceSettings> load();
  Future<void> save(VoiceSettings settings);
}

class SharedPreferencesVoiceSettingsStore implements VoiceSettingsStore {
  static const String storageKey = 'smartnavigator.voice';

  SharedPreferencesVoiceSettingsStore();

  Future<SharedPreferences>? _preferences;

  Future<SharedPreferences> get _instance =>
      _preferences ??= SharedPreferences.getInstance();

  @override
  Future<VoiceSettings> load() async {
    try {
      final raw = (await _instance).getString(storageKey);
      if (raw == null) return VoiceSettings.defaults;
      // A corrupted value falls back to the safe default (voice output off)
      // instead of rejecting the whole settings screen.
      return VoiceSettings.fromJson(jsonDecode(raw));
    } catch (_) {
      return VoiceSettings.defaults;
    }
  }

  @override
  Future<void> save(VoiceSettings settings) async {
    final saved = await (await _instance).setString(
      storageKey,
      jsonEncode(settings.toJson()),
    );
    if (!saved) {
      throw StateError('Не удалось сохранить настройки голоса.');
    }
  }
}
