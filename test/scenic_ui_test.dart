import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/scenic_walk_engine.dart';
import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';

/// Phase C5 §7/§12: walk-type choice, route comparison, honest fallback
/// messaging, narrow screens, enlarged text, semantics.
void main() {
  group('Smart Walk wizard: walk type choice', () {
    testWidgets('scenic choice is deferred until native geometry is checked', (
      tester,
    ) async {
      final routing = RoutingProvider();
      addTearDown(routing.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<PlacesRepository>(create: (_) => PlacesRepository()),
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
            ChangeNotifierProvider<PlacesProvider>(
              create: (ctx) =>
                  PlacesProvider(repository: ctx.read<PlacesRepository>()),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SmartWalkWizardSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Точка отправления'), findsOneWidget);
      expect(find.text('Живописный маршрут'), findsNothing);
      expect(
        find.textContaining('По возможности через парки, набережные'),
        findsNothing,
      ); // description appears only for the scenic choice

      await tester.tap(find.text('Продолжить'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('По возможности через парки, набережные'),
        findsNothing,
      );
      expect(find.text('Умная прогулка'), findsOneWidget);
      expect(find.text('Собственный маршрут'), findsOneWidget);
    });

    testWidgets('narrow screen renders the selector without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final routing = RoutingProvider();
      addTearDown(routing.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<PlacesRepository>(create: (_) => PlacesRepository()),
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
            ChangeNotifierProvider<PlacesProvider>(
              create: (ctx) =>
                  PlacesProvider(repository: ctx.read<PlacesRepository>()),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SmartWalkWizardSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('enlarged text renders without overflow', (tester) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final routing = RoutingProvider();
      addTearDown(routing.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<PlacesRepository>(create: (_) => PlacesRepository()),
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
            ChangeNotifierProvider<PlacesProvider>(
              create: (ctx) =>
                  PlacesProvider(repository: ctx.read<PlacesRepository>()),
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: const Scaffold(body: SmartWalkWizardSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('Route details: scenic comparison and fallback (§7.2/§10)', () {
    Widget harness(RoutingProvider routing) =>
        ChangeNotifierProvider<RoutingProvider>.value(
          value: routing,
          child: const MaterialApp(home: Scaffold(body: RouteDetailsSheet())),
        );

    PedestrianRouteModel scenicRoute() {
      const leg = RouteLegModel(
        fromTitle: 'Старт',
        toTitle: 'POI 1',
        distanceMeters: 500,
        durationSeconds: 360,
        geometryPoints: [],
      );
      return const PedestrianRouteModel(
        distanceMeters: 500,
        durationSeconds: 360,
        geometryPoints: [],
        steps: [],
        legs: [leg],
        placesCount: 1,
        walkKind: WalkKind.scenic,
      );
    }

    testWidgets('comparison card shows both variants and verified benefits', (
      tester,
    ) async {
      final routing = RoutingProvider()
        ..setProposedWalkForScenicTest(
          scenic: true,
          comparison: const RouteComparison(
            normalWalkingSeconds: 360,
            scenicWalkingSeconds: 480,
            normalDistanceMeters: 500,
            scenicDistanceMeters: 640,
            stopCount: 2,
            benefitLines: ['Проходит по набережной реки Мойки'],
          ),
          walkKind: WalkKind.scenic,
          route: scenicRoute(),
        );
      addTearDown(routing.dispose);
      await tester.pumpWidget(harness(routing));
      await tester.pumpAndSettle();
      expect(find.text('Живописный маршрут построен'), findsOneWidget);
      expect(find.textContaining('Обычная: 6 мин'), findsOneWidget);
      expect(find.textContaining('Живописная: 8 мин'), findsOneWidget);
      expect(find.textContaining('+2 мин ходьбы'), findsOneWidget);
      expect(
        find.textContaining('Проходит по набережной реки Мойки'),
        findsOneWidget,
      );
    });

    testWidgets('fallback message is honest when no scenic variant passed', (
      tester,
    ) async {
      final routing = RoutingProvider()
        ..setProposedWalkForScenicTest(
          scenic: true,
          comparison: null,
          walkKind: WalkKind.normal,
          route: scenicRoute(),
          // Product wording for ScenicFallbackReason.noVerifiedGeometry
          // (scenicFallbackReasonText) — the UI must show exactly what the
          // provider composed for the actual reason.
          fallbackMessage: scenicFallbackReasonText(
            ScenicFallbackReason.noVerifiedGeometry,
          ),
        );
      addTearDown(routing.dispose);
      await tester.pumpWidget(harness(routing));
      await tester.pumpAndSettle();
      expect(find.text('Живописный маршрут построен'), findsNothing);
      expect(
        find.textContaining('не удалось достаточно надёжно подтвердить'),
        findsOneWidget,
      );
    });

    testWidgets('normal walks show neither card nor fallback message', (
      tester,
    ) async {
      final routing = RoutingProvider()
        ..setProposedWalkForScenicTest(
          scenic: false,
          comparison: null,
          walkKind: WalkKind.normal,
          route: scenicRoute(),
        );
      addTearDown(routing.dispose);
      await tester.pumpWidget(harness(routing));
      await tester.pumpAndSettle();
      expect(find.textContaining('живописный'), findsNothing);
      expect(find.textContaining('Живописная'), findsNothing);
    });

    testWidgets('comparison card fits a 320 dp screen and enlarged text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final routing = RoutingProvider()
        ..setProposedWalkForScenicTest(
          scenic: true,
          comparison: const RouteComparison(
            normalWalkingSeconds: 360,
            scenicWalkingSeconds: 480,
            normalDistanceMeters: 500,
            scenicDistanceMeters: 640,
            stopCount: 2,
            benefitLines: [
              'Проходит по набережной реки Мойки',
              'Проходит рядом с пешеходной улицей Малая Садовая',
            ],
          ),
          walkKind: WalkKind.scenic,
          route: scenicRoute(),
        );
      addTearDown(routing.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<RoutingProvider>.value(
          value: routing,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: const Scaffold(body: RouteDetailsSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
