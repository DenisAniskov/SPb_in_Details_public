import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/puddle_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/context_recommendations_section.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';

import 'context_recommendation_fixtures.dart';
import 'live_navigation_test.dart' show MockNavigationLocationService;
import 'off_route_reroute_test.dart' show FakeRouteService, FixClock;

// --------------------------------------------------------------------------
// Phase C7.4 UI: a compact panel that answers «что известно», «почему» and
// «насколько полны данные» — without ever showing a number a model withheld,
// an invented factor, a combined score, or an overflowed bottom sheet on a
// 320×480 screen.
// --------------------------------------------------------------------------

final _t1400 = DateTime(2026, 7, 1, 14);
final _t1405 = DateTime(2026, 7, 1, 14, 5);

const _p0 = GeoCoord(59.9300, 30.3100);
const _p1 = GeoCoord(59.9345, 30.3100);
const _p2 = GeoCoord(59.9390, 30.3100);

const _comparison = RouteComparison(
  normalWalkingSeconds: 600,
  scenicWalkingSeconds: 780,
  normalDistanceMeters: 800,
  scenicDistanceMeters: 950,
  stopCount: 2,
  benefitLines: ['Проходит по набережной реки Мойки'],
);

PedestrianRouteModel _walkRoute({WalkKind walkKind = WalkKind.normal}) {
  const legs = [
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'POI 1',
      distanceMeters: 500,
      durationSeconds: 360,
      geometryPoints: [_p0, _p1],
      visitMinutes: 15,
    ),
    RouteLegModel(
      fromTitle: 'POI 1',
      toTitle: 'Финиш',
      distanceMeters: 500,
      durationSeconds: 360,
      geometryPoints: [_p1, _p2],
    ),
  ];
  return PedestrianRouteModel(
    distanceMeters: 1000,
    durationSeconds: 720,
    geometryPoints: const [_p0, _p1, _p2],
    steps: const [],
    legs: legs,
    placesCount: 2,
    walkKind: walkKind,
  );
}

class _FakeShadeService implements BaseShadeAnalysisService {
  int calls = 0;
  ShadeAnalysisFailure? failure;
  ShadeAnalysisModel Function()? response;

  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async {
    calls++;
    final failure = this.failure;
    if (failure != null) throw failure;
    return (response ?? shadeFixture)();
  }
}

class _FakePuddleService implements BasePuddleAnalysisService {
  int calls = 0;
  PuddleAnalysisFailure? failure;
  PuddleAnalysisModel Function()? response;

  @override
  Future<PuddleAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    calls++;
    final failure = this.failure;
    if (failure != null) throw failure;
    return (response ?? puddleHighFixture)();
  }
}

class _FakePollenService implements BasePollenAnalysisService {
  int calls = 0;
  PollenAnalysisFailure? failure;
  PollenAnalysisModel Function()? response;

  @override
  Future<PollenAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    calls++;
    final failure = this.failure;
    if (failure != null) throw failure;
    return (response ?? pollenConcentrationsFixture)();
  }
}

class _Harness {
  _Harness({bool scenic = false, bool withClock = false})
    : shadeService = _FakeShadeService(),
      puddleService = _FakePuddleService(),
      pollenService = _FakePollenService(),
      fixClock = FixClock(),
      location = MockNavigationLocationService(),
      routeService = FakeRouteService() {
    clock = withClock ? VirtualShadeClock() : null;
    routing = RoutingProvider(shadeAnalysisService: shadeService)
      ..setProposedWalkForScenicTest(
        scenic: scenic,
        comparison: scenic ? _comparison : null,
        walkKind: scenic ? WalkKind.scenic : WalkKind.normal,
        route: _walkRoute(walkKind: scenic ? WalkKind.scenic : WalkKind.normal),
      );
    if (clock != null) routing.attachShadeClock(clock);
    navigation = NavigationProvider(
      locationService: location,
      routingProvider: routing,
      routeService: routeService,
    );
    puddle = PuddleAssessmentProvider(
      puddleService,
      routing: routing,
      navigation: navigation,
      clock: clock,
      now: () => now,
    );
    pollen = PollenAssessmentProvider(
      pollenService,
      routing: routing,
      navigation: navigation,
      clock: clock,
      now: () => now,
    );
    panel = ContextRecommendationProvider(
      routing: routing,
      navigation: navigation,
      puddle: puddle,
      pollen: pollen,
      clock: clock,
      // One shared injectable wall clock: the section, the factor providers
      // and the live-walk freshness rules all read the same instant.
      now: () => now,
    );
  }

