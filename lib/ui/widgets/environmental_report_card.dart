import 'package:flutter/material.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/formatting/pollen_units.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';

/// Shared, presentation-only wording for the four environmental assessments.
///
/// The helpers never compute or reinterpret a scientific value: they turn an
/// already validated backend answer into a human sentence, keep the unknown /
/// partial scope visible, and leave every technical number for
/// [HumanEnvironmentalSummary.details]. No threshold, model or API contract is
/// changed here.

String environmentalPercent(double share) {
  final clamped = share.clamp(0.0, 1.0);
  return '${(clamped * 100).round()}%';
}

/// States how much of the walk the model could actually classify. The wording
/// avoids turning the uncovered share into a claim about the whole route.
String environmentalCoverageSentence(
  double share, {
  String full = 'Данными покрыт весь маршрут.',
  String none = 'Подтверждённых данных для этого маршрута нет.',
}) {
  final percent = (share.clamp(0.0, 1.0) * 100).round();
  if (percent >= 100) return full;
  if (percent <= 0) return none;
  return 'Данные покрывают $percent% маршрута; '
      'для ${100 - percent}% оценка неизвестна.';
}

/// Shade: a plain-language result scoped honestly to the classified part.
String shadeHumanVerdict(ShadeAnalysisModel analysis) {
  if (!analysis.hasEstimate) return analysis.statusMessage;
  final percent = ((analysis.shadeFraction ?? 0) * 100).round();
  return analysis.status == ShadeStatus.partial
      ? 'По модели, около $percent% покрытой части маршрута в тени.'
      : 'По модели, около $percent% маршрута в тени.';
}

const String shadeExplanation =
    'Это модельная оценка по данным OpenStreetMap о зданиях и положении '
    'Солнца на выбранное время, а не измерение освещённости.';

/// Puddle: the answer states a relative model level, never a probability that
/// a puddle exists and never a claim that a route without data is dry.
String puddleHumanVerdict(PuddleAnalysisModel? analysis) {
  if (analysis == null) return 'Оценка мокрых участков ещё не выполнялась.';
  if (!analysis.hasEstimate) {
    if (analysis.coverageShare <= 0) {
      return 'Оценить мокрые участки не удалось: подтверждённых данных о '
          'покрытии нет. Это не значит, что маршрут сухой.';
    }
    return 'Оценить мокрые участки не удалось: подтверждённых данных '
        'недостаточно. Это не значит, что маршрут сухой.';
  }
  final scope = analysis.status == PuddleStatus.partial
      ? 'На покрытой части маршрута'
      : 'На маршруте';
  final level = switch (analysis.risk) {
    PuddleRisk.low => 'низкий',
    PuddleRisk.moderate => 'умеренный',
    PuddleRisk.high => 'высокий',
    PuddleRisk.unknown => null,
  };
  if (level == null) {
    return 'Оценить мокрые участки не удалось: данных недостаточно. '
        'Это не значит, что маршрут сухой.';
  }
  return '$scope модель оценивает относительный риск влажного покрытия '
      'как $level.';
}

const String puddleExplanation =
    'Экспериментальная модельная оценка влажности покрытия. Это не '
    'вероятность встретить лужу и не гарантия сухого пути.';

/// Pollen: modelled concentrations by species. A withheld panel and a valid
/// zero are different states, and neither is a medical verdict.
String pollenHumanVerdict(PollenAnalysisModel analysis) {
  if (analysis.hasWithheldNumbers) {
    return 'Значений пыльцы для этой прогулки нет: источник располагал '
        'данными по некоторым видам, но полного набора за час прогулки не '
        'было. Значения не подменены нулями.';
  }
  if (!analysis.hasEstimate) {
    return 'Значений пыльцы для этой прогулки нет.';
  }
  return analysis.status == PollenStatus.partial
      ? 'Модель рассчитала концентрации пыльцы для покрытой части маршрута. '
            'Значения по видам приведены ниже.'
      : 'Модель рассчитала концентрации пыльцы для маршрута. '
            'Значения по видам приведены ниже.';
}

const String pollenExplanation =
    'Это модельные концентрации в воздухе по видам растений, а не измерения '
    'на вашей улице, не вдыхаемая доза и не прогноз самочувствия.';

