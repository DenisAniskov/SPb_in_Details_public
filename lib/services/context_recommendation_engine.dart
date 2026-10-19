import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/services/recommendation_context.dart';

/// Phase C7.4 — the deterministic recommendation engine.
///
/// Pure Dart over the results of the already-verified models: no services, no
/// clock, no `DateTime.now()`, no I/O. The instant a statement is built for
/// comes from [RecommendationContext]; the engine never reads the wall clock,
/// which is what makes «повторное вычисление на одинаковом наборе входов даёт
/// идентичный список рекомендаций» (ТЗ C7.4 §9.16) true by construction.
///
/// It does NOT re-implement any physics: shade metres, wet-surface metres,
/// pollen concentrations and walking minutes are read from the models as they
/// are and reported side by side with their own units. There is intentionally
/// no combined index and no cross-factor spatial claim (ТЗ C7.4 §4.5): saying
/// "the wettest stretch is also the shadiest" would require an intersection
/// that this phase does not compute.
///
/// Every rule is documented with its preconditions, required fields, mandatory
/// completeness, conclusion, allowed action and its own test.
class ContextRecommendationEngine {
  const ContextRecommendationEngine();

  /// How many entries the section shows before «Показать все». This is a UI
  /// POLICY, not a rating: the full ordered list is always available and the
  /// order is documented in [orderFor].
  static const int maxVisible = 3;

  /// The documented order of the factors for a preference. The preference
  /// changes order and visibility only — never a model, a route or the lock.
  ///
  /// * `all` — the default order the cards themselves follow on the sheet:
  ///   shade, puddle, pollen, scenic;
  /// * `shade` — the same order (shade already leads), PLUS the entry that
  ///   names the missing shade assessment, so preferring shade is visibly
  ///   different from the default even before anything was assessed;
  /// * `scenic` — the scenic entries lead, because a user who asked for a
  ///   scenic walk asks first about the scenic trade-off.
  static List<RecommendationFactor> orderFor(
    RecommendationPreference preference,
  ) => switch (preference) {
    RecommendationPreference.all => const [
      RecommendationFactor.shade,
      RecommendationFactor.puddle,
      RecommendationFactor.pollen,
      RecommendationFactor.scenic,
    ],
    RecommendationPreference.shade => const [
      RecommendationFactor.shade,
      RecommendationFactor.puddle,
      RecommendationFactor.pollen,
      RecommendationFactor.scenic,
    ],
    RecommendationPreference.scenic => const [
      RecommendationFactor.scenic,
      RecommendationFactor.shade,
      RecommendationFactor.puddle,
      RecommendationFactor.pollen,
    ],
  };

  /// Builds the ordered recommendation set of one verified context.
  List<ContextRecommendation> build(RecommendationContext context) {
    if (!context.hasRoute) return const [];
    final entries = <ContextRecommendation>[];

    final shade = context.shade;
    if (shade != null) {
      entries.add(_shadeEntry(context, shade));
    } else if (context.preference == RecommendationPreference.shade) {
      entries.add(_shadeNotAssessedEntry(context));
    }
    final puddle = context.puddle;
    if (puddle != null) entries.add(_puddleEntry(context, puddle));
    final pollen = context.pollen;
    if (pollen != null) entries.add(_pollenEntry(context, pollen));
    final comparison = context.scenicComparison;
    if (comparison != null) {
      entries.add(_scenicComparisonEntry(context, comparison));
    } else if (context.scenicFallbackMessage != null) {
      entries.add(_scenicFallbackEntry(context));
    }

    final order = orderFor(context.preference);
    entries.sort((a, b) {
      final byFactor = order
          .indexOf(a.factor)
          .compareTo(order.indexOf(b.factor));
      return byFactor != 0 ? byFactor : a.id.compareTo(b.id);
    });
    return List.unmodifiable(entries);
  }

  // ------------------------------------------------------------------ shade