  final _FakeShadeService shadeService;
  final _FakePuddleService puddleService;
  final _FakePollenService pollenService;
  final FixClock fixClock;
  final MockNavigationLocationService location;
  final FakeRouteService routeService;
  late final RoutingProvider routing;
  late final NavigationProvider navigation;
  late final PuddleAssessmentProvider puddle;
  late final PollenAssessmentProvider pollen;
  late final ContextRecommendationProvider panel;
  VirtualShadeClock? clock;

  /// The one wall clock the whole stack reads. A test moves it forward while
  /// pumping the fake timer clock — that is how "time passed in a real walk"
  /// is staged without waiting.
  DateTime now = _t1400;

  Widget host(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider<RoutingProvider>.value(value: routing),
      ChangeNotifierProvider<NavigationProvider>.value(value: navigation),
      ChangeNotifierProvider<PuddleAssessmentProvider>.value(value: puddle),
      ChangeNotifierProvider<PollenAssessmentProvider>.value(value: pollen),
      ChangeNotifierProvider<ContextRecommendationProvider>.value(value: panel),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );

  Future<void> startWalk() async {
    location.currentPositionResult = UserLocationSnapshot(
      coordinate: _p0,
      timestamp: fixClock.next(),
    );
    await navigation.startNavigation(routing.currentRoute!);
  }

  void walkTo(double latitude) {
    for (var i = 0; i < 2; ++i) {
      navigation.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: GeoCoord(latitude, 30.3100),
          timestamp: fixClock.next(),
        ),
      );
    }
  }

  void dispose() {
    panel.dispose();
    pollen.dispose();
    puddle.dispose();
    clock?.dispose();
    navigation.dispose();
    routing.dispose();
    location.close();
  }
}

const _scrollable = SingleChildScrollView(
  child: ContextRecommendationsSection(),
);

