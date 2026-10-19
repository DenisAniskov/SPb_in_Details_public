import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/core/utils/russian_plurals.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/providers/historical_content_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/context_recommendations_section.dart';
import 'package:smart_navigator_spb/ui/widgets/pollen_assessment_section.dart';
import 'package:smart_navigator_spb/ui/widgets/puddle_assessment_section.dart';
import 'package:smart_navigator_spb/ui/widgets/quiet_assessment_section.dart';
import 'package:smart_navigator_spb/ui/widgets/shade_assessment_section.dart';
import 'package:smart_navigator_spb/ui/widgets/start_point_selector_dialog.dart';

class RouteDetailsSheet extends StatefulWidget {
  const RouteDetailsSheet({super.key, this.initiallyExpanded = true});

  /// Expanded is the historical presentation. Route data, the start action
  /// and the provider state are unaffected by collapsing.
  final bool initiallyExpanded;

  @override
  State<RouteDetailsSheet> createState() => _RouteDetailsSheetState();
}

class _RouteDetailsSheetState extends State<RouteDetailsSheet> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() {
    setState(() => _expanded = !_expanded);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 150 && _expanded) {
      setState(() => _expanded = false);
    } else if (velocity < -150 && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final routingProvider = context.watch<RoutingProvider>();
    final route = routingProvider.currentRoute;
    final startPoint = routingProvider.startPoint;
    final isWalkRoute = routingProvider.isWalkRoute;
    final walkPlaces = routingProvider.walkPlaces;
    final destinationTitle = routingProvider.destinationTitle;
    // Phase C6: short verified history lines for the stops — fetched lazily
    // (≤6 small cached requests), never altering route data itself. The
    // provider is optional: without it the sheet renders exactly as before.
    final historyProvider = context.watch<HistoricalContentProvider?>();
    if (historyProvider != null) {
      for (final place in walkPlaces) {
        historyProvider.ensureLoaded(place);
      }
    }
    final destinationPlace = routingProvider.destinationPlace;
    if (!isWalkRoute && destinationPlace != null) {
      historyProvider?.ensureLoaded(destinationPlace);
    }

    if (route == null || (!routingProvider.hasRoute)) {
      return const SizedBox.shrink();
    }

    return Container(
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
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Полоса перетаскивания: вниз — свернуть, вверх — раскрыть.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: _onVerticalDragEnd,
                child: Center(
                  child: Container(
                    key: const Key('route_details_drag_handle'),
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: AppPalette.of(context).divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),

              // Заголовок и кнопка сброса
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.routeColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      isWalkRoute ? Icons.directions_walk : Icons.alt_route,
                      color: AppColors.routeColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragEnd: _onVerticalDragEnd,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isWalkRoute
                                ? 'Маршрут прогулки (${route.placesCount} ${pluralPlaces(route.placesCount)})'
                                : AppStrings.routeBuiltSuccess,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: AppPalette.of(context).textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                route.formattedDistance,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.routeColor,
                                ),
                              ),
                              Text(
                                '•',
                                style: TextStyle(
                                  color: AppPalette.of(context).textMuted,
                                ),
                              ),
                              Text(
                                'ходьба ~${route.formattedDuration}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.routeColor,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('route_details_toggle'),
                    tooltip: _expanded
                        ? 'Свернуть панель маршрута'
                        : 'Развернуть панель маршрута',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 48,
                    ),
                    onPressed: _toggle,
                    icon: Icon(
                      _expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_up,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.close,
                      color: AppPalette.of(context).textMuted,
                    ),
                    onPressed: () => routingProvider.clearRoute(),
                    tooltip: AppStrings.clearRoute,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              if (_expanded) ...[
              if (isWalkRoute) ...[
                if (routingProvider.walkBudgetMinutes != null)
                  Text(
                    '${routingProvider.walkPreset == null ? 'Прогулка' : routingProvider.walkPreset!.label} '
                    '• бюджет ${routingProvider.walkBudgetMinutes} мин',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppPalette.of(context).textSecondary,
                    ),
                  ),
                Text(
                  'Осмотр ~${routingProvider.visitDurationMinutes} мин • редакторская оценка',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppPalette.of(context).textSecondary,
                  ),
                ),
                Text(
                  'Всего ~${(routingProvider.totalWalkDurationSeconds! / 60).ceil()} мин '
                  '(ходьба MapKit + осмотр)',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
              ],

              // Phase C5: scenic comparison (only when a scenic alternative
              // was actually built from verified MapKit segments) and the
              // honest fallback message otherwise.
              if (isWalkRoute && routingProvider.routeComparison != null)
                _ScenicComparisonCard(
                  comparison: routingProvider.routeComparison!,
                  walkKind: route.walkKind,
                ),
              if (isWalkRoute &&
                  routingProvider.routeComparison == null &&
                  routingProvider.scenicFallbackMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.landscape_outlined,
                        size: 15,
                        color: AppPalette.of(context).textSecondary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          routingProvider.scenicFallbackMessage!,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppPalette.of(context).textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Предупреждение об автокоррекции бюджета (если сработало)
              if (routingProvider.budgetWarningMessage != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppPalette.of(context).accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppPalette.of(context).accent
                          .withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: AppPalette.of(context).accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          routingProvider.budgetWarningMessage!,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppPalette.of(context).textPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close,
                          size: 14,
                          color: AppPalette.of(context).textMuted,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        onPressed: routingProvider.clearBudgetWarning,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],

              // Пояснение о времени ходьбы
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppPalette.of(context).surfaceVariant
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Указано расчётное время пешего хода (без учёта времени посещения объектов).',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppPalette.of(context).textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Кнопка запуска Live Navigation
              Builder(
                builder: (context) {
                  final navProvider = Provider.of<NavigationProvider?>(context);
                  final sessionStatus =
                      navProvider?.status ?? NavigationStatus.idle;
                  final isStarting = sessionStatus == NavigationStatus.starting;
                  // A running session (starting/active/rerouting/paused) owns
                  // the screen: this action must never silently no-op against
                  // it. A terminal session follows the app-wide dismissal
                  // convention — stop it first, then start the retained route.
                  final sessionOwnsRoute =
                      sessionStatus == NavigationStatus.active ||
                      sessionStatus == NavigationStatus.waitingForGps ||
                      sessionStatus == NavigationStatus.rerouting ||
                      sessionStatus == NavigationStatus.paused;
                  final isTerminalSession =
                      sessionStatus == NavigationStatus.completed ||
                      sessionStatus == NavigationStatus.error;

                  return SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppPalette.of(context).primary,
                        foregroundColor: AppPalette.of(context).onSolid,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: isStarting
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppPalette.of(context).onSolid,
                              ),
                            )
                          : const Icon(Icons.navigation, size: 18),
                      label: Text(
                        isStarting
                            ? 'Запуск навигации...'
                            : (isWalkRoute
                                  ? 'Начать прогулку'
                                  : 'Начать маршрут'),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed:
                          isStarting || sessionOwnsRoute || navProvider == null
                          ? null
                          : () {
                              if (isTerminalSession) {
                                navProvider.stopNavigation();
                              }
                              navProvider.startNavigation(route);
                            },
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),

              // Точки маршрута: Старт и Посещаемые места
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppPalette.of(context).surfaceVariant
                      .withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Точка старта
                    Row(
                      children: [
                        const Icon(
                          Icons.trip_origin,
                          size: 16,
                          color: AppColors.routeStartMarker,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'От: ${startPoint.title}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.of(context).textPrimary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(48, 48),
                            tapTargetSize: MaterialTapTargetSize.padded,
                            textStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppPalette.of(context).primary,
                            ),
                          ),
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (_) => const StartPointSelectorDialog(),
                            );
                          },
                          child: const Text('Сменить'),
                        ),
                      ],
                    ),

                    // Если это прогулка по нескольким местам: показываем цепочку
                    if (isWalkRoute) ...[
                      for (int i = 0; i < walkPlaces.length; i++) ...[
                        Padding(
                          padding: const EdgeInsets.only(left: 7),
                          child: SizedBox(
                            height: 12,
                            child: VerticalDivider(
                              width: 1,
                              color: AppPalette.of(context).divider,
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 8,
                              backgroundColor: AppPalette.of(context).primary,
                              child: Text(
                                '${i + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    walkPlaces[i].title,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: (i == walkPlaces.length - 1)
                                          ? FontWeight.bold
                                          : FontWeight.w500,
                                      color: AppPalette.of(context).textPrimary,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (routingProvider
                                          .placeReasons[walkPlaces[i].id]
                                          ?.isNotEmpty ??
                                      false)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        routingProvider
                                            .placeReasons[walkPlaces[i].id]!
                                            .first,
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
                                  // Phase C6: одна краткая историческая
                                  // фраза остановки — только проверенные
                                  // данные, без каскада запросов.
                                  if (historyProvider
                                          ?.contentFor(walkPlaces[i].id)
                                          ?.shortHistoricalSummary
                                          .isNotEmpty ??
                                      false)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        historyProvider!
                                            .contentFor(walkPlaces[i].id)!
                                            .shortHistoricalSummary,
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          height: 1.35,
                                          color: AppPalette.of(context)
                                              .textSecondary,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                minimumSize: const Size(48, 40),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppPalette.of(context).primary,
                                ),
                              ),
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        PlaceDetailScreen(place: walkPlaces[i]),
                                  ),
                                );
                              },
                              child: const Text('Подробнее'),
                            ),
                          ],
                        ),
                      ],
                    ] else ...[
                      // Одиночный маршрут A -> B
                      Padding(
                        padding: const EdgeInsets.only(left: 7),
                        child: SizedBox(
                          height: 12,
                          child: VerticalDivider(
                            width: 1,
                            color: AppPalette.of(context).divider,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on,
                            size: 16,
                            color: AppColors.routeEndMarker,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'До: $destinationTitle',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppPalette.of(context).textPrimary,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (destinationPlace != null)
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                minimumSize: const Size(48, 40),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: AppPalette.of(context).primary,
                                ),
                              ),
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => PlaceDetailScreen(
                                      place: destinationPlace,
                                    ),
                                  ),
                                );
                              },
                              child: const Text('Подробнее'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Если есть разбивка по участкам (legs): показываем реальные расстояния отрезков
              if (route.legs.length > 1) ...[
                const SizedBox(height: 10),
                Text(
                  'Участки пешеходного маршрута:',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppPalette.of(context).textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                for (int i = 0; i < route.legs.length; i++) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Text(
                          '${i + 1}. ',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppPalette.of(context).primary,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '${route.legs[i].fromTitle} → ${route.legs[i].toTitle}',
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${route.legs[i].distanceMeters.round()} м (~${(route.legs[i].durationSeconds / 60).round()} мин)',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppPalette.of(context).textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],

              const SizedBox(height: 10),
              // Phase C7.4: a compact, derived summary of the factors below.
              // It duplicates none of their cards, invents nothing for a
              // factor that was not assessed, and changes nothing by itself.
              const ContextRecommendationsSection(),
              const SizedBox(height: 10),
              // Phase C7.1: shade IS estimated now (real OSM building data,
              // opt-in, per request).
              const ShadeAssessmentSection(),
              // Phase C7.2: an optional relative wet-surface assessment of
              // THIS walk. It changes nothing about the route; it reports what
              // the pinned OSM pilot and modeled rain support — and says
              // "unknown" where they do not.
              const SizedBox(height: 10),
              const PuddleAssessmentSection(),
              // Phase C7.3: modelled pollen concentrations per species, with
              // their source, coverage and limitations — no danger levels.
              const SizedBox(height: 10),
              const PollenAssessmentSection(),
              // Phase C11: relative road-network proximity proxy with honest
              // coverage and provenance. Never dB and never a route generator.
              const SizedBox(height: 10),
              const QuietAssessmentSection(),
              ] else
                _collapsedSummary(
                  context,
                  routingProvider,
                  route,
                  isWalkRoute: isWalkRoute,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Compact route card. The start action stays available, so collapsing
  /// never traps the user without a way to begin or close the route.
  Widget _collapsedSummary(
    BuildContext context,
    RoutingProvider routing,
    PedestrianRouteModel route, {
    required bool isWalkRoute,
  }) {
    final palette = AppPalette.of(context);
    final nav = Provider.of<NavigationProvider?>(context);
    final status = nav?.status ?? NavigationStatus.idle;
    final sessionBusy =
        status == NavigationStatus.starting ||
        status == NavigationStatus.active ||
        status == NavigationStatus.waitingForGps ||
        status == NavigationStatus.rerouting ||
        status == NavigationStatus.paused;
    final isTerminal =
        status == NavigationStatus.completed ||
        status == NavigationStatus.error;
    return Container(
      key: const Key('route_details_collapsed_summary'),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.surfaceVariant.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _toggle,
            child: Row(
              children: [
                Icon(
                  isWalkRoute ? Icons.directions_walk : Icons.alt_route,
                  size: 20,
                  color: AppColors.routeColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${route.formattedDistance} • ходьба ~${route.formattedDuration}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
                Icon(Icons.keyboard_arrow_up, color: palette.textSecondary),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
              icon: Icon(
                sessionBusy ? Icons.hourglass_top : Icons.navigation,
                size: 16,
              ),
              label: Text(
                sessionBusy
                    ? 'Навигация уже идёт'
                    : (isWalkRoute ? 'Начать прогулку' : 'Начать маршрут'),
                style: const TextStyle(fontSize: 12.5),
              ),
              onPressed: sessionBusy || nav == null
                  ? null
                  : () {
                      if (isTerminal) nav.stopNavigation();
                      nav.startNavigation(route);
                    },
            ),
          ),
        ],
      ),
    );
  }

}

/// Phase C5 §7.2: normal-vs-scenic comparison built only from native
/// MapKit results and verified benefit lines. The user always sees WHY the
/// scenic option costs more walking time.
class _ScenicComparisonCard extends StatelessWidget {
  final RouteComparison comparison;
  final WalkKind walkKind;

  const _ScenicComparisonCard({
    required this.comparison,
    required this.walkKind,
  });

  String _minutes(int seconds) {
    final minutes = (seconds / 60).round();
    return '$minutes мин';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final extraSeconds = comparison.extraWalkingSeconds;
    final extraLabel = extraSeconds > 0
        ? '+${_minutes(extraSeconds)} ходьбы'
        : 'без лишнего времени';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.landscape, size: 16, color: AppColors.secondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  walkKind == WalkKind.scenic
                      ? 'Живописный маршрут построен'
                      : 'Доступен живописный вариант',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Обычная: ${_minutes(comparison.normalWalkingSeconds)} ходьбы • '
            'Живописная: ${_minutes(comparison.scenicWalkingSeconds)} '
            '($extraLabel) • остановок: ${comparison.stopCount}',
            style: TextStyle(fontSize: 12, color: palette.textSecondary),
          ),
          if (comparison.benefitLines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                comparison.benefitLines.join('. '),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
