import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/services/voice/navigation_voice_coordinator.dart';
import 'package:smart_navigator_spb/services/voice/tts_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_settings.dart';

/// Owns the local voice preferences and the navigation speech coordinator.
/// Speech is off by default, never starts without a Russian engine, and a
/// failure here never affects textual navigation.
class TtsProvider extends ChangeNotifier {
  TtsProvider({
    required TtsService service,
    required VoiceSettingsStore store,
    required NavigationProvider navigation,
    // Public dependency names are part of the injection contract.
    // ignore: prefer_initializing_formals
  }) : _service = service,
       // ignore: prefer_initializing_formals
       _store = store,
       // ignore: prefer_initializing_formals
       _navigation = navigation,
       _coordinator = NavigationVoiceCoordinator(speaker: service) {
    _navigation.addListener(_onNavigation);
  }

  final TtsService _service;
  final VoiceSettingsStore _store;
  final NavigationProvider _navigation;
  final NavigationVoiceCoordinator _coordinator;

  VoiceSettings _settings = VoiceSettings.defaults;
  TtsAvailability? _availability;
  String? _errorMessage;
  String? _voiceNotice;
  bool _ready = false;
  bool _suspended = false;
  bool _disposed = false;
  Future<void>? _initializing;

  bool _narrationActive = false;
  String? _narrationError;
  int _narrationToken = 0;

  bool get ready => _ready;
  bool get available => _availability?.available ?? false;
  bool get enabled => _settings.enabled && available;

  /// C14: optional story playback through the same Android engine as
  /// navigation speech. It never starts by itself and never runs at the same
  /// time as another phrase: [TtsService.speak] stops the previous utterance
  /// first.
  bool get isNarrating => _narrationActive;
  String? get narrationError => _narrationError;
  bool get canNarrate => _ready && available && !_suspended;
  bool get configuredEnabled => _settings.enabled;
  double get rate => _settings.rate;
  List<TtsVoice> get voices => _availability?.voices ?? const [];
  String? get errorMessage => _errorMessage ?? _availability?.message;
  String? get voiceNotice => _voiceNotice;

