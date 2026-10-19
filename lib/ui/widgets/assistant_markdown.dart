import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:url_launcher/url_launcher.dart';

/// Markdown rendering for confirmed assistant answers only.
///
/// Safety contract:
/// - raw HTML/JavaScript is not interpreted (the package has no HTML renderer);
/// - remote images are never loaded: every image becomes a neutral notice;
/// - links are limited to http/https and require an explicit confirmation;
/// - opening a link never triggers an app action such as routing.
class AssistantMarkdown extends StatelessWidget {
  const AssistantMarkdown({super.key, required this.data, this.onOpenLink});

  final String data;

  /// Injection point for tests and hosts without a browser.
  final Future<bool> Function(Uri uri)? onOpenLink;

  static bool isAllowedLink(Uri uri) =>
      uri.scheme == 'http' || uri.scheme == 'https';

  MarkdownStyleSheet _style(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final base = MarkdownStyleSheet.fromTheme(theme);
    final body = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 14,
      height: 1.42,
      color: palette.textPrimary,
    );
    return base.copyWith(
      p: body,
      a: TextStyle(
        color: palette.primary,
        decoration: TextDecoration.underline,
        fontWeight: FontWeight.w600,
      ),
      em: TextStyle(fontStyle: FontStyle.italic, color: palette.textPrimary),
      strong: TextStyle(fontWeight: FontWeight.bold, color: palette.textPrimary),
      del: TextStyle(
        decoration: TextDecoration.lineThrough,
        color: palette.textSecondary,
      ),
      h1: theme.textTheme.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: palette.textPrimary,
      ),
      h2: theme.textTheme.titleMedium?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.bold,
        color: palette.textPrimary,
      ),
      h3: theme.textTheme.titleSmall?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.bold,
        color: palette.textPrimary,
      ),
      h4: body?.copyWith(fontWeight: FontWeight.bold),
      h5: body?.copyWith(fontWeight: FontWeight.w600),
      h6: body?.copyWith(fontWeight: FontWeight.w600),
      blockquote: body?.copyWith(color: palette.textSecondary),
      blockquoteDecoration: BoxDecoration(
        color: palette.surfaceVariant.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: palette.primary, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12.5,
        color: palette.textPrimary,
        backgroundColor: palette.surfaceVariant,
      ),
      codeblockDecoration: BoxDecoration(
        color: palette.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      codeblockPadding: const EdgeInsets.all(8),
      listBullet: body,
      listBulletPadding: const EdgeInsets.only(right: 6),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.divider)),
      ),
    );
  }

  Future<void> _confirmLink(BuildContext context, String? href) async {
    final raw = (href ?? '').trim();
    final uri = Uri.tryParse(raw);
    if (uri == null || !isAllowedLink(uri)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Ссылка имеет неподдерживаемый формат.'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Открыть внешнюю ссылку?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ссылка создана ИИ или ведёт на внешний сайт. '
                'Приложение не проверяет её содержимое.',
              ),
              const SizedBox(height: 8),
              SelectableText(uri.toString()),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Открыть'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    var opened = false;
    try {
      opened = await (onOpenLink?.call(uri) ??
          launchUrl(uri, mode: LaunchMode.externalApplication));
    } catch (_) {
      opened = false;
    }
    if (!context.mounted || opened) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Не удалось открыть ссылку')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return MarkdownBody(
      data: data,
      selectable: false,
      fitContent: true,
      onTapLink: (_, href, _) => _confirmLink(context, href),
      // Never fetch remote images from model output. This also avoids the
      // package's default NetworkImage path entirely.
      imageBuilder: (_, _, alt) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 15,
              color: palette.textMuted,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                alt == null || alt.trim().isEmpty
                    ? 'Изображение не загружается'
                    : 'Изображение не загружается: $alt',
                style: TextStyle(fontSize: 12, color: palette.textSecondary),
              ),
            ),
          ],
        ),
      ),
      styleSheet: _style(context),
    );
  }
}