  ContextRecommendation _shadeEntry(
    RecommendationContext context,
    AdmittedFacts<ShadeAnalysisModel> admitted,
  ) {
    final analysis = admitted.facts;
    if (!analysis.hasEstimate) {
      // The estimate exists and honestly produced no numbers (sun below the
      // horizon, route outside the mapped buildings, …). The model's own
      // status message is the explanation — never a fabricated percentage.
      return ContextRecommendation(
        id: 'shade.no_estimate',
        factor: RecommendationFactor.shade,
        availability: RecommendationAvailability.unavailable,
        title: 'Тень: числовой оценки нет',
        explanation: analysis.statusMessage,
        facts: const [],
        completenessNote:
            'Числовых значений в ответе нет — сравнивать и '
            'показывать нечего.',
        limitations: analysis.limitations,
        method: analysis.method,
        methodVersion: analysis.methodVersion,
        sourceLabel: _shadeSourceLabel,
        scope: context.scope,
        evaluatedFor: admitted.evaluatedFor,
        action: _recompute('Пересчитать тень'),
      );
    }

    final percent = _percent(analysis.shadeFraction ?? 0);
    final unknownPercent = _percent(
      analysis.routeLengthMeters <= 0
          ? 0
          : (analysis.unknownMeters ?? 0) / analysis.routeLengthMeters,
    );
    final unknown = (analysis.unknownMeters ?? 0) > 0.05;
    final facts = <RecommendationFact>[
      RecommendationFact(
        label: 'В тени',
        value: _meters(analysis.shadedMeters ?? 0),
        unit: 'м',
      ),
      RecommendationFact(
        label: 'На солнце',
        value: _meters(analysis.exposedMeters ?? 0),
        unit: 'м',
      ),
      RecommendationFact(
        label: 'Неизвестно',
        value: _meters(analysis.unknownMeters ?? 0),
        unit: 'м',
      ),
      RecommendationFact(
        label: 'Оценено (тень/солнце)',
        value: _percent(analysis.classifiedShare),
      ),
      if ((analysis.datasetVersion ?? '').isNotEmpty)
        RecommendationFact(
          label: 'Данные о зданиях',
          value: analysis.datasetVersion!,
        ),
    ];
    return ContextRecommendation(
      id: 'shade.estimate',
      factor: RecommendationFactor.shade,
      availability: analysis.status == ShadeStatus.available && !unknown
          ? RecommendationAvailability.available
          : RecommendationAvailability.limited,
      title: 'Тень: $percent маршрута в тени',
      // The exact wording the ТЗ asks for, and the two things a shade
      // estimate may never silently imply: another hour, and a "comfort"
      // threshold that the dataset does not define.
      explanation:
          'Для этой прогулки рассчитана тень на $percent маршрута; '
          'неизвестная часть — $unknownPercent. Оценка выполнена для одного '
          'момента времени, о других часах она ничего не утверждает.',
      facts: facts,
      completenessNote:
          'Модель классифицировала ${_percent(analysis.classifiedShare)} '
          'длины маршрута; доля внутри покрытых данными зон — '
          '${_percent(analysis.coverageShare)}. Достоверность: '
          '${analysis.confidence.label.toLowerCase()}.',
      limitations: analysis.limitations,
      method: analysis.method,
      methodVersion: analysis.methodVersion,
      sourceLabel: _shadeSourceLabel,
      scope: context.scope,
      evaluatedFor: admitted.evaluatedFor,
      action: _recompute(
        context.planning ? 'Пересчитать тень' : 'Пересчитать для пути впереди',
      ),
    );
  }

  /// Only under the `shade` preference: the user asked for a shade-first walk
  /// and just needs the explicit entry that names the missing estimate. It
  /// makes no claim about any hour.
  ContextRecommendation _shadeNotAssessedEntry(RecommendationContext context) =>
      ContextRecommendation(
        id: 'shade.not_assessed',
        factor: RecommendationFactor.shade,
        availability: RecommendationAvailability.unavailable,
        title: 'Тень пока не рассчитана',
        explanation:
            'Вы выбрали приоритет тени. Запустите оценку — она выполнится '
            'для текущего маршрута и времени, и ничего не изменит в самой прогулке.',
        facts: const [],
        completenessNote:
            'Данных нет: оценка не выполнялась. Она выполняется '
            'только по явному нажатию.',
        limitations: const [
          'Оценка тени не рассчитывается автоматически и не подменяется '
              'предположением о времени суток.',
        ],
        method: '',
        methodVersion: '',
        sourceLabel: '',
        scope: context.scope,
        evaluatedFor: null,
        action: _recompute('Оценить тень'),
      );

  static const String _shadeSourceLabel = 'OpenStreetMap (ODbL)';

  // ----------------------------------------------------------------- puddle

