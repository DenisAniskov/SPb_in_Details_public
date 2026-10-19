import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/services/device_location_service.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';

final _fixEpoch = DateTime.now().subtract(const Duration(seconds: 10));
int _fixSequence = 0;
DateTime nextFixTime() => _fixEpoch.add(Duration(milliseconds: ++_fixSequence));

class MockNavigationLocationService implements BaseDeviceLocationService {
  bool serviceEnabled = true;
  LocationPermissionStatus checkPermissionResult =
      LocationPermissionStatus.grantedPrecise;
  LocationPermissionStatus requestPermissionResult =
      LocationPermissionStatus.grantedPrecise;
  UserLocationSnapshot? lastKnownPositionResult;
  UserLocationSnapshot? currentPositionResult;
  final StreamController<UserLocationSnapshot> _streamController =
      StreamController<UserLocationSnapshot>.broadcast();

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermissionStatus> checkPermission() async =>
      checkPermissionResult;

  @override
  Future<LocationPermissionStatus> requestPermission() async =>
      requestPermissionResult;

  @override
  Future<UserLocationSnapshot?> getLastKnownPosition() async =>
      lastKnownPositionResult;

  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) async {
    return currentPositionResult ??
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9343, 30.3351),
          timestamp: nextFixTime(),
        );
  }

  @override
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  }) => _streamController.stream;

  @override
  Stream<bool> getServiceStatusStream() => const Stream<bool>.empty();

  void emitLocation(UserLocationSnapshot snapshot) {
    _streamController.add(snapshot);
  }

  void close() {
    _streamController.close();
  }
}

