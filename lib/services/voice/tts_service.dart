import 'package:flutter_tts/flutter_tts.dart';
import 'package:smart_navigator_spb/services/voice/voice_settings.dart';

class TtsVoice {
  const TtsVoice({required this.name, required this.locale});

  final String name;
  final String locale;

  String get id => '$locale::$name';

  @override
  bool operator ==(Object other) =>
      other is TtsVoice && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);
}

class TtsAvailability {
  const TtsAvailability({
    required this.available,
    this.voices = const [],
    this.message,
  });

  final bool available;
  final List<TtsVoice> voices;
  final String? message;
}

class TtsException implements Exception {
  const TtsException(this.message);
  final String message;

  @override
  String toString() => message;
}

abstract interface class VoiceSpeaker {
  Future<void> speak(
    String text, {
    required double rate,
    String? voiceName,
    String? voiceLocale,
  });
  Future<void> stop();
}

/// Navigation speech is rendered by the platform TTS engine through the
/// official Android TextToSpeech API exposed by flutter_tts. No cloud voice
/// service is involved.
abstract interface class TtsService implements VoiceSpeaker {
  Future<TtsAvailability> initialize();
  Future<void> dispose();
}

class FlutterTtsService implements TtsService {
  FlutterTtsService({FlutterTts? engine}) : _tts = engine ?? FlutterTts();

  final FlutterTts _tts;
  bool _initialized = false;
  bool _available = false;

  @override
  Future<TtsAvailability> initialize() async {
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setQueueMode(0);
      await _tts.setPitch(1.0);
      await _tts.setLanguage('ru-RU');
      final language = await _tts.isLanguageAvailable('ru-RU');
      final available = language == true || language == 1;
      final voices = <TtsVoice>[];
      try {
        final rawVoices = await _tts.getVoices;
        if (rawVoices is List) {
          for (final raw in rawVoices) {
            if (raw is! Map) continue;
            final name = raw['name']?.toString().trim() ?? '';
            final locale = raw['locale']?.toString().trim() ?? '';
            if (name.isEmpty || locale.isEmpty) continue;
            if (!locale.toLowerCase().startsWith('ru')) continue;
            final voice = TtsVoice(name: name, locale: locale);
            if (!voices.contains(voice)) voices.add(voice);
          }
        }
      } catch (_) {
        // Some engines expose no voice list; the language check still counts.
      }
      _initialized = true;
      _available = available;
      return TtsAvailability(
        available: available,
        voices: List.unmodifiable(voices),
        message: available
            ? null
            : 'Русский голос не установлен. Текстовая навигация работает '
                  'без озвучивания.',
      );
    } catch (_) {
      return const TtsAvailability(
        available: false,
        message:
            'Синтез речи недоступен на этом устройстве. '
            'Текстовая навигация работает без озвучивания.',
      );
    }
  }

  @override
  Future<void> speak(
    String text, {
    required double rate,
    String? voiceName,
    String? voiceLocale,
  }) async {
    if (!_initialized || !_available) {
      final readiness = await initialize();
      if (!readiness.available) {
        throw TtsException(readiness.message ?? 'Русский голос недоступен.');
      }
    }
    try {
      await _tts.stop();
      final name = voiceName?.trim();
      final locale = voiceLocale?.trim();
      if (name != null &&
          name.isNotEmpty &&
          locale != null &&
          locale.isNotEmpty) {
        await _tts.setVoice({'name': name, 'locale': locale});
      } else {
        await _tts.setLanguage('ru-RU');
      }
      await _tts.setSpeechRate(
        rate.clamp(VoiceSettings.minRate, VoiceSettings.maxRate),
      );
      await _tts.speak(text, focus: true);
    } catch (error) {
      throw TtsException('Не удалось озвучить подсказку: $error');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Stopping an idle engine is harmless.
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
  }
}
