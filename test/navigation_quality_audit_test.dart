import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';

import 'off_route_reroute_test.dart'
    show RerouteTestLocation, FakeRouteService, threeLegRoute, straightRoute;

class DelayedAccessLocation extends RerouteTestLocation {
  Completer<LocationPermissionStatus>? nextAccessCheck;

  @override
  Future<LocationPermissionStatus> checkPermission() {
    final pending = nextAccessCheck;
    nextAccessCheck = null;
    return pending?.future ?? super.checkPermission();
  }
}

void main() {
  late DelayedAccessLocation device;
  late FakeRouteService router;
  late NavigationProvider nav;
  late DateTime epoch;
  var sequence = 0;

  UserLocationSnapshot fix({
    double latitude = 60.00025,
    double longitude = 30.0014,
    DateTime? timestamp,
  }) => UserLocationSnapshot(
    coordinate: GeoCoord(latitude, longitude),
    accuracy: 10,
    timestamp: timestamp ?? epoch.add(Duration(milliseconds: ++sequence)),
  );

  Future<void> start() async {
    device.currentPositionResult = fix(latitude: 60, longitude: 30);
    await nav.startNavigation(threeLegRoute());
  }

  void offRoute() {
    for (final seconds in [3, 6, 9]) {
      nav.injectLocationForTesting(
        fix(timestamp: epoch.add(Duration(seconds: seconds))),
      );
    }
    expect(nav.state.isOffRoute, true);
    sequence = 9000;
  }

  setUp(() {
    epoch = DateTime.now().subtract(const Duration(seconds: 14));
    sequence = 0;
    device = DelayedAccessLocation();
    router = FakeRouteService();
    nav = NavigationProvider(locationService: device, routeService: router);
  });

  tearDown(() {
    nav.dispose();
    device.close();
  });

  test(
    'isolated fixes separated by a GPS outage cannot confirm deviation',
    () async {
      await start();
      nav.injectLocationForTesting(
        fix(timestamp: epoch.add(const Duration(seconds: 1))),
      );
      nav.injectLocationForTesting(
        fix(timestamp: epoch.add(const Duration(seconds: 2))),
      );
      nav.injectLocationForTesting(fix(timestamp: DateTime.now()));
      expect(nav.state.isOffRoute, false);
    },
  );

  test(
    'GPS loss breaks a return streak without clearing confirmed deviation',
    () async {
      await start();
      offRoute();
      nav.injectLocationForTesting(fix(longitude: 30.0004));
      device.source.addError(StateError('GPS unavailable'));
      await Future<void>.delayed(Duration.zero);
      nav.injectLocationForTesting(fix(longitude: 30.0004));
      expect(nav.state.isOffRoute, true);
      nav.injectLocationForTesting(fix(longitude: 30.0004));
      expect(nav.state.isOffRoute, false);
    },
  );

  for (final permission in [
    LocationPermissionStatus.denied,
    LocationPermissionStatus.serviceDisabled,
  ]) {
    test('reroute rejects $permission despite a fresh stored fix', () async {
      await start();
      offRoute();
      final oldRoute = nav.state.route;
      device.checkPermissionResult = permission;
      device.failFix = true;
      await nav.rerouteToNextStop();
      expect(router.calls, 0);
      expect(nav.state.route, same(oldRoute));
      // Rejected access keeps the session and the old route in the
      // recoverable waiting state instead of ending navigation.
      expect(nav.status, NavigationStatus.waitingForGps);
      expect(nav.state.isGpsLost, true);
      nav.stopNavigation();
    });
  }

  test(
    'revocation while acquiring the reroute origin prevents a route request',
    () async {
      await start();
      offRoute();
      final oldRoute = nav.state.route;
      device.pendingFix = Completer();
      final pending = nav.rerouteToNextStop();
      await Future<void>.delayed(Duration.zero);
      device.checkPermissionResult = LocationPermissionStatus.denied;
      device.pendingFix!.complete(fix());
      await pending;
      expect(router.calls, 0);
      expect(nav.state.route, same(oldRoute));
    },
  );

  test(
    'revocation during a native request prevents replacement of the old route',
    () async {
      await start();
      offRoute();
      final oldRoute = nav.state.route;
      device.currentPositionResult = fix();
      router.pending = Completer();
      final pending = nav.rerouteToNextStop();
      await Future<void>.delayed(Duration.zero);
      expect(router.calls, 1);
      device.checkPermissionResult = LocationPermissionStatus.denied;
      router.pending!.complete(
        straightRoute(router.starts.first, router.destinations.first),
      );
      await pending;
      expect(nav.state.route, same(oldRoute));
      expect(nav.state.isGpsLost, true);
    },
  );

  test(
    'stream fixes remain observable while a reroute request is pending',
    () async {
      await start();
      offRoute();
      final oldRoute = nav.state.route;
      device.currentPositionResult = fix();
      router.pending = Completer();
      final pending = nav.rerouteToNextStop();
      await Future<void>.delayed(Duration.zero);
      final newest = fix(longitude: 30.0015);
      device.source.add(newest);
      await Future<void>.delayed(Duration.zero);
      expect(nav.status, NavigationStatus.rerouting);
      expect(nav.state.currentLocation, same(newest));
      expect(nav.state.route, same(oldRoute));
      router.pending!.completeError(StateError('network unavailable'));
      await pending;
      expect(nav.state.route, same(oldRoute));
    },
  );

  test(
    'a slower one-shot origin cannot override a newer streamed fix',
    () async {
      await start();
      offRoute();
      device.pendingFix = Completer();
      final pending = nav.rerouteToNextStop();
      await Future<void>.delayed(Duration.zero);
      final newest = fix(longitude: 30.0015);
      device.source.add(newest);
      await Future<void>.delayed(Duration.zero);
      device.pendingFix!.complete(
        fix(
          longitude: 30.002,
          timestamp: epoch.add(const Duration(seconds: 8)),
        ),
      );
      await pending;
      expect(router.starts.single.longitude, newest.coordinate.longitude);
    },
  );

  test('an error-bearing native result keeps the original geometry', () async {
    await start();
    offRoute();
    final oldRoute = nav.state.route;
    device.currentPositionResult = fix();
    router.result = const PedestrianRouteModel(
      distanceMeters: 70,
      durationSeconds: 60,
      geometryPoints: [GeoCoord(60.00025, 30.0014), GeoCoord(60.0005, 30)],
      steps: [],
      errorMessage: 'partial native failure',
    );
    await nav.rerouteToNextStop();
    expect(nav.state.route, same(oldRoute));
    expect(nav.state.isOffRoute, true);
    expect(nav.state.errorMessage, isNotNull);
  });

  testWidgets(
    'GPS health expires at measurement time rather than receipt time',
    (tester) async {
      device.currentPositionResult = fix(
        latitude: 60,
        longitude: 30,
        timestamp: DateTime.now().subtract(const Duration(milliseconds: 14800)),
      );
      await nav.startNavigation(threeLegRoute());
      expect(nav.state.isGpsLost, false);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump(const Duration(seconds: 4));
      expect(nav.state.isGpsLost, true);
      expect(nav.state.totalProgressMeters, 0);
      nav.stopNavigation();
    },
  );

  testWidgets('the GPS watchdog keeps checking access during rerouting', (
    tester,
  ) async {
    await start();
    offRoute();
    final oldRoute = nav.state.route;
    device.currentPositionResult = fix();
    router.pending = Completer();
    final pending = nav.rerouteToNextStop();
    await tester.pump();
    expect(router.calls, 1);
    device.checkPermissionResult = LocationPermissionStatus.serviceDisabled;
    await tester.pump(const Duration(seconds: 4));
    // GPS loss aborts the native replacement before it can commit: the old
    // route survives and the same session waits for a fresh validated fix.
    expect(nav.status, NavigationStatus.waitingForGps);
    expect(nav.state.isGpsLost, true);
    expect(nav.state.route, same(oldRoute));
    expect(router.cancellations, 1);
    await pending;
    expect(nav.state.route, same(oldRoute));
    expect(nav.status, NavigationStatus.waitingForGps);
    nav.stopNavigation();
  });

  test(
    'completed tourist stops survive a current-leg geometry reroute',
    () async {
      await start();
      nav.confirmArrivalManually();
      expect(nav.state.completedStopsCount, 1);
      nav.continueToNextLeg();
      offRoute();
      final completedDistance = nav.state.totalProgressMeters;
      device.currentPositionResult = fix();
      await nav.rerouteToNextStop();
      expect(nav.state.completedStopsCount, 1);
      expect(nav.state.totalStopsCount, 3);
      expect(nav.state.stopProgressFraction, closeTo(1 / 3, 0.001));
      expect(nav.state.totalProgressMeters, completedDistance);
      expect(nav.state.progressOnCurrentLegMeters, 0);
      expect(nav.state.nextStopTitle, 'POI 2');
    },
  );

  testWidgets(
    'a delayed old access check cannot suppress a new session watchdog',
    (tester) async {
      await start();
      final oldCheck = Completer<LocationPermissionStatus>();
      device.nextAccessCheck = oldCheck;
      await tester.pump(const Duration(seconds: 4));
      nav.stopNavigation();
      await start();
      device.checkPermissionResult = LocationPermissionStatus.denied;
      await tester.pump(const Duration(seconds: 4));
      expect(nav.state.isGpsLost, true);
      oldCheck.complete(LocationPermissionStatus.grantedPrecise);
      await tester.pump();
      expect(nav.state.isGpsLost, true);
      nav.stopNavigation();
    },
  );
}
