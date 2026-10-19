import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/device_location_service.dart';
import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/context_recommendations_section.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';

import 'smart_walk_audit_test.dart' show NativeRouteAdapter, poi;

class _NavLocation implements BaseDeviceLocationService {
  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      LocationPermissionStatus.grantedPrecise;

  @override
  Future<LocationPermissionStatus> requestPermission() async =>
      LocationPermissionStatus.grantedPrecise;

  @override
  Future<UserLocationSnapshot?> getLastKnownPosition() async => null;

  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) async => UserLocationSnapshot(
    coordinate: const GeoCoord(59.9300, 30.3300),
    timestamp: DateTime.now(),
  );

  @override
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  }) => const Stream<UserLocationSnapshot>.empty();

  @override
  Stream<bool> getServiceStatusStream() => const Stream<bool>.empty();
}

const _liveRoute = PedestrianRouteModel(
  distanceMeters: 600,
  durationSeconds: 400,
  geometryPoints: [
    GeoCoord(59.9300, 30.3300),
    GeoCoord(59.9350, 30.3300),
  ],
  steps: [],
  legs: [
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'Эрмитаж',
      distanceMeters: 600,
      durationSeconds: 400,
      geometryPoints: [
        GeoCoord(59.9300, 30.3300),
        GeoCoord(59.9350, 30.3300),
      ],
    ),
  ],
  placesCount: 1,
);

Future<NavigationProvider> _activeNavigation() async {
  final nav = NavigationProvider(locationService: _NavLocation());
  addTearDown(nav.dispose);
  await nav.startNavigation(_liveRoute);
  return nav;
}

Future<void> _mountLiveSheet(WidgetTester tester, NavigationProvider nav) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChangeNotifierProvider<NavigationProvider>.value(
        value: nav,
        child: const Scaffold(body: LiveNavigationSheet()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<RoutingProvider> _routeDetails() async {
  final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
  addTearDown(routing.dispose);
  routing.setProposedWalk([poi(1), poi(2)]);
  await routing.buildWalkRoute();
  expect(routing.hasRoute, isTrue);
  return routing;
}

Future<void> _mountRouteSheet(
  WidgetTester tester,
  RoutingProvider routing,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<RoutingProvider>.value(
      value: routing,
      child: const MaterialApp(home: Scaffold(body: RouteDetailsSheet())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('LiveNavigationSheet collapse', () {
    testWidgets('the toggle keeps navigation running and finish available', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final nav = await _activeNavigation();
      await _mountLiveSheet(tester, nav);

      expect(find.byType(ContextRecommendationsSection), findsWidgets);
      expect(
        find.byKey(const Key('live_navigation_collapsed_summary')),
        findsNothing,
      );
      expect(find.text('Завершить'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_navigation_toggle')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('live_navigation_collapsed_summary')),
        findsOneWidget,
      );
      expect(find.byType(ContextRecommendationsSection), findsNothing);
      expect(find.text('Завершить'), findsOneWidget);
      expect(nav.status, NavigationStatus.active);
      expect(tester.takeException(), isNull);
      nav.stopNavigation();
    });

    testWidgets('a downward swipe collapses and an upward swipe expands', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final nav = await _activeNavigation();
      await _mountLiveSheet(tester, nav);

      await tester.fling(
        find.byKey(const Key('live_navigation_drag_handle')),
        const Offset(0, 260),
        1200,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('live_navigation_collapsed_summary')),
        findsOneWidget,
      );
      expect(nav.status, NavigationStatus.active);

      await tester.fling(
        find.byKey(const Key('live_navigation_drag_handle')),
        const Offset(0, -260),
        1200,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('live_navigation_collapsed_summary')),
        findsNothing,
      );
      expect(nav.status, NavigationStatus.active);
      expect(tester.takeException(), isNull);
      nav.stopNavigation();
    });
  });

  group('RouteDetailsSheet collapse', () {
    testWidgets('the toggle collapses details and keeps the start action', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final routing = await _routeDetails();
      await _mountRouteSheet(tester, routing);

      expect(find.byType(ContextRecommendationsSection), findsWidgets);
      expect(
        find.byKey(const Key('route_details_collapsed_summary')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('route_details_toggle')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('route_details_collapsed_summary')),
        findsOneWidget,
      );
      expect(find.byType(ContextRecommendationsSection), findsNothing);
      expect(
        find.widgetWithText(ElevatedButton, 'Начать прогулку'),
        findsOneWidget,
      );
      expect(routing.hasRoute, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('swipes collapse and expand without clearing the route', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final routing = await _routeDetails();
      await _mountRouteSheet(tester, routing);

      await tester.fling(
        find.byKey(const Key('route_details_drag_handle')),
        const Offset(0, 260),
        1200,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('route_details_collapsed_summary')),
        findsOneWidget,
      );
      expect(routing.hasRoute, isTrue);

      await tester.fling(
        find.byKey(const Key('route_details_drag_handle')),
        const Offset(0, -260),
        1200,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('route_details_collapsed_summary')),
        findsNothing,
      );
      expect(routing.hasRoute, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
