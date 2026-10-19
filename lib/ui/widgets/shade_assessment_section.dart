import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/shade_routing_engine.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/widgets/environmental_report_card.dart';

/// Phase C7.1 shade section of the route card (§14), extended in C7.1.2 to
/// stay reachable DURING an active walk.
///
/// What the user can do here: pick the departure instant and ask for a shade
/// estimate of the CURRENT route before walking, and — while walking — refresh
/// the estimate for the path still AHEAD. The two are different questions and
/// are labelled as such: the plan is evaluated from the walk's start with its
/// own schedule, the remaining path from the current instant. Only the plan
/// can offer a route comparison, and only when a REAL MapKit alternative was
/// found and passed the documented gates.
///
/// What this widget never does: invent a shade percentage, switch the route
/// silently, hide the unknown share, keep a stale estimate after the route or
/// the departure time changed, or lift the planning lock to refresh a layer —
/// the refresh never changes the route the user is walking.
class ShadeAssessmentSection extends StatelessWidget {
  const ShadeAssessmentSection({super.key});

  @override
  Widget build(BuildContext context) {
    // Nullable lookup: the live navigation sheet renders without a routing
    // provider in several existing contexts.
    final routing = context.watch<RoutingProvider?>();
    final palette = AppPalette.of(context);
    if (routing == null || !routing.hasRoute) {
      return const SizedBox.shrink();
    }
    // While a walk is in progress the only admissible estimate is the
    // remaining path (§15.5): the plan's schedule belongs to a start that has
    // already happened.
    final navigating = routing.navigationLocked;
    final nav = navigating ? context.watch<NavigationProvider?>() : null;
    final canRefreshRemaining =
        navigating &&
        nav != null &&
        (nav.isActive || nav.state.isRerouting || nav.state.isPaused);
    final analysis = routing.shadeAnalysis;
    final decision = routing.shadeDecision;
    final failure = routing.shadeFailure;
    final departure = routing.shadeDeparture;
    final evaluated = routing.shadeEvaluatedFor;
    final remainingScope =
        routing.shadeScope == ShadeAssessmentScope.remainingPath;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surfaceVariant,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.wb_shade_outlined,
                size: 18,
                color: AppColors.secondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Тень на маршруте',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              if (routing.isAssessingShade)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _subtitle(
              navigating: navigating,
              remainingScope: remainingScope,
              departure: departure,
              evaluated: evaluated,
            ),
            style: TextStyle(fontSize: 12, color: palette.textMuted),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: navigating
                ? [
                    FilledButton.icon(
                      onPressed:
                          routing.isAssessingShade || !canRefreshRemaining
                          ? null
                          : () => routing.assessShade(
                              remainingRoute: nav.buildRemainingRoute(),
                              // The tail starts at the session's current
                              // progress; recording it lets consumers verify
                              // the estimate still describes the way ahead
                              // after the walker moves on.
                              progressMeters: nav.state.totalProgressMeters,
                            ),
                      icon: const Icon(Icons.search, size: 16),
                      label: const Text('Оценить оставшийся путь'),
                    ),
                  ]
                : [
                    FilledButton.tonalIcon(
                      onPressed: routing.isAssessingShade
                          ? null
                          : () => _pickDeparture(context, routing),
                      icon: const Icon(Icons.schedule, size: 16),
                      label: Text(
                        departure == null ? 'Выбрать время' : 'Другое время',
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: routing.isAssessingShade
                          ? null
                          : () => routing.assessShade(),
                      icon: const Icon(Icons.search, size: 16),
                      label: const Text('Оценить тень'),
                    ),
                  ],
          ),
          if (failure != null) ...[
            const SizedBox(height: 10),
            _message(context, failure.message, isError: true),
          ],
          const _SimulatorClockNotice(),
          if (analysis != null) ...[
            const SizedBox(height: 12),
            _AnalysisView(analysis: analysis, routing: routing),
            // A comparison is a PLANNING offer: mid-walk the route is locked,
            // so a candidate could never be applied and is not proposed.
            if (!navigating &&
                decision != null &&
                decision.offersAlternative) ...[
              const SizedBox(height: 10),
              _AlternativeOffer(decision: decision),
            ] else if (decision != null && decision.fallback != null) ...[
              const SizedBox(height: 10),
              _message(context, decision.fallback!.message, isError: false),
            ],
          ],
        ],
      ),
    );
  }

  String _subtitle({
    required bool navigating,
    required bool remainingScope,
    required DateTime? departure,
    required DateTime? evaluated,
  }) {
    if (evaluated != null) {
      if (remainingScope) {
        final start = departure;
        final startNote = start == null
            ? ''
            : ' Старт прогулки: ${formatLocalDateTime(start)}.';
        return 'Оценка оставшегося пути на ${formatLocalDateTime(evaluated)} '
            '(${_timezoneLabel(evaluated)}).$startNote';
      }
      final startNote = departure != null && departure != evaluated
          ? ' Старт прогулки: ${formatLocalDateTime(departure)}.'
          : '';
      return 'Расчёт на ${formatLocalDateTime(evaluated)} '
          '(${_timezoneLabel(evaluated)}).$startNote';
    }
    if (navigating) {
      return 'Текущее время прогулки ещё не оценено: рассчитайте тень '
          'для оставшегося пути.';
    }
    if (departure != null) {
      return 'Выбрано время старта ${formatLocalDateTime(departure)} '
          '(${_timezoneLabel(departure)}).';
    }
    return 'Выберите дату и время прогулки — тень зависит от положения Солнца.';
  }

  Widget _message(BuildContext context, String text, {required bool isError}) {
    final palette = AppPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          isError ? Icons.info_outline : Icons.lightbulb_outline,
          size: 16,
          color: isError ? AppColors.warning : palette.textMuted,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: palette.textSecondary),
          ),
        ),
      ],
    );
  }
}

