import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/simulated_location_source.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/widgets/pollen_assessment_section.dart';

import 'off_route_reroute_test.dart' show FakeRouteService;
import 'simulated_location_source_test.dart' show SimClock;

// --------------------------------------------------------------------------
// Phase C7.3 UI: the card is optional (absent provider → absent card), it
// shows concentrations WITH their unit and their source, it lists species
// without data as gaps, and it never presents a danger level, a dose or a
// medical conclusion — the source provides none of those.
// --------------------------------------------------------------------------

const _a = GeoCoord(59.9300, 30.3100);
const _b = GeoCoord(59.9400, 30.3200);

final _departure = DateTime(2026, 7, 1, 14);

class _NoopShadeService implements BaseShadeAnalysisService {
  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async => throw StateError('shade is not exercised in C7.3 tests');
}

PollenSpeciesModel _species(
  String code,
  String name, {
  double? mean = 12.6,
  PollenSpeciesState state = PollenSpeciesState.available,
  double? knownShare,
}) => PollenSpeciesModel(
  code: code,
  name: name,
  unit: 'grains/m³',
  state: state,
  knownSeconds: mean == null ? 0 : 3240,
  totalSeconds: 3240,
  knownShare: knownShare ?? (mean == null ? 0 : 1),
  meanConcentration: mean,
  peakConcentration: mean,
  peakAt: mean == null ? null : '2026-07-01T11:00:00+00:00',
  exposureGrainsHoursPerM3: mean == null ? null : 11.34,
);

/// [withGap] leaves two species without values; [unavailable] builds the
/// honest "no numbers at all" answer the backend sends when the source is off
/// or off-season-without-data; [withheld] builds the C7.3.1 answer in which the
/// source HAD values for some species, but no hour of the walk carried the
/// whole six-species panel, so the backend published none of them.
PollenAnalysisModel _analysis({
  bool withGap = false,
  bool unavailable = false,
  bool withheld = false,
}) {
  final List<PollenSpeciesModel> species;
  if (withheld) {
    species = [
      _species(
        'alder_pollen',
        'Ольха',
        mean: null,
        state: PollenSpeciesState.unknown,
        knownShare: 0.5,
      ),
      _species(
        'birch_pollen',
        'Берёза',
        mean: null,
        state: PollenSpeciesState.unknown,
        knownShare: 1,
      ),
    ];
  } else if (unavailable) {
    species = [
      _species(
        'birch_pollen',
        'Берёза',
        mean: null,
        state: PollenSpeciesState.unknown,
      ),
      _species(
        'grass_pollen',
        'Злаки',
        mean: null,
        state: PollenSpeciesState.unknown,
      ),
    ];
  } else if (withGap) {
    species = [
      _species('birch_pollen', 'Берёза'),
      _species(
        'grass_pollen',
        'Злаки',
        mean: null,
        state: PollenSpeciesState.unknown,
      ),
      _species(
        'ragweed_pollen',
        'Амброзия',
        mean: null,
        state: PollenSpeciesState.unknown,
      ),
    ];
  } else {
    species = [
      _species('birch_pollen', 'Берёза'),
      _species('grass_pollen', 'Злаки', mean: 0.0),
    ];
  }
  final noNumbers = unavailable || withheld;
  final known = noNumbers ? 0.0 : (withGap ? 500.0 : 1000.0);
  return PollenAnalysisModel(
    status: noNumbers
        ? PollenStatus.unavailable
        : (withGap ? PollenStatus.partial : PollenStatus.available),
    method: 'experimental_pollen_exposure',
    methodVersion: 'c7_3.1',
    confidence: noNumbers ? 'unavailable' : 'low',
    periodStart: _departure,
    periodEnd: _departure.add(const Duration(minutes: 54)),
    timezoneName: '+03:00',
    routeLengthMeters: 1000,
    knownMeters: known,
    unknownMeters: 1000 - known,
    coverageShare: known / 1000,
    walkingDurationSeconds: 3240,
    elapsedDurationSeconds: 3240,
    concentrationUnit: 'grains/m³',
    species: species,
    legs: null,
    reasons: withheld
        ? const ['pollen_incomplete', 'pollen_no_complete_panel']
        : unavailable
        ? const ['pollen_not_configured']
        : const ['modeled_pollen_concentration', 'pollen_incomplete'],
    limitations: const [
      'Это концентрации пыльцы в воздухе, а не прогноз симптомов.',
    ],
    assumptions: const [
      'Концентрация считается постоянной внутри часа [t, t+1h) — источник не даёт более тонкого временного разрешения.',
    ],
    source: PollenSourceModel(
      available: !unavailable,
      provider: 'Open-Meteo',
      model: 'cams_europe',
      modelName: 'CAMS European Air Quality Forecast (CAMS ENSEMBLE)',
      kind: 'modeled_forecast_and_recent_archived_forecast',
      license: 'CC-BY-4.0',
      attribution: 'Pollen data by Open-Meteo.com; CAMS ENSEMBLE (Copernicus Atmosphere Monitoring Service) model',
      sourceUrl: 'https://open-meteo.com/en/docs/air-quality-api',
      retrievedAt: unavailable ? null : _departure,
      validUntil: unavailable ? null : _departure.add(const Duration(hours: 1)),
      intervalStart: _departure.subtract(const Duration(hours: 1)),
      intervalEnd: _departure.add(const Duration(days: 4)),
      temporalResolutionSeconds: 3600,
      spatialResolutionMeters: 11000,
      gridStepDegrees: 0.1,
      cellLatitude: 59.9,
      cellLongitude: 30.3,
      cellBounds: const [59.85, 30.25, 59.95, 30.35],
      timeSemantics: 'instantaneous concentration valid for the indicated hour',
      reason: unavailable ? 'pollen_not_configured' : null,
    ),
  );
}