void main() {
  testWidgets('without the provider the panel simply does not exist', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ContextRecommendationsSection())),
    );
    expect(find.text('Рекомендации для прогулки'), findsNothing);
  });

  testWidgets('with nothing assessed the panel says so and starts nothing', (
    tester,
  ) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.host(_scrollable));

    expect(find.text('Рекомендации для прогулки'), findsOneWidget);
    expect(find.textContaining('Рекомендаций пока нет'), findsOneWidget);
    expect(find.textContaining('Область: Вся прогулка'), findsOneWidget);
    // The reasons list is collapsed but present, and names every factor.
    expect(
      find.textContaining('Почему не учтены другие факторы (3)'),
      findsOneWidget,
    );
    expect(harness.shadeService.calls, 0);
    expect(harness.puddleService.calls, 0);
    expect(harness.pollenService.calls, 0);

    await tester.tap(find.textContaining('Почему не учтены другие факторы'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Тень: оценка ещё не выполнялась'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Мокрые участки: оценка ещё не выполнялась'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Пыльца: оценка ещё не выполнялась'),
      findsOneWidget,
    );

    harness.dispose();
  });

  testWidgets('assessed factors answer what, why and how complete', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.routing.assessShade(departure: _t1400);
    await harness.puddle.assess();
    await harness.pollen.assess();
    await tester.pumpWidget(harness.host(_scrollable));

    // 1. What is known: the titles and the facts with their units.
    expect(find.text('Тень: 60% маршрута в тени'), findsOneWidget);
    expect(find.text('В тени: 600 м'), findsOneWidget);
    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Пыльца: концентрации по видам'),
      findsOneWidget,
    );
    expect(find.text('Берёза: 12.6 зёрен пыльцы/м³'), findsOneWidget);
    // 3. How complete: the completeness line is on the card itself.
    expect(find.textContaining('Модель классифицировала 100%'), findsOneWidget);
    expect(find.textContaining('Достоверность: средняя'), findsOneWidget);
    // The set is explicitly not a rating.
    expect(find.textContaining('общий балл не вычисляется'), findsOneWidget);
    expect(
      find.textContaining(
        'Маршрут, остановки и время прогулки рекомендации не меняют',
      ),
      findsOneWidget,
    );

    // 2. Why: the explanation, provenance and limitations are one tap away.
    await tester.tap(find.text('Почему и насколько надёжно').first);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Для этой прогулки рассчитана тень на 60% маршрута'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Метод: building_shadow_projection, версия c7_1_2'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Источник: OpenStreetMap (ODbL)'),
      findsOneWidget,
    );

    harness.dispose();
  });

  testWidgets('a withheld pollen panel shows no concentration at all', (
    tester,
  ) async {
    final harness = _Harness()..pollenService.response = pollenWithheldFixture;
    await harness.pollen.assess();
    await tester.pumpWidget(harness.host(_scrollable));

    expect(find.textContaining('Пыльца: значения удержаны'), findsOneWidget);
    expect(
      find.text('Ольха: 50% времени ходьбы'),
      findsOneWidget,
      reason: 'доля покрытия публикуется',
    );
    expect(
      find.textContaining('grains/m³'),
      findsNothing,
      reason: 'удержанные концентрации не восстанавливаются',
    );
    expect(find.textContaining('числа удержаны'), findsOneWidget);

    harness.dispose();
  });

  testWidgets('a failing factor explains itself instead of disappearing', (
    tester,
  ) async {
    final harness = _Harness()
      ..puddleService.failure = const PuddleAnalysisFailure(
        PuddleAnalysisFailureKind.serviceUnavailable,
        'Оценка мокрых участков сейчас недоступна. Обычная навигация работает.',
      );
    await harness.puddle.assess();
    await tester.pumpWidget(harness.host(_scrollable));

    await tester.tap(find.textContaining('Почему не учтены другие факторы'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Обычная навигация работает'), findsOneWidget);

    harness.dispose();
  });

  testWidgets('the preference chips re-order and reveal, and compute nothing', (
    tester,
  ) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.host(_scrollable));
    expect(find.text('Тень пока не рассчитана'), findsNothing);

    await tester.tap(find.text('Больше тени'));
    await tester.pumpAndSettle();

    expect(harness.panel.preference, RecommendationPreference.shade);
    expect(find.text('Тень пока не рассчитана'), findsOneWidget);
    // Nothing was computed by switching a preference.
    expect(harness.shadeService.calls, 0);
    expect(harness.puddleService.calls, 0);
    expect(harness.routeService.calls, 0);

    await tester.tap(find.text('Все факторы'));
    await tester.pumpAndSettle();
    expect(find.text('Тень пока не рассчитана'), findsNothing);

    harness.dispose();
  });

  testWidgets('four factors stay compact behind «Показать все»', (
    tester,
  ) async {
    final harness = _Harness(scenic: true);
    await harness.routing.assessShade(departure: _t1400);
    await harness.puddle.assess();
    await harness.pollen.assess();
    await tester.pumpWidget(harness.host(_scrollable));

    expect(harness.panel.recommendations, hasLength(4));
    expect(
      find.text('Живописный маршрут построен: +3 мин ходьбы'),
      findsNothing,
      reason: 'по умолчанию видны только три записи',
    );
    await tester.ensureVisible(find.text('Показать все (4)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Показать все (4)'));
    await tester.pumpAndSettle();
    expect(
      find.text('Живописный маршрут построен: +3 мин ходьбы'),
      findsOneWidget,
    );
    expect(find.text('Свернуть'), findsOneWidget);

    harness.dispose();
  });

  testWidgets('the action re-runs only its own factor', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(harness.host(_scrollable));
    await tester.tap(find.text('Больше тени'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Оценить тень'));
    await tester.pumpAndSettle();

    expect(harness.shadeService.calls, 1);
    expect(harness.puddleService.calls, 0);
    expect(harness.pollenService.calls, 0);
    expect(find.text('Тень: 60% маршрута в тени'), findsOneWidget);

    harness.dispose();
  });

  testWidgets('the planning sheet mounts the panel', (tester) async {
    final harness = _Harness();
    await tester.pumpWidget(
      harness.host(const SingleChildScrollView(child: RouteDetailsSheet())),
    );
    expect(find.text('Рекомендации для прогулки'), findsOneWidget);

    harness.dispose();
  });

  testWidgets('mid-walk the sheet asks only about the path ahead', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.routing.assessShade(departure: _t1400);
    await harness.startWalk();
    harness.walkTo(59.9322);
    await harness.puddle.assess();

    await tester.pumpWidget(
      harness.host(const SingleChildScrollView(child: LiveNavigationSheet())),
    );

    expect(find.text('Рекомендации для прогулки'), findsOneWidget);
    expect(find.textContaining('Область: Путь впереди'), findsOneWidget);
    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsOneWidget,
    );
    // The plan's shade estimate is not presented as a fact about the way on.
    expect(find.text('Тень: 60% маршрута в тени'), findsNothing);

    harness.dispose();
  });

  testWidgets('the section states why an overtaken tail estimate is gone', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.startWalk();
    harness.walkTo(59.9322); // ≈ 245 м
    await harness.puddle.assess();

    await tester.pumpWidget(harness.host(_scrollable));
    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsOneWidget,
    );

    // The walker moves on ≈ 200 м along the same session geometry.
    harness.walkTo(59.9340);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsNothing,
      reason: 'оценка описывала остаток, который начинался 200 м назад',
    );
    await tester.tap(find.textContaining('Почему не учтены другие факторы'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'продвинулись по этому же маршруту примерно на 200 м',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('порог — 150 м'), findsOneWidget);
    expect(find.textContaining('Пересчитайте'), findsWidgets);
    expect(tester.takeException(), isNull);

    harness.dispose();
  });

  // --- C7.4.2 #2: an open panel learns that time alone made a fact stale ----

  testWidgets('time alone reaches an open panel: no event, no request', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.startWalk();
    harness.walkTo(59.9322);
    await harness.puddle.assess();
    await tester.pumpWidget(harness.host(_scrollable));
    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsOneWidget,
    );
    final puddleCalls = harness.puddleService.calls;
    final shadeCalls = harness.shadeService.calls;
    expect(harness.panel.hasPendingLiveExpiryWakeUp, isTrue);

    // The walker stands still: no GPS fix, no provider event, no tap. Only
    // time passes — and 14 minutes in the estimate is still the current one.
    harness.now = _t1400.add(const Duration(minutes: 14));
    await tester.pump(const Duration(minutes: 14));
    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsOneWidget,
    );

    // Past the 15-minute window the panel updates by itself and states why.
    harness.now = _t1400.add(const Duration(minutes: 16));
    await tester.pump(const Duration(minutes: 2));
    await tester.pump();

    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsNothing,
      reason: 'оценка устарела без единого события',
    );
    expect(
      harness.panel.hasPendingLiveExpiryWakeUp,
      isFalse,
      reason: 'стареть больше нечему — пробуждение снято',
    );
    await tester.tap(find.textContaining('Почему не учтены другие факторы'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('оценка сделана не менее 15 мин назад'),
      findsOneWidget,
    );
    // The wake-up recomputed nothing and requested nothing.
    expect(harness.puddleService.calls, puddleCalls);
    expect(harness.shadeService.calls, shadeCalls);
    expect(harness.routeService.calls, 0);
    expect(tester.takeException(), isNull);

    harness.dispose();
  });

  testWidgets('an expired source deadline reaches the open panel too', (
    tester,
  ) async {
    final harness = _Harness()
      ..puddleService.response = () =>
          PuddleAnalysisModelWithWeatherValidity(puddleHighFixture(), _t1405);
    await harness.startWalk();
    harness.walkTo(59.9322);
    await harness.puddle.assess();
    await tester.pumpWidget(harness.host(_scrollable));
    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsOneWidget,
    );

    // The forecast is valid until 14:05, so the wake-up is due well before the
    // 15-minute age mark — and again nothing announces it.
    harness.now = _t1400.add(const Duration(minutes: 6));
    await tester.pump(const Duration(minutes: 6));
    await tester.pump();

    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsNothing,
    );
    await tester.tap(find.textContaining('Почему не учтены другие факторы'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('источник был актуален до 01.07.2026 14:05'),
      findsOneWidget,
    );
    expect(
      harness.puddleService.calls,
      1,
      reason: 'пробуждение ничего не пересчитывает',
    );
    expect(tester.takeException(), isNull);

    harness.dispose();
  });

  testWidgets('planning schedules no wake-up and is never aged', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.routing.assessShade(departure: _t1400);
    await harness.puddle.assess();
    await tester.pumpWidget(harness.host(_scrollable));
    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsOneWidget,
    );
    expect(
      harness.panel.hasPendingLiveExpiryWakeUp,
      isFalse,
      reason:
          'в планировании время прогулки выбрано осознанно — стареть нечему',
    );

    // Whatever a wake-up would have been armed for, none exists: two days of
    // wall clock and sixteen minutes of timer time change nothing at all.
    harness.now = _t1400.add(const Duration(days: 2));
    await tester.pump(const Duration(minutes: 16));
    expect(harness.panel.hasPendingLiveExpiryWakeUp, isFalse);
    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsOneWidget,
    );
    expect(find.text('Тень: 60% маршрута в тени'), findsOneWidget);
    expect(tester.takeException(), isNull);

    harness.dispose();
  });

  testWidgets('with the simulator armed the virtual timeline owns freshness', (
    tester,
  ) async {
    final harness = _Harness(withClock: true);
    await harness.startWalk();
    harness.walkTo(59.9322);
    await harness.puddle.assess();
    await tester.pumpWidget(harness.host(_scrollable));
    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsOneWidget,
    );
    expect(
      harness.panel.hasPendingLiveExpiryWakeUp,
      isFalse,
      reason: 'при взведённых часах настенное время ничего не решает',
    );

    harness.now = _t1400.add(const Duration(hours: 5));
    await tester.pump(const Duration(minutes: 16));
    expect(
      find.textContaining('520 м с высоким относительным риском'),
      findsOneWidget,
      reason: 'виртуальная шкала важнее настенного времени',
    );
    expect(tester.takeException(), isNull);

    harness.dispose();
  });

  testWidgets('no overflow on a 320×480 screen with everything expanded', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final harness = _Harness(scenic: true);
    await harness.routing.assessShade(departure: _t1400);
    await harness.puddle.assess();
    await harness.pollen.assess();
    await tester.pumpWidget(harness.host(_scrollable));

    Future<void> tapText(String text) async {
      final finder = find.textContaining(text);
      await tester.ensureVisible(finder.first);
      await tester.pumpAndSettle();
      await tester.tap(finder.first);
      await tester.pumpAndSettle();
    }

    await tapText('Больше живописности');
    await tapText('Показать все (4)');
    final tiles = find.text('Почему и насколько надёжно').evaluate().length;
    for (var i = 0; i < tiles; ++i) {
      final tile = find.text('Почему и насколько надёжно').at(i);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }
    // Every factor contributed, so no "why not accounted for" list exists yet.
    expect(
      find.textContaining('Почему не учтены другие факторы'),
      findsNothing,
    );

    // Now one factor fails while the panel is on screen: the report list and
    // its layout must fit the same small screen too.
    harness.shadeService.failure = const ShadeAnalysisFailure(
      ShadeAnalysisFailureKind.serviceUnavailable,
      'Оценка тени недоступна. Обычная навигация работает.',
    );
    await harness.routing.assessShade(departure: _t1400);
    await tester.pumpAndSettle();
    await tapText('Почему не учтены другие факторы');
    expect(find.textContaining('Тень: Оценка тени недоступна'), findsOneWidget);

    expect(tester.takeException(), isNull);

    harness.dispose();
  });
}
