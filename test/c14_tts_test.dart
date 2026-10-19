import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/tts_provider.dart';
import 'package:smart_navigator_spb/services/voice/tts_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_settings.dart';

class _NarrationTts implements TtsService {
  TtsAvailability availability = const TtsAvailability(
    available: true,
    voices: [TtsVoice(name: 'ru-alpha', locale: 'ru-RU')],
  );
  final List<String> spoken = [];
  final List<double> rates = [];
  Completer<void>? pending;
  int stops = 0;
  int disposes = 0;

  @override
  Future<TtsAvailability> initialize() async => availability;

  @override
  Future<void> speak(
    String text, {
    required double rate,
    String? voiceName,
    String? voiceLocale,
  }) async {
    spoken.add(text);
    rates.add(rate);
    final gate = pending;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    final gate = pending;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> dispose() async {
    disposes++;
  }
}

class _MemoryVoiceStore implements VoiceSettingsStore {
  VoiceSettings settings = const VoiceSettings(enabled: false, rate: 0.58);

  @override
  Future<VoiceSettings> load() async => settings;

  @override
  Future<void> save(VoiceSettings settings) async {
    this.settings = settings;
  }
}

void main() {
  group('TtsProvider narration', () {
    late _NarrationTts service;
    late NavigationProvider navigation;
    late TtsProvider provider;

    setUp(() async {
      service = _NarrationTts();
      navigation = NavigationProvider();
      provider = TtsProvider(
        service: service,
        store: _MemoryVoiceStore(),
        navigation: navigation,
      );
      await provider.initialize();
    });

    tearDown(() {
      final gate = service.pending;
      if (gate != null && !gate.isCompleted) gate.complete();
      provider.dispose();
      navigation.dispose();
    });

    test('is active only while the story is actually being spoken', () async {
      service.pending = Completer<void>();

      final spoken = provider.speakNarration('Короткая история места.');
      await Future<void>.delayed(Duration.zero);

      expect(provider.isNarrating, isTrue);
      expect(service.spoken, ['Короткая история места.']);
      expect(provider.narrationError, isNull);

      service.pending!.complete();
      await spoken;

      expect(provider.isNarrating, isFalse);
    });

    test('stop ends the story and reports idle immediately', () async {
      service.pending = Completer<void>();
      final stopsBefore = service.stops;

      final spoken = provider.speakNarration('История.');
      await Future<void>.delayed(Duration.zero);
      expect(provider.isNarrating, isTrue);

      await provider.stopNarration();
      await spoken;

      expect(provider.isNarrating, isFalse);
      expect(service.stops, stopsBefore + 1);
    });

    test('uses the user rate and the same local engine', () async {
      await provider.setRate(0.72);

      expect(await provider.speakNarration('История.'), isTrue);
      expect(service.rates.single, closeTo(0.72, 0.0001));
      expect(service.spoken.single, 'История.');
    });

    test('an unavailable Russian engine fails softly', () async {
      final unavailableService = _NarrationTts()
        ..availability = const TtsAvailability(
          available: false,
          message: 'Русский голос не установлен.',
        );
      final unavailableNavigation = NavigationProvider();
      final unavailable = TtsProvider(
        service: unavailableService,
        store: _MemoryVoiceStore(),
        navigation: unavailableNavigation,
      );
      await unavailable.initialize();

      expect(await unavailable.speakNarration('История.'), isFalse);
      expect(unavailable.isNarrating, isFalse);
      expect(unavailable.narrationError, contains('Русский голос'));
      expect(unavailableService.spoken, isEmpty);

      unavailable.dispose();
      unavailableNavigation.dispose();
    });

    test('leaving the foreground stops the story', () async {
      service.pending = Completer<void>();
      final stopsBefore = service.stops;

      final spoken = provider.speakNarration('История.');
      await Future<void>.delayed(Duration.zero);
      expect(provider.isNarrating, isTrue);

      provider.suspendForAppLifecycle();
      await spoken;

      expect(provider.isNarrating, isFalse);
      expect(service.stops, stopsBefore + 1);
    });

    test('empty text is rejected without touching the engine', () async {
      expect(await provider.speakNarration('   '), isFalse);
      expect(service.spoken, isEmpty);
      expect(provider.isNarrating, isFalse);
      expect(provider.narrationError, isNotNull);
    });

    test('dispose releases the same local engine', () async {
      final localService = _NarrationTts();
      final localNavigation = NavigationProvider();
      final local = TtsProvider(
        service: localService,
        store: _MemoryVoiceStore(),
        navigation: localNavigation,
      );
      await local.initialize();
      local.dispose();
      expect(localService.disposes, 1);
      localNavigation.dispose();
    });
  });
}