String environmentalInstant(DateTime value) {
  final local = value.toLocal();
  String two(int number) => '$number'.padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// First sentence of dataset provenance: the full editorial text is long and
/// the version + licence already carry the load-bearing facts.
String environmentalShortProvenance(String provenance) {
  final trimmed = provenance.trim();
  if (trimmed.isEmpty) return 'происхождение не указано.';
  final stop = trimmed.indexOf('. ');
  final first = stop > 0 ? trimmed.substring(0, stop + 1) : trimmed;
  return first.length > 160 ? '${first.substring(0, 157)}…' : first;
}

String? shadeCoverageNote(ShadeAnalysisModel analysis) {
  if (analysis.status == ShadeStatus.partial) {
    return 'Оценка относится к покрытой части маршрута '
        '(${environmentalPercent(analysis.coverageShare)}). '
        'Сколько тени на остальных '
        '${(100 - analysis.coverageShare * 100).round()}%, неизвестно: '
        'эти участки не считаются солнечными.';
  }
  if (!analysis.hasEstimate && analysis.coverageShare <= 0) {
    return 'Для этого маршрута нет проверенных данных о зданиях: '
        'оценка тени недоступна.';
  }
  return null;
}

String? puddleCoverageNote(PuddleAnalysisModel analysis) {
  if (analysis.coverageShare > 0 && analysis.coverageShare < 0.999) {
    return 'Данные покрывают '
        '${environmentalPercent(analysis.coverageShare)} маршрута; '
        'для остальных ${(100 - analysis.coverageShare * 100).round()}% '
        'оценка неизвестна. Эти участки не считаются сухими.';
  }
  if (analysis.coverageShare <= 0) {
    return 'Подтверждённых данных о покрытии нет: 100% маршрута остаются '
        'неизвестными. Это не означает, что луж нет.';
  }
  return null;
}

String? pollenCoverageNote(PollenAnalysisModel analysis) {
  if (analysis.coverageShare > 0 && analysis.coverageShare < 0.999) {
    return 'Данные покрывают '
        '${environmentalPercent(analysis.coverageShare)} маршрута; '
        'для остальной части значений пыльцы нет.';
  }
  if (analysis.coverageShare <= 0) {
    return 'Подтверждённых данных о покрытии нет: значения пыльцы не '
        'рассчитаны.';
  }
  return null;
}

String? quietCoverageNote(QuietAnalysisModel analysis) {
  if (analysis.coverageShare > 0 && analysis.coverageShare < 0.999) {
    return 'Оценка относится только к покрытой части маршрута '
        '(${environmentalPercent(analysis.coverageShare)}). '
        'Остальные ${(100 - analysis.coverageShare * 100).round()}% '
        'не считаются тихими.';
  }
  return null;
}

List<String> shadeTechnicalDetails(ShadeAnalysisModel analysis) => [
  environmentalCoverageSentence(
    analysis.coverageShare,
    none:
        'Для этого маршрута нет проверенных данных о зданиях: '
        'оценка тени недоступна.',
  ),
  if (analysis.hasEstimate)
    'В тени: ${analysis.shadedMeters?.round() ?? 0} м · '
        'на солнце: ${analysis.exposedMeters?.round() ?? 0} м · '
        'неизвестно: ${analysis.unknownMeters?.round() ?? 0} м.',
  'Достоверность: ${analysis.confidence.label} · '
      'датасет: ${analysis.datasetVersion ?? '—'}.',
  'Оценка по OpenStreetMap (ODbL). '
      '${environmentalShortProvenance(analysis.datasetProvenance)}',
  ...analysis.limitations,
];

List<String> puddleTechnicalDetails(PuddleAnalysisModel analysis) => [
  environmentalCoverageSentence(
    analysis.coverageShare,
    none:
        'Подтверждённых данных о покрытии нет: '
        '100% маршрута остаются неизвестными.',
  ),
  'Относительный риск модели: ${analysis.risk.label}.',
  if (analysis.riskIndex != null)
    'Индекс риска: ${analysis.riskIndex!.toStringAsFixed(2)} из 1.00 — '
        'безразмерная величина модели, не вероятность лужи.',
  'Покрытие данными: ${environmentalPercent(analysis.coverageShare)} длины; '
      'неизвестно '
      '${environmentalPercent(analysis.unknownMeters / analysis.routeLengthMeters)}.',
  'Уверенность: '
      '${analysis.confidence == 'low' ? 'низкая' : 'недоступна'}.',
  'Интервал прохождения: ${environmentalInstant(analysis.periodStart)} — '
      '${environmentalInstant(analysis.periodEnd)}.',
  if (analysis.datasetSource.isNotEmpty)
    'Геоданные: ${analysis.datasetSource}; ${analysis.datasetLicense}. '
        'Версия: ${analysis.datasetVersion ?? 'недоступна'}.',
  analysis.weather.provider.isEmpty
      ? 'Погода: источник недоступен.'
      : 'Погода: ${analysis.weather.provider}'
            '${analysis.weather.model.isEmpty ? '' : ', модель ${analysis.weather.model}'}'
            '${analysis.weather.attribution.isEmpty ? '' : ' — ${analysis.weather.attribution}'}'
            '${analysis.weather.license.isEmpty ? '' : '; лицензия ${analysis.weather.license}'}'
            '${analysis.weather.sourceUrl.isEmpty ? '' : '; ${analysis.weather.sourceUrl}'}.',
  if (analysis.weather.retrievedAt != null)
    'Погодные данные получены: '
        '${environmentalInstant(analysis.weather.retrievedAt!)}.',
  if (analysis.weather.validUntil != null)
    'Погодные данные актуальны до: '
        '${environmentalInstant(analysis.weather.validUntil!)}.',
  if (analysis.weather.temporalResolutionSeconds != null)
    'Шаг погоды: ${analysis.weather.temporalResolutionSeconds! ~/ 60} мин; '
        'пространственное разрешение: '
        '${analysis.weather.spatialResolutionMeters == null ? 'неизвестно' : '${(analysis.weather.spatialResolutionMeters! / 1000).toStringAsFixed(1)} км'}.',
  if (analysis.sensitivity != null) ...[
    if (analysis.sensitivity!.variants.isNotEmpty)
      'Устойчивость к параметрам (экспериментально): '
          '${analysis.sensitivity!.variants.entries.map((entry) => '${puddleSensitivityLabel(entry.key)} → ${entry.value.shortLabel}').join('; ')}.',
    if (analysis.sensitivity!.note.isNotEmpty) analysis.sensitivity!.note,
  ],
  for (final reason in analysis.reasons.map(puddleReasonText).toSet()) reason,
  ...analysis.limitations,
];

/// The visible, human-readable concentration block shared by the wizard report
/// and the route card. A withheld panel and a valid zero stay distinguishable.
List<String> pollenConcentrationLines(PollenAnalysisModel analysis) => [
  if (analysis.speciesWithValues.isNotEmpty)
    'Оценочная концентрация пыльцевых зёрен в одном кубическом метре '
        'воздуха.',
  for (final item in analysis.speciesWithValues)
    '${item.name}: ${item.concentrationLabel}',
  if (analysis.speciesWithValues.any((item) => item.meanConcentration == 0))
    'Нулевое значение — это рассчитанная концентрация модели, '
        'а не отсутствие данных.',
  if (analysis.speciesWithValues.isEmpty && analysis.hasWithheldNumbers)
    'Значения в источнике есть (доля времени ходьбы): '
        '${analysis.speciesWithSourceValues.map((item) => '${item.name} — ${(item.knownShare * 100).toStringAsFixed(0)}%').join(', ')}.',
  if (!analysis.hasWithheldNumbers &&
      analysis.speciesWithValues.length < analysis.species.length)
    'Нет данных: '
        '${analysis.species.where((item) => item.meanConcentration == null).map((item) => item.name).join(', ')}.',
];

List<String> pollenTechnicalDetails(PollenAnalysisModel analysis) => [
  environmentalCoverageSentence(
    analysis.coverageShare,
    none:
        'Подтверждённых данных о покрытии нет: значения пыльцы не рассчитаны.',
  ),
  'Покрытие данными: ${environmentalPercent(analysis.coverageShare)} длины; '
      'неизвестно '
      '${environmentalPercent(analysis.unknownMeters / analysis.routeLengthMeters)}.',
  'Уверенность: '
      '${analysis.confidence == 'low' ? 'низкая' : 'недоступна'}.',
  'Интервал прохождения: ${environmentalInstant(analysis.periodStart)} — '
      '${environmentalInstant(analysis.periodEnd)}.',
  if (analysis.hasEstimate)
    'Единица источника: ${analysis.concentrationUnit} '
        '($pollenConcentrationDisplayUnit); значения не пересчитывались.',
  for (final species in analysis.species)
    '${species.name}: среднее ${species.concentrationLabel}; '
        'максимум ${species.peakLabel}; '
        'состояние — ${pollenSpeciesStateLabel(species.state)}.',
  analysis.source.provider.isEmpty
      ? 'Источник пыльцы: недоступен.'
      : 'Источник: ${analysis.source.provider}'
            '${analysis.source.modelName.isEmpty ? '' : ', ${analysis.source.modelName}'}'
            '${analysis.source.attribution.isEmpty ? '' : ' — ${analysis.source.attribution}'}'
            '${analysis.source.license.isEmpty ? '' : '; лицензия ${analysis.source.license}'}'
            '${analysis.source.sourceUrl.isEmpty ? '' : '; ${analysis.source.sourceUrl}'}.',
  if (analysis.source.retrievedAt != null)
    'Данные получены: '
        '${environmentalInstant(analysis.source.retrievedAt!)}.',
  if (analysis.source.validUntil != null)
    'Данные актуальны до: '
        '${environmentalInstant(analysis.source.validUntil!)}.',
  if (analysis.source.temporalResolutionSeconds != null)
    'Шаг по времени: ${analysis.source.temporalResolutionSeconds! ~/ 60} мин; '
        'пространственное разрешение: '
        '${analysis.source.spatialResolutionMeters == null ? 'неизвестно' : '${(analysis.source.spatialResolutionMeters! / 1000).toStringAsFixed(1)} км'}.',
  if (analysis.source.cellLatitude != null &&
      analysis.source.cellLongitude != null)
    'Значения относятся к ячейке модели '
        '${analysis.source.cellLatitude!.toStringAsFixed(2)}° с. ш., '
        '${analysis.source.cellLongitude!.toStringAsFixed(2)}° в. д. '
        '— одна ячейка на всю прогулку.',
  for (final assumption in analysis.assumptions) 'Как считано: $assumption',
  for (final reason in analysis.reasons.map(pollenReasonText).toSet()) reason,
  ...analysis.limitations,
];

List<String> quietTechnicalDetails(QuietAnalysisModel analysis) => [
  environmentalCoverageSentence(
    analysis.coverageShare,
    none:
        'Подтверждённых дорожных данных нет: '
        '100% маршрута остаются неизвестными.',
  ),
  if (analysis.roadNoiseExposureIndex != null)
    'Относительный прокси: '
        '${analysis.roadNoiseExposureIndex!.toStringAsFixed(2)} из 1.00',
  if (analysis.roadNoiseExposureIndex != null)
    'Это безразмерный относительный показатель модели, а не децибелы (дБ) '
        'и не измерение шума.',
  if (analysis.lowExposureShare != null)
    'Доля проверенного пути вдали от крупных автомобильных дорог: '
        '${analysis.lowExposureLabel}. Это не доля тишины.',
  'Покрытие дорожными данными: ${analysis.coverageLabel}; '
      'неизвестно ${(100 - analysis.coverageShare * 100).round()}%.',
  if (analysis.meanNearestRoadDistanceM != null)
    'Среднее расстояние до ближайшей дороги: '
        '${analysis.meanNearestRoadDistanceM!.round()} м.',
  if (analysis.datasetVersion != null)
    'Версия дорожного снимка: ${analysis.datasetVersion}',
  if (analysis.sourceProvenance['attribution'] != null)
    '${analysis.sourceProvenance['attribution']} · '
        '${analysis.sourceProvenance['license'] ?? 'ODbL-1.0'}',
  'Модель: ${analysis.method} ${analysis.methodVersion}; '
      'уверенность: ${analysis.confidence}.',
  'Время используется только для согласования отчёта; '
      'модель не прогнозирует транспортный поток по часам.',
  for (final reason in analysis.reasons.map(quietReasonText).toSet()) reason,
  ...analysis.limitations,
  ...analysis.assumptions,
];

/// Human-first report block: verdict → short explanation → visible data-scope
/// notice → expandable technical details. Used by the wizard report and the
/// route/navigation cards, so all four assessments share one hierarchy.
class HumanEnvironmentalSummary extends StatelessWidget {
  const HumanEnvironmentalSummary({
    super.key,
    required this.verdict,
    required this.explanation,
    this.coverageNote,
    this.coverageIsPartial = false,
    this.detailsTitle = 'Технические подробности',
    this.details = const [],
    this.visibleDetails = const [],
    this.footer,
  });

  final String verdict;
  final String explanation;

  /// Shown directly under the verdict. A partial/none notice must be visible
  /// before any technical expansion: the verdict alone never describes the
  /// uncovered part of the walk.
  final String? coverageNote;
  final bool coverageIsPartial;
  final String detailsTitle;
  final List<String> details;
  final List<Widget> visibleDetails;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          verdict,
          style: TextStyle(
            fontSize: 15,
            height: 1.35,
            fontWeight: FontWeight.bold,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          explanation,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: palette.textSecondary,
          ),
        ),
        if (coverageNote case final note?) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: (coverageIsPartial ? AppColors.warning : palette.primary)
                  .withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  coverageIsPartial
                      ? Icons.info_outline
                      : Icons.data_usage_outlined,
                  size: 16,
                  color: coverageIsPartial
                      ? AppColors.warning
                      : palette.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    note,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: palette.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        ...visibleDetails,
        if (details.isNotEmpty)
          Material(
            type: MaterialType.transparency,
            child: Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 6),
                title: Text(
                  detailsTitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: palette.textSecondary,
                  ),
                ),
                children: [
                  for (final line in details.where(
                    (line) => line.trim().isNotEmpty,
                  ))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          line,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: palette.textMuted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (footer case final footer?) ...[const SizedBox(height: 4), footer],
      ],
    );
  }
}
