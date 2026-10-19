import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';

class ExternalPointPreviewCard extends StatelessWidget {
  final ExternalMapPoint point;
  final VoidCallback? onClose;

  const ExternalPointPreviewCard({
    super.key,
    required this.point,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final routingProvider = context.watch<RoutingProvider>();
    final isCurrentStart =
        routingProvider.startPoint.latitude == point.latitude &&
        routingProvider.startPoint.longitude == point.longitude;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        color: AppPalette.of(context).surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: AppPalette.of(context).primary.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Верхняя строка: Иконка, Заголовок, Бейдж и Крестик
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade700.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.location_on,
                    color: Colors.amber.shade800,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppPalette.of(context).surfaceVariant,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Адрес на карте',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: AppPalette.of(context).textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        point.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppPalette.of(context).textPrimary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (point.address != null || point.subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          point.address ?? point.subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppPalette.of(context).textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    color: AppPalette.of(context).textMuted,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: onClose,
                    tooltip: 'Закрыть',
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Кнопки действий: "Маршрут сюда" и "Сделать стартом"
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: routingProvider.isCalculating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.directions_walk, size: 18),
                  label: const Text(
                    'Маршрут сюда',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  onPressed: routingProvider.isCalculating
                      ? null
                      : () {
                          routingProvider.buildRouteToExternalPoint(point);
                        },
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: Icon(
                    isCurrentStart ? Icons.check : Icons.trip_origin,
                    size: 16,
                    color: isCurrentStart
                        ? AppColors.routeStartMarker
                        : AppPalette.of(context).primary,
                  ),
                  label: Text(
                    isCurrentStart ? 'Выбран' : 'Старт',
                    style: TextStyle(
                      fontSize: 12,
                      color: isCurrentStart
                          ? AppColors.routeStartMarker
                          : AppPalette.of(context).primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: () {
                    routingProvider.setExternalStartPoint(point);
                    context.read<SearchProvider>().clearSearch();
                    Provider.of<PlacesProvider?>(
                      context,
                      listen: false,
                    )?.setSearchQuery('');
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Точка старта: ${point.title}'),
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