  ContextRecommendation _puddleEntry(
    RecommendationContext context,
    AdmittedFacts<PuddleAnalysisModel> admitted,
  ) {
    final analysis = admitted.facts;
    final sensitivityNote = _sensitivitySentence(analysis.sensitivity);
    if (!analysis.hasEstimate) {
      // Risk unknown / unavailable / outside coverage: the entry explains the
      // limitation and states explicitly that no dryness conclusion follows.
      // "Только объяснение ограничений, никаких выводов о сухости" (ТЗ §4.2).
      final reasons = analysis.reasons.map(puddleReasonText).toSet().join(' ');
      return ContextRecommendation(
        id: 'puddle.no_estimate',
        factor: RecommendationFactor.puddle,
        availability: RecommendationAvailability.unavailable,
        title: 'Мокрые участки: числовой оценки нет',
        explanation: reasons.isEmpty
            ? 'Классификации участков нет: модель не получила достаточных '
                  'данных. Выводов о сухости покрытия сделать нельзя.'
            : '$reasons Выводов о сухости покрытия сделать нельзя.',
        facts: [
          RecommendationFact(
            label: 'Оценено покрытие',
            value: _percent(analysis.coverageShare),
          ),
        ],
        completenessNote:
            'Модель оценила ${_percent(analysis.coverageShare)} '
            'длины маршрута; остальное осталось неизвестным.',
        limitations: analysis.limitations,
        method: analysis.method,
        methodVersion: analysis.methodVersion,
        sourceLabel: _puddleSourceLabel(analysis),
        scope: context.scope,
        evaluatedFor: admitted.evaluatedFor,
        action: _recompute('Пересчитать оценку'),
      );
    }

    final high = analysis.highMeters.round();
    final moderate = analysis.moderateMeters.round();
    final low = analysis.lowMeters.round();
    final unknown = analysis.unknownMeters.round();
    final unstable = sensitivityNote.isNotEmpty;
    final facts = <RecommendationFact>[
      RecommendationFact(
        label: 'Высокий относительный риск',
        value: '$high',
        unit: 'м',
      ),
      RecommendationFact(label: 'Умеренный', value: '$moderate', unit: 'м'),
      RecommendationFact(
        label: 'Оценено покрытие',
        value: _percent(analysis.coverageShare),
      ),
      RecommendationFact(label: 'Неизвестно', value: '$unknown', unit: 'м'),
      if (analysis.weather.provider.isNotEmpty)
        RecommendationFact(
          label: 'Прогноз осадков',
          value: [
            analysis.weather.provider,
            analysis.weather.model,
          ].where((part) => part.isNotEmpty).join(' '),
        ),
      if (analysis.weather.validUntil != null)
        RecommendationFact(
          label: 'Погода актуальна до',
          value: _instant(analysis.weather.validUntil!),
        ),
      if ((analysis.datasetVersion ?? '').isNotEmpty)
        RecommendationFact(
          label: 'Данные о покрытии',
          value: analysis.datasetVersion!,
        ),
    ];
    const experimental =
        'Это относительная оценка увлажнения покрытия, а не подтверждение '
        'луж: модель не откалибрована на местности.';
    final String title;
    final String explanation;
    if (high > 0) {
      title =
          'Изучите перед выходом: $high м с высоким относительным риском '
          'мокрого покрытия';
      explanation =
          'Экспериментальная модель отметила $high м маршрута как '
          'участки с высоким относительным риском увлажнения покрытия.'
          '${unstable ? ' $sensitivityNote' : ''} $experimental';
    } else {
      title = 'Мокрые участки: высокого относительного риска не выделено';
      explanation =
          'Среди оценённых моделью участков нет участков с высоким '
          'относительным риском: $moderate м с умеренным, $low м с низким.'
          '${unstable ? ' $sensitivityNote' : ''} Это не означает, что '
          'покрытие сухое: оценка относительная, не откалибрована и не '
          'подтверждает отсутствие луж.';
    }
    return ContextRecommendation(
      id: high > 0 ? 'puddle.high_sections' : 'puddle.no_high_sections',
      factor: RecommendationFactor.puddle,
      // The puddle model is experimental and never fully covered, so its
      // entries are labelled `limited` even when the classification exists.
      availability: RecommendationAvailability.limited,
      title: title,
      explanation: explanation,
      facts: facts,
      completenessNote:
          'Модель оценила ${_percent(analysis.coverageShare)} '
          'длины маршрута; $unknown м остались неизвестными. Достоверность: '
          '${analysis.confidence == 'low' ? 'низкая (без калибровки)' : 'недоступна'}.'
          '${unstable ? ' Классификация зависит от параметров модели.' : ''}',
      limitations: analysis.limitations,
      method: analysis.method,
      methodVersion: analysis.methodVersion,
      sourceLabel: _puddleSourceLabel(analysis),
      scope: context.scope,
      evaluatedFor: admitted.evaluatedFor,
      action: _recompute('Пересчитать оценку'),
    );
  }