class _FakePollenService implements BasePollenAnalysisService {
  _FakePollenService({this.response, this.failure});

  final PollenAnalysisModel Function()? response;
  final Object? failure;

  @override
  Future<PollenAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    final thrown = failure;
    if (thrown != null) throw thrown;
    return (response ?? _analysis)();
  }
}

RoutingProvider _routingWithRoute() {
  const leg = RouteLegModel(
    fromTitle: 'Старт',
    toTitle: 'Финиш',
    distanceMeters: 1300,
    durationSeconds: 900,
    geometryPoints: [_a, _b],
  );
  return RoutingProvider(shadeAnalysisService: _NoopShadeService())
    ..setProposedWalkForScenicTest(
      scenic: false,
      comparison: null,
      walkKind: WalkKind.normal,
      route: const PedestrianRouteModel(
        distanceMeters: 1300,
        durationSeconds: 900,
        geometryPoints: [_a, _b],
        steps: [],
        legs: [leg],
        placesCount: 1,
      ),
    );
}

Widget _host(PollenAssessmentProvider provider) => MaterialApp(
  home: Scaffold(
    body: ChangeNotifierProvider<PollenAssessmentProvider>.value(
      value: provider,
      child: const SingleChildScrollView(child: PollenAssessmentSection()),
    ),
  ),
);

/// Builds a provider around a fake service and runs the card once.
Future<
  ({
    PollenAssessmentProvider provider,
    NavigationProvider nav,
    RoutingProvider routing,
  })
>
_setUpAndAssess(
  WidgetTester tester, {
  PollenAnalysisModel Function()? response,
  Object? failure,
}) async {
  final source = SimulatedLocationSource(clock: SimClock().call);
  final routing = _routingWithRoute();
  final nav = NavigationProvider(
    locationService: source,
    routingProvider: routing,
    routeService: FakeRouteService(),
  );
  final provider = PollenAssessmentProvider(
    _FakePollenService(response: response, failure: failure),
    routing: routing,
    navigation: nav,
    now: () => _departure,
  );
  await tester.pumpWidget(_host(provider));
  return (provider: provider, nav: nav, routing: routing);
}

