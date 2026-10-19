import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/utils/maneuver_instruction_formatter.dart';
import 'package:smart_navigator_spb/core/utils/russian_plurals.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/providers/historical_content_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/tts_provider.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/context_recommendations_section.dart';
import 'package:smart_navigator_spb/ui/widgets/maneuver_icons.dart';
import 'package:smart_navigator_spb/ui/widgets/pollen_assessment_section.dart';
import 'package:smart_navigator_spb/ui/widgets/puddle_assessment_section.dart';
import 'package:smart_navigator_spb/ui/widgets/shade_assessment_section.dart';

/// Floating live navigation card showing the next verified maneuver, progress,
/// active stop, remaining distance, GPS status and action controls during an
/// active walk.
///
/// The primary instruction is the most prominent element. Directional turn
/// icons are shown only for verified native maneuvers; fallback guidance uses
/// a neutral walking icon and honest route-following wording.
class LiveNavigationSheet extends StatefulWidget {
  const LiveNavigationSheet({super.key, this.initiallyExpanded = true});

  /// Expanded is the historical presentation. The panel can always be
  /// collapsed with the header button or a downward swipe.
  final bool initiallyExpanded;

  @override
  State<LiveNavigationSheet> createState() => _LiveNavigationSheetState();
}

class _LiveNavigationSheetState extends State<LiveNavigationSheet> {
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
    final nav = context.watch<NavigationProvider>();
    final tts = context.watch<TtsProvider?>();
    final state = nav.state;
    final guidance = nav.guidance;
    // Phase C6: the next tourist stop may offer its verified short history.
    // Resolving the PlaceModel is title-based and honest: without a match
    // the button is simply not shown. The history provider is optional —
    // without it the sheet renders exactly as before. GPS guidance is never
    // blocked: history opens only on explicit user action.
    final historyProvider = context.watch<HistoricalContentProvider?>();
    final nextStop = historyProvider == null
        ? null
        : _resolveNextStopPlace(context, nav);

    if (state.status == NavigationStatus.idle) {
      return const SizedBox.shrink();
    }

    final isCompleted = state.isCompleted;
    final isWaitingConfirmation = state.isWaitingForNextLegConfirmation;
    final isGpsLost = state.isGpsLost;
    final isOffRoute = state.isOffRoute;