String _timezoneLabel(DateTime value) {
  final offset = value.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hours = offset.inHours.abs().toString().padLeft(2, '0');
  final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
  return 'UTC$sign$hours:$minutes';
}

/// Localised date/time for display (no external localization dependency).
String formatLocalDateTime(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}.${value.year} '
      '${two(value.hour)}:${two(value.minute)}';
}

Future<void> _pickDeparture(
  BuildContext context,
  RoutingProvider routing,
) async {
  final now = DateTime.now();
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.access_time),
            title: const Text('Сейчас'),
            onTap: () => Navigator.of(sheetContext).pop('now'),
          ),
          ListTile(
            leading: const Icon(Icons.today),
            title: const Text('Другое время сегодня'),
            onTap: () => Navigator.of(sheetContext).pop('today'),
          ),
          ListTile(
            leading: const Icon(Icons.event),
            title: const Text('Другая дата и время'),
            onTap: () => Navigator.of(sheetContext).pop('other'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  DateTime selected = now;
  if (choice == 'today') {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null || !context.mounted) return;
    selected = DateTime(now.year, now.month, now.day, time.hour, time.minute);
  } else if (choice == 'other') {
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null || !context.mounted) return;
    selected = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
  }

  // A changed instant invalidates the previous estimate: recomputing for the
  // new time is part of pressing "Оценить тень", but the stale estimate must
  // not stay on screen in the meantime.
  routing.clearShadeAssessment();
  await routing.assessShade(departure: selected, exploreAlternatives: false);
}

class _AnalysisView extends StatelessWidget {
  const _AnalysisView({required this.analysis, required this.routing});

  final ShadeAnalysisModel analysis;
  final RoutingProvider routing;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    if (!analysis.hasEstimate) {
      return Text(
        analysis.statusMessage,
        style: TextStyle(fontSize: 12, color: palette.textSecondary),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HumanEnvironmentalSummary(
          verdict: shadeHumanVerdict(analysis),
          explanation: shadeExplanation,
          coverageNote: shadeCoverageNote(analysis),
          coverageIsPartial: analysis.coverageShare < 0.999,
          detailsTitle: 'Технические подробности оценки тени',
          details: shadeTechnicalDetails(analysis),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Switch(
              value: routing.shadeOverlayEnabled,
              onChanged: routing.setShadeOverlayEnabled,
            ),
            Expanded(
              child: Text(
                'Показывать слой тени на карте',
                style: TextStyle(fontSize: 12, color: palette.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Simulator-only notice (§15): the shade estimate belongs to a virtual
/// instant. While the virtual clock advances, the overlay stays valid only
/// within the documented refresh step; once the model time drifts past it the
/// layer is taken off the map and the user is told why, instead of the app
/// silently re-running the analysis on every tick or leaving a stale layer.
class _SimulatorClockNotice extends StatelessWidget {
  const _SimulatorClockNotice();

  @override
  Widget build(BuildContext context) {
    final clock = Provider.of<VirtualShadeClock?>(context);
    final modelTime = clock?.modelTime;
    if (clock == null || modelTime == null) return const SizedBox.shrink();
    final palette = AppPalette.of(context);
    final analyzedFor = clock.analyzedFor;
    final String text;
    if (!clock.needsReanalysis) {
      text =
          'Виртуальное время симулятора: ${formatLocalDateTime(modelTime)}; '
          'оценка соответствует этому времени.';
    } else if (analyzedFor == null) {
      text =
          'Виртуальное время симулятора: ${formatLocalDateTime(modelTime)}. '
          'Оценка тени для этого времени ещё не рассчитана.';
    } else {
      text =
          'Виртуальное время симулятора: ${formatLocalDateTime(modelTime)} — '
          'оценка рассчитана для ${formatLocalDateTime(analyzedFor)}, '
          'слой тени снят с карты. Пересчитайте оценку для этого времени.';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.timer_outlined,
            size: 16,
            color: AppColors.unusualBadge,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlternativeOffer extends StatelessWidget {
  const _AlternativeOffer({required this.decision});

  final ShadeRoutingDecision decision;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final best = decision.best!;
    final candidatePercent =
        ((best.analysis.comparableShadeFraction ?? 0) * 100).round();
    final normalPercent =
        ((decision.normalAnalysis.comparableShadeFraction ?? 0) * 100).round();
    final extraMinutes = best.extraMinutes.round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Более затенённый вариант: $candidatePercent% в тени '
          '(обычный — $normalPercent%)',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: palette.textPrimary,
          ),
        ),
        Text(
          'Дополнительное время: ${extraMinutes >= 0 ? '+' : ''}$extraMinutes мин · '
          'достоверность: ${best.analysis.confidence.label}',
          style: TextStyle(fontSize: 12, color: palette.textSecondary),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () {
                final applied = context
                    .read<RoutingProvider>()
                    .applyShadeAlternative();
                if (applied && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Выбран более затенённый маршрут.'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Выбрать более затенённый'),
            ),
            OutlinedButton(
              onPressed: () =>
                  context.read<RoutingProvider>().clearShadeAssessment(),
              child: const Text('Оставить обычный'),
            ),
          ],
        ),
      ],
    );
  }
}
