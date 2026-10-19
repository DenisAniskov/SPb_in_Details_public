import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/services/context_recommendation_engine.dart';
import 'package:smart_navigator_spb/services/recommendation_context.dart';

String _formatInstant(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// Phase C7.4 — «Рекомендации для прогулки».
///
/// A COMPACT summary of the already-verified factors, not a fifth panel
/// duplicating the four cards below: at most [ContextRecommendationEngine
/// .maxVisible] entries are shown at once, every one of them answers
/// «что известно», «почему» and «насколько полны данные», and the rest of the
/// set stays one tap away under «Показать все».
///
/// What this widget never does: invent a recommendation for a factor that was
/// not assessed, hide an unavailable factor without saying why, show a
/// number that the source withheld, combine physically incomparable
/// quantities into a score, change the route, the stops, the planning lock or
/// the walk time, or start an assessment on its own. The only action it offers
/// is the explicit re-run of an existing assessment.
class ContextRecommendationsSection extends StatefulWidget {
  const ContextRecommendationsSection({super.key});

  @override
  State<ContextRecommendationsSection> createState() =>
      _ContextRecommendationsSectionState();
}

class _ContextRecommendationsSectionState
    extends State<ContextRecommendationsSection> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ContextRecommendationProvider?>();
    if (provider == null || !provider.hasRoute || !provider.panelVisible) {
      return const SizedBox.shrink();
    }
    final palette = AppPalette.of(context);
    final context0 = provider.context;
    final recommendations = provider.recommendations;
    final visible = _showAll
        ? recommendations
        : provider.visibleRecommendations;

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
                Icons.auto_awesome_outlined,
                size: 18,
                color: AppColors.secondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Рекомендации для прогулки',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Скрыть рекомендации для текущей прогулки',
                onPressed: provider.hideForCurrentWalk,
                icon: const Icon(Icons.visibility_off_outlined, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _scopeLine(context0),
            style: TextStyle(fontSize: 11.5, color: palette.textMuted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final preference in RecommendationPreference.values)
                ChoiceChip(
                  label: Text(
                    _preferenceLabel(preference),
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  selected: provider.preference == preference,
                  onSelected: (_) => provider.setPreference(preference),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (recommendations.isEmpty)
            Text(
              'Рекомендаций пока нет: ни один фактор не оценён. '
              'Запустите оценку в карточке нужного фактора ниже — '
              'рекомендации построятся из её результата. Автоматически '
              'ничего не рассчитывается.',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: palette.textSecondary,
              ),
            )
          else ...[
            for (final recommendation in visible)
              _RecommendationCard(
                key: ValueKey(recommendation.id),
                recommendation: recommendation,
                loading: provider.isLoading(recommendation.factor),
                onRecompute: () => provider.recompute(recommendation.factor),
              ),
            if (recommendations.length > ContextRecommendationEngine.maxVisible)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _showAll = !_showAll),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(48, 40),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    _showAll
                        ? 'Свернуть'
                        : 'Показать все (${recommendations.length})',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
          if (context0.sources.isNotEmpty)
            _SourceReports(reports: context0.sources),
          const SizedBox(height: 6),
          Text(
            'Это отдельные факты по каждому фактору: общий балл не '
            'вычисляется, потому что тень, увлажнение покрытия, пыльца и '
            'время ходьбы несопоставимы. Маршрут, остановки и время прогулки '
            'рекомендации не меняют.',
            style: TextStyle(
              fontSize: 11,
              height: 1.35,
              color: palette.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  String _scopeLine(RecommendationContext context0) {
    final scope = recommendationScopeLabel(context0.scope);
    final instant = context0.referenceInstant;
    if (instant == null) {
      return 'Область: $scope. Оценок, привязанных ко времени, пока нет.';
    }
    return 'Область: $scope. Факты относятся к ${_formatInstant(instant)}: '
        'оценки, сделанные для другого времени, сюда не подставляются.';
  }

  static String _preferenceLabel(RecommendationPreference preference) =>
      switch (preference) {
        RecommendationPreference.all => 'Все факторы',
        RecommendationPreference.shade => 'Больше тени',
        RecommendationPreference.scenic => 'Больше живописности',
      };
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({
    super.key,
    required this.recommendation,
    required this.loading,
    required this.onRecompute,
  });

  final ContextRecommendation recommendation;
  final bool loading;
  final VoidCallback onRecompute;

  /// Inline facts are capped so the panel stays compact; the full list is
  /// always inside the expandable explanation.
  static const int _inlineFacts = 4;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final facts = recommendation.facts;
    final inline = facts.take(_inlineFacts).toList();
    final hidden = facts.length - inline.length;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _factorIcon(recommendation.factor),
                size: 16,
                color: palette.secondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recommendation.title,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        fontWeight: FontWeight.bold,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${recommendationFactorLabel(recommendation.factor)} · '
                      '${_availabilityLabel(recommendation.availability)}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: palette.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (inline.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final fact in inline)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${fact.label}: ${fact.display}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.textSecondary,
                  ),
                ),
              ),
            if (hidden > 0)
              Text(
                'и ещё $hidden ${hidden == 1 ? 'значение' : 'значения'} — '
                'в подробностях ниже.',
                style: TextStyle(
                  fontSize: 10.5,
                  fontStyle: FontStyle.italic,
                  color: palette.textMuted,
                ),
              ),
          ],
          const SizedBox(height: 4),
          Text(
            recommendation.completenessNote,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.3,
              color: palette.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          // The "why" and the full provenance — the second and third question
          // the card must answer, one tap away instead of always on screen.
          Material(
            type: MaterialType.transparency,
            child: Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 4),
                title: Text(
                  'Почему и насколько надёжно',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: palette.textSecondary,
                  ),
                ),
                children: [
                  _detail(context, recommendation.explanation),
                  for (var i = _inlineFacts; i < facts.length; i++)
                    _detail(
                      context,
                      '${facts[i].label}: ${facts[i].display}',
                      bullet: true,
                    ),
                  if (recommendation.sourceLabel.isNotEmpty)
                    _detail(
                      context,
                      'Источник: ${recommendation.sourceLabel}.',
                      bullet: true,
                    ),
                  if (recommendation.method.isNotEmpty)
                    _detail(
                      context,
                      'Метод: ${recommendation.method}, версия '
                      '${recommendation.methodVersion.isEmpty ? 'не указана' : recommendation.methodVersion}.',
                      bullet: true,
                    ),
                  _detail(
                    context,
                    'Область: '
                    '${recommendationScopeLabel(recommendation.scope)}'
                    '${recommendation.evaluatedFor == null ? ' (время оценки не определено)' : ', оценка на ${_formatInstant(recommendation.evaluatedFor!)}'}.',
                    bullet: true,
                  ),
                  for (final limitation in recommendation.limitations)
                    _detail(context, limitation, bullet: true),
                ],
              ),
            ),
          ),
          if (recommendation.action != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: loading ? null : onRecompute,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(48, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: loading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 15),
                label: Text(
                  recommendation.action!.label,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context, String text, {bool bullet = false}) =>
      Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            bullet ? '• $text' : text,
            style: TextStyle(
              fontSize: 11,
              height: 1.35,
              color: AppPalette.of(context).textSecondary,
            ),
          ),
        ),
      );

  static IconData _factorIcon(RecommendationFactor factor) => switch (factor) {
    RecommendationFactor.shade => Icons.wb_shade_outlined,
    RecommendationFactor.puddle => Icons.water_drop_outlined,
    RecommendationFactor.pollen => Icons.grass_outlined,
    RecommendationFactor.scenic => Icons.landscape_outlined,
  };

  static String _availabilityLabel(RecommendationAvailability availability) =>
      switch (availability) {
        RecommendationAvailability.available => 'данные полные',
        RecommendationAvailability.limited => 'данные частичные',
        RecommendationAvailability.withheld => 'числа удержаны',
        RecommendationAvailability.unavailable => 'данных нет',
      };
}

/// «Почему не учтены другие факторы» — the reasons other factors are absent
/// from the set, so an unassessed or excluded factor is never silently
/// missing. Collapsed by default to keep the panel compact.
class _SourceReports extends StatelessWidget {
  const _SourceReports({required this.reports});

  final List<RecommendationSourceReport> reports;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 4),
          title: Text(
            'Почему не учтены другие факторы (${reports.length})',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: palette.textSecondary,
            ),
          ),
          children: [
            for (final report in reports)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• ${report.message}',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: palette.textMuted,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
