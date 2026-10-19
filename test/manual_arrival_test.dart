import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';

import 'live_navigation_test.dart' show MockNavigationLocationService;
import 'off_route_reroute_test.dart'
    show FixClock, RerouteTestLocation, threeLegRoute, a, b, c, d;

/// Manual arrival confirmation («Я на месте») — v2.3 reliability fallback.
///
/// Auto-arrival requires two validated fixes within 25 m of the leg endpoint.
/// MapKit endpoint snapping, courtyards and degraded urban GPS can keep every
/// real fix slightly outside that radius while the user already stands at the
/// POI, so the session would otherwise hang at «Осталось N м» forever. The
/// manual action is bounded to 150 m of remaining geometry.
void main() {
  group('Live Navigation v2.3: manual arrival confirmation', () {
    late RerouteTestLocation device;
    late RoutingProvider routing;
    late NavigationProvider nav;
    late FixClock clock;

    UserLocationSnapshot fix(
      double lat,
      double lon, {
      Duration gap = const Duration(milliseconds: 1),
    }) => UserLocationSnapshot(
      coordinate: GeoCoord(lat, lon),
      timestamp: clock.next(gap),
    );

    void send(double lat, double lon, [Duration gap = const Duration(seconds: 2)]) =>
        nav.injectLocationForTesting(fix(lat, lon, gap: gap));

    Future<void> start() async {
      device.currentPositionResult = fix(a.latitude, a.longitude);
      await nav.startNavigation(threeLegRoute());
    }

    setUp(() {
      clock = FixClock();
      device = RerouteTestLocation();
      routing = RoutingProvider();
      nav = NavigationProvider(
        locationService: device,
        routingProvider: routing,
      );
    });

    tearDown(() {
      nav.dispose();
      routing.dispose();
      device.close();
    });

    test('not offered before a session or far from the leg endpoint', () async {
      expect(nav.canConfirmArrivalManually, isFalse);

      await start();
      // Leg 0 is ~55.6 m long: the whole walk is inside the manual bound, so
      // the action is honestly offered from the start of this leg.
      expect(nav.isActive, isTrue);
      expect(nav.canConfirmArrivalManually, isTrue);
    });

    test('not offered while waiting for next-leg confirmation', () async {
      await start();
      // Two fixes at the intermediate endpoint confirm arrival automatically.
      send(b.latitude, b.longitude);
      send(b.latitude, b.longitude);
      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);
      expect(nav.canConfirmArrivalManually, isFalse);
    });

    test(
      'intermediate manual confirm freezes the leg and continues in order',
      () async {
        await start();
        // Mid-leg 0, remaining ~30 m: well inside the bound.
        final mid = GeoCoord(
          (a.latitude + b.latitude) / 2,
          a.longitude,
        );
        send(mid.latitude, mid.longitude);
        final remaining = nav.remainingDistanceMeters;
        expect(remaining, lessThan(NavigationProvider.manualArrivalMaxMeters));

        nav.confirmArrivalManually();

        expect(nav.state.isWaitingForNextLegConfirmation, isTrue);
        expect(nav.state.arrivedPlaceTitle, 'POI 1');
        expect(nav.state.progressOnCurrentLegMeters, closeTo(55.6, 1.0));
        expect(nav.state.remainingDistanceOnCurrentLegMeters, 0);
        expect(nav.state.currentLegIndex, 0);

        nav.continueToNextLeg();
        expect(nav.state.currentLegIndex, 1);
        expect(nav.state.arrivedPlaceTitle, isNull);
        expect(nav.remainingDistanceMeters, closeTo(55.6, 1.0));
      },
    );

    test('final manual confirm completes the session and releases the lock', () async {
      await start();
      // Walk legs 0 and 1 with auto-arrival…
      send(b.latitude, b.longitude);
      send(b.latitude, b.longitude);
      nav.continueToNextLeg();
      send(c.latitude, c.longitude);
      send(c.latitude, c.longitude);
      nav.continueToNextLeg();
      expect(nav.currentLegIndex, 2);

      // …then confirm the final leg manually near its endpoint.
      final nearEnd = GeoCoord(
        d.latitude - (d.latitude - c.latitude) * 0.2,
        d.longitude,
      );
      send(nearEnd.latitude, nearEnd.longitude);
      expect(nav.canConfirmArrivalManually, isTrue);

      nav.confirmArrivalManually();

      expect(nav.isCompleted, isTrue);
      expect(nav.state.arrivedPlaceTitle, 'POI 3');
      expect(nav.state.totalRemainingMeters, 0);
      expect(routing.navigationLocked, isFalse);
      expect(device.subscriptions, 1, reason: 'stream released after completion');

      // Late fixes are rejected by the bumped revision and cannot un-complete.
      send(d.latitude + 0.01, d.longitude);
      expect(nav.isCompleted, isTrue);
    });

    test('manual confirm beyond the bound is a no-op', () async {
      // 0.008° latitude ≈ 890 m — far beyond the manual bound.
      const longRoute = PedestrianRouteModel(
        distanceMeters: 0,
        durationSeconds: 600,
        geometryPoints: [a, GeoCoord(60.008, 30.0)],
        steps: [],
        legs: [
          RouteLegModel(
            fromTitle: 'Старт',
            toTitle: 'Далёкая точка',
            distanceMeters: 0,
            durationSeconds: 600,
            geometryPoints: [a, GeoCoord(60.008, 30.0)],
          ),
        ],
        placesCount: 1,
      );
      device.currentPositionResult = fix(a.latitude, a.longitude);
      await nav.startNavigation(longRoute);
      send(a.latitude, a.longitude);

      expect(
        nav.state.remainingDistanceOnCurrentLegMeters,
        greaterThan(NavigationProvider.manualArrivalMaxMeters),
      );
      expect(nav.canConfirmArrivalManually, isFalse);

      nav.confirmArrivalManually();

      expect(nav.isActive, isTrue);
      expect(nav.state.isWaitingForNextLegConfirmation, isFalse);
      expect(nav.state.arrivedPlaceTitle, isNull);
    });

    test('manual confirm rescues a confirmed off-route session near the end', () async {
      await start();
      // Walk most of leg 0 on-route…
      send(60.0004, 30.0);
      // …then deviate: three spaced fixes > 50 m from the geometry confirm.
      for (var i = 0; i < 3; i++) {
        send(60.0004, 30.001, const Duration(seconds: 3));
      }
      expect(nav.state.isOffRoute, isTrue);

      // Remaining was frozen at the last on-route projection (~9 m), inside
      // the bound: the user asserts they are already at the POI.
      expect(nav.canConfirmArrivalManually, isTrue);
      nav.confirmArrivalManually();

      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);
      expect(nav.state.isOffRoute, isFalse);
      expect(nav.state.arrivedPlaceTitle, 'POI 1');
    });
  });

  group('LiveNavigationSheet manual arrival button', () {
    testWidgets('shows «Я на месте» only inside the bound and completes the leg', (
      tester,
    ) async {
      final clock = FixClock();
      final mock = MockNavigationLocationService();
      UserLocationSnapshot fresh(GeoCoord p) => UserLocationSnapshot(
        coordinate: p,
        timestamp: clock.next(),
      );
      mock.currentPositionResult = fresh(a);
      final nav = NavigationProvider(locationService: mock);
      addTearDown(() {
        nav.dispose();
        mock.close();
      });

      await nav.startNavigation(threeLegRoute());

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<NavigationProvider>.value(
            value: nav,
            child: const Scaffold(body: LiveNavigationSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Short leg (~55.6 m) is entirely inside the manual bound.
      expect(find.text('Я на месте'), findsOneWidget);

      await tester.tap(find.text('Я на месте'));
      await tester.pumpAndSettle();

      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);
      // The confirmation banner replaced the manual action…
      expect(find.text('Я на месте'), findsNothing);
      // …and the continue button is available.
      expect(find.text('Продолжить к следующей точке'), findsOneWidget);

      // The session watchdog must not outlive the test body.
      nav.stopNavigation();
      await tester.pumpAndSettle();
    });

    testWidgets('manual button hidden while waiting for next-leg confirmation', (
      tester,
    ) async {
      final clock = FixClock();
      final mock = MockNavigationLocationService();
      UserLocationSnapshot fresh(GeoCoord p) => UserLocationSnapshot(
        coordinate: p,
        timestamp: clock.next(),
      );
      mock.currentPositionResult = fresh(a);
      final nav = NavigationProvider(locationService: mock);
      addTearDown(() {
        nav.dispose();
        mock.close();
      });

      await nav.startNavigation(threeLegRoute());
      nav.injectLocationForTesting(fresh(b));
      nav.injectLocationForTesting(fresh(b));
      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<NavigationProvider>.value(
            value: nav,
            child: const Scaffold(body: LiveNavigationSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Я на месте'), findsNothing);
      expect(find.text('Продолжить к следующей точке'), findsOneWidget);

      nav.stopNavigation();
      await tester.pumpAndSettle();
    });
  });
}