  TtsVoice? get selectedVoice {
    final name = _settings.voiceName;
    final locale = _settings.voiceLocale;
    if (name == null || locale == null) return null;
    for (final voice in voices) {
      if (voice.name == name && voice.locale == locale) return voice;
    }
    return null;
  }

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    VoiceSettings settings;
    try {
      settings = await _store.load();
    } catch (_) {
      settings = VoiceSettings.defaults;
      _errorMessage =
          'Не удалось прочитать настройки голоса. '
          'Озвучивание выключено до изменения настройки.';
    }
    TtsAvailability availability;
    try {
      availability = await _service.initialize();
    } catch (_) {
      availability = const TtsAvailability(
        available: false,
        message:
            'Синтез речи недоступен на этом устройстве. '
            'Текстовая навигация работает без озвучивания.',
      );
    }
    if (_disposed) return;
    _settings = settings;
    _availability = availability;
    if (settings.voiceName != null && settings.voiceLocale != null) {
      final known = availability.voices.any(
        (voice) =>
            voice.name == settings.voiceName &&
            voice.locale == settings.voiceLocale,
      );
      if (availability.voices.isNotEmpty && !known) {
        _settings = _settings.copyWith(clearVoice: true);
        _voiceNotice =
            'Ранее выбранный голос больше не установлен. '
            'Используется русский голос по умолчанию.';
        unawaited(_persist());
      }
    }
    _coordinator.applySettings(_settings);
    _ready = true;
    notifyListeners();
    _onNavigation();
  }

  Future<bool> setEnabled(bool value) async {
    if (!_ready) return false;
    if (value && !available) {
      _errorMessage =
          _availability?.message ??
          'Русский голос не установлен. Текстовая навигация работает '
              'без озвучивания.';
      notifyListeners();
      return false;
    }
    if (_settings.enabled == value) return true;
    _settings = _settings.copyWith(enabled: value);
    _coordinator.applySettings(_settings);
    _errorMessage = null;
    notifyListeners();
    if (value) _onNavigation();
    await _persist();
    return true;
  }

  Future<bool> toggle() => setEnabled(!enabled);

  Future<void> setRate(double value) async {
    if (!_ready) return;
    final next = value.clamp(VoiceSettings.minRate, VoiceSettings.maxRate);
    if ((next - _settings.rate).abs() < 0.0001) return;
    _settings = _settings.copyWith(rate: next);
    _coordinator.applySettings(_settings);
    notifyListeners();
    await _persist();
  }

  Future<void> selectVoice(TtsVoice? voice) async {
    if (!_ready) return;
    _settings = voice == null
        ? _settings.copyWith(clearVoice: true)
        : _settings.copyWith(voiceName: voice.name, voiceLocale: voice.locale);
    _coordinator.applySettings(_settings);
    _voiceNotice = null;
    notifyListeners();
    await _persist();
  }

  Future<bool> speakTest() async {
    if (!available) {
      _errorMessage =
          _availability?.message ??
          'Русский голос не установлен. Озвучивание недоступно.';
      notifyListeners();
      return false;
    }
    try {
      await _service.speak(
        'Через сто метров поверните налево.',
        rate: _settings.rate,
        voiceName: _settings.voiceName,
        voiceLocale: _settings.voiceLocale,
      );
      _errorMessage = null;
      notifyListeners();
      return true;
    } catch (_) {
      _errorMessage = 'Не удалось воспроизвести пример озвучивания.';
      notifyListeners();
      return false;
    }
  }

  /// C14: explicit user action only. The story is read by the same local TTS
  /// engine and the same Russian voice preference as navigation. No network
  /// request, no audio file and no automatic playback are involved.
  ///
  /// Returns false with [narrationError] when the engine is missing, the app
  /// is backgrounded/in recognition, or synthesis fails. A navigation phrase
  /// may interrupt the story (the platform stops the previous utterance), so
  /// navigation keeps priority without two voices speaking at once.
  Future<bool> speakNarration(String text) async {
    if (_disposed) return false;
    final normalized = text.trim();
    if (normalized.isEmpty) {
      _narrationError = 'Текст истории пуст.';
      notifyListeners();
      return false;
    }
    if (!_ready) {
      await initialize();
      if (_disposed) return false;
    }
    if (_suspended) {
      _narrationError = 'Озвучивание временно недоступно. Попробуйте позже.';
      notifyListeners();
      return false;
    }
    if (!available) {
      _narrationError =
          _availability?.message ??
          'Русский голос не установлен. Озвучивание недоступно.';
      notifyListeners();
      return false;
    }
    if (_narrationActive) await stopNarration();
    if (_disposed) return false;

    final token = ++_narrationToken;
    _narrationActive = true;
    _narrationError = null;
    notifyListeners();
    try {
      await _service.speak(
        normalized,
        rate: _settings.rate,
        voiceName: _settings.voiceName,
        voiceLocale: _settings.voiceLocale,
      );
      if (_disposed || token != _narrationToken) return true;
      _narrationActive = false;
      notifyListeners();
      return true;
    } catch (_) {
      if (_disposed || token != _narrationToken) return false;
      _narrationActive = false;
      _narrationError =
          'Не удалось озвучить историю. Проверьте голосовой движок.';
      notifyListeners();
      return false;
    }
  }

  /// Stops only the story. Navigation speech is left untouched when the story
  /// is already finished.
  Future<void> stopNarration() async {
    if (_disposed || !_narrationActive) return;
    ++_narrationToken;
    _narrationActive = false;
    _narrationError = null;
    notifyListeners();
    try {
      await _service.stop();
    } catch (_) {
      // Stopping an idle or unavailable engine is harmless.
    }
  }

  /// Stops current speech and suppresses new phrases while the microphone is
  /// active, so the app's own voice cannot be captured.
  void pauseForRecognition() {
    if (_disposed) return;
    if (_narrationActive) unawaited(stopNarration());
    _suspended = true;
    _coordinator.pauseForRecognition();
  }

  void resumeAfterRecognition() {
    if (_disposed) return;
    _suspended = false;
    _coordinator.resumeAfterRecognition();
    _onNavigation();
  }

  /// Called when the app leaves the foreground. Speech must not continue from
  /// a background screen, and the navigation pause notification must not be
  /// announced into an empty room.
  void suspendForAppLifecycle() {
    if (_disposed) return;
    if (_narrationActive) unawaited(stopNarration());
    _suspended = true;
    _coordinator.pauseForRecognition();
  }

  void resumeAfterAppLifecycle() {
    if (_disposed) return;
    _suspended = false;
    _coordinator.resumeAfterRecognition();
    _onNavigation();
  }

  void _onNavigation() {
    if (!_ready || _disposed) return;
    if (!enabled || _suspended) return;
    _coordinator.onNavigation(
      state: _navigation.state,
      guidance: _navigation.guidance,
    );
  }

  Future<void> _persist() async {
    try {
      await _store.save(_settings);
    } catch (_) {
      if (_disposed) return;
      _errorMessage =
          'Настройки голоса не сохранились на устройстве. '
          'Они действуют до закрытия приложения.';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _navigation.removeListener(_onNavigation);
    _coordinator.dispose();
    unawaited(_service.dispose());
    super.dispose();
  }
}