    return Container(
      decoration: BoxDecoration(
        color: AppPalette.of(context).surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
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
              // Drag handle: swipe down to collapse, up to expand. It never
              // ends navigation — only the explicit «Завершить» button does.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: _onVerticalDragEnd,
                child: Center(
                  child: Container(
                    key: const Key('live_navigation_drag_handle'),
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

              // Header row: Status badge + Close/Stop button
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isCompleted
                          ? AppPalette.of(context).success
                                .withValues(alpha: 0.15)
                          : AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      isCompleted ? Icons.check_circle : Icons.navigation,
                      color: isCompleted
                          ? AppPalette.of(context).success
                          : AppPalette.of(context).primary,
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
                            _headerTitle(state),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isCompleted
                                  ? AppPalette.of(context).success
                                  : AppPalette.of(context).textPrimary,
                            ),
                          ),
                          if (!isCompleted &&
                              state.route != null &&
                              state.route!.legs.length > 1)
                            Text(
                              'Участок ${state.currentLegIndex + 1} из ${state.route!.legs.length}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppPalette.of(context).textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('live_navigation_toggle'),
                    tooltip: _expanded
                        ? 'Свернуть панель навигации'
                        : 'Развернуть панель навигации',
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
                  if (tts != null)
                    IconButton(
                      key: const Key('navigation_voice_toggle'),
                      tooltip: tts.enabled ? 'Звук включён' : 'Звук выключен',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 48,
                      ),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        if (!tts.ready) return;
                        if (!tts.available) {
                          messenger?.showSnackBar(
                            SnackBar(
                              content: Text(
                                tts.errorMessage ??
                                    'Русский голос не установлен.',
                              ),
                            ),
                          );
                          return;
                        }
                        final ok = await tts.toggle();
                        if (!ok && messenger != null) {
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                tts.errorMessage ?? 'Озвучивание недоступно.',
                              ),
                            ),
                          );
                        }
                      },
                      icon: Icon(
                        tts.enabled ? Icons.volume_up : Icons.volume_off,
                      ),
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 92),
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () async {
                        if (isCompleted ||
                            state.status == NavigationStatus.error) {
                          nav.stopNavigation();
                          return;
                        }
                        final stop = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Завершить прогулку?'),
                            content: const Text(
                              'Построенный маршрут останется доступным.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Отмена'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Остановить'),
                              ),
                            ],
                          ),
                        );
                        if (stop == true && context.mounted) {
                          nav.stopNavigation();
                        }
                      },
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          isCompleted ? 'Закрыть' : 'Завершить',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppPalette.of(context).textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (_expanded) ...[
              if (state.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    state.errorMessage!,
                    style: TextStyle(
                      color: AppPalette.of(context).textSecondary,
                    ),
                  ),
                ),
              // Completed celebration banner
              if (isCompleted) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppPalette.of(context).success
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppPalette.of(context).success
                          .withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.celebration,
                        color: AppPalette.of(context).success,
                        size: 24,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Вы успешно достигли финальной точки: «${state.arrivedPlaceTitle ?? 'Точка назначения'}». Надеемся, прогулка вам понравилась!',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: AppPalette.of(context).textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Intermediate POI Arrival Banner
              if (!isCompleted && isWaitingConfirmation) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppPalette.of(context).accent
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppPalette.of(context).accent
                          .withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.place,
                            color: AppPalette.of(context).accent,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Вы пришли: «${state.arrivedPlaceTitle}»',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppPalette.of(context).textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppPalette.of(context).primary,
                            foregroundColor: AppPalette.of(context).onSolid,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: state.isActive
                              ? () => nav.continueToNextLeg()
                              : null,
                          icon: const Icon(Icons.arrow_forward, size: 16),
                          label: const Text(
                            'Продолжить к следующей точке',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // Warnings: GPS Lost or Off-Route observation
              if (!isCompleted) ...[
                if (isGpsLost && !state.isRerouting) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: AppPalette.of(context).error
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppPalette.of(context).error
                            .withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.gps_off,
                          size: 16,
                          color: AppPalette.of(context).error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            state.isWaitingForGps
                                ? (state.errorMessage ??
                                      'Ожидаем местоположение. '
                                          'Включите геолокацию.')
                                : 'Сигнал GPS потерян или временно недоступен.',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppPalette.of(context).error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (isOffRoute || state.isRerouting) ...[
                  // Confirmed off-route: non-modal banner with the explicit
                  // manual reroute action. Nothing reroutes automatically.
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: AppPalette.of(context).accent
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppPalette.of(context).accent
                            .withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              size: 16,
                              color: AppPalette.of(context).accent,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                state.isRerouting
                                    ? 'Строим новый пешеходный маршрут от вашего местоположения...'
                                    : 'Вы отклонились от маршрута (~${state.distanceFromRouteMeters.round()} м)',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppPalette.of(context).accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: state.isRerouting
                              ? OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  onPressed: null,
                                  icon: const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  label: const Text(
                                    'Перестраиваем маршрут...',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                )
                              : ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppPalette.of(context)
                                        .accent,
                                    foregroundColor: AppPalette.of(context)
                                        .onSolid,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  onPressed: state.isActive
                                      ? () => nav.rerouteToNextStop()
                                      : null,
                                  icon: const Icon(Icons.alt_route, size: 16),
                                  label: const Text(
                                    'Перестроить маршрут',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],

              // Primary guidance card: the next movement instruction is the
              // most prominent information on the sheet.
              if (!isCompleted && state.route != null)
                _PrimaryGuidanceCard(guidance: guidance, state: state),

              // Next Stop & Distance Card
              if (!isCompleted && state.route != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppPalette.of(context).surfaceVariant
                        .withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.directions_walk,
                            size: 20,
                            color: AppPalette.of(context).primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Следующая остановка:',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppPalette.of(context).textSecondary,
                                  ),
                                ),
                                Text(
                                  state.nextStopTitle,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: AppPalette.of(context).textPrimary,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (state.route!.legs.length > 1)
                                  Text(
                                    'Остановка ${state.currentLegIndex + 1} из ${state.route!.legs.length}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: AppPalette.of(context)
                                          .textSecondary,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'Осталось',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppPalette.of(context).textSecondary,
                                ),
                              ),
                              Text(
                                state.formattedRemainingDistance,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AppPalette.of(context).primary,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Достигнуто точек: ${state.completedStopsCount} из ${state.totalStopsCount}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppPalette.of(context).textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Progress bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: state.totalProgressFraction,
                          minHeight: 6,
                          backgroundColor: AppPalette.of(context).divider,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            AppPalette.of(context).primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          Text(
                            'Пройдено по текущему маршруту: ${state.totalProgressMeters.round()} м',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppPalette.of(context).textSecondary,
                            ),
                          ),
                          Text(
                            'Всего: ${state.route?.formattedDistance ?? ''}',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppPalette.of(context).textSecondary,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),

                      // Phase C6: ненавязчивый доступ к проверенной краткой
                      // истории следующей туристической остановки. Кнопка —
                      // только явное действие пользователя; инструкции
                      // поворота остаются главным элементом экрана.
                      if (!isCompleted && nextStop != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              minimumSize: const Size(48, 40),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () =>
                                _showNextStopHistory(context, nextStop),
                            icon: Icon(
                              Icons.history_edu,
                              size: 15,
                              color: AppPalette.of(context).primary,
                            ),
                            label: Text(
                              'Краткая история',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: AppPalette.of(context).primary,
                              ),
                            ),
                          ),
                        ),

                      // Manual arrival fallback: auto-arrival needs two
                      // validated fixes within 25 m of the leg endpoint, which
                      // MapKit endpoint snapping or degraded GPS can block
                      // while the user already stands at the POI. Offered only
                      // while the remaining geometry is small.
                      if (nav.canConfirmArrivalManually) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              side: BorderSide(
                                color: AppPalette.of(context).primary,
                              ),
                            ),
                            onPressed: () => nav.confirmArrivalManually(),
                            icon: const Icon(Icons.where_to_vote, size: 16),
                            label: const Text(
                              'Я на месте',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              // Phase C7.4: the derived summary of the path AHEAD. Mid-walk
              // the only admissible facts are remaining-path ones (§15.5); the
              // panel says so and never reuses the plan's estimates.
              if (!isCompleted) const ContextRecommendationsSection(),
              // Phase C7.1.2: the shade layer of the path still AHEAD stays
              // refreshable while walking. The section itself is scope-aware:
              // during a session it offers only «Оценить оставшийся путь» and
              // never lifts the planning lock or touches the route. A finished
              // walk has no remaining path, so nothing is offered after it.
              if (!isCompleted) const ShadeAssessmentSection(),
              // Phase C7.2: the same "remaining path only" contract for the
              // wet-surface assessment — it never changes the active walk.
              if (!isCompleted) const PuddleAssessmentSection(),
              // Phase C7.3: the same "remaining path only" contract for the
              // pollen assessment of the path still ahead.
              if (!isCompleted) const PollenAssessmentSection(),
              ] else
                _collapsedSummary(
                  context,
                  nav,
                  state,
                  guidance,
                  isCompleted: isCompleted,
                  isWaitingConfirmation: isWaitingConfirmation,
                  isGpsLost: isGpsLost,
                  isOffRoute: isOffRoute,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Compact collapsed card: the current instruction, remaining distance and
  /// the only context-specific action. Navigation, TTS and GPS keep running;
  /// the header still exposes voice and «Завершить».
  Widget _collapsedSummary(
    BuildContext context,
    NavigationProvider nav,
    LiveNavigationState state,
    PedestrianGuidanceModel guidance, {
    required bool isCompleted,
    required bool isWaitingConfirmation,
    required bool isGpsLost,
    required bool isOffRoute,
  }) {
    final palette = AppPalette.of(context);
    if (isCompleted) {
      return InkWell(
        key: const Key('live_navigation_collapsed_summary'),
        borderRadius: BorderRadius.circular(12),
        onTap: _toggle,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: palette.success.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle, size: 20, color: palette.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Вы достигли финальной точки. Нажмите, чтобы открыть итоги.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: palette.textPrimary),
                ),
              ),
              Icon(Icons.keyboard_arrow_up, color: palette.textSecondary),
            ],
          ),
        ),
      );
    }
    final maneuver = guidance.maneuver;
    return InkWell(
      key: const Key('live_navigation_collapsed_summary'),
      borderRadius: BorderRadius.circular(12),
      onTap: _toggle,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: palette.surfaceVariant.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  maneuver == null
                      ? Icons.directions_walk
                      : maneuverIcon(maneuver.kind),
                  size: 22,
                  color: palette.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    guidance.instruction,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  state.formattedRemainingDistance,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: palette.primary,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.keyboard_arrow_up, color: palette.textSecondary),
              ],
            ),
            if (isWaitingConfirmation) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: state.isActive ? nav.continueToNextLeg : null,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  child: const Text('Продолжить к следующей точке'),
                ),
              ),
            ] else if (isGpsLost || isOffRoute) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    isGpsLost ? Icons.gps_off : Icons.warning_amber_rounded,
                    size: 13,
                    color: isGpsLost ? palette.error : palette.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isGpsLost
                          ? (state.isWaitingForGps
                                ? 'Ожидаем местоположение'
                                : 'Ожидаем сигнал GPS')
                          : 'Вы вне маршрута. Разверните панель.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isGpsLost ? palette.error : palette.accent,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Maps the active leg to the walk stop it leads to. Matching is by exact
  /// leg title (legs are titled with the destination place title); when the
  /// geometry was rerouted and no stop matches, no history is offered.
  PlaceModel? _resolveNextStopPlace(
    BuildContext context,
    NavigationProvider nav,
  ) {
    final state = nav.state;
    if (state.status == NavigationStatus.idle) return null;
    final legs = state.route?.legs;
    if (legs == null || state.currentLegIndex < 0) return null;
    if (state.currentLegIndex >= legs.length) return null;
    final nextTitle = legs[state.currentLegIndex].toTitle;
    if (nextTitle.isEmpty) return null;
    final routing = context.read<RoutingProvider?>();
    if (routing == null) return null;
    for (final place in routing.walkPlaces) {
      if (place.title == nextTitle) return place;
    }
    final destination = routing.destinationPlace;
    if (destination != null && destination.title == nextTitle) {
      return destination;
    }
    return null;
  }

  /// Non-blocking history sheet for the next stop. GPS navigation keeps
  /// running in the background (the provider is app-scoped); nothing starts
  /// automatically and no arrival events are faked.
  Future<void> _showNextStopHistory(
    BuildContext context,
    PlaceModel place,
  ) async {
    context.read<HistoricalContentProvider?>()?.ensureLoaded(place);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final historyProvider = sheetContext.read<HistoricalContentProvider?>();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppPalette.of(sheetContext).divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  'Следующая остановка — ${place.title}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppPalette.of(sheetContext).textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                if (historyProvider != null)
                  AnimatedBuilder(
                    animation: historyProvider,
                    builder: (sheetContext, _) {
                      final provider = historyProvider;
                      final content = provider.contentFor(place.id);
                      if (provider.isLoading(place.id) && content == null) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        );
                      }
                      if (content == null) {
                        if (provider.hasFailed(place.id)) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Не удалось загрузить историческую справку',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppPalette.of(sheetContext).textMuted,
                                ),
                              ),
                              TextButton(
                                onPressed: () => provider.retry(place),
                                child: const Text('Повторить'),
                              ),
                            ],
                          );
                        }
                        return Text(
                          'Историческая справка для этого места пока не подготовлена.',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: AppPalette.of(sheetContext).textSecondary,
                          ),
                        );
                      }
                      return Text(
                        content.shortHistoricalSummary,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: AppPalette.of(sheetContext).textPrimary,
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppPalette.of(sheetContext).primary,
                      foregroundColor: AppPalette.of(sheetContext).onSolid,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PlaceDetailScreen(place: place),
                        ),
                      );
                    },
                    icon: const Icon(Icons.place_outlined, size: 18),
                    label: const Text(
                      'Открыть карточку места',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _headerTitle(LiveNavigationState state) {
    final isCompleted = state.isCompleted;
    return isCompleted
        ? 'Прогулка завершена!'
        : (state.status == NavigationStatus.starting
              ? 'Запуск навигации...'
              : state.status == NavigationStatus.error
              ? 'Навигация недоступна'
              : state.isPaused
              ? 'Прогулка приостановлена'
              : state.isRerouting
              ? 'Перестраиваем маршрут...'
              : state.isWaitingForGps
              ? 'Ожидаем местоположение'
              : state.isGpsLost
              ? 'Ожидаем сигнал GPS'
              : state.isOffRoute
              ? 'Вы вне маршрута'
              : state.isWaitingForNextLegConfirmation
              ? 'Вы у точки прогулки'
              : 'Идём по маршруту');
  }
}

