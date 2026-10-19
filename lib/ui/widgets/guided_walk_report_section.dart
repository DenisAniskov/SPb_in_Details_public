import 'package:flutter/material.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/controllers/guided_walk_environment_coordinator.dart';
import 'package:smart_navigator_spb/ui/widgets/environmental_report_card.dart';

/// A read-only view of one confirmed route and the coordinator's current
/// report. Scientific values and recommendation rules remain in C7 providers.
class GuidedWalkReportSection extends StatelessWidget {
  const GuidedWalkReportSection({
    super.key,
    required this.routing,
    this.environment,
  });

  final RoutingProvider routing;
  final GuidedWalkEnvironmentCoordinator? environment;

  @override
  Widget build(BuildContext context) {
    final route = routing.currentRoute;
    if (route == null) {
      return const Text('Сначала проверьте пешеходный маршрут.');
    }
    final report = environment?.report;
    final shadeResult = report?.shade ?? environment?.shade;
    final puddleResult = report?.puddle ?? environment?.puddle;
    final pollenResult = report?.pollen ?? environment?.pollen;
    final quietResult = report?.quiet ?? environment?.quiet;
    final shade = shadeResult?.data;
    final puddle = puddleResult?.data;
    final pollen = pollenResult?.data;
    final quiet = quietResult?.data;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (environment?.phase == GuidedWalkEnvironmentPhase.stale) ...[
          const Text('Условия прогулки изменились. Прежние оценки устарели.'),
          FilledButton(
            onPressed: environment!.isRunning ? null : environment!.assess,
            child: const Text('Проверить условия заново'),
          ),
        ],
        _section('Маршрут', [
          Text('Отправление: ${routing.startPoint.title}'),
          for (var i = 0; i < routing.walkPlaces.length; i++)
            Text('${i + 1}. ${routing.walkPlaces[i].title}'),
          Text(
            'По MapKit: ${_distance(route.distanceMeters)} · '
            'ходьба ${_minutes(route.durationSeconds)}',
          ),
          Text(
            'Осмотр: ${routing.visitDurationMinutes} мин · '
            'всего ${_minutes(route.durationSeconds + routing.visitDurationMinutes * 60)}',
          ),
          if (routing.budgetWarningMessage case final message?) Text(message),
        ]),
        _section('Живописность', [
          Text(switch (route.walkKind) {
            WalkKind.scenic => 'Выбран живописный маршрут',
            WalkKind.quiet => 'Выбран более тихий маршрут',
            WalkKind.normal => 'Выбран обычный пешеходный маршрут',
          }),
          for (final stage in route.legs.map((leg) => leg.scenic).nonNulls)
            Text(
              '${stage.featureNames.join(', ')}. '
              '${stage.evidence == ScenicEvidenceLevel.verifiedOnPath ? 'Подтверждено по геометрии пути' : 'Подтверждено прохождение рядом'}',
            ),
          if (route.walkKind != WalkKind.scenic &&
              routing.scenicFallbackMessage != null)
            Text(routing.scenicFallbackMessage!),
        ]),
        if (report?.coverageWarning case final warning?)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(warning),
            ),
          ),
        if (report != null)
          Text('Условия всей прогулки на ${_instant(report.evaluatedFor)}'),
        _section('Тень', [
          if (shade != null)
            HumanEnvironmentalSummary(
              verdict: shadeHumanVerdict(shade),
              explanation: shadeExplanation,
              coverageNote: shadeCoverageNote(shade),
              coverageIsPartial: shade.coverageShare < 0.999,
              detailsTitle: 'Технические подробности оценки тени',
              details: shadeTechnicalDetails(shade),
            )
          else
            Text(_status(shadeResult?.status, shadeResult?.message)),
          if (shade?.hasEstimate == true)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Карта тени'),
              subtitle: const Text('Показать модельный слой на карте'),
              value: routing.shadeOverlayEnabled,
              onChanged: routing.setShadeOverlayEnabled,
            ),
          _retry(GuidedWalkEnvironmentalFactor.shade, shadeResult?.status),
        ]),
        _section('Мокрые участки', [
          if (puddle != null)
            HumanEnvironmentalSummary(
              verdict: puddleHumanVerdict(puddle),
              explanation: puddleExplanation,
              coverageNote: puddleCoverageNote(puddle),
              coverageIsPartial: puddle.coverageShare < 0.999,
              detailsTitle: 'Технические подробности влажных участков',
              details: puddleTechnicalDetails(puddle),
              visibleDetails: [
                if (!puddle.hasEstimate)
                  for (final reason
                      in puddle.reasons.map(puddleReasonText).take(2))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(reason, style: const TextStyle(fontSize: 12)),
                    ),
              ],
            )
          else
            Text(_status(puddleResult?.status, puddleResult?.message)),
          _retry(GuidedWalkEnvironmentalFactor.puddle, puddleResult?.status),
        ]),
        _section('Пыльца', [
          if (pollen != null)
            HumanEnvironmentalSummary(
              verdict: pollenHumanVerdict(pollen),
              explanation: pollen.hasEstimate
                  ? pollenExplanation
                  : '$pollenExplanation Это не означает, что пыльцы нет в '
                        'воздухе.',
              coverageNote: pollenCoverageNote(pollen),
              coverageIsPartial: pollen.coverageShare < 0.999,
              detailsTitle: 'Технические подробности оценки пыльцы',
              details: pollenTechnicalDetails(pollen),
              visibleDetails: [
                const SizedBox(height: 6),
                for (final line in pollenConcentrationLines(pollen))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(line),
                  ),
                if (!pollen.hasEstimate)
                  for (final reason
                      in pollen.reasons.map(pollenReasonText).take(2))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(reason, style: const TextStyle(fontSize: 12)),
                    ),
              ],
            )
          else
            Text(_status(pollenResult?.status, pollenResult?.message)),
          _retry(GuidedWalkEnvironmentalFactor.pollen, pollenResult?.status),
        ]),
        _section('Тишина на маршруте', [
          if (quiet != null)
            HumanEnvironmentalSummary(
              verdict: quiet.hasEstimate
                  ? quiet.summary
                  : _status(quietResult?.status, quietResult?.message),
              explanation:
                  'Оценка показывает близость маршрута к автомобильным '
                  'дорогам по данным OpenStreetMap. Это не дБ, не измерение '
                  'шума и не медицинская оценка.',
              coverageNote: quietCoverageNote(quiet),
              coverageIsPartial: quiet.coverageShare < 0.999,
              detailsTitle: 'Технические подробности оценки тишины',
              details: quietTechnicalDetails(quiet),
            )
          else
            Text(_status(quietResult?.status, quietResult?.message)),
          if (quiet != null &&
              routing.currentRoute?.walkKind == WalkKind.quiet &&
              routing.quietDecision?.offersAlternative == true) ...[
            const SizedBox(height: 8),
            Text(
              'Сравнение с обычным маршрутом: +'
              '${routing.quietDecision!.extraDistanceMeters.round()} м · '
              '+${(routing.quietDecision!.extraWalkingSeconds / 60).ceil()} мин.',
            ),
            Text(routing.quietDecision!.evidenceNote),
          ],
          _retry(GuidedWalkEnvironmentalFactor.quiet, quietResult?.status),
        ]),
        if (report != null && report.recommendations.isNotEmpty)
          _section('Рекомендации', [
            for (final recommendation in report.recommendations.take(3))
              _details(recommendation.title, [
                recommendation.explanation,
                for (final fact in recommendation.facts)
                  '${fact.label}: ${fact.display}',
                recommendation.completenessNote,
                recommendation.sourceLabel,
                ...recommendation.limitations,
              ]),
          ]),
        const Text(
          'Маршрут сохранится после перехода на карту. '
          'Для навигации отдельно нажмите «Начать прогулку».',
        ),
      ],
    );
  }

  Widget _retry(
    GuidedWalkEnvironmentalFactor factor,
    GuidedWalkEnvironmentalStatus? status,
  ) {
    if (environment == null ||
        status == null ||
        status == GuidedWalkEnvironmentalStatus.available ||
        status == GuidedWalkEnvironmentalStatus.partial ||
        status == GuidedWalkEnvironmentalStatus.skipped) {
      return const SizedBox.shrink();
    }
    return TextButton.icon(
      onPressed: environment!.isRunning
          ? null
          : () => environment!.retry(factor),
      icon: const Icon(Icons.refresh),
      label: const Text('Повторить эту проверку'),
    );
  }

  static Widget _section(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );

  static Widget _details(String title, List<String> details) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text(title),
    children: [
      for (final line in details.where((line) => line.trim().isNotEmpty))
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(line)),
    ],
  );

  static String _status(
    GuidedWalkEnvironmentalStatus? status,
    String? message,
  ) {
    if (message != null && message.isNotEmpty) return message;
    return switch (status) {
      GuidedWalkEnvironmentalStatus.skipped => 'Проверка пропущена',
      GuidedWalkEnvironmentalStatus.stale =>
        'Оценка устарела. Повторите проверку условий.',
      GuidedWalkEnvironmentalStatus.running => 'Проверяем…',
      GuidedWalkEnvironmentalStatus.timedOut => 'Источник не ответил вовремя',
      GuidedWalkEnvironmentalStatus.cancelled => 'Проверка отменена',
      null ||
      GuidedWalkEnvironmentalStatus.notAssessed => 'Условия ещё не проверены',
      _ => 'Оценка недоступна',
    };
  }
}

String _distance(double value) => value < 1000
    ? '${value.round()} м'
    : '${(value / 1000).toStringAsFixed(1)} км';
String _minutes(int seconds) => '${(seconds / 60).ceil()} мин';
String _instant(DateTime value) {
  final local = value.toLocal();
  String two(int number) => '$number'.padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} ${two(local.hour)}:${two(local.minute)}';
}
