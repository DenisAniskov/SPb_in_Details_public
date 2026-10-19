import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/services/voice/voice_search_controller.dart';
import 'package:smart_navigator_spb/ui/widgets/voice_consent_dialog.dart';

/// Compact microphone sheet. It reflects the controller state and returns the
/// confirmed query through Navigator; it never starts routing and never writes
/// the search field on its own.
class VoiceSearchSheet extends StatefulWidget {
  const VoiceSearchSheet({super.key});

  @override
  State<VoiceSearchSheet> createState() => _VoiceSearchSheetState();
}

class _VoiceSearchSheetState extends State<VoiceSearchSheet> {
  VoiceSearchState _lastState = VoiceSearchState.idle;
  bool _autoApplied = false;

  Future<void> _close(VoiceSearchController voice) async {
    await voice.cancel();
    voice.reset();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// C13.2: a successful normalized transcript is applied immediately. The
  /// sheet closes, the map fills the normal search field and the existing
  /// PlacesProvider/SearchProvider show results. Manual editing stays
  /// available in the ordinary search field.
  void _autoApply(VoiceSearchController voice) {
    if (_autoApplied) return;
    _autoApplied = true;
    final query = voice.confirm();
    if (query == null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(query);
    });
  }

  @override
  Widget build(BuildContext context) {
    final voice = context.watch<VoiceSearchController>();
    if (voice.state == VoiceSearchState.transcriptReady &&
        _lastState != VoiceSearchState.transcriptReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoApply(voice);
      });
    }
    if (voice.state != VoiceSearchState.transcriptReady) {
      _autoApplied = false;
    }
    _lastState = voice.state;
    final palette = AppPalette.of(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: palette.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Icon(Icons.mic, color: palette.primary),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Голосовой поиск',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  tooltip: 'Закрыть голосовой поиск',
                  onPressed: () => _close(voice),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _body(context, voice, palette),
            const SizedBox(height: 12),
            Text(
              _privacyText,
              style: TextStyle(fontSize: 11, color: palette.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    VoiceSearchController voice,
    AppPalette palette,
  ) {
    return switch (voice.state) {
      VoiceSearchState.requestingPermission => _progress(
        'Проверяем микрофон и системное распознавание…',
      ),
      VoiceSearchState.recording => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statusIcon(Icons.mic, 'Слушаю…', palette.primary),
          if (voice.partialTranscript.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: palette.surfaceVariant,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  voice.partialTranscript,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: voice.stop,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Готово'),
          ),
          const SizedBox(height: 4),
          const Text(
            'Назовите место или адрес. Когда закончите, нажмите «Готово».',
            textAlign: TextAlign.center,
          ),
          TextButton(
            onPressed: () => _close(voice),
            child: const Text('Отмена'),
          ),
        ],
      ),
      VoiceSearchState.recognizing => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _progress('Распознаём речь…'),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => _close(voice),
            child: const Text('Отмена'),
          ),
        ],
      ),
      VoiceSearchState.transcriptReady => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _message(
            voice.errorMessage.isEmpty
                ? 'Не удалось использовать распознанный запрос. '
                      'Повторите или найдите место вручную.'
                : voice.errorMessage,
            palette,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => _restart(voice),
            icon: const Icon(Icons.mic),
            label: const Text('Повторить'),
          ),
          TextButton(
            onPressed: () => _close(voice),
            child: const Text('Найти вручную'),
          ),
        ],
      ),
      VoiceSearchState.permissionDenied ||
      VoiceSearchState.permissionPermanentlyDenied => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _message(
            voice.errorMessage.isEmpty
                ? 'Микрофон недоступен. Можно найти место вручную.'
                : voice.errorMessage,
            palette,
          ),
          if (voice.state == VoiceSearchState.permissionPermanentlyDenied)
            OutlinedButton(
              onPressed: voice.openPermissionSettings,
              child: const Text('Открыть настройки приложения'),
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => _restart(voice),
            child: const Text('Попробовать снова'),
          ),
          TextButton(
            onPressed: () => _close(voice),
            child: const Text('Найти вручную'),
          ),
        ],
      ),
      VoiceSearchState.consentRequired => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _message(voiceSystemConsentNotice, palette),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => _grantConsentAndStart(voice),
            icon: const Icon(Icons.mic),
            label: const Text('Согласен и продолжить'),
          ),
          TextButton(
            onPressed: () => _close(voice),
            child: const Text('Найти вручную'),
          ),
        ],
      ),
      VoiceSearchState.modelUnavailable => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _message(
            voice.errorMessage.isEmpty
                ? 'Голосовое распознавание недоступно. '
                      'Можно найти место вручную.'
                : voice.errorMessage,
            palette,
          ),
          FilledButton(
            onPressed: () => _restart(voice),
            child: const Text('Попробовать снова'),
          ),
          TextButton(
            onPressed: () => _close(voice),
            child: const Text('Найти вручную'),
          ),
        ],
      ),
      VoiceSearchState.emptySpeech ||
      VoiceSearchState.recognitionFailed ||
      VoiceSearchState.timeout ||
      VoiceSearchState.cancelled => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _message(
            voice.errorMessage.isEmpty
                ? 'Не удалось распознать речь.'
                : voice.errorMessage,
            palette,
          ),
          FilledButton.icon(
            onPressed: () => _restart(voice),
            icon: const Icon(Icons.mic),
            label: const Text('Попробовать снова'),
          ),
          TextButton(
            onPressed: () => _close(voice),
            child: const Text('Найти вручную'),
          ),
        ],
      ),
      VoiceSearchState.idle => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Нажмите на микрофон, чтобы назвать место или адрес.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => _restart(voice),
            icon: const Icon(Icons.mic),
            label: const Text('Слушать'),
          ),
          TextButton(
            onPressed: () => _close(voice),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    };
  }

  Future<void> _restart(VoiceSearchController voice) async {
    _autoApplied = false;
    voice.reset();
    await voice.start();
  }

  Future<void> _grantConsentAndStart(VoiceSearchController voice) async {
    final saved = await voice.setOnlineConsent(true);
    if (!saved) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Не удалось сохранить согласие.')),
        );
      }
      return;
    }
    if (!mounted) return;
    await _restart(voice);
  }

  static const String _privacyText =
      'Системная служба Android вправе передать аудио поставщику службы '
      'распознавания. Приложение не получает, не сохраняет и не '
      'отправляет запись на свой сервер.';

  Widget _progress(String title) => Semantics(
    liveRegion: true,
    child: Column(
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 14),
        Text(title, textAlign: TextAlign.center),
      ],
    ),
  );

  Widget _statusIcon(IconData icon, String title, Color color) => Semantics(
    liveRegion: true,
    label: title,
    child: Column(
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 36, color: color),
        ),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  Widget _message(String message, AppPalette palette) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message),
    ),
  );
}
