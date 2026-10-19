/// Narrow, deterministic cleanup of spoken search phrasing. It removes only
/// explicit search lead-ins; the landmark name itself is never rewritten or
/// guessed, and no command engine is involved.
class VoiceQueryNormalizer {
  VoiceQueryNormalizer._();

  static final RegExp _leadIn = RegExp(
    r'^(?:пожалуйста[,\s]+)?'
    r'(?:найди(?:те)?|найти|где\s+находится|где\s+найти|'
    r'покажи(?:те)?|показать|подскажи(?:те)?)'
    r'[,:\s]+',
    caseSensitive: false,
    unicode: true,
  );

  static String normalize(String input) {
    var text = input.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '';
    // A second lead-in appears in speech such as «подскажи, где находится …».
    for (var pass = 0; pass < 2; pass++) {
      final next = text.replaceFirst(_leadIn, '').trim();
      if (next == text) break;
      text = next;
    }
    return text;
  }
}
