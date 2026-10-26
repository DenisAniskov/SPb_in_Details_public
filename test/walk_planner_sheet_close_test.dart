import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/walk_planner_sheet.dart';

import 'smart_walk_audit_test.dart' show NativeRouteAdapter, poi, route;

void main() {
  Future<void> mountPlanner(
    WidgetTester tester,
    RoutingProvider routing, {
    WalkPlannerSheet Function()? sheet,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<RoutingProvider>.value(
        value: routing,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => sheet?.call() ?? const WalkPlannerSheet(),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
  }

  Finder buildButton() => find.byType(ElevatedButton);

  testWidgets(
    'standalone planner closes with a snack bar after a real successful build',
    (tester) async {
      final native = NativeRouteAdapter();
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.addPlaceToWalk(poi(1));

      await mountPlanner(tester, routing);
      expect(find.text('Туристическая прогулка'), findsOneWidget);

      await tester.tap(buildButton());
      await tester.pumpAndSettle();

      expect(native.calls, hasLength(1));
      expect(routing.hasRoute, isTrue);
      expect(routing.isWalkRoute, isTrue);
      // The sheet closed itself and the map-level confirmation appeared once.
      expect(find.text('Туристическая прогулка'), findsNothing);
      expect(find.text(AppStrings.routeBuiltSuccess), findsOneWidget);
      expect(find.text('Открыть'), findsOneWidget);
    },
  );

  testWidgets(
    'failed build keeps the sheet open with an error and the selection',
    (tester) async {
      final native = NativeRouteAdapter()..fail = true;
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.addPlaceToWalk(poi(1));

      await mountPlanner(tester, routing);

      await tester.tap(buildButton());
      await tester.pumpAndSettle();

      expect(routing.hasRoute, isFalse);
      expect(find.text('Туристическая прогулка'), findsOneWidget);
      expect(find.text(AppStrings.routeBuiltSuccess), findsNothing);
      // The provider's human-readable message is visible inside the sheet.
      expect(routing.errorMessage, isNotNull);
      expect(find.text(routing.errorMessage!), findsOneWidget);
      expect(find.byType(WalkPlannerSheet), findsOneWidget);
      expect(routing.walkPlaces, hasLength(1));
      // The button is enabled again for a retry.
      final button = tester.widget<ElevatedButton>(buildButton());
      expect(button.onPressed, isNotNull);
    },
  );

  testWidgets(
    'button locks during a slow build: no duplicate requests, exactly one close',
    (tester) async {
      final native = NativeRouteAdapter()..wait = true;
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.addPlaceToWalk(poi(1));

      await mountPlanner(tester, routing);

      await tester.tap(buildButton());
      await tester.pump();
      expect(routing.isCalculating, isTrue);
      final button = tester.widget<ElevatedButton>(buildButton());
      expect(button.onPressed, isNull);

      // A second press while disabled must not queue another MapKit request.
      await tester.tap(buildButton(), warnIfMissed: false);
      await tester.pump();
      expect(native.calls, hasLength(1));
      expect(find.text('Туристическая прогулка'), findsOneWidget);

      native.pending.single.complete(route(120, 1));
      await tester.pumpAndSettle();

      expect(native.calls, hasLength(1));
      expect(routing.hasRoute, isTrue);
      // Exactly one close: the sheet is gone and the root screen survived.
      expect(find.text('Туристическая прогулка'), findsNothing);
      expect(find.text('Открыть'), findsOneWidget);
      expect(find.text(AppStrings.routeBuiltSuccess), findsOneWidget);
    },
  );

  testWidgets(
    'user closing the sheet mid-build causes no late success, pop or exception',
    (tester) async {
      final native = NativeRouteAdapter()..wait = true;
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.addPlaceToWalk(poi(1));

      await mountPlanner(tester, routing);

      await tester.tap(buildButton());
      await tester.pump();
      expect(native.calls, hasLength(1));

      // The user dismisses the sheet before the route resolves.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Туристическая прогулка'), findsNothing);

      native.pending.single.complete(route(120, 1));
      await tester.pumpAndSettle();

      // No exception, no late snack bar, no second pop of the root screen.
      expect(tester.takeException(), isNull);
      expect(find.text(AppStrings.routeBuiltSuccess), findsNothing);
      expect(find.text('Открыть'), findsOneWidget);
    },
  );

  testWidgets(
    'embedded planner keeps the wizard flow: onContinue runs, sheet stays, no success snack bar',
    (tester) async {
      final native = NativeRouteAdapter();
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.addPlaceToWalk(poi(1));

      var continued = 0;
      await mountPlanner(
        tester,
        routing,
        sheet: () =>
            WalkPlannerSheet(embedded: true, onContinue: () => continued++),
      );

      await tester.tap(buildButton());
      await tester.pumpAndSettle();

      expect(continued, 1);
      // The wizard step is still on screen; the standalone success message
      // must not appear and no route is published to the map provider.
      expect(find.byType(WalkPlannerSheet), findsOneWidget);
      expect(find.text(AppStrings.routeBuiltSuccess), findsNothing);
      expect(routing.hasRoute, isFalse);
      expect(native.calls, isEmpty);
    },
  );

  testWidgets(
    'superseded build result does not close the sheet or fake success',
    (tester) async {
      final native = NativeRouteAdapter()..wait = true;
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.addPlaceToWalk(poi(1));

      await mountPlanner(tester, routing);

      await tester.tap(buildButton());
      await tester.pump();
      expect(native.calls, hasLength(1));

      // A newer operation invalidates the in-flight request...
      routing.clearRoute();
      await tester.pump();

      native.pending.single.complete(route(120, 1));
      await tester.pumpAndSettle();

      // ...so the stale completion is neither a route nor a reason to close.
      expect(routing.hasRoute, isFalse);
      expect(find.text('Туристическая прогулка'), findsOneWidget);
      expect(find.text(AppStrings.routeBuiltSuccess), findsNothing);
      expect(find.text('Открыть'), findsOneWidget);
    },
  );
}
