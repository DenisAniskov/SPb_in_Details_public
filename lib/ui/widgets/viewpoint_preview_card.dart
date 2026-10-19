import 'package:flutter/material.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/providers/city_viewpoint_provider.dart';

/// Compact map card for a C14 viewpoint. It never starts a route by itself:
/// both actions are explicit user choices.
class ViewpointPreviewCard extends StatelessWidget {
  const ViewpointPreviewCard({
    super.key,
    required this.session,
    required this.onClose,
    required this.onOpenPlace,
    this.onBuildRoute,
  });

  final CityViewpointSession session;
  final VoidCallback onClose;
  final VoidCallback onOpenPlace;
  final VoidCallback? onBuildRoute;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final viewpoint = session.viewpoint;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.photo_camera_outlined,
                      size: 20,
                      color: palette.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Точка обзора',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: palette.primary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          viewpoint.name,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: palette.textPrimary,
                          ),
                        ),
                        Text(
                          session.place.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: palette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть точку обзора',
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                viewpoint.description,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: onOpenPlace,
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: const Text('Вернуться к карточке'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                  ),
                  if (onBuildRoute != null)
                    OutlinedButton.icon(
                      onPressed: onBuildRoute,
                      icon: const Icon(Icons.directions_walk, size: 18),
                      label: const Text('Маршрут к точке'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Общедоступная точка, проверена по OpenStreetMap.',
                style: TextStyle(fontSize: 11, color: palette.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