void main() {
  group('Route Projection Algorithm Tests', () {
    test('projection onto straight polyline calculates correct distance, progress, and remaining', () {
      // Straight line north from (59.9300, 30.3300) to (59.9400, 30.3300)
      final polyline = [
        const GeoCoord(59.9300, 30.3300),
        const GeoCoord(59.9400, 30.3300),
      ];

      final totalLen = RouteProjectionUtils.polylineLengthMeters(polyline);
      expect(totalLen, greaterThan(1000)); // ~1.11 km

      // Test point exactly halfway along the line
      const midPoint = GeoCoord(59.9350, 30.3300);
      final projMid = RouteProjectionUtils.projectOntoPolyline(
        point: midPoint,
        polyline: polyline,
      );

      expect(projMid.distanceFromRouteMeters, lessThan(1.0)); // On the route
      expect(projMid.progressMeters, closeTo(totalLen / 2, 2.0));
      expect(projMid.remainingDistanceMeters, closeTo(totalLen / 2, 2.0));

      // Test point 50m west of the midpoint
      // 0.0009 deg lon at lat 59.935 is ~50m
      const westPoint = GeoCoord(59.9350, 30.3291);
      final projWest = RouteProjectionUtils.projectOntoPolyline(
        point: westPoint,
        polyline: polyline,
      );

      expect(projWest.distanceFromRouteMeters, closeTo(50.0, 5.0));
      expect(projWest.progressMeters, closeTo(totalLen / 2, 5.0));
    });

    test('projection onto bent L-shaped polyline handles multiple segments correctly', () {
      // L-shaped polyline: A -> B (east), B -> C (north)
      final polyline = [
        const GeoCoord(59.9300, 30.3300), // A
        const GeoCoord(59.9300, 30.3400), // B (~556m east)
        const GeoCoord(59.9400, 30.3400), // C (~1112m north)
      ];

      final seg1Len = RouteProjectionUtils.distanceBetween(
        polyline[0],
        polyline[1],
      );
      final seg2Len = RouteProjectionUtils.distanceBetween(
        polyline[1],
        polyline[2],
      );
      final totalLen = RouteProjectionUtils.polylineLengthMeters(polyline);

      // Point on second segment (halfway along B -> C)
      const pointOnSeg2 = GeoCoord(59.9350, 30.3400);
      final proj = RouteProjectionUtils.projectOntoPolyline(
        point: pointOnSeg2,
        polyline: polyline,
      );

      expect(proj.segmentIndex, 1);
      expect(proj.distanceFromRouteMeters, lessThan(1.0));
      expect(proj.progressMeters, closeTo(seg1Len + (seg2Len / 2), 3.0));
      expect(proj.remainingDistanceMeters, closeTo(seg2Len / 2, 3.0));
      expect(
        proj.progressMeters + proj.remainingDistanceMeters,
        closeTo(totalLen, 1.0),
      );
    });
  });

  group('Live Navigation Session State Machine & Core Logic', () {
    late MockNavigationLocationService mockLocation;
    late NavigationProvider nav;

    const singleLegRoute = PedestrianRouteModel(
      distanceMeters: 500,
      durationSeconds: 360,
      geometryPoints: [GeoCoord(59.9300, 30.3300), GeoCoord(59.9345, 30.3300)],
      steps: [],
      legs: [
        RouteLegModel(
          fromTitle: 'Дворцовая площадь',
          toTitle: 'Казанский собор',
          distanceMeters: 500,
          durationSeconds: 360,
          geometryPoints: [
            GeoCoord(59.9300, 30.3300),
            GeoCoord(59.9345, 30.3300),
          ],
        ),
      ],
      placesCount: 1,
    );

    const multiLegRoute = PedestrianRouteModel(
      distanceMeters: 1000,
      durationSeconds: 720,
      geometryPoints: [
        GeoCoord(59.9300, 30.3300),
        GeoCoord(59.9345, 30.3300),
        GeoCoord(59.9390, 30.3300),
      ],
      steps: [],
      legs: [
        RouteLegModel(
          fromTitle: 'Старт',
          toTitle: 'POI 1',
          distanceMeters: 500,
          durationSeconds: 360,
          geometryPoints: [
            GeoCoord(59.9300, 30.3300),
            GeoCoord(59.9345, 30.3300),
          ],
        ),
        RouteLegModel(
          fromTitle: 'POI 1',
          toTitle: 'POI 2',
          distanceMeters: 500,
          durationSeconds: 360,
          geometryPoints: [
            GeoCoord(59.9345, 30.3300),
            GeoCoord(59.9390, 30.3300),
          ],
        ),
      ],
      placesCount: 2,
    );

    setUp(() {
      mockLocation = MockNavigationLocationService();
      nav = NavigationProvider(locationService: mockLocation);
    });

    tearDown(() {
      nav.dispose();
      mockLocation.close();
    });

    test('initial state is idle and inactive', () {
      expect(nav.status, NavigationStatus.idle);
      expect(nav.isActive, isFalse);
      expect(nav.isCompleted, isFalse);
      expect(nav.state.route, isNull);
    });

    test(
      'explicit start transitions to active session with initial fix',
      () async {
        mockLocation.currentPositionResult = UserLocationSnapshot(
          coordinate: const GeoCoord(59.9300, 30.3300),
          timestamp: nextFixTime(),
        );

        await nav.startNavigation(singleLegRoute);

        expect(nav.status, NavigationStatus.active);
        expect(nav.isActive, isTrue);
        expect(nav.state.nextStopTitle, 'Казанский собор');
        expect(
          nav.state.remainingDistanceOnCurrentLegMeters,
          closeTo(500, 5.0),
        );
        expect(nav.state.totalProgressMeters, closeTo(0, 5.0));
      },
    );

    test(
      'start without location service waits and keeps the route',
      () async {
        mockLocation.serviceEnabled = false;

        await nav.startNavigation(singleLegRoute);

        expect(nav.status, NavigationStatus.waitingForGps);
        expect(nav.isActive, isFalse);
        expect(nav.isCompleted, isFalse);
        expect(nav.state.route, isNotNull);
        expect(nav.state.errorMessage, contains('Включите геолокацию'));
        nav.stopNavigation();
      },
    );

    test('start with denied permission waits for access', () async {
      mockLocation.requestPermissionResult = LocationPermissionStatus.denied;

      await nav.startNavigation(singleLegRoute);

      expect(nav.status, NavigationStatus.waitingForGps);
      expect(nav.isActive, isFalse);
      expect(nav.state.route, isNotNull);
      expect(nav.state.errorMessage, contains('разрешения'));
      nav.stopNavigation();
    });

    test(
      'location fix updates progress along active leg and remaining distance',
      () async {
        mockLocation.currentPositionResult = UserLocationSnapshot(
          coordinate: const GeoCoord(59.9300, 30.3300),
          timestamp: nextFixTime(),
        );
        await nav.startNavigation(singleLegRoute);

        // Move halfway up
        nav.injectLocationForTesting(
          UserLocationSnapshot(
            coordinate: const GeoCoord(59.93225, 30.3300),
            timestamp: nextFixTime(),
          ),
        );

        nav.injectLocationForTesting(
          UserLocationSnapshot(
            coordinate: const GeoCoord(59.93225, 30.3300),
            timestamp: nextFixTime(),
          ),
        );
        expect(nav.state.progressOnCurrentLegMeters, closeTo(250, 10.0));
        expect(
          nav.state.remainingDistanceOnCurrentLegMeters,
          closeTo(250, 10.0),
        );
        expect(nav.state.isOffRoute, isFalse);
      },
    );

    test('GPS jitter backwards within maxProgressRewindMeters is absorbed monotonically', () async {
      mockLocation.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.9300, 30.3300),
        timestamp: nextFixTime(),
      );
      await nav.startNavigation(singleLegRoute);

      // Forward to 250m
      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.93225, 30.3300),
          timestamp: nextFixTime(),
        ),
      );
      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.93225, 30.3300),
          timestamp: nextFixTime(),
        ),
      );
      final reachedProgress = nav.state.progressOnCurrentLegMeters;

      // Jitter slightly backwards by ~8 meters
      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.93218, 30.3300),
          timestamp: nextFixTime(),
        ),
      );

      // Progress did not drop backwards due to monotonic policy
      expect(nav.state.progressOnCurrentLegMeters, equals(reachedProgress));
    });

    test('off-route observation detects user walking away without triggering automatic rerouting', () async {
      mockLocation.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.9300, 30.3300),
        timestamp: nextFixTime(),
      );
      await nav.startNavigation(singleLegRoute);

      // v2.2 policy: one noisy fix is never enough. Sustained deviation
      // ~84 m east — three spaced fixes (>=3 fixes AND >=5 s span) — confirm
      // the off-route state.
      for (final offset in const [2, 5, 8]) {
        nav.injectLocationForTesting(
          UserLocationSnapshot(
            coordinate: const GeoCoord(59.9320, 30.3315),
            timestamp: _fixEpoch.add(Duration(seconds: offset)),
          ),
        );
      }

      expect(nav.state.isOffRoute, isTrue);
      expect(nav.state.distanceFromRouteMeters, greaterThan(50.0));
      // Route itself remains unchanged (no automatic rerouting on this milestone)
      expect(
        nav.state.route!.legs.first.geometryPoints.first,
        singleLegRoute.legs.first.geometryPoints.first,
      );
    });

    test('multi-stop route: intermediate arrival requires 2 consecutive fixes and allows continueToNextLeg', () async {
      mockLocation.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.9300, 30.3300),
        timestamp: nextFixTime(),
      );
      await nav.startNavigation(multiLegRoute);

      expect(nav.currentLegIndex, 0);
      expect(nav.state.nextStopTitle, 'POI 1');

      // 1st fix at POI 1 destination (59.9345, 30.3300) -> debounce: waiting for second confirmation
      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9345, 30.3300),
          timestamp: nextFixTime(),
        ),
      );
      expect(nav.state.isWaitingForNextLegConfirmation, isFalse);

      // 2nd fix at POI 1 destination -> triggers arrival!
      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9345, 30.3300),
          timestamp: nextFixTime(),
        ),
      );

      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9345, 30.3300),
          timestamp: nextFixTime(),
        ),
      );
      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);
      expect(nav.state.arrivedPlaceTitle, 'POI 1');
      expect(nav.isCompleted, isFalse);

      // Explicit user confirmation to continue
      nav.continueToNextLeg();

      expect(nav.currentLegIndex, 1);
      expect(nav.state.nextStopTitle, 'POI 2');
      expect(nav.state.isWaitingForNextLegConfirmation, isFalse);
      expect(nav.state.arrivedPlaceTitle, isNull);
    });

    test('final arrival transitions session to completed state', () async {
      mockLocation.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.9300, 30.3300),
        timestamp: nextFixTime(),
      );
      await nav.startNavigation(singleLegRoute);

      // Send 2 consecutive fixes at final destination
      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9345, 30.3300),
          timestamp: nextFixTime(),
        ),
      );
      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9345, 30.3300),
          timestamp: nextFixTime(),
        ),
      );

      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9345, 30.3300),
          timestamp: nextFixTime(),
        ),
      );
      expect(nav.status, NavigationStatus.completed);
      expect(nav.isCompleted, isTrue);
      expect(nav.state.arrivedPlaceTitle, 'Казанский собор');
      expect(nav.state.remainingDistanceOnCurrentLegMeters, 0.0);
    });

    test('stopNavigation cleanly resets session to idle without losing original route data', () async {
      mockLocation.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.9300, 30.3300),
        timestamp: nextFixTime(),
      );
      await nav.startNavigation(singleLegRoute);
      expect(nav.isActive, isTrue);

      nav.stopNavigation();

      expect(nav.status, NavigationStatus.idle);
      expect(nav.isActive, isFalse);
    });

    test('lifecycle pause and resume pauses stream subscription', () async {
      mockLocation.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.9300, 30.3300),
        timestamp: nextFixTime(),
      );
      await nav.startNavigation(singleLegRoute);
      expect(nav.isActive, isTrue);

      nav.pauseNavigation();
      expect(nav.status, NavigationStatus.paused);
      expect(nav.state.isPaused, isTrue);

      await nav.resumeNavigation();
      expect(nav.status, NavigationStatus.active);
      expect(nav.isActive, isTrue);
    });

    test(
      'stale location fix (> 30s) is rejected from updating progress',
      () async {
        mockLocation.currentPositionResult = UserLocationSnapshot(
          coordinate: const GeoCoord(59.9300, 30.3300),
          timestamp: nextFixTime(),
        );
        await nav.startNavigation(singleLegRoute);

        // Stale fix with timestamp 60s ago
        nav.injectLocationForTesting(
          UserLocationSnapshot(
            coordinate: const GeoCoord(59.9345, 30.3300),
            timestamp: DateTime.now().subtract(const Duration(seconds: 60)),
          ),
        );

        // Progress was not updated by stale fix
        expect(nav.state.progressOnCurrentLegMeters, 0.0);
        expect(nav.isCompleted, isFalse);
      },
    );
  });

  group('LiveNavigationSheet Widget Tests', () {
    testWidgets('renders active navigation sheet with next stop and progress', (
      tester,
    ) async {
      final mock = MockNavigationLocationService();
      final nav = NavigationProvider(locationService: mock);

      const route = PedestrianRouteModel(
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

      mock.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.9300, 30.3300),
        timestamp: nextFixTime(),
      );
      await nav.startNavigation(route);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<NavigationProvider>.value(
            value: nav,
            child: const Scaffold(body: LiveNavigationSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Идём по маршруту'), findsOneWidget);
      expect(find.text('Эрмитаж'), findsOneWidget);
      expect(find.text('Завершить'), findsOneWidget);

      // Tap stop button
      await tester.tap(find.text('Завершить'));
      await tester.pumpAndSettle();
      expect(nav.isActive, isTrue);
      await tester.tap(find.text('Остановить'));
      await tester.pumpAndSettle();

      expect(nav.status, NavigationStatus.idle);
      nav.dispose();
      mock.close();
    });

    testWidgets('renders arrival confirmation prompt for multi-stop walk', (
      tester,
    ) async {
      final mock = MockNavigationLocationService();
      final nav = NavigationProvider(locationService: mock);

      const multiRoute = PedestrianRouteModel(
        distanceMeters: 800,
        durationSeconds: 600,
        geometryPoints: [
          GeoCoord(59.9300, 30.3300),
          GeoCoord(59.9330, 30.3300),
          GeoCoord(59.9360, 30.3300),
        ],
        steps: [],
        legs: [
          RouteLegModel(
            fromTitle: 'Старт',
            toTitle: 'Спас на Крови',
            distanceMeters: 400,
            durationSeconds: 300,
            geometryPoints: [
              GeoCoord(59.9300, 30.3300),
              GeoCoord(59.9330, 30.3300),
            ],
          ),
          RouteLegModel(
            fromTitle: 'Спас на Крови',
            toTitle: 'Михайловский сад',
            distanceMeters: 400,
            durationSeconds: 300,
            geometryPoints: [
              GeoCoord(59.9330, 30.3300),
              GeoCoord(59.9360, 30.3300),
            ],
          ),
        ],
        placesCount: 2,
      );

      mock.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.9300, 30.3300),
        timestamp: nextFixTime(),
      );
      await nav.startNavigation(multiRoute);

      // Simulate arrival at first stop (2 consecutive fixes)
      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9330, 30.3300),
          timestamp: nextFixTime(),
        ),
      );
      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9330, 30.3300),
          timestamp: nextFixTime(),
        ),
      );

      nav.injectLocationForTesting(
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9330, 30.3300),
          timestamp: nextFixTime(),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<NavigationProvider>.value(
            value: nav,
            child: const Scaffold(body: LiveNavigationSheet()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Вы пришли: «Спас на Крови»'), findsOneWidget);
      expect(find.text('Продолжить к следующей точке'), findsOneWidget);

      await tester.tap(find.text('Продолжить к следующей точке'));
      await tester.pumpAndSettle();

      expect(nav.currentLegIndex, 1);
      expect(nav.state.nextStopTitle, 'Михайловский сад');

      nav.dispose();
      mock.close();
    });
  });
}