/// The prominent next-maneuver card. In NATIVE_MANEUVER_GUIDANCE it shows the
/// verified maneuver with its typed icon and an optional «Затем …» follower;
/// otherwise it shows the honest route-following instruction with a neutral
/// walking icon — never a directional icon without verified metadata.
class _PrimaryGuidanceCard extends StatelessWidget {
  final PedestrianGuidanceModel guidance;
  final LiveNavigationState state;

  const _PrimaryGuidanceCard({required this.guidance, required this.state});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final maneuver = guidance.maneuver;
    final icon = maneuver != null
        ? maneuverIcon(maneuver.kind)
        : Icons.directions_walk;
    final following = guidance.followingManeuver;
    final leg =
        guidance.routeSnapshot != null &&
            guidance.legIndex >= 0 &&
            guidance.legIndex < guidance.routeSnapshot!.legs.length
        ? guidance.routeSnapshot!.legs[guidance.legIndex]
        : null;
    final visitMinutes = leg?.visitMinutes;

    return Semantics(
      label: 'Подсказка навигации',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.primary.withValues(alpha: 0.10),
              AppColors.primary.withValues(alpha: 0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: palette.primary.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 28,
                    color: palette.primary,
                    semanticLabel: maneuver == null
                        ? 'Движение по маршруту'
                        : 'Манёвр: ${maneuver.instruction}',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    guidance.instruction,
                    style: TextStyle(
                      fontSize: 18,
                      height: 1.25,
                      fontWeight: FontWeight.bold,
                      color: palette.textPrimary,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (following != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 8),
                child: Row(
                  children: [
                    Icon(
                      maneuverIcon(following.kind),
                      size: 16,
                      color: palette.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        ManeuverInstructionFormatter.composeFollowingInstruction(
                          following.instruction,
                        ),
                        style: TextStyle(
                          fontSize: 13,
                          color: palette.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                if (guidance.formattedManeuverDistance != null)
                  _detail(
                    context,
                    Icons.turn_slight_right,
                    'до манёвра: ${guidance.formattedManeuverDistance}',
                  ),
                if (guidance.formattedRemainingDistance != null)
                  _detail(
                    context,
                    Icons.place_outlined,
                    'до точки: ${guidance.formattedRemainingDistance}',
                  ),
                if (guidance.formattedRemainingWalkingTime != null)
                  _detail(
                    context,
                    Icons.schedule,
                    'пешком: ~${guidance.formattedRemainingWalkingTime}',
                  ),
                if (visitMinutes != null)
                  _detail(
                    context,
                    Icons.photo_camera_outlined,
                    'осмотр: ~$visitMinutes мин',
                  ),
                if (state.route != null && state.totalRemainingMeters.isFinite)
                  _detail(
                    context,
                    Icons.route,
                    'всего осталось: '
                    '${PedestrianGuidanceModel.formatDistance(state.totalRemainingMeters.clamp(0, double.infinity))}',
                  ),
              ],
            ),
            _UpcomingStepsBlock(guidance: guidance),
          ],
        ),
      ),
    );
  }