  /// The parameter uncertainty is part of the conclusion when the model's own
  /// variants disagree with the baseline (ТЗ C7.4 §4.2): the recommendation
  /// must carry it rather than present one parameter choice as the answer.
  static String _sensitivitySentence(PuddleSensitivity? sensitivity) {
    if (sensitivity == null) return '';
    final differing = sensitivity.variants.entries
        .where((entry) => entry.value != sensitivity.baseline)
        .toList();
    if (differing.isEmpty) return '';
    final spread = differing
        .map(
          (entry) =>
              '${puddleSensitivityLabel(entry.key)} → ${entry.value.shortLabel}',
        )
        .join('; ');
    return 'При других допустимых параметрах модели классификация меняется '
        '($spread): устойчивость результата ограничена.';
  }

  static String _puddleSourceLabel(PuddleAnalysisModel analysis) {
    final dataset = analysis.datasetSource.isEmpty
        ? 'геоданные не указаны'
        : analysis.datasetSource;
    final licence = analysis.datasetLicense.isEmpty
        ? ''
        : ' (${analysis.datasetLicense})';
    final weather = [
      analysis.weather.provider,
      analysis.weather.model,
    ].where((part) => part.isNotEmpty).join(' ');
    return weather.isEmpty ? '$dataset$licence' : '$dataset$licence + $weather';
  }

  // ----------------------------------------------------------------- pollen

  ContextRecommendation _pollenEntry(
    RecommendationContext context,
    AdmittedFacts<PollenAnalysisModel> admitted,
  ) {
    final analysis = admitted.facts;
    if (analysis.hasWithheldNumbers) return _pollenWithheld(context, admitted);
    if (analysis.hasEstimate && analysis.speciesWithValues.isNotEmpty) {
      return _pollenConcentrations(context, admitted);
    }
    return _pollenUnavailable(context, admitted);
  }

  ContextRecommendation _pollenConcentrations(
    RecommendationContext context,
    AdmittedFacts<PollenAnalysisModel> admitted,
  ) {
    final analysis = admitted.facts;
    final unit = analysis.concentrationUnit;
    final valued = analysis.speciesWithValues;
    final gaps = analysis.species
        .where((item) => item.meanConcentration == null)
        .map((item) => item.name)
        .toList();
    final partialSpecies = valued
        .where((item) => item.knownShare < 1 - 1e-9)
        .map(
          (item) =>
              '${item.name} — ${_percent(item.knownShare)} времени ходьбы',
        )
        .toList();
    return ContextRecommendation(
      id: 'pollen.concentrations',
      factor: RecommendationFactor.pollen,
      availability: gaps.isEmpty && analysis.coverageShare >= 1 - 1e-9
          ? RecommendationAvailability.available
          : RecommendationAvailability.limited,
      title: 'Пыльца: концентрации по видам за время прогулки',
      explanation:
          'Значения — модельный прогноз концентрации в воздухе для '
          'часов прогулки, по видам отдельно: единый индекс из них не '
          'строится. Ноль — подтверждённое моделью значение, а не гарантия '
          'отсутствия аллергенов.',
      facts: [
        for (final item in valued)
          RecommendationFact(
            label: item.name,
            value: _concentration(item.meanConcentration!),
            unit: unit,
          ),
        RecommendationFact(
          label: 'Покрытие источника',
          value: _percent(analysis.coverageShare),
        ),
      ],
      completenessNote:
          'Покрытие источника: ${_percent(analysis.coverageShare)} длины '
          'маршрута.'
          '${gaps.isEmpty ? '' : ' Без значений: ${gaps.join(', ')}.'}'
          '${partialSpecies.isEmpty ? '' : ' Покрытие по видам: ${partialSpecies.join(', ')}.'}',
      limitations: analysis.limitations,
      method: analysis.method,
      methodVersion: analysis.methodVersion,
      sourceLabel: _pollenSourceLabel(analysis),
      scope: context.scope,
      evaluatedFor: admitted.evaluatedFor,
      action: _recompute('Пересчитать оценку'),
    );
  }

