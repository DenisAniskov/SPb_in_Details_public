import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/favorite_button.dart';

class PlacePreviewCard extends StatelessWidget {
  final PlaceModel place;
  final VoidCallback? onClose;

  const PlacePreviewCard({super.key, required this.place, this.onClose});

  @override
  Widget build(BuildContext context) {
    final routing = context.watch<RoutingProvider>();
    final inWalk = routing.isPlaceInWalk(place);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppPalette.of(context).surface,
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
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PlaceDetailScreen(place: place),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Верхняя строка: бейджи категории, рейтинга и кнопка закрытия
                Stack(
                  children: [
                    const SizedBox(width: double.infinity, height: 48),
                    Padding(
                      padding: const EdgeInsets.only(right: 96),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          // Бейдж категории
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: place.category.color.withValues(
                                alpha: 0.12,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Icon(
                                  place.category.icon,
                                  size: 13,
                                  color: AppPalette.of(context)
                                      .category(place.category.color),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  place.category.displayName,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: AppPalette.of(context)
                                        .category(place.category.color),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Бейдж "Необычное место"
                          if (place.isUnusual)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppPalette.of(context).unusualBadge
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Icon(
                                    Icons.auto_awesome,
                                    size: 11,
                                    color: AppPalette.of(context).unusualBadge,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    'Необычное',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: AppPalette.of(context)
                                          .unusualBadge,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          // Время осмотра
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppPalette.of(context).surfaceVariant,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Icon(
                                  Icons.access_time,
                                  size: 11,
                                  color: AppPalette.of(context).textSecondary,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '~${place.recommendedVisitMinutes} мин',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppPalette.of(context).textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 48,
                      child: FavoriteButton(place: place),
                    ),
                    // Кнопка закрыть
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        tooltip: 'Закрыть карточку',
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        visualDensity: VisualDensity.standard,
                        onPressed:
                            onClose ??
                            () => context.read<PlacesProvider>().selectPlace(
                              null,
                            ),
                        icon: Icon(
                          Icons.close,
                          color: AppPalette.of(context).textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Название места
                Text(
                  place.title,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: AppPalette.of(context).textPrimary,
                    letterSpacing: -0.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),

                // Краткое описание
                Text(
                  place.shortDescription,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppPalette.of(context).textSecondary,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                // Уточнение к бейджу времени осмотра выше
                Text(
                  'Время осмотра — редакторская оценка',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: AppPalette.of(context).textMuted,
                  ),
                ),
                const SizedBox(height: 8),

                // Адрес
                Row(
                  children: [
                    Icon(
                      Icons.location_on_outlined,
                      size: 14,
                      color: AppPalette.of(context).textMuted,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        place.address,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppPalette.of(context).textMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Кнопки действий:
                // Primary: Маршрут сюда (ElevatedButton)
                // Secondary: В прогулку / В прогулке (OutlinedButton)
                // Tertiary: Подробнее (OutlinedButton)
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    // Маршрут сюда (Основное действие)
                    ElevatedButton.icon(
                      icon: const Icon(Icons.directions_walk, size: 16),
                      label: const Text(
                        'Маршрут сюда',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      onPressed: routing.isCalculating
                          ? null
                          : () {
                              context.read<RoutingProvider>().buildRouteTo(
                                place,
                              );
                            },
                    ),

                    // В прогулку (Второстепенное действие)
                    OutlinedButton.icon(
                      icon: Icon(
                        inWalk
                            ? Icons.check_circle
                            : Icons.add_location_alt_outlined,
                        size: 14,
                        color: inWalk
                            ? AppPalette.of(context).secondary
                            : AppPalette.of(context).primary,
                      ),
                      label: Text(inWalk ? 'В прогулке' : '+ В прогулку'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: inWalk
                            ? AppPalette.of(context).secondary
                            : AppPalette.of(context).primary,
                        side: BorderSide(
                          color: inWalk
                              ? AppPalette.of(context).secondary
                              : AppPalette.of(context).primary,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        minimumSize: const Size(48, 48),
                        tapTargetSize: MaterialTapTargetSize.padded,
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: () {
                        if (inWalk) {
                          routing.removePlaceFromWalk(place.id);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '«${place.title}» удалено из прогулки',
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        } else {
                          final added = routing.addPlaceToWalk(place);
                          if (!added) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'В прогулку можно добавить не более 6 мест.',
                                ),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '«${place.title}» добавлено в прогулку (${routing.walkPlaces.length} из ${RoutingProvider.maxWalkPlaces})',
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        }
                      },
                    ),

                    // Подробнее
                    TextButton.icon(
                      icon: const Icon(Icons.info_outline, size: 14),
                      label: const Text('Подробнее'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        minimumSize: const Size(48, 48),
                        tapTargetSize: MaterialTapTargetSize.padded,
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PlaceDetailScreen(place: place),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
