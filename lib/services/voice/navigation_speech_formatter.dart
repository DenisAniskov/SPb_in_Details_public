/// Converts the UI distance prefix into words that a Russian TTS engine reads
/// naturally. The verified maneuver itself is never changed.
class NavigationSpeechFormatter {
  NavigationSpeechFormatter._();

  static final RegExp _prefix = RegExp(
    r'^Через ([0-9]+(?:[,.][0-9]+)?) (км|м) (.+)$',
    unicode: true,
  );

  static String forSpeech(String instruction) {
    final match = _prefix.firstMatch(instruction.trim());
    if (match == null) return instruction;
    final raw = match.group(1)!;
    final unit = match.group(2)!;
    final rest = match.group(3)!;
    if (unit == 'м') {
      final value = int.tryParse(raw);
      if (value == null) return instruction;
      return 'Через $raw ${_meterWord(value)} $rest';
    }
    if (raw.endsWith(',0')) {
      final value = int.tryParse(raw.substring(0, raw.length - 2));
      if (value != null) {
        return 'Через $value ${_kilometerWord(value)} $rest';
      }
    }
    return 'Через $raw километра $rest';
  }

  static String _meterWord(int value) {
    final mod10 = value % 10;
    final mod100 = value % 100;
    if (mod10 == 1 && mod100 != 11) return 'метр';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'метра';
    }
    return 'метров';
  }

  static String _kilometerWord(int value) {
    final mod10 = value % 10;
    final mod100 = value % 100;
    if (mod10 == 1 && mod100 != 11) return 'километр';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'километра';
    }
    return 'километров';
  }
}