  /// The C7.3.1 withheld panel: the source HAD values, no hour carried the
  /// whole six-species panel, so the answer publishes no concentrations.
  /// The entry names the species and their coverage and restores NOTHING from
  /// `known_share` or the diagnostics (ТЗ C7.4 §4.3).
  ContextRecommendation _pollenWithheld(
    RecommendationContext context,
    AdmittedFacts<PollenAnalysisModel> admitted,
  ) {
    final analysis = admitted.facts;
    final source = analysis.speciesWithSourceValues;
    return ContextRecommendation(
      id: 'pollen.withheld',
      factor: RecommendationFactor.pollen,
      availability: RecommendationAvailability.withheld,
      title: 'Пыльца: значения удержаны — полного набора по видам нет',
      explanation:
          'В источнике есть значения по видам '
          '(${source.map((item) => item.name).join(', ')}), но ни на одном '
          'часе прогулки нет значений по всем шести видам сразу, поэтому '
          'числа не публикуются: часть не должна выглядеть как целое. '
          'Концентрации из доли покрытия не восстанавливаются.',
      facts: [
        for (final item in source)
          RecommendationFact(
            label: item.name,
            value: _percent(item.knownShare),
            unit: 'времени ходьбы',
          ),
        RecommendationFact(
          label: 'Покрытие источника',
          value: _percent(analysis.coverageShare),
        ),
      ],
      completenessNote:
          'Числовых концентраций в ответе нет; доли покрытия '
          'показывают, за какую часть времени ходьбы значения в источнике есть.',
      limitations: analysis.limitations,
      method: analysis.method,
      methodVersion: analysis.methodVersion,
      sourceLabel: _pollenSourceLabel(analysis),
      scope: context.scope,
      evaluatedFor: admitted.evaluatedFor,
      action: null,
    );
  }

  ContextRecommendation _pollenUnavailable(
    RecommendationContext context,
    AdmittedFacts<PollenAnalysisModel> admitted,
  ) {
    final analysis = admitted.facts;
    final reasons = analysis.reasons.map(pollenReasonText).toSet().join(' ');
    final notConfigured = analysis.reasons.contains('pollen_not_configured');
    return ContextRecommendation(
      id: 'pollen.no_values',
      factor: RecommendationFactor.pollen,
      availability: RecommendationAvailability.unavailable,
      title: notConfigured
          ? 'Пыльца: источник не подключён'
          : 'Пыльца: числовых значений нет',
      explanation: reasons.isEmpty
          ? 'Числовых концентраций в ответе нет. Это не означает отсутствия '
                'пыльцы в воздухе — это означает отсутствие данных.'
          : '$reasons Это не означает отсутствия пыльцы в воздухе — это '
                'означает отсутствие данных.',
      facts: [
        RecommendationFact(
          label: 'Покрытие источника',
          value: _percent(analysis.coverageShare),
        ),
      ],
      completenessNote:
          'Числовых концентраций в ответе нет; показывать '
          'нечего.',
      limitations: analysis.limitations,
      method: analysis.method,
      methodVersion: analysis.methodVersion,
      sourceLabel: _pollenSourceLabel(analysis),
      scope: context.scope,
      evaluatedFor: admitted.evaluatedFor,
      action: _recompute('Пересчитать оценку'),
    );
  }

  static String _pollenSourceLabel(PollenAnalysisModel analysis) {
    final parts = [
      analysis.source.provider,
      analysis.source.modelName.isEmpty
          ? analysis.source.model
          : analysis.source.modelName,
    ].where((part) => part.isNotEmpty);
    return parts.isEmpty ? 'источник не указан' : parts.join(', ');
  }

  // ----------------------------------------------------------------- scenic

