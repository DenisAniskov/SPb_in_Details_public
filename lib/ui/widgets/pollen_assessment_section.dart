import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/environmental_report_card.dart';

/// An opt-in assessment only: pollen CONCENTRATIONS per species with their
/// source and coverage. There is no danger level, no "allergy risk" and no
/// route offer here — the source does not provide thresholds, so the card does
/// not invent any (ТЗ C7.3 §4). The human result comes first; technical
/// values, provenance and limitations live in an expandable block.
class PollenAssessmentSection extends StatelessWidget {
  const PollenAssessmentSection({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PollenAssessmentProvider?>();
    if (provider == null || !provider.canAssess) return const SizedBox.shrink();
    final analysis = provider.analysis;
    final evaluated = provider.evaluatedFor;
    final reasons = analysis?.reasons.map(pollenReasonText).toSet() ?? const {};
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Пыльца на маршруте',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              provider.navigating
                  ? 'Оценка пути впереди от текущего времени. Текущая прогулка сохраняется.'
                  : 'Необязательная экспериментальная оценка существующего маршрута.',
            ),
            if (provider.modelTime != null)
              Text('Время симуляции: ${_format(provider.modelTime!)}'),
            if (provider.usesSharedSimulationTime)
              const Text(
                'Это общее время симуляции. Его смена сбрасывает прежнюю '
                'оценку пыльцы и помечает оценку тени как требующую '
                'пересчёта (устаревший слой тени не показывается).',
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!provider.navigating)
                  TextButton.icon(
                    onPressed: provider.isLoading
                        ? null
                        : () => _pickTime(context, provider),
                    icon: const Icon(Icons.schedule),
                    label: Text(
                      provider.selectedDeparture == null
                          ? (provider.usesSharedSimulationTime
                                ? 'Время симуляции'
                                : 'Время оценки')
                          : _format(provider.selectedDeparture!),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: provider.isLoading ? null : provider.assess,
                  icon: provider.isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.grass_outlined),
                  label: Text(
                    provider.navigating
                        ? 'Оценить пыльцу впереди'
                        : 'Оценить пыльцу',
                  ),
                ),
              ],
            ),
            if (provider.failure != null) ...[
              const SizedBox(height: 8),
              Text(provider.failure!.message),
            ],
            if (analysis != null) ...[
              const SizedBox(height: 10),
              if (evaluated != null)
                Text(
                  '${provider.scope == PollenAssessmentScope.remainingPath ? 'Оставшийся путь' : 'Вся прогулка'}: оценка на ${_format(evaluated)}',
                ),
              const SizedBox(height: 6),
              HumanEnvironmentalSummary(
                verdict: pollenHumanVerdict(analysis),
                explanation: analysis.hasEstimate
                    ? pollenExplanation
                    : '$pollenExplanation Это не означает, что пыльцы нет в '
                          'воздухе.',
                coverageNote: pollenCoverageNote(analysis),
                coverageIsPartial: analysis.coverageShare < 0.999,
                detailsTitle: 'Технические подробности оценки пыльцы',
                visibleDetails: [
                  const SizedBox(height: 8),
                  for (final line in pollenConcentrationLines(analysis))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(line),
                    ),
                  if (!analysis.hasEstimate && reasons.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    for (final reason in reasons.take(2))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          reason,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ],
                details: pollenTechnicalDetails(analysis),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Это концентрации пыльцы в воздухе, а не прогноз симптомов.',
            ),
            const SizedBox(height: 4),
            const Text(
              'Это модельный прогноз, а не измерение на вашей улице и не '
              'вдыхаемая доза. Порогов и медицинских выводов здесь нет: '
              'сравнение маршрутов по пыльце не выполняется.',
            ),
          ],
        ),
      ),
    );
  }

  static String _format(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _pickTime(
    BuildContext context,
    PollenAssessmentProvider provider,
  ) async {
    final current =
        provider.selectedDeparture ?? provider.modelTime ?? DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(current.year - 1),
      lastDate: DateTime(current.year + 1, 12, 31),
    );
    if (day == null || !context.mounted || provider.navigating) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null || !context.mounted || provider.navigating) return;
    provider.selectDeparture(
      DateTime(day.year, day.month, day.day, time.hour, time.minute),
    );
  }
}
