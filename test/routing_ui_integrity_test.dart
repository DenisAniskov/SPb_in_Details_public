import 'guided_walk_test_helpers.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/walk_planner_sheet.dart';

import 'smart_walk_audit_test.dart'
    show PendingRepository, mountWizard, poi, proposal, tapVisible;

PedestrianRouteModel testRoute({int seconds = 120, int count = 2}) {
  final legs = List.generate(
    count,
    (index) => RouteLegModel(
      fromTitle: 'Точка $index',
      toTitle: 'Точка ${index + 1}',
      distanceMeters: 100,
      durationSeconds: seconds ~/ count,
      geometryPoints: [
        GeoCoord(59.94 + index * 0.001, 30.31),
        GeoCoord(59.94 + (index + 1) * 0.001, 30.31),
      ],
    ),
  );
  return PedestrianRouteModel(
    distanceMeters: count * 100,
    durationSeconds: seconds,
    geometryPoints: legs.expand((leg) => leg.geometryPoints).toList(),
    legs: legs,
    steps: const [],
    placesCount: count,
  );
}

class PlanningRoutes extends MapKitService {
  bool wait = false;
  final pending = <Completer<PedestrianRouteModel>>[];
  final starts = <RoutePointModel>[];
  int Function(int count) walkingSeconds = (_) => 120;

  @override
  void cancel() {}

  @override
  Future<PedestrianRouteModel> calculatePedestrianRoute({
    required RoutePointModel startPoint,
    required PlaceModel destination,
  }) async {
    starts.add(startPoint);
    if (wait) {
      final result = Completer<PedestrianRouteModel>();
      pending.add(result);
      return result.future;
    }
    return testRoute(count: 1);
  }

  @override
  Future<PedestrianRouteModel> calculateWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
  }) async =>
      testRoute(seconds: walkingSeconds(places.length), count: places.length);
}

class NavigationPresentation extends NavigationProvider {
  NavigationPresentation(this.snapshot);
  LiveNavigationState snapshot;
  int stops = 0;
  int pauses = 0;

  @override
  LiveNavigationState get state => snapshot;
  @override
  NavigationStatus get status => snapshot.status;
  @override
  bool get locksPlanning => {
    NavigationStatus.starting,
    NavigationStatus.active,
    NavigationStatus.rerouting,
    NavigationStatus.paused,
  }.contains(status);

  @override
  void stopNavigation() {
    stops++;
    snapshot = const LiveNavigationState();
    notifyListeners();
  }

  @override
  void pauseNavigation() {
    pauses++;
    snapshot = snapshot.copyWith(status: NavigationStatus.paused);
    notifyListeners();
  }
}

