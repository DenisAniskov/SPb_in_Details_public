import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';

import 'live_navigation_test.dart' show MockNavigationLocationService;

class ControlledLocation extends MockNavigationLocationService {
  Completer<UserLocationSnapshot>? pending;
  bool failFix = false;
  int subscriptions = 0, cancellations = 0;
  final source = StreamController<UserLocationSnapshot>.broadcast();
  ControlledLocation() {
    source.onListen = () => subscriptions++;
    source.onCancel = () => cancellations++;
  }
  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) async {
    if (failFix) throw StateError('private native details');
    return pending == null
        ? super.getCurrentPosition(timeLimit: timeLimit)
        : pending!.future;
  }

  @override
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  }) => source.stream;
  @override
  void close() {
    source.close();
    super.close();
  }
}

PedestrianRouteModel route({
  int count = 1,
  bool bent = false,
  double metadata = 9999,
}) {
  final points = bent
      ? [
          const GeoCoord(60, 30),
          const GeoCoord(60.001, 30),
          const GeoCoord(60.001, 30.002),
          const GeoCoord(60, 30.0002),
        ]
      : [
          const GeoCoord(60, 30),
          const GeoCoord(60.001, 30),
          const GeoCoord(60.002, 30),
          const GeoCoord(60.003, 30),
        ];
  return PedestrianRouteModel(
    distanceMeters: metadata,
    durationSeconds: 300,
    geometryPoints: bent ? points : points.take(count + 1).toList(),
    steps: const [],
    legs: List.generate(
      count,
      (i) => RouteLegModel(
        fromTitle: 'Start $i',
        toTitle: 'Stop ${i + 1}',
        distanceMeters: metadata / count,
        durationSeconds: 100,
        geometryPoints: bent ? points : [points[i], points[i + 1]],
      ),
    ),
    placesCount: count,
  );
}

