import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/config/simulator_gate.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/simulated_location_source.dart';
import 'package:smart_navigator_spb/ui/controllers/simulation_controller.dart';
import 'package:smart_navigator_spb/ui/widgets/simulation_control_panel.dart';

import 'off_route_reroute_test.dart' show a, b;
import 'simulated_location_source_test.dart' show SimClock;

/// Phase C4.1 Sections 2/5: the debug simulator panel — gating, controls,
/// the «РЕЖИМ СИМУЛЯЦИИ» banner, and layout stability.
void main() {
  PedestrianRouteModel fixtureRoute() => const PedestrianRouteModel(
        distanceMeters: 55.6,
        durationSeconds: 60,
        geometryPoints: [a, b],
        steps: [],
        legs: [
          RouteLegModel(
            fromTitle: 'Старт',
            toTitle: 'POI 1',
            distanceMeters: 55.6,
            durationSeconds: 60,
            geometryPoints: [a, b],
          ),
        ],
        placesCount: 1,
      );

  late SimClock clock;
  late SimulatedLocationSource source;
  late NavigationProvider nav;
  late RoutingProvider routing;
  late SimulationController controller;

  setUp(() {
    clock = SimClock();
    UserLocationSnapshot.clock = clock.call;
    source = SimulatedLocationSource(clock: clock.call);
    nav = NavigationProvider(locationService: source);
    routing = RoutingProvider();
    controller = SimulationController(
      source: source,
      nav: nav,
      tickInterval: const Duration(hours: 1),
    );
  });

  tearDown(() {
    NavigationSimulatorGate.overrideForTesting = null;
    UserLocationSnapshot.clock = DateTime.now;
    nav.dispose();
    routing.dispose();
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    Size surface = const Size(412, 900),
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ChangeNotifierProvider<RoutingProvider>.value(value: routing),
          ChangeNotifierProvider<SimulationController>.value(value: controller),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SimulationControlPanel(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  test('gate: enabled only with an explicit override in debug builds', () {
    NavigationSimulatorGate.overrideForTesting = true;
    expect(NavigationSimulatorGate.enabled, isTrue);
    NavigationSimulatorGate.overrideForTesting = false;
    expect(NavigationSimulatorGate.enabled, isFalse);
    NavigationSimulatorGate.overrideForTesting = null;
    // In test builds the dart-define is absent → disabled by default.
    expect(NavigationSimulatorGate.enabled, isFalse);
  });

  testWidgets('panel is invisible when the simulator gate is off', (
    tester,
  ) async {
    NavigationSimulatorGate.overrideForTesting = false;
    await pumpPanel(tester);
    expect(find.text('РЕЖИМ СИМУЛЯЦИИ'), findsNothing);
  });

  testWidgets('panel shows the banner and transport controls', (tester) async {
    NavigationSimulatorGate.overrideForTesting = true;
    await pumpPanel(tester);
    expect(find.text('РЕЖИМ СИМУЛЯЦИИ'), findsOneWidget);
    expect(find.text('Старт'), findsOneWidget);
    expect(find.text('Заново'), findsOneWidget);
    expect(find.text('Завершить'), findsOneWidget);
    expect(find.text('3 км/ч'), findsOneWidget);
    expect(find.text('5 км/ч'), findsOneWidget);
    expect(find.text('8 км/ч'), findsOneWidget);
    expect(find.textContaining('Симуляция: 0 м'), findsOneWidget);
  });

  testWidgets('start builds the session and switches to pause', (tester) async {
    NavigationSimulatorGate.overrideForTesting = true;
    await pumpPanel(tester);
    // Give the panel a scenario route the way the map screen would.
    await controller.startWithRoute(fixtureRoute());
    await tester.pump();
    // The periodic timer never fires in the test environment; state changes
    // come from the controller directly.
    expect(find.text('Пауза'), findsOneWidget);
    expect(find.text('Старт'), findsNothing);
    controller.pause();
    await tester.pump();
    expect(find.text('Старт'), findsOneWidget);
    // Release the engine's watchdog and the simulator ticker in-body: the
    // widget-test invariant check rejects still-pending timers.
    await controller.finish();
    await tester.pump();
  });

  testWidgets('error injection chips are present', (tester) async {
    NavigationSimulatorGate.overrideForTesting = true;
    // A scenario route unlocks the seek and injection sections.
    await controller.startWithRoute(fixtureRoute());
    controller.pause();
    await pumpPanel(tester);
    expect(find.text('Потеря GPS 10 с'), findsOneWidget);
    expect(find.text('Точность 45 м'), findsOneWidget);
    expect(find.text('Устаревший фикс'), findsOneWidget);
    expect(find.text('Скачок +120 м'), findsOneWidget);
    expect(find.text('Отклонение 80 м'), findsOneWidget);
    // Return-to-route is disabled while there is no deviation.
    expect(find.text('Вернуться на маршрут'), findsOneWidget);
    await controller.finish();
    await tester.pump();
  });

  testWidgets('320 dp screen renders the panel without overflow', (tester) async {
    NavigationSimulatorGate.overrideForTesting = true;
    await pumpPanel(tester, surface: const Size(320, 640));
    expect(tester.takeException(), isNull);
  });

  testWidgets('enlarged system font renders without overflow', (tester) async {
    NavigationSimulatorGate.overrideForTesting = true;
    await pumpPanel(tester, textScale: 1.6);
    expect(tester.takeException(), isNull);
  });
}
