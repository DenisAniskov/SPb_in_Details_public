import 'package:flutter_test/flutter_test.dart';

import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/services/context_recommendation_engine.dart';
import 'package:smart_navigator_spb/services/recommendation_context.dart';

import 'context_recommendation_fixtures.dart';

// --------------------------------------------------------------------------
// Phase C7.4 — the deterministic rules engine, tested on its own (ТЗ §9:
// «Проверь движок отдельно»). Every mandatory scenario that is a property of
// the RULES lives here; the ones that are properties of the PROVIDERS are in
// context_recommendation_provider_test.dart.
//
// What every test in this file is really checking: a recommendation never
// says more than the model behind it measured, and never less than the model
// says about its own limits.
// --------------------------------------------------------------------------

const _engine = ContextRecommendationEngine();

ContextRecommendation _one(
  List<ContextRecommendation> entries,
  RecommendationFactor factor,
) {
  final matches = entries.where((entry) => entry.factor == factor).toList();
  expect(matches, hasLength(1), reason: 'ровно одна запись на фактор');
  return matches.single;
}

String _text(ContextRecommendation entry) =>
    '${entry.title} ${entry.explanation} ${entry.completenessNote} '
    '${entry.facts.map((fact) => '${fact.label} ${fact.display}').join(' ')} '
    '${entry.limitations.join(' ')}';

void _expectAbsentInAll(
  List<ContextRecommendation> entries,
  List<String> forbidden,
) {
  for (final entry in entries) {
    for (final phrase in forbidden) {
      expect(
        _text(entry).toLowerCase(),
        isNot(contains(phrase.toLowerCase())),
        reason: '${entry.id} не должен содержать «$phrase»',
      );
    }
  }
}

RecommendationContext _context({
  DateTime? reference,
  bool planning = true,
  RecommendationPreference preference = RecommendationPreference.all,
  AdmittedFacts<ShadeAnalysisModel>? shade,
  AdmittedFacts<PuddleAnalysisModel>? puddle,
  AdmittedFacts<PollenAnalysisModel>? pollen,
  RouteComparison? comparison,
  String? scenicFallback,
  String scenicVersion = 'scenic-spb-2026-04',
}) => RecommendationContext(
  scope: planning
      ? RecommendationScope.wholeWalk
      : RecommendationScope.remainingPath,
  preference: preference,
  hasRoute: true,
  referenceInstant: reference ?? shade?.evaluatedFor,
  shade: shade,
  puddle: puddle,
  pollen: pollen,
  scenicComparison: comparison,
  scenicFallbackMessage: scenicFallback,
  scenicDatasetVersion: scenicVersion,
);

