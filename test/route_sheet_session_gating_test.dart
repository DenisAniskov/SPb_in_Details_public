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
import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';

import 'smart_walk_audit_test.dart' show PendingRepository, poi;

/// RouteDetailsSheet / navigation-session gating (Controller Round 2, M-5).
///
/// While any non-idle navigation session is still represented, the route
/// details presentation must not expose a conflicting «Начать маршрут»
/// action — neither through the bottom-sheet priority chain (including
/// keyboard/viewInsets transitions) nor through the sheet's own button.
class InstantRoutes extends MapKitService {
  @override
  void cancel() {}

  @override
  Future<PedestrianRouteModel> calculatePedestrianRoute({
    required RoutePointModel startPoint,
    required PlaceModel destination,
  }) async {
    return const PedestrianRouteModel(
      distanceMeters: 500,
      durationSeconds: 360,
      geometryPoints: [GeoCoord(59.94, 30.31), GeoCoord(59.945, 30.315)],
      steps: [],
      placesCount: 1,
      legs: [
        RouteLegModel(
          fromTitle: 'Старт',
          toTitle: 'Финиш',
          distanceMeters: 500,
          durationSeconds: 360,
          geometryPoints: [GeoCoord(59.94, 30.31), GeoCoord(59.945, 30.315)],
        ),
      ],
    );
  }
}

class SessionNav extends NavigationProvider {
  SessionNav(LiveNavigationState initial) : snapshot = initial;

  LiveNavigationState snapshot;
  int starts = 0;
  int stops = 0;

  @override
  LiveNavigationState get state => snapshot;
  @override
  NavigationStatus get status => snapshot.status;

  void show(LiveNavigationState next) {
    snapshot = next;
    notifyListeners();
  }

  @override
  Future<void> startNavigation(PedestrianRouteModel route) async {
    starts++;
  }

  @override
  void stopNavigation() {
    stops++;
    snapshot = const LiveNavigationState();
    notifyListeners();
  }
}

Widget _host({
  required PlacesProvider places,
  required RoutingProvider routing,
  required NavigationProvider nav,
  required double keyboard,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PlacesProvider>.value(value: places),
      ChangeNotifierProvider<RoutingProvider>.value(value: routing),
      ChangeNotifierProvider<NavigationProvider>.value(value: nav),
    ],
    child: MaterialApp(
      home: const MainMapScreen(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
        child: child!,
      ),
    ),
  );
}

void main() {
  setUp(() {
    MapKitService.isMapKitInitialized = false;
  });

  for (final status in [
    NavigationStatus.active,
    NavigationStatus.completed,
    NavigationStatus.error,
    NavigationStatus.paused,
  ]) {
    testWidgets(
      'keyboard transitions never resurface route details for $status session',
      (tester) async {
        final repo = PendingRepository();
        final places = PlacesProvider(repository: repo);
        final routing = RoutingProvider(mapKitService: InstantRoutes());
        await routing.buildRouteTo(poi(1));
        expect(routing.hasRoute, isTrue);
        final nav = SessionNav(
          LiveNavigationState(status: status, route: routing.currentRoute),
        );
        addTearDown(places.dispose);
        addTearDown(routing.dispose);
        addTearDown(nav.dispose);

        // Keyboard closed: the live presentation wins the priority chain for
        // every non-idle session status.
        await tester.pumpWidget(_host(
          places: places,
          routing: routing,
          nav: nav,
          keyboard: 0,
        ));
        await tester.pumpAndSettle();
        expect(find.byType(LiveNavigationSheet), findsOneWidget);
        expect(find.byType(RouteDetailsSheet), findsNothing);

        // Keyboard opens. The Scaffold consumes the inset by resizing its
        // body, so the sheet chain keeps rendering the live presentation —
        // and must never fall through to the route details sheet.
        await tester.pumpWidget(_host(
          places: places,
          routing: routing,
          nav: nav,
          keyboard: 300,
        ));
        await tester.pump();
        expect(find.byType(RouteDetailsSheet), findsNothing);
        expect(find.byType(LiveNavigationSheet), findsOneWidget);

        // Keyboard closes again: the session still exists, so the route
        // details sheet must not resurface.
        await tester.pumpWidget(_host(
          places: places,
          routing: routing,
          nav: nav,
          keyboard: 0,
        ));
        await tester.pumpAndSettle();
        expect(find.byType(RouteDetailsSheet), findsNothing);
        expect(find.byType(LiveNavigationSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('route sheet start action defers to a running session',
      (tester) async {
    final routing = RoutingProvider(mapKitService: InstantRoutes());
    await routing.buildRouteTo(poi(1));
    final nav = SessionNav(
      const LiveNavigationState(status: NavigationStatus.active),
    );
    addTearDown(routing.dispose);
    addTearDown(nav.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RoutingProvider>.value(value: routing),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ],
        child: const MaterialApp(
          home: Scaffold(body: RouteDetailsSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A running session owns the screen: the action is disabled, never a
    // silent no-op waiting for a tap.
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button.onPressed, isNull);

    // Terminal session: the action follows the app-wide dismissal convention —
    // stop first, then start the retained route.
    nav.show(const LiveNavigationState(status: NavigationStatus.completed));
    await tester.pumpAndSettle();
    final reopened = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(reopened.onPressed, isNotNull);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(nav.stops, 1, reason: 'terminal session is dismissed first');
    expect(nav.starts, 1, reason: 'the retained route starts after dismissal');
  });
}
