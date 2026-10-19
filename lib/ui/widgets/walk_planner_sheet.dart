import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/utils/russian_plurals.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/start_point_selector_dialog.dart';

class WalkPlannerSheet extends StatelessWidget {
  const WalkPlannerSheet({
    super.key,
    this.embedded = false,
    this.disabled = false,
    this.busy = false,
    this.onContinue,
    this.repository,
  });

  /// The guided flow reuses this planner against its isolated routing draft.
  final bool embedded;
  final bool disabled;

  /// The guided flow is building native geometry right now.
  final bool busy;
  final VoidCallback? onContinue;
  final PlacesRepository? repository;

  @override
  Widget build(BuildContext context) {
    final routing = context.watch<RoutingProvider>();
    final walkPlaces = routing.walkPlaces;
    final startPoint = routing.startPoint;
    final isMaxReached = walkPlaces.length >= RoutingProvider.maxWalkPlaces;
    final isNavActive = routing.navigationLocked || disabled;
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

    return PopScope(
      // Back closes the keyboard before the modal sheet itself.
      canPop: !keyboardOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) FocusManager.instance.primaryFocus?.unfocus();
      },
      child: Container(
        decoration: BoxDecoration(
          color: AppPalette.of(context).surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            // The modal sheet route does not apply keyboard insets; reserve the
            // keyboard height here so the place-search field stays reachable.
            padding: EdgeInsets.fromLTRB(
              16,
              10,
              16,
              16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: AppPalette.of(context).divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Заголовок
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppPalette.of(context).primary
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.map_outlined,
                        color: AppPalette.of(context).primary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Туристическая прогулка',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppPalette.of(context).textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'Единый пешеходный маршрут через выбранные места',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppPalette.of(context).textSecondary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (!embedded)
                      IconButton(
                        tooltip: 'Умная прогулка (автоподбор)',
                        icon: Icon(
                          Icons.auto_awesome,
                          color: AppPalette.of(context).primary,
                        ),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        onPressed: isNavActive
                            ? null
                            : () {
                                // Replace the current sheet using a live navigator context.
                                final navigator = Navigator.of(context);
                                navigator.pop();
                                showModalBottomSheet<void>(
                                  context: navigator.context,
                                  isScrollControlled: true,
                                  backgroundColor: Colors.transparent,
                                  builder: (_) => const SmartWalkWizardSheet(),
                                );
                              },
                      ),
                    if (walkPlaces.isNotEmpty)
                      IconButton(
                        tooltip: 'Очистить прогулку',
                        icon: Icon(
                          Icons.delete_outline,
                          color: isNavActive
                              ? AppPalette.of(context).divider
                              : AppPalette.of(context).textMuted,
                        ),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        onPressed: isNavActive ? null : routing.clearWalk,
                      ),
                  ],
                ),
                const SizedBox(height: 12),

                if (embedded)
                  ChangeNotifierProvider(
                    create: (_) => PlacesProvider(repository: repository),
                    child: _ManualCatalog(disabled: disabled),
                  ),

                // Стартовая точка
                if (!embedded)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppPalette.of(context).surfaceVariant
                          .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.trip_origin,
                          size: 18,
                          color: AppColors.routeStartMarker,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Стартовая точка прогулки:',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppPalette.of(context).textSecondary,
                                ),
                              ),
                              Text(
                                startPoint.title,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: AppPalette.of(context).textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(48, 48),
                            tapTargetSize: MaterialTapTargetSize.padded,
                          ),
                          onPressed: isNavActive
                              ? null
                              : () {
                                  showDialog(
                                    context: context,
                                    builder: (_) =>
                                        const StartPointSelectorDialog(),
                                  );
                                },
                          child: const Text('Сменить'),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),

                // Пояснение о лимите точек
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      'Места прогулки (${walkPlaces.length} из ${RoutingProvider.maxWalkPlaces}):',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isMaxReached
                            ? AppPalette.of(context).accent
                            : AppPalette.of(context).textPrimary,
                      ),
                    ),
                    if (isMaxReached)
                      Text(
                        'Лимит достигнут',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppPalette.of(context).accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                if (routing.walkBudgetMinutes != null)
                  Text(
                    '${routing.walkPreset == null ? '' : '${routing.walkPreset!.label}. '}'
                    'Бюджет ${routing.walkBudgetMinutes} мин сохраняется при изменении прогулки. '
                    'При построении список может быть сокращён по времени MapKit.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppPalette.of(context).textSecondary,
                    ),
                  ),
                if (isNavActive)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: AppPalette.of(context).accent
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppPalette.of(context).accent
                            .withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lock_outline,
                          size: 16,
                          color: AppPalette.of(context).accent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Идёт активная прогулка. Чтобы изменить состав мест или порядок, сначала завершите навигацию.',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.of(context).accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Text(
                  'В прогулку можно добавить до 6 мест, чтобы маршрут оставался комфортным для пешей прогулки.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppPalette.of(context).textMuted,
                  ),
                ),
                const SizedBox(height: 8),

                // Список мест или пустое состояние
                if (walkPlaces.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 24,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      color: AppPalette.of(context).surfaceVariant
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppPalette.of(context).border),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.add_location_alt_outlined,
                          size: 36,
                          color: AppPalette.of(context).textMuted,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'В прогулке пока нет мест',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppPalette.of(context).textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Нажмите на маркер места на карте или найдите его в поиске и выберите «Добавить в прогулку».',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppPalette.of(context).textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  // ignore: deprecated_member_use
                  ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: walkPlaces.length,
                    // ignore: deprecated_member_use
                    onReorder: (oldIndex, newIndex) {
                      if (!isNavActive) {
                        routing.reorderWalkPlaces(oldIndex, newIndex);
                      }
                    },
                    itemBuilder: (context, index) {
                      final place = walkPlaces[index];
                      return Container(
                        key: ValueKey(place.id),
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.of(context).surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppPalette.of(context).border,
                          ),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 12,
                              backgroundColor: place.category.color,
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    place.title,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppPalette.of(context).textPrimary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    place.category.displayName,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: place.category.color,
                                    ),
                                  ),
                                  if (routing
                                          .placeReasons[place.id]
                                          ?.isNotEmpty ??
                                      false)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        routing.placeReasons[place.id]!.first,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: AppPalette.of(context)
                                              .secondary,
                                          fontStyle: FontStyle.italic,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.close,
                                size: 18,
                                color: isNavActive
                                    ? AppPalette.of(context).divider
                                    : AppPalette.of(context).textMuted,
                              ),
                              tooltip: isNavActive
                                  ? 'Навигация активна'
                                  : 'Удалить из прогулки',
                              onPressed: isNavActive
                                  ? null
                                  : () => routing.removePlaceFromWalk(place.id),
                            ),
                            if (!isNavActive)
                              ReorderableDragStartListener(
                                index: index,
                                child: Tooltip(
                                  message: 'Изменить порядок места',
                                  child: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Icon(
                                      Icons.drag_handle,
                                      size: 20,
                                      color: AppPalette.of(context).textMuted,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),

                const SizedBox(height: 14),

                // Кнопка построения маршрута прогулки
                if (walkPlaces.isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: routing.isCalculating
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.directions_walk),
                      label: Text(
                        routing.isCalculating || busy
                            ? 'Строим пешеходный маршрут…'
                            : onContinue != null
                            ? 'Построить прогулку'
                            : 'Построить прогулку (${walkPlaces.length} ${pluralPlaces(walkPlaces.length)})',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: routing.isCalculating || busy || isNavActive
                          ? null
                          : onContinue ?? () => routing.buildWalkRoute(),
                    ),
                  ),
                if (walkPlaces.isNotEmpty && onContinue != null) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Проверим настоящий пешеходный маршрут, расстояние и время по карте.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Catalog search shares the existing provider and the planner's six-stop
/// operations. This local provider has no guest preference writer.
class _ManualCatalog extends StatefulWidget {
  const _ManualCatalog({this.disabled = false});
  final bool disabled;

  @override
  State<_ManualCatalog> createState() => _ManualCatalogState();
}

class _ManualCatalogState extends State<_ManualCatalog> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final places = context.watch<PlacesProvider>();
    final routing = context.watch<RoutingProvider>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Выберите места из каталога или найдите их по названию.'),
        const SizedBox(height: 8),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Найти достопримечательность',
            prefixIcon: Icon(Icons.search),
          ),
          enabled: !widget.disabled,
          onChanged: places.setSearchQuery,
        ),
        if (places.isLoading) const LinearProgressIndicator(),
        if (places.hasError)
          TextButton.icon(
            onPressed: places.loadPlaces,
            icon: const Icon(Icons.refresh),
            label: Text(places.errorMessage ?? 'Повторить загрузку каталога'),
          ),
        if (places.isEmpty) const Text('Места не найдены. Измените запрос.'),
        OutlinedButton.icon(
          onPressed:
              places.places.isEmpty ||
                  widget.disabled ||
                  routing.navigationLocked ||
                  routing.walkPlaces.length >= RoutingProvider.maxWalkPlaces
              ? null
              : () async {
                  final place = await chooseGuidedWalkPlaceOnMap(
                    context,
                    places.places,
                  );
                  if (context.mounted &&
                      place != null &&
                      !widget.disabled &&
                      !routing.navigationLocked &&
                      routing.walkPlaces.length <
                          RoutingProvider.maxWalkPlaces) {
                    routing.addPlaceToWalk(place);
                  }
                },
          icon: const Icon(Icons.map_outlined),
          label: const Text('Выбрать место на карте'),
        ),
        for (final place in _showAll ? places.places : places.places.take(8))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(place.title),
            subtitle: Text(place.category.displayName),
            trailing: IconButton(
              tooltip: routing.isPlaceInWalk(place)
                  ? 'Место уже в прогулке'
                  : 'Добавить ${place.title} в прогулку',
              icon: Icon(
                routing.isPlaceInWalk(place) ? Icons.check : Icons.add,
              ),
              onPressed:
                  widget.disabled ||
                      routing.navigationLocked ||
                      routing.isPlaceInWalk(place) ||
                      routing.walkPlaces.length >= RoutingProvider.maxWalkPlaces
                  ? null
                  : () => routing.addPlaceToWalk(place),
            ),
          ),
        if (places.places.length > 8)
          TextButton(
            onPressed: () => setState(() => _showAll = !_showAll),
            child: Text(
              _showAll ? 'Свернуть каталог' : 'Показать весь каталог',
            ),
          ),
        const Divider(),
      ],
    );
  }
}
