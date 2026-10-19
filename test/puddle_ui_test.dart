import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/puddle_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/simulated_location_source.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/widgets/puddle_assessment_section.dart';

import 'off_route_reroute_test.dart' show FakeRouteService;
import 'simulated_location_source_test.dart' show SimClock;

// --------------------------------------------------------------------------
// Phase C7.2 UI: the card is optional (absent provider → absent card), it
// states its uncertainty in words, and it never presents a percentage as the
// probability of an actual puddle.
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
  }) async => throw StateError('shade is not exercised in C7.2 tests');
}

class _FakePuddleService implements BasePuddleAnalysisService {
  Object? failure;

  @override
  Future<PuddleAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    final thrown = failure;
    if (thrown != null) throw thrown;
    return PuddleAnalysisModel(
      status: PuddleStatus.available,
      method: 'test',
      methodVersion: 'test',
      risk: PuddleRisk.moderate,
      riskIndex: 0.42,
      routeLengthMeters: 1300,
      knownMeters: 1300,
      unknownMeters: 0,
      lowMeters: 300,
      moderateMeters: 1000,
      highMeters: 0,
      coverageShare: 1,
      confidence: 'low',
      periodStart: _departure,
      periodEnd: _departure.add(const Duration(minutes: 15)),
      timezoneName: 'MSK',
      datasetVersion: 'c7_2_palace_pilot_v1',
      datasetSource: 'OpenStreetMap',
      datasetLicense: 'ODbL-1.0',
      weather: const PuddleWeatherSource(
        provider: 'Open-Meteo',
        kind: 'modeled',
        model: 'icon_global',
        license: 'CC-BY-4.0',
        attribution: 'Weather data by Open-Meteo.com; DWD ICON model',
        sourceUrl: 'https://open-meteo.com/en/docs',
        available: true,
      ),
      reasons: const ['model_precipitation_history'],
      limitations: const ['Оценка относительная.'],
      sensitivity: const PuddleSensitivity(
        baseline: PuddleRisk.moderate,
        variants: {
          'drying_faster_0_5x': PuddleRisk.low,
          'drying_slower_2x': PuddleRisk.high,
        },
        variantIndexes: {'drying_faster_0_5x': 0.1, 'drying_slower_2x': 0.8},
        note: 'Параметры экспериментальные и не калиброваны.',
      ),
    );
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

Widget _host(PuddleAssessmentProvider provider) => MaterialApp(
  home: Scaffold(
    body: ChangeNotifierProvider<PuddleAssessmentProvider>.value(
      value: provider,
      child: const SingleChildScrollView(child: PuddleAssessmentSection()),
    ),
  ),
);

void main() {
  testWidgets('without the provider the card simply does not exist', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PuddleAssessmentSection())),
    );
    expect(find.text('Мокрые участки после дождя'), findsNothing);
  });

  testWidgets('assessing shows the level, the uncertainty and the caveats', (
    tester,
  ) async {
    final simClock = SimClock();
    final source = SimulatedLocationSource(clock: simClock.call);
    final routing = _routingWithRoute();
    final nav = NavigationProvider(
      locationService: source,
      routingProvider: routing,
      routeService: FakeRouteService(),
    );
    final provider = PuddleAssessmentProvider(
      _FakePuddleService(),
      routing: routing,
      navigation: nav,
      now: () => _departure,
    );

    await tester.pumpWidget(_host(provider));

    expect(find.text('Мокрые участки после дождя'), findsOneWidget);
    expect(
      find.textContaining('не вероятность лужи'),
      findsOneWidget,
      reason: 'карточка прямо говорит, чем оценка НЕ является',
    );
    expect(
      find.textContaining('Сравнение более сухих маршрутов'),
      findsOneWidget,
    );

    await tester.tap(find.text('Оценить мокрые участки'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('относительный риск влажного покрытия как умеренный'),
      findsOneWidget,
      reason: 'главный вывод сформулирован словами',
    );
    expect(find.textContaining('Вся прогулка'), findsOneWidget);
    expect(find.textContaining('не вероятность лужи'), findsWidgets);
    expect(
      find.textContaining('Покрытие данными'),
      findsNothing,
      reason: 'технические значения находятся в раскрываемом блоке',
    );

    await tester.ensureVisible(
      find.text('Технические подробности влажных участков'),
    );
    await tester.tap(find.text('Технические подробности влажных участков'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Покрытие данными'), findsOneWidget);
    expect(find.textContaining('Уверенность: низкая'), findsOneWidget);
    expect(find.textContaining('Геоданные: OpenStreetMap'), findsOneWidget);
    expect(find.textContaining('Погода: Open-Meteo'), findsOneWidget);
    expect(
      find.textContaining(
        'Weather data by Open-Meteo.com; DWD ICON model; лицензия CC-BY-4.0',
      ),
      findsOneWidget,
      reason: 'лицензия CC-BY-4.0 требует полной атрибуции в интерфейсе',
    );
    expect(
      find.textContaining('Устойчивость к параметрам (экспериментально)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('высыхание вдвое быстрее → низкий'),
      findsOneWidget,
    );
    expect(
      find.textContaining('высыхание вдвое медленнее → высокий'),
      findsOneWidget,
    );
    expect(
      find.text('Параметры экспериментальные и не калиброваны.'),
      findsOneWidget,
    );
    expect(find.text('Оценка относительная.'), findsOneWidget);

    provider.dispose();
    nav.dispose();
    routing.dispose();
  });

  testWidgets('in the simulator the picker names the shared simulation time', (
    tester,
  ) async {
    final simClock = SimClock();
    final source = SimulatedLocationSource(clock: simClock.call);
    final routing = _routingWithRoute();
    final nav = NavigationProvider(
      locationService: source,
      routingProvider: routing,
      routeService: FakeRouteService(),
    );
    final clock = VirtualShadeClock();
    final provider = PuddleAssessmentProvider(
      _FakePuddleService(),
      routing: routing,
      navigation: nav,
      clock: clock,
      now: () => _departure,
    );

    await tester.pumpWidget(_host(provider));

    expect(
      find.text('Время симуляции'),
      findsOneWidget,
      reason: 'выбор времени в симуляторе — это общее виртуальное время',
    );
    expect(find.text('Время оценки'), findsNothing);
    expect(
      find.textContaining('Это общее время симуляции'),
      findsOneWidget,
      reason: 'смена времени явно названа сменой времени симуляции',
    );

    provider.dispose();
    clock.dispose();
    nav.dispose();
    routing.dispose();
  });

  testWidgets('a service failure is shown in words and nothing else changes', (
    tester,
  ) async {
    final simClock = SimClock();
    final source = SimulatedLocationSource(clock: simClock.call);
    final routing = _routingWithRoute();
    final nav = NavigationProvider(
      locationService: source,
      routingProvider: routing,
      routeService: FakeRouteService(),
    );
    final service = _FakePuddleService()
      ..failure = const PuddleAnalysisFailure(
        PuddleAnalysisFailureKind.serviceUnavailable,
        'Оценка мокрых участков сейчас недоступна. Обычная навигация работает.',
      );
    final provider = PuddleAssessmentProvider(
      service,
      routing: routing,
      navigation: nav,
      now: () => _departure,
    );

    await tester.pumpWidget(_host(provider));
    await tester.tap(find.text('Оценить мокрые участки'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Оценка мокрых участков сейчас недоступна. '
        'Обычная навигация работает.',
      ),
      findsOneWidget,
    );
    expect(routing.navigationLocked, isFalse, reason: 'лок не поднят');

    provider.dispose();
    nav.dispose();
    routing.dispose();
  });
}
