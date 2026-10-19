import 'package:flutter/material.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:url_launcher/url_launcher.dart';

void showSourceLicensesDialog(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (_) => const SourceLicensesDialog(),
  );
}

class SourceAttribution extends StatelessWidget {
  const SourceAttribution({super.key});

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => showSourceLicensesDialog(context),
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      foregroundColor: AppPalette.of(context).textMuted,
      textStyle: const TextStyle(fontSize: 11),
    ),
    child: const Text(
      'Места: © OpenStreetMap contributors • Карты: Яндекс',
      textAlign: TextAlign.center,
    ),
  );
}

class SourceLicensesDialog extends StatelessWidget {
  const SourceLicensesDialog({super.key, this.openLink});

  final Future<bool> Function(Uri)? openLink;

  static final osmCopyright = Uri.parse(
    'https://www.openstreetmap.org/copyright',
  );
  static final odbl = Uri.parse(
    'https://opendatacommons.org/licenses/odbl/1-0/',
  );
  static final yandexTerms = Uri.parse(
    'https://yandex.ru/legal/maps_termsofuse/',
  );

  Future<void> _open(BuildContext context, Uri uri) async {
    var launched = false;
    try {
      launched =
          await (openLink?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
    } catch (_) {
      // The selectable URL remains available when the device has no browser.
    }
    if (!context.mounted || launched) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Не удалось открыть ссылку')));
  }

  Widget _link(BuildContext context, String label, Uri uri) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextButton(onPressed: () => _open(context, uri), child: Text(label)),
      SelectableText(uri.toString(), style: const TextStyle(fontSize: 11)),
    ],
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Источники и условия'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Места: © OpenStreetMap contributors. '
            'Данные каталога — по лицензии ODbL 1.0. '
            'Описания и время осмотра — редакторские материалы приложения.',
          ),
          _link(context, 'OpenStreetMap: источники и лицензия', osmCopyright),
          _link(context, 'Open Database License 1.0', odbl),
          const SizedBox(height: 12),
          const Text(
            'Картографическая основа и пешеходные маршруты '
            'предоставляются сервисом Яндекс.Карты.',
          ),
          _link(
            context,
            'Условия использования сервиса Яндекс.Карты',
            yandexTerms,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Понятно'),
      ),
    ],
  );
}