void main() {
  testWidgets('without the provider the card simply does not exist', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PollenAssessmentSection())),
    );
    expect(find.text('Пыльца на маршруте'), findsNothing);
  });

  testWidgets('assessing shows concentrations, units, source and caveats', (
    tester,
  ) async {
    final setup = await _setUpAndAssess(tester);

    expect(find.text('Пыльца на маршруте'), findsOneWidget);
    expect(
      find.textContaining('не измерение на вашей улице'),
      findsOneWidget,
      reason: 'карточка прямо говорит, чем оценка НЕ является',
    );
    expect(
      find.textContaining('сравнение маршрутов по пыльце не выполняется'),
      findsOneWidget,
    );

    await tester.tap(find.text('Оценить пыльцу'));
    await tester.pumpAndSettle();

    // Concentrations with their unit, per species.
    expect(find.textContaining('Берёза: 12.6 зёрен пыльцы/м³'), findsOneWidget);
    expect(find.textContaining('Злаки: 0 зёрен пыльцы/м³'), findsOneWidget);
    expect(
      find.textContaining(
        'Оценочная концентрация пыльцевых зёрен в одном кубическом метре',
      ),
      findsOneWidget,
      reason: 'понятная единица сопровождается кратким пояснением',
    );
    expect(
      find.textContaining('Нулевое значение — это рассчитанная концентрация'),
      findsOneWidget,
      reason: 'достоверный ноль не выдаётся за отсутствие данных',
    );
    expect(find.textContaining('Вся прогулка'), findsOneWidget);
    expect(
      find.textContaining('Покрытие данными'),
      findsNothing,
      reason: 'технические значения находятся в раскрываемом блоке',
    );
    expect(
      find.text('Это концентрации пыльцы в воздухе, а не прогноз симптомов.'),
      findsOneWidget,
    );

    await tester.ensureVisible(
      find.text('Технические подробности оценки пыльцы'),
    );
    await tester.tap(find.text('Технические подробности оценки пыльцы'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Покрытие данными'), findsOneWidget);
    expect(find.textContaining('Уверенность: низкая'), findsOneWidget);
    expect(
      find.textContaining('Единица источника: grains/m³'),
      findsOneWidget,
      reason: 'техническое обозначение сохранено в подробностях',
    );
    // Full attribution and licence, as CC-BY-4.0 requires.
    expect(find.textContaining('Источник: Open-Meteo'), findsOneWidget);
    expect(
      find.textContaining('CAMS European Air Quality Forecast'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'CAMS ENSEMBLE (Copernicus Atmosphere Monitoring Service) model',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('лицензия CC-BY-4.0'), findsOneWidget);
    expect(find.textContaining('open-meteo.com'), findsOneWidget);
    // Spatial and temporal precision are stated, not implied.
    expect(find.textContaining('Шаг по времени: 60 мин'), findsOneWidget);
    expect(find.textContaining('11.0 км'), findsOneWidget);
    expect(
      find.textContaining('одна ячейка на всю прогулку'),
      findsOneWidget,
      reason: 'разрешение источника должно быть заявлено явно',
    );

    setup.provider.dispose();
    setup.nav.dispose();
    setup.routing.dispose();
  });

  testWidgets('the card never shows a danger level or a recommendation', (
    tester,
  ) async {
    final setup = await _setUpAndAssess(tester);
    await tester.tap(find.text('Оценить пыльцу'));
    await tester.pumpAndSettle();

    // The puddle-style verdict vocabulary must not exist for pollen at all.
    for (final forbidden in [
      'Уровень риска',
      'Риск:',
      'низкий риск',
      'высокий риск',
      'умеренный',
      'опасн',
      'Рекомендуется',
      'аллерг',
      'безопасн',
    ]) {
      expect(
        find.textContaining(forbidden),
        findsNothing,
        reason: 'карточка не должна содержать «$forbidden»',
      );
    }
    // ...and it says so explicitly instead of leaving it implied.
    expect(
      find.textContaining('Порогов и медицинских выводов здесь нет'),
      findsOneWidget,
    );

    setup.provider.dispose();
    setup.nav.dispose();
    setup.routing.dispose();
  });

  testWidgets('species without data are listed as gaps, never as zeros', (
    tester,
  ) async {
    final setup = await _setUpAndAssess(
      tester,
      response: () => _analysis(withGap: true),
    );
    await tester.tap(find.text('Оценить пыльцу'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Берёза: 12.6 зёрен пыльцы/м³'), findsOneWidget);
    expect(find.text('Нет данных: Злаки, Амброзия.'), findsOneWidget);
    expect(
      find.textContaining('Злаки: 0'),
      findsNothing,
      reason: 'пропуск не показывается как ноль',
    );
    expect(find.textContaining('покрытие 100%'), findsNothing);

    setup.provider.dispose();
    setup.nav.dispose();
    setup.routing.dispose();
  });

  testWidgets('an unavailable answer says so instead of showing zeros', (
    tester,
  ) async {
    final setup = await _setUpAndAssess(
      tester,
      response: () => _analysis(unavailable: true),
    );
    await tester.tap(find.text('Оценить пыльцу'));
    await tester.pumpAndSettle();

    expect(find.text('Значений пыльцы для этой прогулки нет.'), findsOneWidget);
    expect(find.textContaining('grains/m³'), findsNothing);
    expect(
      find.textContaining('Источник пыльцы не подключён'),
      findsOneWidget,
      reason: 'причина недоступности называется словами',
    );
    await tester.ensureVisible(
      find.text('Технические подробности оценки пыльцы'),
    );
    await tester.tap(find.text('Технические подробности оценки пыльцы'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Уверенность: недоступна'), findsOneWidget);
    expect(find.textContaining('grains/m³'), findsNothing);

    setup.provider.dispose();
    setup.nav.dispose();
    setup.routing.dispose();
  });

  testWidgets(
    'a withheld panel names the species instead of claiming nothing',
    (tester) async {
      final setup = await _setUpAndAssess(
        tester,
        response: () => _analysis(withheld: true),
      );
      await tester.tap(find.text('Оценить пыльцу'));
      await tester.pumpAndSettle();

      // ТЗ C7.3.1: the source HAD values for these species — the card must not
      // report "нет значений" for a walk whose numbers were merely withheld.
      expect(
        find.textContaining(
          'Значения в источнике есть (доля времени ходьбы): '
          'Ольха — 50%, Берёза — 100%.',
        ),
        findsOneWidget,
      );
      expect(find.text('Значений пыльцы для этой прогулки нет.'), findsNothing);
      expect(find.textContaining('Нет данных:'), findsNothing);
      expect(
        find.textContaining('Ни на одном часе прогулки нет значений'),
        findsOneWidget,
        reason: 'причина называется словами, а не кодом',
      );
      // And still not a single concentration, with or without a unit.
      expect(find.textContaining('grains/m³'), findsNothing);
      await tester.ensureVisible(
        find.text('Технические подробности оценки пыльцы'),
      );
      await tester.tap(find.text('Технические подробности оценки пыльцы'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Уверенность: недоступна'), findsOneWidget);
      expect(find.textContaining('Покрытие данными: 0%'), findsOneWidget);

      setup.provider.dispose();
      setup.nav.dispose();
      setup.routing.dispose();
    },
  );

  testWidgets('in the simulator the picker names the shared simulation time', (
    tester,
  ) async {
    final source = SimulatedLocationSource(clock: SimClock().call);
    final routing = _routingWithRoute();
    final nav = NavigationProvider(
      locationService: source,
      routingProvider: routing,
      routeService: FakeRouteService(),
    );
    final clock = VirtualShadeClock();
    final provider = PollenAssessmentProvider(
      _FakePollenService(),
      routing: routing,
      navigation: nav,
      clock: clock,
      now: () => _departure,
    );

    await tester.pumpWidget(_host(provider));

    expect(find.text('Время симуляции'), findsOneWidget);
    expect(find.text('Время оценки'), findsNothing);
    expect(
      find.textContaining('Это общее время симуляции'),
      findsOneWidget,
      reason: 'общие часы симуляции должны быть названы явно',
    );

    provider.dispose();
    clock.dispose();
    nav.dispose();
    routing.dispose();
  });

  testWidgets('a service failure is shown in words and nothing else changes', (
    tester,
  ) async {
    final setup = await _setUpAndAssess(
      tester,
      failure: const PollenAnalysisFailure(
        PollenAnalysisFailureKind.invalidResponse,
        'Сервис вернул неполную оценку пыльцы. Обычная навигация работает.',
      ),
    );
    await tester.tap(find.text('Оценить пыльцу'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Сервис вернул неполную оценку пыльцы. Обычная навигация работает.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('grains/m³'), findsNothing);
    expect(setup.routing.navigationLocked, isFalse);
    expect(setup.routing.currentRoute, isNotNull);

    setup.provider.dispose();
    setup.nav.dispose();
    setup.routing.dispose();
  });
}
