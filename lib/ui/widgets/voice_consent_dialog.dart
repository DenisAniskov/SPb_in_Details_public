import 'package:flutter/material.dart';

/// Shown immediately before the first system-recognition session and from the
/// settings screen. It states the only thing this consent covers: Android's
/// speech service may process audio off-device, and the app never receives or
/// stores the recording.
const String voiceSystemConsentNotice =
    'Для распознавания речи используется системная служба Android. '
    'В зависимости от устройства она может использовать интернет и '
    'передавать аудио поставщику службы распознавания.\n\n'
    'Приложение не получает, не сохраняет и не отправляет аудиозапись '
    'на свой сервер. Без согласия текстовый поиск остаётся доступен.';

Future<bool> showVoiceConsentDialog(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Разрешить голосовой поиск?'),
      content: const SingleChildScrollView(
        child: Text(voiceSystemConsentNotice),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Не разрешать'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Согласен'),
        ),
      ],
    ),
  );
  return accepted == true;
}
