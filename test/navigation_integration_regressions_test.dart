import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';

import 'off_route_reroute_test.dart'
    show RerouteTestLocation, FakeRouteService, threeLegRoute, a;

void main() {
  late RerouteTestLocation device;
  late FakeRouteService router;
  late NavigationProvider nav;
  late DateTime epoch;
  var sequence = 0;

  UserLocationSnapshot fix({
    GeoCoord point = a,
    int? seconds,
    double accuracy = 10,
    bool cached = false,
  }) => UserLocationSnapshot(
    coordinate: point,
    timestamp: seconds == null
        ? epoch.add(Duration(milliseconds: ++sequence))
        : epoch.add(Duration(seconds: seconds)),
    accuracy: accuracy,
    isCached: cached,
  );

  setUp(() {
    epoch = DateTime.now().subtract(const Duration(seconds: 12));
    sequence = 0;
    device = RerouteTestLocation();
    router = FakeRouteService();
    nav = NavigationProvider(locationService: device, routeService: router);
  });

  tearDown(() {
    UserLocationSnapshot.clock = DateTime.now;
    nav.dispose();
    device.close();
  });

  test(
    'manual arrival cannot visit a short leg without a validated GPS fix',
    () async {
      device.failFix = true;
      await nav.startNavigation(threeLegRoute());
      expect(nav.isActive, true);
      expect(nav.state.currentLocation, isNull);
      expect(nav.canConfirmArrivalManually, false);
      nav.confirmArrivalManually();
      expect(nav.state.completedStopsCount, 0);
    },
  );

  test('manual arrival cannot reuse an expired near-end projection', () async {
    // Freeze the freshness clock so the fix is exactly 14.8 s old at the
    // start and no real delay between statements can flake the boundary.
    final frozen = DateTime(2026);
    UserLocationSnapshot.clock = () => frozen;
    epoch = frozen.subtract(const Duration(milliseconds: 14800));
    device.currentPositionResult = fix();
    await nav.startNavigation(threeLegRoute());
    expect(nav.canConfirmArrivalManually, true);
    // The stored fix was accepted just inside the 15-second window. Expiry
    // must be checked when the action is pressed, even before a watchdog tick.
    UserLocationSnapshot.clock =
        () => frozen.add(const Duration(milliseconds: 300));
    expect(nav.canConfirmArrivalManually, false);
    nav.confirmArrivalManually();
    expect(nav.state.completedStopsCount, 0);
  });

  test('remote deviation cannot use small frozen remaining geometry to visit a stop', () async {
    device.currentPositionResult = fix();
    await nav.startNavigation(threeLegRoute());
    nav.injectLocationForTesting(
      fix(point: const GeoCoord(60.0004, 30), seconds: 1),
    );
    for (final seconds in [3, 6, 9]) {
      nav.injectLocationForTesting(
        fix(point: const GeoCoord(60.0004, 30.02), seconds: seconds),
      );
    }
    expect(nav.state.isOffRoute, true);
    expect(nav.remainingDistanceMeters, lessThan(20));
    expect(
      RouteProjectionUtils.distanceBetween(
        nav.state.currentLocation!.coordinate,
        nav.currentLeg!.geometryPoints.last,
      ),
      greaterThan(1000),
    );
    expect(nav.canConfirmArrivalManually, false);
    nav.confirmArrivalManually();
    expect(nav.state.completedStopsCount, 0);
    expect(router.calls, 0);
  });

  test(
    'poor quality observation breaks an incomplete off-route streak',
    () async {
      device.currentPositionResult = fix();
      await nav.startNavigation(threeLegRoute());
      const deviated = GeoCoord(60.00025, 30.0014);
      for (final seconds in [1, 3]) {
        nav.injectLocationForTesting(fix(point: deviated, seconds: seconds));
      }
      nav.injectLocationForTesting(fix(point: a, seconds: 4, accuracy: 200));
      nav.injectLocationForTesting(fix(point: deviated, seconds: 7));
      expect(nav.state.isOffRoute, false);
      expect(router.calls, 0);
    },
  );
  test(
    'known permission loss detaches streaming fixes after reroute is rejected',
    () async {
      device.currentPositionResult = fix();
      await nav.startNavigation(threeLegRoute());
      for (final seconds in [1, 4, 7]) {
        nav.injectLocationForTesting(
          fix(point: const GeoCoord(60.00025, 30.0014), seconds: seconds),
        );
      }
      expect(nav.state.isOffRoute, true);
      device.checkPermissionResult = LocationPermissionStatus.denied;
      await nav.rerouteToNextStop();
      final lastAuthorizedFix = nav.state.currentLocation;
      expect(nav.status, NavigationStatus.waitingForGps);
      expect(nav.state.isGpsLost, true);
      expect(nav.canConfirmArrivalManually, false);
      device.source.add(fix(point: const GeoCoord(60.00025, 30), seconds: 8));
      await Future<void>.delayed(Duration.zero);
      expect(nav.state.currentLocation, same(lastAuthorizedFix));
      expect(nav.status, NavigationStatus.waitingForGps);
      expect(nav.state.isGpsLost, true);
      expect(nav.state.isOffRoute, false);
      expect(router.calls, 0);
      nav.stopNavigation();
    },
  );

  test(
    'manual arrival is unavailable as soon as GPS becomes unavailable',
    () async {
      device.currentPositionResult = fix();
      await nav.startNavigation(threeLegRoute());
      expect(nav.canConfirmArrivalManually, true);
      device.source.addError(StateError('signal lost'));
      await Future<void>.delayed(Duration.zero);
      expect(
        nav.state.currentLocation!.isFresh(maxAge: const Duration(seconds: 15)),
        true,
      );
      expect(nav.canConfirmArrivalManually, false);
      nav.confirmArrivalManually();
      expect(nav.state.completedStopsCount, 0);
    },
  );

  for (final cached in [true, false]) {
    test(
      'rejected ${cached ? "cached" : "poor accuracy"} initial GPS cannot authorize manual arrival',
      () async {
        device.currentPositionResult = fix(
          cached: cached,
          accuracy: cached ? 10 : 200,
        );
        await nav.startNavigation(threeLegRoute());
        expect(nav.state.currentLocation, isNull);
        expect(nav.canConfirmArrivalManually, false);
        nav.confirmArrivalManually();
        expect(nav.state.completedStopsCount, 0);
      },
    );
  }

  for (final meters in [149.999, 150.0, 150.001]) {
    test(
      'remaining geometry at $meters m respects the inclusive 150m bound',
      () async {
        const origin = GeoCoord(0, 0);
        final target = GeoCoord(
          // Closest binary latitude just inside the mathematical 150m bound;
          // the direct inverse formula rounds 3e-14m above it on this runtime.
          meters == 150
              ? 0.0013489824088780957
              : meters / RouteProjectionUtils.earthRadiusMeters * 180 / math.pi,
          0,
        );
        final route = PedestrianRouteModel(
          distanceMeters: meters,
          durationSeconds: 100,
          geometryPoints: [origin, target],
          steps: const [],
        );
        device.currentPositionResult = fix(point: origin);
        await nav.startNavigation(route);
        expect(nav.remainingDistanceMeters, closeTo(meters, 0.0000001));
        expect(nav.canConfirmArrivalManually, meters <= 150);
      },
    );
  }

  for (final meters in [149.999, 150.001]) {
    test(
      'physical endpoint distance at $meters m independently bounds manual arrival',
      () async {
        device.currentPositionResult = fix();
        await nav.startNavigation(threeLegRoute());
        final endpoint = nav.currentLeg!.geometryPoints.last;
        final longitudeOffset =
            meters /
            RouteProjectionUtils.earthRadiusMeters *
            180 /
            math.pi /
            math.cos(endpoint.latitude * math.pi / 180);
        nav.injectLocationForTesting(
          fix(
            point: GeoCoord(
              endpoint.latitude,
              endpoint.longitude + longitudeOffset,
            ),
            seconds: 1,
          ),
        );
        expect(nav.remainingDistanceMeters, lessThan(150));
        expect(nav.canConfirmArrivalManually, meters < 150);
      },
    );
  }

  test(
    'manual double tap and late fixes preserve reached-stop order',
    () async {
      device.currentPositionResult = fix();
      await nav.startNavigation(threeLegRoute());
      nav.confirmArrivalManually();
      nav.confirmArrivalManually();
      expect(nav.state.completedStopsCount, 1);
      expect(nav.currentLegIndex, 0);
      nav.injectLocationForTesting(
        fix(point: const GeoCoord(60.003, 30), seconds: 1),
      );
      expect(nav.state.completedStopsCount, 1);
      expect(nav.currentLegIndex, 0);
      nav.continueToNextLeg();
      expect(nav.currentLegIndex, 1);
      expect(nav.state.nextStopTitle, 'POI 2');
      expect(nav.canConfirmArrivalManually, false);
    },
  );
}