void main() {
  test(
    'rerouted legs are separate polylines without an invented connector',
    () {
      final completed = testRoute(count: 1).legs.single;
      const remaining = RouteLegModel(
        fromTitle: 'Текущее местоположение',
        toTitle: 'Следующая точка',
        distanceMeters: 200,
        durationSeconds: 200,
        geometryPoints: [GeoCoord(60, 30.4), GeoCoord(60.001, 30.4)],
      );
      final route = PedestrianRouteModel(
        distanceMeters: 300,
        durationSeconds: 320,
        geometryPoints: [
          ...completed.geometryPoints,
          ...remaining.geometryPoints,
        ],
        legs: [completed, remaining],
        steps: const [],
      );
      final lines = routePolylineGeometries(route).toList();
      expect(lines, [completed.geometryPoints, remaining.geometryPoints]);
      expect(lines.first.last, isNot(same(lines.last.first)));
      expect(lines.every((line) => line.length == 2), isTrue);
    },
  );

  test('legacy routes draw their genuine aggregate geometry', () {
    final native = testRoute(count: 1);
    final route = PedestrianRouteModel(
      distanceMeters: native.distanceMeters,
      durationSeconds: native.durationSeconds,
      geometryPoints: native.geometryPoints,
      steps: const [],
    );
    expect(routePolylineGeometries(route).single, same(native.geometryPoints));
  });

  test('new start is never published with old successful geometry', () async {
    final native = PlanningRoutes();
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    await routing.buildRouteTo(poi(1));
    final oldRoute = routing.currentRoute;
    final observations = <(double, PedestrianRouteModel?)>[];
    routing.addListener(() {
      observations.add((routing.startPoint.latitude, routing.currentRoute));
    });
    native.wait = true;
    routing.setCustomStartPoint(60, 31);
    expect(observations, isNotEmpty);
    expect(observations.every((state) => state.$2 == null), isTrue);
    expect(routing.currentRoute, isNot(same(oldRoute)));
    expect(native.starts.last.latitude, 60);
    native.pending.single.complete(testRoute(count: 1));
    await Future<void>.delayed(Duration.zero);
    expect(routing.hasRoute, isTrue);
  });

  test(
    'ordinary route clears old Smart Walk budget correction notice',
    () async {
      final native = PlanningRoutes()
        ..walkingSeconds = (count) => count == 2 ? 50 * 60 : 10 * 60;
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk([poi(1), poi(2)], timeBudgetMinutes: 40);
      await routing.buildWalkRoute();
      expect(routing.budgetWarningMessage, isNotNull);
      await routing.buildRouteTo(poi(3));
      expect(routing.isWalkRoute, isFalse);
      expect(routing.budgetWarningMessage, isNull);
    },
  );

  test('navigation lock ends pending map start selection', () {
    final routing = RoutingProvider(mapKitService: PlanningRoutes());
    addTearDown(routing.dispose);
    routing.beginStartSelection();
    expect(routing.isChoosingStart, isTrue);
    routing.setNavigationLocked(true);
    expect(routing.isChoosingStart, isFalse);
  });

  testWidgets('planner disables every mutation using the provider lock', (
    tester,
  ) async {
    final routing = RoutingProvider(mapKitService: PlanningRoutes());
    addTearDown(routing.dispose);
    routing.addPlaceToWalk(poi(1));
    routing.setNavigationLocked(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: routing,
        child: const MaterialApp(home: Scaffold(body: WalkPlannerSheet())),
      ),
    );
    await tester.pumpAndSettle();
    final buttons = tester.widgetList<ButtonStyleButton>(
      find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    );
    expect(buttons, isNotEmpty);
    expect(buttons.every((button) => button.onPressed == null), isTrue);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) =>
                  w is IconButton && w.tooltip == 'Умная прогулка (автоподбор)',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(find.byTooltip('Изменить порядок места'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wizard drops pending proposal across navigation lock/unlock', (
    tester,
  ) async {
    final repo = PendingRepository();
    final routing = RoutingProvider(mapKitService: PlanningRoutes());
    await mountWizard(tester, repo, routing);
    await guidedToInterests(tester);
    await tapVisible(tester, find.text('Сформировать прогулку'));
    routing.setNavigationLocked(true);
    await tester.pump();
    routing.setNavigationLocked(false);
    repo.pending.single.complete(proposal());
    await tester.pumpAndSettle();
    expect(find.text('Предварительный подбор'), findsNothing);
    expect(find.text('Построить прогулку'), findsNothing);
    expect(routing.walkPlaces, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a queued wizard callback cannot apply a proposal after lock', (
    tester,
  ) async {
    final repo = PendingRepository();
    final routing = RoutingProvider(mapKitService: PlanningRoutes());
    await mountWizard(tester, repo, routing);
    await guidedToInterests(tester);
    await tapVisible(tester, find.text('Сформировать прогулку'));
    repo.pending.single.complete(proposal());
    await tester.pumpAndSettle();
    final apply = tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Построить прогулку'),
        )
        .onPressed!;
    routing.setNavigationLocked(true);
    apply();
    await tester.pumpAndSettle();
    expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
    expect(routing.walkPlaces, isEmpty);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Построить прогулку'),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a queued wizard generation cannot send a request after lock', (
    tester,
  ) async {
    final repo = PendingRepository();
    final routing = RoutingProvider(mapKitService: PlanningRoutes());
    await mountWizard(tester, repo, routing);
    await guidedToInterests(tester);
    final generate = tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Сформировать прогулку'),
        )
        .onPressed!;
    routing.setNavigationLocked(true);
    generate();
    await tester.pumpAndSettle();
    expect(repo.pending, isEmpty);
    expect(routing.walkPlaces, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hidden map pauses navigation while inactive keeps dialogs alive',
    (tester) async {
      MapKitService.isMapKitInitialized = false;
      final repo = PendingRepository();
      final places = PlacesProvider(repository: repo);
      final routing = RoutingProvider(mapKitService: PlanningRoutes());
      final nav = NavigationPresentation(
        LiveNavigationState(
          status: NavigationStatus.active,
          route: testRoute(),
        ),
      );
      addTearDown(places.dispose);
      addTearDown(routing.dispose);
      addTearDown(nav.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: places),
            ChangeNotifierProvider.value(value: routing),
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ],
          child: const MaterialApp(home: MainMapScreen()),
        ),
      );
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(nav.pauses, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(nav.pauses, 1);
      expect(nav.status, NavigationStatus.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final status in [NavigationStatus.completed, NavigationStatus.error]) {
    testWidgets('new planner dismisses terminal $status presentation', (
      tester,
    ) async {
      MapKitService.isMapKitInitialized = false;
      final repo = PendingRepository();
      final places = PlacesProvider(repository: repo);
      final routing = RoutingProvider(mapKitService: PlanningRoutes());
      final nav = NavigationPresentation(
        LiveNavigationState(status: status, route: testRoute()),
      );
      addTearDown(places.dispose);
      addTearDown(routing.dispose);
      addTearDown(nav.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: places),
            ChangeNotifierProvider.value(value: routing),
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ],
          child: const MaterialApp(home: MainMapScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LiveNavigationSheet), findsOneWidget);
      await tester.tap(find.byTooltip('Прогулка'));
      await tester.pumpAndSettle();
      expect(nav.stops, 1);
      expect(nav.status, NavigationStatus.idle);
      expect(find.byType(LiveNavigationSheet), findsNothing);
      expect(find.byType(WalkPlannerSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('live presentation separates tourist stops from geometry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final nav = NavigationPresentation(
      LiveNavigationState(
        status: NavigationStatus.active,
        route: testRoute(),
        currentLegIndex: 1,
        totalProgressMeters: 100,
        remainingDistanceOnCurrentLegMeters: 100,
        isOffRoute: true,
        distanceFromRouteMeters: 60,
      ),
    );
    addTearDown(nav.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<NavigationProvider>.value(
        value: nav,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const Scaffold(body: LiveNavigationSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Вы вне маршрута'), findsOneWidget);
    expect(find.text('Достигнуто точек: 1 из 2'), findsOneWidget);
    expect(find.text('Пройдено по текущему маршруту: 100 м'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation failure with no route does not claim zero distance', (
    tester,
  ) async {
    final nav = NavigationPresentation(
      const LiveNavigationState(
        status: NavigationStatus.error,
        errorMessage: 'Маршрут недоступен',
      ),
    );
    addTearDown(nav.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<NavigationProvider>.value(
        value: nav,
        child: const MaterialApp(home: Scaffold(body: LiveNavigationSheet())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Навигация недоступна'), findsOneWidget);
    expect(find.text('Следующая точка:'), findsNothing);
    expect(find.text('0 м'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