  /// A VALIDATED comparison of the built walk with its normal variant: both
  /// sides are real native MapKit results for the same stops (Phase C5 §7.2).
  /// The phase never creates new scenic candidates and never starts a router.
  ContextRecommendation _scenicComparisonEntry(
    RecommendationContext context,
    RouteComparison comparison,
  ) {
    final extraSeconds = comparison.extraWalkingSeconds;
    final extraMinutes = (extraSeconds / 60).round();
    final extraMeters = comparison.extraDistanceMeters;
    final extraLabel = extraSeconds > 0
        ? '+$extraMinutes мин'
        : 'без лишнего времени';
    final facts = <RecommendationFact>[
      RecommendationFact(
        label: 'Обычный вариант',
        value: '${(comparison.normalWalkingSeconds / 60).round()}',
        unit: 'мин ходьбы',
      ),
      RecommendationFact(
        label: 'Живописный вариант',
        value: '${(comparison.scenicWalkingSeconds / 60).round()}',
        unit: 'мин ходьбы',
      ),
      RecommendationFact(
        label: 'Разница',
        value:
            '${extraSeconds >= 0 ? '+' : ''}$extraMinutes мин, '
            '${extraMeters >= 0 ? '+' : ''}${extraMeters.round()} м',
      ),
      RecommendationFact(label: 'Остановок', value: '${comparison.stopCount}'),
      for (final line in comparison.benefitLines)
        RecommendationFact(label: 'Проверено', value: line),
    ];
    final dataset = context.scenicDatasetVersion.isEmpty
        ? 'версия набора не указана'
        : context.scenicDatasetVersion;
    return ContextRecommendation(
      id: 'scenic.comparison',
      factor: RecommendationFactor.scenic,
      availability: RecommendationAvailability.available,
      title: 'Живописный маршрут построен: $extraLabel ходьбы',
      explanation:
          'Сравнение сделано по реальным пешеходным маршрутам MapKit '
          'для тех же остановок: живописный вариант — '
          '${(comparison.scenicWalkingSeconds / 60).round()} мин ходьбы против '
          '${(comparison.normalWalkingSeconds / 60).round()} мин у обычного. '
          'Ничего не переключается автоматически.',
      facts: facts,
      completenessNote:
          'Сравнение охватывает ${comparison.stopCount} ост. и '
          'обе величины измерены нативным роутером; время — ходьба без учёта '
          'осмотра. Набор живописных участков: $dataset.',
      limitations: const [
        'Сравнение относится ко всей прогулке и к тем же остановкам; для пути '
            'впереди оно не пересчитывается.',
        'Живописность подтверждена только для проверенных участков набора; '
            'остальная часть маршрута — обычная городская застройка.',
      ],
      method: 'native_mapkit_comparison',
      methodVersion: context.scenicDatasetVersion,
      sourceLabel: 'MapKit + проверенный набор живописных участков',
      scope: RecommendationScope.wholeWalk,
      evaluatedFor: null,
      action: null,
    );
  }

  /// The engine's own honest fallback text (Phase C5 §8): the walk stays
  /// normal and must never be called scenic.
  ContextRecommendation _scenicFallbackEntry(RecommendationContext context) {
    final message = context.scenicFallbackMessage ?? '';
    return ContextRecommendation(
      id: 'scenic.fallback',
      factor: RecommendationFactor.scenic,
      availability: RecommendationAvailability.unavailable,
      title: 'Живописный вариант не построен',
      explanation:
          '$message Подтверждённого живописного варианта нет, поэтому '
          'текущий маршрут — обычный пешеходный: живописным он не называется.',
      facts: const [],
      completenessNote:
          'Подтверждённого живописного варианта нет; обычный '
          'маршрут сохранён.',
      limitations: const [
        'Отсутствие подтверждённого варианта не означает, что по пути нет '
            'живописных мест: проверялись только участки из набора данных.',
      ],
      method: 'native_mapkit_comparison',
      methodVersion: context.scenicDatasetVersion,
      sourceLabel: 'MapKit + проверенный набор живописных участков',
      scope: RecommendationScope.wholeWalk,
      evaluatedFor: null,
      action: null,
    );
  }

  // -------------------------------------------------------------- utilities

  /// The only action C7.4 offers in v1: an explicit re-run of an existing
  /// assessment. Mid-walk it is offered on the remaining-path question, which
  /// is exactly what the factor cards do for the same button.
  static RecommendationAction _recompute(String label) => RecommendationAction(
    kind: RecommendationActionKind.recompute,
    label: label,
  );

  static String _percent(double share) => '${(share * 100).round()}%';

  static String _meters(double value) => '${value.round()}';

  /// One decimal, without a trailing `.0` — the same shape the C7.3 card uses
  /// for concentrations.
  static String _concentration(double value) {
    final rounded = (value * 10).round() / 10;
    return rounded == rounded.roundToDouble()
        ? rounded.toStringAsFixed(0)
        : rounded.toStringAsFixed(1);
  }

  static String _instant(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
