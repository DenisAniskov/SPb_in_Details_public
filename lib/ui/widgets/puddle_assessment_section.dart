import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/environmental_report_card.dart';

/// An opt-in assessment only: no route offer, no road-geometry overlay and no
/// percentage suggesting a probability of an actual puddle. The human result
/// is followed by an explicit data-scope notice; every technical value is in
/// an expandable block.
class PuddleAssessmentSection extends StatelessWidget {
  const PuddleAssessmentSection({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PuddleAssessmentProvider?>();
    if (provider == null || !provider.canAssess) return const SizedBox.shrink();
    final analysis = provider.analysis;
    final evaluated = provider.evaluatedFor;
    final reasons = analysis?.reasons.map(puddleReasonText).toSet() ?? const {};
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Мокрые участки после дождя',
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
                'оценку мокрых участков и помечает оценку тени как требующую '
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
                      : const Icon(Icons.water_drop_outlined),
                  label: Text(
                    provider.navigating
                        ? 'Оценить мокрые участки впереди'
                        : 'Оценить мокрые участки',
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
                  '${provider.scope == PuddleAssessmentScope.remainingPath ? 'Оставшийся путь' : 'Вся прогулка'}: оценка на ${_format(evaluated)}',
                ),
              const SizedBox(height: 6),
              HumanEnvironmentalSummary(
                verdict: puddleHumanVerdict(analysis),
                explanation: puddleExplanation,
                coverageNote: puddleCoverageNote(analysis),
                coverageIsPartial: analysis.coverageShare < 0.999,
                detailsTitle: 'Технические подробности влажных участков',
                visibleDetails: [
                  if (!analysis.hasEstimate && reasons.isNotEmpty) ...[
                    const SizedBox(height: 8),
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
                details: puddleTechnicalDetails(analysis),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Это относительный риск, не вероятность лужи и не гарантия сухого пути. '
              'Сравнение более сухих маршрутов пока недоступно: точности данных недостаточно.',
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
    PuddleAssessmentProvider provider,
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