  Widget _detail(BuildContext context, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: AppPalette.of(context).textSecondary),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: AppPalette.of(context).textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact upcoming-steps view: only verified native maneuvers, the active
/// step indicated, approximate distances shown. When no verified metadata
/// exists the block says so honestly instead of inventing turns.
class _UpcomingStepsBlock extends StatelessWidget {
  final PedestrianGuidanceModel guidance;

  const _UpcomingStepsBlock({required this.guidance});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final steps = guidance.upcomingSteps;
    if (guidance.action != PedestrianGuidanceAction.followRoute) {
      return const SizedBox.shrink();
    }
    if (steps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 13, color: palette.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Пошаговые манёвры для этого участка недоступны — '
                'следуйте линии маршрута.',
                style: TextStyle(
                  fontSize: 11,
                  color: palette.textMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final remaining = steps.length - 1;
    if (remaining == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            initiallyExpanded: false,
            iconColor: palette.textSecondary,
            collapsedIconColor: palette.textSecondary,
            title: Text(
              'Далее по участку: $remaining ${pluralManeuvers(remaining)}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: palette.textSecondary,
              ),
            ),
            children: [
              for (var i = 1; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(
                        maneuverIcon(steps[i].maneuver.kind),
                        size: 16,
                        color: palette.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          steps[i].maneuver.instruction,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: palette.textPrimary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (steps[i].distanceMeters != null)
                        Text(
                          'через ${ManeuverInstructionFormatter.formatApproachDistance(steps[i].distanceMeters!)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
