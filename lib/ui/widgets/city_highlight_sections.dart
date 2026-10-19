import 'package:flutter/material.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/data/city_highlights/city_highlight_model.dart';
import 'package:smart_navigator_spb/providers/tts_provider.dart';

/// C14 compact blocks for one place card.
///
/// Every block is optional and rendered only with prepared data. The widget
/// deliberately adds no full-screen flow, no automatic sound and no empty
/// headers: an absent section is simply absent.
class CityHighlightSections extends StatelessWidget {
  const CityHighlightSections({
    super.key,
    required this.highlight,
    this.tts,
    this.onShowViewpoint,
  });

  final CityHighlight highlight;
  final TtsProvider? tts;
  final VoidCallback? onShowViewpoint;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final blocks = <Widget>[
      if (highlight.hasAttentionHints)
        _AttentionCard(hints: highlight.attentionHints),
      if (highlight.hasViewpoint)
        _ViewpointCard(
          viewpoint: highlight.viewpoint!,
          onShowOnMap: onShowViewpoint,
        ),
      if (highlight.hasShortStory)
        _StoryCard(story: highlight.shortStory!.trim(), tts: tts),
    ];
    if (blocks.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < blocks.length; index++) ...[
          if (index > 0) const SizedBox(height: 12),
          blocks[index],
        ],
        const SizedBox(height: 4),
        Text(
          'Подсказки и история — редакция приложения. '
          'Проверено ${_formatVerificationDate(highlight.verifiedOn)}.',
          style: TextStyle(
            fontSize: 11,
            height: 1.35,
            color: palette.textMuted,
          ),
        ),
      ],
    );
  }

  /// Keeps the data ISO date, but the card reads naturally in Russian.
  static String _formatVerificationDate(String isoDate) {
    final parts = isoDate.split('-');
    if (parts.length != 3) return isoDate;
    return '${parts[2]}.${parts[1]}.${parts[0]}';
  }
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({required this.hints});

  final List<String> hints;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = palette.accent;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            icon: Icons.visibility_outlined,
            title: 'Обрати внимание',
            color: color,
          ),
          for (var index = 0; index < hints.length; index++)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 10 : 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      hints[index],
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.45,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ViewpointCard extends StatelessWidget {
  const _ViewpointCard({required this.viewpoint, this.onShowOnMap});

  final CityViewpoint viewpoint;
  final VoidCallback? onShowOnMap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = palette.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            icon: Icons.photo_camera_outlined,
            title: 'Посмотреть с другого ракурса',
            color: color,
          ),
          const SizedBox(height: 10),
          Text(
            viewpoint.name,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            viewpoint.description,
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onShowOnMap,
            icon: const Icon(Icons.map_outlined, size: 18),
            label: const Text('Показать на карте'),
            style: OutlinedButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.place_outlined, size: 14, color: palette.textMuted),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Проверенная общедоступная точка',
                  style: TextStyle(fontSize: 11, color: palette.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StoryCard extends StatelessWidget {
  const _StoryCard({required this.story, this.tts});

  final String story;
  final TtsProvider? tts;

  Future<void> _toggleNarration(BuildContext context) async {
    final provider = tts;
    if (provider == null) return;
    if (provider.isNarrating) {
      await provider.stopNarration();
      return;
    }
    final started = await provider.speakNarration(story);
    if (started || !context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            provider.narrationError ?? 'Не удалось озвучить историю.',
          ),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = palette.secondary;
    final provider = tts;
    final narrating = provider?.isNarrating ?? false;
    final unavailable =
        provider != null && provider.ready && !provider.available;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            icon: Icons.auto_stories_outlined,
            title: 'Короткая история',
            color: color,
          ),
          const SizedBox(height: 10),
          Text(
            story,
            style: TextStyle(
              fontSize: 14.5,
              height: 1.5,
              color: palette.textPrimary,
            ),
          ),
          if (provider != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: provider.isNarrating || provider.canNarrate
                      ? () => _toggleNarration(context)
                      : null,
                  icon: Icon(
                    narrating
                        ? Icons.stop_circle_outlined
                        : Icons.headphones_outlined,
                    size: 18,
                  ),
                  label: Text(narrating ? 'Остановить' : 'Слушать'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                ),
                if (!provider.ready)
                  Text(
                    'Проверяем озвучивание…',
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  )
                else if (unavailable)
                  Text(
                    'Озвучивание недоступно на этом устройстве.',
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.color,
  });

  final IconData icon;
  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: palette.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}
