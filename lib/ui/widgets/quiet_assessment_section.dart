import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/providers/quiet_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/environmental_report_card.dart';

/// Read-only quiet card for the selected walk. It leads with the model's
/// human summary, keeps partial coverage visible, and puts the dimensionless
/// index, provenance and limitations into expandable technical details.
/// It never shows dB, a measured noise level, a health verdict or a guarantee
/// of silence.
class QuietAssessmentSection extends StatelessWidget {
  const QuietAssessmentSection({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<QuietAssessmentProvider?>();
    final routing = context.watch<RoutingProvider>();
    if (provider == null || !provider.canAssess) return const SizedBox.shrink();
    final analysis = provider.analysis;
    final evaluated = provider.evaluatedFor;
    final decision = routing.quietDecision;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Тишина на маршруте',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            if (provider.modelTime != null)
              Text('Время отчёта: ${_format(provider.modelTime!)}'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: provider.isLoading ? null : provider.assess,
                  icon: provider.isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.volume_off_outlined),
                  label: Text(
                    provider.navigating
                        ? 'Оценить тишину впереди'
                        : 'Оценить тишину',
                  ),
                ),
                if (decision?.offersAlternative == true &&
                    routing.currentRoute?.walkKind != WalkKind.quiet &&
                    !provider.navigating)
                  TextButton.icon(
                    onPressed: () =>
                        routing.selectVerifiedWalkVariant(WalkKind.quiet),
                    icon: const Icon(Icons.alt_route),
                    label: const Text('Выбрать более тихий вариант'),
                  ),
              ],
            ),
            if (provider.failure != null) ...[
              const SizedBox(height: 8),
              Text(provider.failure!.message),
            ],
            if (analysis == null) ...[
              const SizedBox(height: 8),
              const Text(
                'Относительная оценка близости к автомобильным дорогам OSM. '
                'Это не дБ, не измерение шума и не медицинская оценка.',
              ),
            ] else ...[
              const SizedBox(height: 10),
              if (evaluated != null)
                Text(
                  '${provider.scope == QuietAssessmentScope.remainingPath ? 'Оставшийся путь' : 'Вся прогулка'}: '
                  'оценка на ${_format(evaluated)}',
                ),
              const SizedBox(height: 6),
              HumanEnvironmentalSummary(
                verdict: analysis.summary,
                explanation:
                    'Оценка показывает близость маршрута к автомобильным '
                    'дорогам по данным OpenStreetMap. Это не дБ, не измерение '
                    'шума и не медицинская оценка.',
                coverageNote: quietCoverageNote(analysis),
                coverageIsPartial: analysis.coverageShare < 0.999,
                detailsTitle: 'Технические подробности оценки тишины',
                details: quietTechnicalDetails(analysis),
              ),
              if (decision != null && decision.offersAlternative) ...[
                const SizedBox(height: 8),
                Text(
                  'Найден более тихий вариант: +'
                  '${decision.extraDistanceMeters.round()} м · '
                  '+${(decision.extraWalkingSeconds / 60).ceil()} мин. '
                  'Покрытие ${(decision.candidateCoverageShare! * 100).round()}%.',
                ),
                Text(decision.evidenceNote),
              ],
            ],
          ],
        ),
      ),
    );
  }

  static String _format(DateTime value) {
    final local = value.toLocal();
    String two(int number) => '$number'.padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