void main() {
  group('shade rules (ТЗ §4.1)', () {
    test('the estimate states the measured share and its unknown part', () {
      final entries = _engine.build(
        _context(
          shade: AdmittedFacts(
            facts: shadeFixture(),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      final shade = _one(entries, RecommendationFactor.shade);
      expect(shade.id, 'shade.estimate');
      expect(shade.title, 'Тень: 60% маршрута в тени');
      expect(
        shade.explanation,
        contains('Для этой прогулки рассчитана тень на 60% маршрута'),
      );
      expect(shade.explanation, contains('неизвестная часть — 0%'));
      expect(shade.availability, RecommendationAvailability.available);
      expect(
        shade.facts.map((fact) => fact.display),
        containsAll(['600 м', '400 м', '0 м', '100%']),
      );
      expect(
        shade.facts.map((fact) => fact.label),
        contains('Данные о зданиях'),
      );
      expect(shade.method, 'building_shadow_projection');
      expect(shade.methodVersion, 'c7_1_2');
      expect(shade.sourceLabel, contains('OpenStreetMap'));
      expect(shade.scope, RecommendationScope.wholeWalk);
      expect(shade.evaluatedFor, fixtureInstant);
      expect(shade.completenessNote, contains('Достоверность: средняя'));
      expect(shade.limitations, isNotEmpty);
    });

    test('a partly unknown estimate is labelled partial and keeps the gap', () {
      final entries = _engine.build(
        _context(
          shade: AdmittedFacts(
            facts: shadeFixture(
              status: ShadeStatus.partial,
              shadedMeters: 600,
              exposedMeters: 200,
              unknownMeters: 200,
              shadeFraction: 0.6,
              confidence: ShadeConfidence.low,
              coverageShare: 0.8,
            ),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      final shade = _one(entries, RecommendationFactor.shade);
      expect(shade.availability, RecommendationAvailability.limited);
      expect(shade.explanation, contains('неизвестная часть — 20%'));
      expect(shade.completenessNote, contains('классифицировала 80%'));
      expect(shade.facts.map((fact) => fact.display), contains('200 м'));
    });

    test('the estimate never claims another hour (ТЗ §4.1)', () {
      final entries = _engine.build(
        _context(
          shade: AdmittedFacts(
            facts: shadeFixture(),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      final shade = _one(entries, RecommendationFactor.shade);
      expect(
        shade.explanation,
        contains('о других часах она ничего не утверждает'),
      );
      _expectAbsentInAll(entries, [
        'через час',
        'будет больше тени',
        'станет тенистее',
        'рекомендуем',
        'комфортн',
      ]);
    });

    test('no comfort threshold is ever introduced', () {
      final entries = _engine.build(
        _context(
          shade: AdmittedFacts(
            facts: shadeFixture(
              status: ShadeStatus.partial,
              unknownMeters: 500,
            ),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      _expectAbsentInAll(entries, [
        'достаточно тени',
        'комфорт',
        'оптимальн',
        'хорош',
        'плох',
      ]);
    });

    test(
      'an estimate that produced no numbers explains instead of guessing',
      () {
        final entries = _engine.build(
          _context(
            shade: AdmittedFacts(
              facts: shadeFixture(
                status: ShadeStatus.sunBelowHorizon,
                shadedMeters: null,
                exposedMeters: null,
                unknownMeters: null,
                shadeFraction: null,
              ),
              evaluatedFor: fixtureInstant,
            ),
          ),
        );
        final shade = _one(entries, RecommendationFactor.shade);
        expect(shade.id, 'shade.no_estimate');
        expect(shade.availability, RecommendationAvailability.unavailable);
        expect(shade.explanation, contains('Солнце ниже горизонта'));
        expect(shade.facts, isEmpty);
        expect(_text(shade), isNot(contains('%')));
      },
    );
  });

  group('puddle rules (ТЗ §4.2)', () {
    test(
      'existing high sections become an experimental, bounded request to look',
      () {
        final entries = _engine.build(
          _context(
            puddle: AdmittedFacts(
              facts: puddleHighFixture(),
              evaluatedFor: fixtureInstant,
            ),
          ),
        );
        final puddle = _one(entries, RecommendationFactor.puddle);
        expect(puddle.id, 'puddle.high_sections');
        expect(
          puddle.title,
          'Изучите перед выходом: 520 м с высоким относительным риском '
          'мокрого покрытия',
        );
        expect(puddle.availability, RecommendationAvailability.limited);
        // The metres and the model coverage are stated, as the ТЗ requires.
        expect(
          puddle.facts.map((fact) => fact.display),
          containsAll(['520 м']),
        );
        expect(puddle.facts.map((fact) => fact.display), contains('70%'));
        // Experimental wording, parameter spread and the native-times note.
        expect(
          puddle.explanation,
          contains('Экспериментальная модель отметила'),
        );
        expect(puddle.explanation, contains('не откалибрована на местности'));
        expect(
          puddle.explanation,
          contains('классификация меняется'),
          reason: 'варианты параметров расходятся — это часть вывода',
        );
        expect(
          puddle.completenessNote,
          contains('300 м остались неизвестными'),
        );
        expect(puddle.completenessNote, contains('низкая (без калибровки)'));
      },
    );

    test('a puddle result never becomes a statement about real puddles', () {
      final entries = _engine.build(
        _context(
          puddle: AdmittedFacts(
            facts: puddleHighFixture(),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      _expectAbsentInAll(entries, [
        'здесь глубокие лужи',
        'гарантированно',
        'безопасн',
        'эта улица сухая',
        'другой маршрут',
        'лужа точно',
      ]);
    });

    test('an unknown puddle result explains limits and concludes nothing (ТЗ §9.4)', () {
      final entries = _engine.build(
        _context(
          puddle: AdmittedFacts(
            facts: puddleUnknownFixture(),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      final puddle = _one(entries, RecommendationFactor.puddle);
      expect(puddle.id, 'puddle.no_estimate');
      expect(puddle.availability, RecommendationAvailability.unavailable);
      expect(puddle.explanation, contains('История осадков неполная'));
      expect(
        puddle.explanation,
        contains('Выводов о сухости покрытия сделать нельзя.'),
      );
      expect(puddle.facts.map((fact) => fact.display), contains('0%'));
      _expectAbsentInAll(entries, [
        'безопасн',
        'можно не беспокоиться',
        'сухой асфальт',
        'покрытие сухое',
      ]);
    });

    test('no high sections are reported without turning them into dryness', () {
      final entries = _engine.build(
        _context(
          puddle: AdmittedFacts(
            facts: puddleNoHighFixture(),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      final puddle = _one(entries, RecommendationFactor.puddle);
      expect(puddle.id, 'puddle.no_high_sections');
      expect(
        puddle.title,
        'Мокрые участки: высокого относительного риска не выделено',
      );
      expect(
        puddle.explanation,
        contains('Это не означает, что покрытие сухое'),
      );
      expect(puddle.explanation, isNot(contains('классификация меняется')));
      expect(puddle.availability, RecommendationAvailability.limited);
    });
  });

  group('pollen rules (ТЗ §4.3)', () {
    test(
      'a full panel of zeros is a modelled value, never an absence claim',
      () {
        final entries = _engine.build(
          _context(
            pollen: AdmittedFacts(
              facts: pollenConcentrationsFixture(),
              evaluatedFor: fixtureInstant,
            ),
          ),
        );
        final pollen = _one(entries, RecommendationFactor.pollen);
        expect(pollen.id, 'pollen.concentrations');
        expect(pollen.availability, RecommendationAvailability.available);
        // Values keep the source's own unit, one species per fact, no index.
        final concentrations = pollen.facts
            .where((fact) => fact.unit == 'grains/m³')
            .toList();
        expect(concentrations, hasLength(6));
        expect(
          concentrations.map((fact) => fact.label),
          containsAll([
            'Ольха',
            'Берёза',
            'Злаки',
            'Полынь',
            'Олива',
            'Амброзия',
          ]),
        );
        expect(
          pollen.facts.map((fact) => fact.display),
          containsAll(['0 зёрен пыльцы/м³', '12.6 зёрен пыльцы/м³']),
        );
        expect(
          pollen.facts.map((fact) => fact.label),
          isNot(contains('Всего')),
          reason: 'виды не объединяются в индекс',
        );
        expect(
          pollen.explanation,
          contains('Ноль — подтверждённое моделью значение'),
        );
        // The card never asserts that there are no allergens at all (ТЗ §9.5).
        _expectAbsentInAll(entries, [
          'аллергенов нет',
          'пыльцы нет',
          'опасн',
          'риск',
          'безопасн',
          'можно гулять',
        ]);
      },
    );

    test('a withheld panel restores NO concentration (ТЗ §9.6)', () {
      final entries = _engine.build(
        _context(
          pollen: AdmittedFacts(
            facts: pollenWithheldFixture(),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      final pollen = _one(entries, RecommendationFactor.pollen);
      expect(pollen.id, 'pollen.withheld');
      expect(pollen.availability, RecommendationAvailability.withheld);
      expect(
        pollen.facts.where((fact) => fact.unit == 'grains/m³'),
        isEmpty,
        reason: 'концентрации не восстанавливаются ни из чего',
      );
      // The coverage shares ARE published — they are not concentrations.
      expect(
        pollen.facts.map((fact) => fact.display),
        containsAll(['50% времени ходьбы', '100% времени ходьбы']),
      );
      expect(pollen.explanation, contains('нет значений по всем шести видам'));
      expect(pollen.explanation, contains('не восстанавливаются'));
      expect(pollen.action, isNull);
    });

    test('an off source is reported as a source state, not as clean air', () {
      final entries = _engine.build(
        _context(
          pollen: AdmittedFacts(
            facts: pollenSourceOffFixture(),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      final pollen = _one(entries, RecommendationFactor.pollen);
      expect(pollen.id, 'pollen.no_values');
      expect(pollen.title, 'Пыльца: источник не подключён');
      expect(pollen.availability, RecommendationAvailability.unavailable);
      expect(pollen.explanation, contains('Источник пыльцы не подключён'));
      expect(pollen.explanation, contains('означает отсутствие данных'));
      _expectAbsentInAll(entries, ['чистый воздух', 'аллергенов нет']);
    });

    test(
      'a species the source did not cover is named, not silently dropped',
      () {
        final analysis = pollenConcentrationsFixture();
        final withGap = analysis.species
            .map(
              (item) => item.code == 'olive_pollen'
                  ? pollenSpecies('olive_pollen', 'Олива')
                  : item,
            )
            .toList();
        final entries = _engine.build(
          _context(
            pollen: AdmittedFacts(
              facts: PollenAnalysisModelWithSpecies(analysis, withGap),
              evaluatedFor: fixtureInstant,
            ),
          ),
        );
        final pollen = _one(entries, RecommendationFactor.pollen);
        expect(pollen.availability, RecommendationAvailability.limited);
        expect(pollen.completenessNote, contains('Без значений: Олива.'));
        expect(
          pollen.facts.where((fact) => fact.unit == 'grains/m³'),
          hasLength(5),
        );
      },
    );
  });

  group('scenic rules (ТЗ §4.4)', () {
    test('a validated comparison states the factual trade-off (ТЗ §9.2)', () {
      const comparison = RouteComparison(
        normalWalkingSeconds: 600,
        scenicWalkingSeconds: 780,
        normalDistanceMeters: 800,
        scenicDistanceMeters: 950,
        stopCount: 3,
        benefitLines: ['Проходит по набережной реки Мойки'],
      );
      final entries = _engine.build(_context(comparison: comparison));
      final scenic = _one(entries, RecommendationFactor.scenic);
      expect(scenic.id, 'scenic.comparison');
      expect(scenic.title, 'Живописный маршрут построен: +3 мин ходьбы');
      expect(scenic.availability, RecommendationAvailability.available);
      expect(
        scenic.facts.map((fact) => fact.display),
        containsAll(['10 мин ходьбы', '13 мин ходьбы', '+3 мин, +150 м']),
      );
      expect(
        scenic.facts.map((fact) => fact.value),
        contains('Проходит по набережной реки Мойки'),
      );
      expect(scenic.completenessNote, contains('3 ост.'));
      expect(scenic.completenessNote, contains('scenic-spb-2026-04'));
      expect(
        scenic.explanation,
        contains('Ничего не переключается автоматически'),
      );
      expect(scenic.method, 'native_mapkit_comparison');
      expect(scenic.scope, RecommendationScope.wholeWalk);
      expect(scenic.evaluatedFor, isNull);
      expect(scenic.action, isNull);
    });

    test('a scenic fallback is never presented as a scenic route (ТЗ §9.14)', () {
      final entries = _engine.build(
        _context(
          scenicFallback:
              'Для этой прогулки пока нет подтверждённых живописных участков. '
              'Построен обычный пешеходный маршрут.',
        ),
      );
      final scenic = _one(entries, RecommendationFactor.scenic);
      expect(scenic.id, 'scenic.fallback');
      expect(scenic.availability, RecommendationAvailability.unavailable);
      expect(scenic.explanation, contains('нет подтверждённых живописных'));
      expect(scenic.explanation, contains('живописным он не называется'));
      expect(_text(scenic), isNot(contains('Живописный маршрут построен')));
    });
  });

  group('set-level properties', () {
    test('the same inputs always produce an identical list (ТЗ §9.16)', () {
      final context = _context(
        shade: AdmittedFacts(
          facts: shadeFixture(),
          evaluatedFor: fixtureInstant,
        ),
        puddle: AdmittedFacts(
          facts: puddleHighFixture(),
          evaluatedFor: fixtureInstant,
        ),
        pollen: AdmittedFacts(
          facts: pollenConcentrationsFixture(),
          evaluatedFor: fixtureInstant,
        ),
        comparison: const RouteComparison(
          normalWalkingSeconds: 600,
          scenicWalkingSeconds: 780,
          normalDistanceMeters: 800,
          scenicDistanceMeters: 950,
          stopCount: 3,
          benefitLines: ['Проходит по набережной реки Мойки'],
        ),
      );
      final first = _engine.build(context);
      final second = _engine.build(context);
      expect(first, equals(second));
      expect(
        first.map((entry) => entry.id).toList(),
        [
          'shade.estimate',
          'puddle.high_sections',
          'pollen.concentrations',
          'scenic.comparison',
        ],
        reason: 'порядок по умолчанию документирован: тень, мокрые, пыльца, живописность',
      );
    });

    test('no factor contributes a number the others cannot be merged with', () {
      final entries = _engine.build(
        _context(
          shade: AdmittedFacts(
            facts: shadeFixture(),
            evaluatedFor: fixtureInstant,
          ),
          puddle: AdmittedFacts(
            facts: puddleHighFixture(),
            evaluatedFor: fixtureInstant,
          ),
          pollen: AdmittedFacts(
            facts: pollenConcentrationsFixture(),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      // Every entry keeps its own quantity and unit; nothing aggregates them.
      for (final entry in entries) {
        for (final fact in entry.facts) {
          expect(
            fact.display,
            isNot(matches(RegExp(r'\b(индекс|балл|score|рейтинг)\b'))),
          );
        }
      }
      _expectAbsentInAll(entries, [
        'общий балл',
        'суммарн',
        'самый мокрый участок одновременно',
        'одновременно самый тенистый',
      ]);
    });

    test('a preference re-orders the set and can reveal the shade entry', () {
      final withoutShade = _context(
        puddle: AdmittedFacts(
          facts: puddleHighFixture(),
          evaluatedFor: fixtureInstant,
        ),
        comparison: const RouteComparison(
          normalWalkingSeconds: 600,
          scenicWalkingSeconds: 780,
          normalDistanceMeters: 800,
          scenicDistanceMeters: 950,
          stopCount: 3,
          benefitLines: [],
        ),
      );
      final all = _engine.build(withoutShade);
      expect(all.map((entry) => entry.factor).toList(), [
        RecommendationFactor.puddle,
        RecommendationFactor.scenic,
      ]);

      final scenicFirst = _engine.build(
        _context(
          preference: RecommendationPreference.scenic,
          puddle: AdmittedFacts(
            facts: puddleHighFixture(),
            evaluatedFor: fixtureInstant,
          ),
          comparison: const RouteComparison(
            normalWalkingSeconds: 600,
            scenicWalkingSeconds: 780,
            normalDistanceMeters: 800,
            scenicDistanceMeters: 950,
            stopCount: 3,
            benefitLines: [],
          ),
        ),
      );
      expect(scenicFirst.map((entry) => entry.factor).toList(), [
        RecommendationFactor.scenic,
        RecommendationFactor.puddle,
      ]);

      final shadePreferred = _engine.build(
        _context(
          preference: RecommendationPreference.shade,
          puddle: AdmittedFacts(
            facts: puddleHighFixture(),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      expect(shadePreferred.map((entry) => entry.id).toList(), [
        'shade.not_assessed',
        'puddle.high_sections',
      ], reason: 'приоритет тени называет отсутствующую оценку вслух');
    });

    test('without a route there are no recommendations at all', () {
      const context = RecommendationContext(
        scope: RecommendationScope.wholeWalk,
        preference: RecommendationPreference.all,
        hasRoute: false,
      );
      expect(_engine.build(context), isEmpty);
    });

    test('each admitted factor yields exactly one entry', () {
      final entries = _engine.build(
        _context(
          shade: AdmittedFacts(
            facts: shadeFixture(
              status: ShadeStatus.unavailable,
              shadedMeters: null,
              exposedMeters: null,
              unknownMeters: null,
              shadeFraction: null,
            ),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      expect(entries, hasLength(1));
      expect(entries.single.factor, RecommendationFactor.shade);
    });
  });

  group('provenance and contract details', () {
    test('the concentration unit is propagated, never hardcoded', () {
      final analysis = pollenConcentrationsFixture();
      final custom = PollenAnalysisModelWithUnit(analysis, 'шт/м³');
      final entries = _engine.build(
        _context(
          pollen: AdmittedFacts(facts: custom, evaluatedFor: fixtureInstant),
        ),
      );
      final pollen = _one(entries, RecommendationFactor.pollen);
      expect(pollen.facts.where((fact) => fact.unit == 'шт/м³'), hasLength(6));
      expect(pollen.facts.where((fact) => fact.unit == 'grains/m³'), isEmpty);
    });

    test('a missing method version is left to the card to phrase', () {
      final entries = _engine.build(
        _context(
          shade: AdmittedFacts(
            facts: shadeFixture(methodVersion: ''),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      final shade = _one(entries, RecommendationFactor.shade);
      expect(shade.methodVersion, '');
      expect(shade.method, isNotEmpty);
    });

    test('every entry with facts names its source', () {
      final entries = _engine.build(
        _context(
          shade: AdmittedFacts(
            facts: shadeFixture(),
            evaluatedFor: fixtureInstant,
          ),
          puddle: AdmittedFacts(
            facts: puddleHighFixture(),
            evaluatedFor: fixtureInstant,
          ),
          pollen: AdmittedFacts(
            facts: pollenConcentrationsFixture(),
            evaluatedFor: fixtureInstant,
          ),
        ),
      );
      for (final entry in entries) {
        expect(entry.sourceLabel, isNotEmpty, reason: entry.id);
        expect(entry.method, isNotEmpty, reason: entry.id);
        expect(entry.completenessNote, isNotEmpty, reason: entry.id);
      }
    });

    test(
      'an entry that claims facts always carries an instant or a scope note',
      () {
        final entries = _engine.build(
          _context(
            shade: AdmittedFacts(
              facts: shadeFixture(),
              evaluatedFor: fixtureInstant,
            ),
          ),
        );
        for (final entry in entries) {
          expect(entry.evaluatedFor, isNotNull, reason: entry.id);
          expect(entry.scope, RecommendationScope.wholeWalk, reason: entry.id);
        }
      },
    );
  });
}