void main() {
  late ControlledLocation device;
  late NavigationProvider nav;
  late RoutingProvider routing;
  late DateTime epoch;
  var seq = 0;
  UserLocationSnapshot fix(
    double lat,
    double lon, {
    DateTime? timestamp,
    bool cached = false,
    double? accuracy,
  }) => UserLocationSnapshot(
    coordinate: GeoCoord(lat, lon),
    timestamp: timestamp ?? epoch.add(Duration(milliseconds: ++seq)),
    isCached: cached,
    accuracy: accuracy,
  );
  Future<void> start({int count = 1, bool bent = false}) async {
    device.currentPositionResult = fix(60, 30);
    await nav.startNavigation(route(count: count, bent: bent));
  }

  void send(double lat, double lon) =>
      nav.injectLocationForTesting(fix(lat, lon));
  void arrive(double lat, double lon) {
    send(lat, lon);
    send(lat, lon);
    send(lat, lon);
  }

  setUp(() {
    // 12 s inside the 15 s freshness window leaves room for the spaced
    // (>=5 s span) fix sequences the v2.2 off-route policy requires.
    epoch = DateTime.now().subtract(const Duration(seconds: 12));
    seq = 0;
    device = ControlledLocation();
    routing = RoutingProvider();
    nav = NavigationProvider(locationService: device, routingProvider: routing);
  });
  tearDown(() {
    nav.dispose();
    routing.dispose();
    device.close();
  });
  test('cancel during pending fix never restarts stream', () async {
    device.pending = Completer();
    final pending = nav.startNavigation(route());
    nav.stopNavigation();
    device.pending!.complete(fix(60, 30));
    await pending;
    expect(nav.status, NavigationStatus.idle);
    expect(device.subscriptions, 0);
  });
  test('dispose during permission/fix await ignores late result', () async {
    final local = NavigationProvider(locationService: device);
    device.pending = Completer();
    final pending = local.startNavigation(route());
    local.dispose();
    device.pending!.complete(fix(60, 30));
    await pending;
    expect(device.subscriptions, 0);
  });
  test('repeated start creates one observation', () async {
    device.pending = Completer();
    final first = nav.startNavigation(route());
    await Future<void>.delayed(Duration.zero);
    await nav.startNavigation(route());
    device.pending!.complete(fix(60, 30));
    await first;
    expect(device.subscriptions, 1);
  });
  test('background during startup cancels late completion', () async {
    device.pending = Completer();
    final pending = nav.startNavigation(route());
    nav.pauseNavigation();
    device.pending!.complete(fix(60, 30));
    await pending;
    expect(nav.status, NavigationStatus.paused);
    expect(device.subscriptions, 0);
  });
  test('background cancels rather than buffering native stream', () async {
    await start();
    nav.pauseNavigation();
    await Future<void>.delayed(Duration.zero);
    expect(device.cancellations, 1);
    device.source.add(fix(60.001, 30));
    await Future<void>.delayed(Duration.zero);
    expect(nav.state.totalProgressMeters, 0);
    await nav.resumeNavigation();
    expect(device.subscriptions, 2);
    expect(nav.state.isGpsLost, true);
  });
  test('resume rechecks permission and waits when revoked', () async {
    await start();
    nav.pauseNavigation();
    device.checkPermissionResult = LocationPermissionStatus.denied;
    await nav.resumeNavigation();
    expect(nav.status, NavigationStatus.waitingForGps);
    expect(nav.isActive, false);
    expect(nav.state.isGpsLost, true);
    expect(nav.state.route, isNotNull);
    // No position stream may be opened without permission.
    expect(device.subscriptions, 1);
    nav.stopNavigation();
  });
  test('fresh stream recovers when initial fix unavailable', () async {
    device.failFix = true;
    await nav.startNavigation(route());
    expect(nav.isActive, true);
    expect(nav.state.isGpsLost, true);
    device.source.add(fix(60.0002, 30));
    await Future<void>.delayed(Duration.zero);
    expect(nav.state.isGpsLost, false);
    expect(nav.state.totalProgressMeters, greaterThan(20));
  });
  test('cached fallback is never queried as live position', () async {
    device.failFix = true;
    device.lastKnownPositionResult = fix(60.001, 30, cached: true);
    await nav.startNavigation(route());
    expect(nav.state.currentLocation, isNull);
    expect(nav.state.totalProgressMeters, 0);
  });
  test(
    'cached stale future invalid and low accuracy fixes cannot arrive',
    () async {
      await start();
      for (final bad in [
        fix(60.001, 30, cached: true),
        fix(
          60.001,
          30,
          timestamp: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        fix(
          60.001,
          30,
          timestamp: DateTime.now().add(const Duration(minutes: 1)),
        ),
        fix(double.nan, 30),
        fix(60.001, 30, accuracy: 200),
      ]) {
        nav.injectLocationForTesting(bad);
        nav.injectLocationForTesting(bad);
      }
      expect(nav.isCompleted, false);
      expect(nav.state.totalProgressMeters, 0);
    },
  );
  test('duplicate fix timestamps cannot confirm arrival', () async {
    await start();
    send(60.0006, 30);
    send(60.0006, 30);
    final same = fix(60.001, 30);
    nav.injectLocationForTesting(same);
    nav.injectLocationForTesting(same);
    expect(nav.isCompleted, false);
  });
  test('far beyond endpoint projection never triggers arrival', () async {
    await start();
    // Sustained deviation far beyond the endpoint (projection clamps there):
    // three spaced fixes confirm off-route, arrival must never fire.
    for (final offset in const [3, 6, 9]) {
      nav.injectLocationForTesting(
        fix(60.01, 30, timestamp: epoch.add(Duration(seconds: offset))),
      );
    }
    expect(nav.isCompleted, false);
    expect(nav.state.isOffRoute, true);
  });
  test(
    'near destination on early segment of bent route cannot arrive',
    () async {
      await start(bent: true);
      arrive(60.00005, 30);
      expect(nav.isCompleted, false);
    },
  );
  test('large false fix is not latched into progress', () async {
    await start();
    send(60.0001, 30);
    final before = nav.state.totalProgressMeters;
    send(60.0009, 30);
    expect(nav.state.totalProgressMeters, before);
    send(60.00012, 30);
    expect(nav.state.totalProgressMeters, lessThan(20));
  });
  test('remaining uses geometry length rather than native metadata', () async {
    await start();
    expect(nav.state.totalRemainingMeters, closeTo(111.2, 1));
    send(60.0003, 30);
    expect(nav.state.remainingDistanceOnCurrentLegMeters, closeTo(77.8, 1));
  });
  test('continue before arrival and duplicate continue are ignored', () async {
    await start(count: 3);
    nav.continueToNextLeg();
    expect(nav.currentLegIndex, 0);
    arrive(60.001, 30);
    expect(nav.state.isWaitingForNextLegConfirmation, true);
    nav.continueToNextLeg();
    nav.continueToNextLeg();
    expect(nav.currentLegIndex, 1);
    expect(nav.state.progressOnCurrentLegMeters, 0);
  });
  test('confirmation freezes reached leg even after walking away', () async {
    await start(count: 2);
    arrive(60.001, 30);
    final progress = nav.state.totalProgressMeters;
    send(60, 30);
    expect(nav.state.totalProgressMeters, progress);
    expect(nav.state.isWaitingForNextLegConfirmation, true);
  });
  test('completed releases stream and reaches 100 percent', () async {
    await start();
    arrive(60.001, 30);
    await Future<void>.delayed(Duration.zero);
    expect(nav.isCompleted, true);
    expect(nav.state.totalProgressFraction, 1);
    expect(device.cancellations, 1);
    expect(routing.navigationLocked, false);
  });
  test('cancel retains planned start and rejects later fixes', () async {
    await start();
    final planned = routing.startPoint;
    nav.stopNavigation();
    arrive(60.001, 30);
    expect(nav.status, NavigationStatus.idle);
    expect(routing.startPoint, planned);
    expect(routing.navigationLocked, false);
  });
  test('route mutation guarded during starting active and paused', () async {
    await start();
    final original = routing.startPoint;
    for (final phase in [0, 1]) {
      routing.setStartPoint(RoutePointModel.defaultStart);
      routing.setCustomStartPoint(12, 13);
      routing.beginStartSelection();
      routing.clearRoute();
      expect(routing.startPoint, original);
      expect(routing.isChoosingStart, false);
      if (phase == 0) nav.pauseNavigation();
    }
    nav.stopNavigation();
    routing.setCustomStartPoint(12, 13);
    expect(routing.startPoint.latitude, 12);
  });
  test('source geometry is immutable within session', () async {
    final mutable = [const GeoCoord(60, 30), const GeoCoord(60.001, 30)];
    final source = PedestrianRouteModel(
      distanceMeters: 100,
      durationSeconds: 60,
      geometryPoints: mutable,
      steps: const [],
    );
    device.currentPositionResult = fix(60, 30);
    await nav.startNavigation(source);
    mutable.clear();
    expect(nav.state.route!.legs.first.geometryPoints.length, 2);
    expect(
      () => nav.state.route!.legs.first.geometryPoints.clear(),
      throwsUnsupportedError,
    );
  });
  test('zero length or missing leg geometry is rejected', () async {
    await nav.startNavigation(
      const PedestrianRouteModel(
        distanceMeters: 10,
        durationSeconds: 10,
        geometryPoints: [GeoCoord(60, 30), GeoCoord(60, 30)],
        steps: [],
      ),
    );
    expect(nav.status, NavigationStatus.error);
    expect(device.subscriptions, 0);
  });
  test('segment endpoint and zero segment projections are finite', () {
    final result = RouteProjectionUtils.projectPointToSegmentCartesian(
      px: 3,
      py: 4,
      ax: 0,
      ay: 0,
      bx: 0,
      by: 0,
    );
    expect(result.distance, 5);
    expect(result.t, 0);
    final end = RouteProjectionUtils.projectPointToSegmentCartesian(
      px: 20,
      py: 0,
      ax: 0,
      ay: 0,
      bx: 10,
      by: 0,
    );
    expect(end.t, 1);
    expect(end.distance, 10);
  });
  testWidgets('services off pauses observation and recovery resubscribes', (
    tester,
  ) async {
    await start();
    device.checkPermissionResult = LocationPermissionStatus.serviceDisabled;
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(nav.status, NavigationStatus.waitingForGps);
    expect(nav.isActive, false);
    expect(nav.state.isGpsLost, true);
    expect(device.cancellations, 1);
    device.checkPermissionResult = LocationPermissionStatus.grantedPrecise;
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(device.subscriptions, 2);
    // A restored service is not yet a position: guidance stays suspended.
    expect(nav.status, NavigationStatus.waitingForGps);
    device.source.add(fix(60.0001, 30));
    await tester.pump();
    expect(nav.status, NavigationStatus.active);
    expect(nav.state.isGpsLost, false);
    nav.stopNavigation();
  });
  testWidgets(
    'stream error is friendly and can recover without ending session',
    (tester) async {
      await start();
      device.source.addError(StateError('private native coordinates'));
      await tester.pump();
      expect(nav.status, NavigationStatus.waitingForGps);
      expect(nav.isActive, false);
      expect(nav.state.isGpsLost, true);
      expect(nav.state.route, isNotNull);
      expect(nav.state.errorMessage, isNot(contains('private')));
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(device.subscriptions, 2);
      device.source.add(fix(60.0001, 30));
      await tester.pump();
      expect(nav.status, NavigationStatus.active);
      expect(nav.state.isGpsLost, false);
      nav.stopNavigation();
    },
  );
  test('arrival boundary requires physical proximity', () async {
    await start();
    const latitude = 60.001 - 26 / 111195.0;
    send(latitude, 30);
    send(latitude, 30);
    send(latitude, 30);
    expect(nav.isCompleted, false);
    send(60.001 - 24 / 111195.0, 30);
    send(60.001 - 24 / 111195.0, 30);
    expect(nav.isCompleted, true);
  });
}
