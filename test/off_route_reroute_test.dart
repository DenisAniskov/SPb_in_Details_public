import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/utils/off_route_detector.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';

import 'live_navigation_test.dart' show MockNavigationLocationService;

/// Fix timestamps must be fresh (<= 15 s old), strictly increasing across the
/// session and never in the future, so every test drives them from one base
/// clock placed just inside the freshness window.
class FixClock {
  FixClock() : _current = DateTime.now().subtract(const Duration(seconds: 13));
  DateTime _current;
  DateTime get last => _current;
  DateTime next([Duration gap = const Duration(milliseconds: 1)]) {
    _current = _current.add(gap);
    return _current;
  }
}

/// Fake implementing the production reroute contract of
/// [BasePedestrianRouteService]. `cancel()` mirrors the real MapKitService
/// behaviour — an in-flight request completes with an error — unless the test
/// simulates an even lazier native layer via [cancelCompletes].
class FakeRouteService implements BasePedestrianRouteService {
  int calls = 0, cancellations = 0;
  final starts = <RoutePointModel>[];
  final destinations = <RoutePointModel>[];
  Completer<PedestrianRouteModel>? pending;
  bool cancelCompletes = true;
  Object? error;
  PedestrianRouteModel? result;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) {
    calls++;
    starts.add(startPoint);
    destinations.add(destinationPoint);
    final c = pending;
    if (c != null) return c.future;
    if (error != null) throw error!;
    return Future.value(result ?? straightRoute(startPoint, destinationPoint));
  }

  @override
  void cancel() {
    cancellations++;
    final c = pending;
    if (c != null && cancelCompletes && !c.isCompleted) {
      c.completeError(StateError('Запрос маршрута отменён'));
    }
  }
}

PedestrianRouteModel straightRoute(RoutePointModel a, RoutePointModel b) {
  final mid = GeoCoord(
    (a.latitude + b.latitude) / 2,
    (a.longitude + b.longitude) / 2,
  );
  final points = [
    GeoCoord(a.latitude, a.longitude),
    mid,
    GeoCoord(b.latitude, b.longitude),
  ];
  final leg = RouteLegModel(
    fromTitle: a.title,
    toTitle: b.title,
    // Native metadata length differs from the polyline length, exactly like
    // a real MapKit leg; navigation must always use the geometry length.
    distanceMeters:
        RouteProjectionUtils.distanceMeters(
          a.latitude,
          a.longitude,
          b.latitude,
          b.longitude,
        ) +
        20,
    durationSeconds: 120,
    geometryPoints: points,
  );
  return PedestrianRouteModel(
    distanceMeters: leg.distanceMeters,
    durationSeconds: leg.durationSeconds,
    geometryPoints: List.of(points),
    steps: const [],
    legs: [leg],
    placesCount: 1,
  );
}

/// Location mock extending the shared navigation mock with a controlled
/// one-shot fix and stream subscription accounting.
class RerouteTestLocation extends MockNavigationLocationService {
  Completer<UserLocationSnapshot>? pendingFix;
  bool failFix = false;
  int subscriptions = 0, cancellations = 0;
  final source = StreamController<UserLocationSnapshot>.broadcast();

  RerouteTestLocation() {
    source.onListen = () => subscriptions++;
    source.onCancel = () => cancellations++;
  }

  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) {
    if (failFix) throw StateError('one-shot fix unavailable');
    final p = pendingFix;
    if (p != null) return p.future;
    return super.getCurrentPosition(timeLimit: timeLimit);
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

PlaceModel place(int id, String title) => PlaceModel(
  id: id,
  title: title,
  shortDescription: 'Описание',
  category: PlaceCategoryEnum.historyArchitecture,
  latitude: 60.0,
  longitude: 30.0,
  address: 'Санкт-Петербург',
  recommendedVisitMinutes: 30,
);

RouteLegModel leg(String from, String to, List<GeoCoord> points) =>
    RouteLegModel(
      fromTitle: from,
      toTitle: to,
      distanceMeters: RouteProjectionUtils.polylineLengthMeters(points),
      durationSeconds: 60,
      geometryPoints: points,
    );

/// Three-leg straight northward walk: A → POI 1 → POI 2 → POI 3,
/// ~55.6 m per leg (0.0005° latitude).
const a = GeoCoord(60.0, 30.0);
const b = GeoCoord(60.0005, 30.0);
const c = GeoCoord(60.0010, 30.0);
const d = GeoCoord(60.0015, 30.0);

PedestrianRouteModel threeLegRoute() => PedestrianRouteModel(
  distanceMeters: 0,
  durationSeconds: 180,
  geometryPoints: [a, b, c, d],
  steps: const [],
  legs: [
    leg('Старт', 'POI 1', [a, b]),
    leg('POI 1', 'POI 2', [b, c]),
    leg('POI 2', 'POI 3', [c, d]),
  ],
  placesCount: 3,
);

void main() {
  group('OffRouteDetector policy (pure state machine)', () {
    final base = DateTime.now().subtract(const Duration(seconds: 13));
    DateTime at(int seconds, [int ms = 0]) =>
        base.add(Duration(seconds: seconds, milliseconds: ms));

    test('starts on-route and stays on-route for small drift', () {
      final detector = OffRouteDetector();
      expect(detector.phase, OffRoutePhase.onRoute);
      expect(detector.registerFix(at(0), 20), OffRoutePhase.onRoute);
      expect(detector.registerFix(at(1), 49), OffRoutePhase.onRoute);
      expect(detector.isConfirmedOffRoute, isFalse);
    });

    test('one noisy fix beyond threshold only suspects, never confirms', () {
      final detector = OffRouteDetector();
      expect(detector.registerFix(at(0), 80), OffRoutePhase.suspected);
      expect(detector.isConfirmedOffRoute, isFalse);
      // Recovery clears the suspicion without any confirmation ritual.
      expect(detector.registerFix(at(1), 10), OffRoutePhase.onRoute);
    });

    test('confirmation needs consecutive fixes AND a sustained time span', () {
      final detector = OffRouteDetector();
      // Three quick outliers 2 ms apart: count satisfied, span not.
      expect(detector.registerFix(at(0), 80), OffRoutePhase.suspected);
      expect(detector.registerFix(at(0, 2), 80), OffRoutePhase.suspected);
      expect(detector.registerFix(at(0, 4), 80), OffRoutePhase.suspected);
      expect(detector.isConfirmedOffRoute, isFalse);
      // A later fix completes the 5 s span and confirms.
      expect(detector.registerFix(at(6), 80), OffRoutePhase.offRoute);
      expect(detector.isConfirmedOffRoute, isTrue);
    });

    test('dead band hysteresis: confirmed state ignores mid-band jitter', () {
      final detector = OffRouteDetector();
      for (var i = 0; i < 3; i++) {
        detector.registerFix(at(i * 3), 90);
      }
      expect(detector.isConfirmedOffRoute, isTrue);
      // 42 m and 48 m sit between return (35) and entry (50): no transition.
      expect(detector.registerFix(at(10), 42), OffRoutePhase.offRoute);
      expect(detector.registerFix(at(11), 48), OffRoutePhase.offRoute);
      expect(detector.registerFix(at(12), 42), OffRoutePhase.offRoute);
      expect(detector.isConfirmedOffRoute, isTrue);
    });

    test('on-route state ignores mid-band jitter in the other direction', () {
      final detector = OffRouteDetector();
      // Hovering at 42–49.5 m while on-route never confirms off-route.
      expect(detector.registerFix(at(0), 42), OffRoutePhase.onRoute);
      expect(detector.registerFix(at(3), 48), OffRoutePhase.onRoute);
      expect(detector.registerFix(at(6), 42), OffRoutePhase.onRoute);
      expect(detector.registerFix(at(9), 49.5), OffRoutePhase.onRoute);
      expect(detector.isConfirmedOffRoute, isFalse);
    });

    test('return requires sustained fixes inside the return threshold', () {
      final detector = OffRouteDetector();
      for (var i = 0; i < 3; i++) {
        detector.registerFix(at(i * 3), 90);
      }
      expect(detector.isConfirmedOffRoute, isTrue);
      // One fix inside 35 m is not enough…
      expect(detector.registerFix(at(9), 20), OffRoutePhase.offRoute);
      // …mid-band jitter resets the return streak…
      expect(detector.registerFix(at(10), 40), OffRoutePhase.offRoute);
      // …and two consecutive inside fixes confirm the return.
      expect(detector.registerFix(at(11), 20), OffRoutePhase.offRoute);
      expect(detector.registerFix(at(12), 15), OffRoutePhase.onRoute);
    });

    test('reset returns to the initial on-route state', () {
      final detector = OffRouteDetector();
      detector.registerFix(at(0), 80);
      detector.registerFix(at(3), 80);
      detector.registerFix(at(6), 80);
      expect(detector.isConfirmedOffRoute, isTrue);
      detector.reset();
      expect(detector.phase, OffRoutePhase.onRoute);
      expect(detector.isConfirmedOffRoute, isFalse);
    });
  });

  group('Live Navigation v2.2: off-route state and manual reroute', () {
    late RerouteTestLocation device;
    late FakeRouteService routeService;
    late RoutingProvider routing;
    late NavigationProvider nav;
    late FixClock clock;

    UserLocationSnapshot fix(
      double lat,
      double lon, {
      Duration gap = const Duration(milliseconds: 1),
      double? accuracy,
      bool cached = false,
      DateTime? timestamp,
    }) => UserLocationSnapshot(
      coordinate: GeoCoord(lat, lon),
      timestamp: timestamp ?? clock.next(gap),
      isCached: cached,
      accuracy: accuracy,
    );

    void send(
      double lat,
      double lon, {
      Duration gap = const Duration(milliseconds: 1),
    }) => nav.injectLocationForTesting(fix(lat, lon, gap: gap));

    /// Three spaced fixes confirm off-route: count >= 3 and span >= 5 s.
    void confirmOffRoute(double lat, double lon) {
      for (var i = 0; i < 3; i++) {
        send(lat, lon, gap: const Duration(seconds: 3));
      }
    }

    /// 55.6 m east of the leg-0 mid-point: beyond the 50 m entry threshold,
    /// and 62 m from the leg endpoint so arrival can never race detection.
    void confirmOffRouteLeg0() => confirmOffRoute(60.00025, 30.001);

    Future<void> start({PedestrianRouteModel? route}) async {
      device.currentPositionResult = fix(a.latitude, a.longitude);
      await nav.startNavigation(route ?? threeLegRoute());
    }

    setUp(() {
      clock = FixClock();
      device = RerouteTestLocation();
      routeService = FakeRouteService();
      routing = RoutingProvider();
      nav = NavigationProvider(
        locationService: device,
        routingProvider: routing,
        routeService: routeService,
      );
    });

    tearDown(() {
      UserLocationSnapshot.clock = DateTime.now;
      nav.dispose();
      routing.dispose();
      device.close();
    });

    test('initial session is on-route and never requests routing', () async {
      await start();
      expect(nav.isActive, isTrue);
      expect(nav.state.isOffRoute, isFalse);
      expect(routeService.calls, 0);
    });

    test('one noisy off-route fix is not confirmed and freezes progress only', () async {
      await start();
      // 80 m east of the leg: beyond the 50 m threshold.
      send(60.00025, 30.0014);
      expect(nav.state.isOffRoute, isFalse);
      expect(nav.state.distanceFromRouteMeters, greaterThan(50));
      // The noisy fix must not advance leg progress…
      expect(nav.state.progressOnCurrentLegMeters, 0);
      // …and no rerouting request may happen automatically.
      expect(routeService.calls, 0);
      // A normal fix clears the suspicion entirely.
      send(60.00025, 30.0);
      expect(nav.state.isOffRoute, isFalse);
      expect(nav.state.progressOnCurrentLegMeters, greaterThan(0));
    });

    test('sustained off-route fixes confirm the state without any routing call', () async {
      await start();
      confirmOffRouteLeg0();
      expect(nav.state.isOffRoute, isTrue);
      expect(routeService.calls, 0);
      // Planned route and stop order stay untouched before an explicit action.
      expect(nav.state.route!.legs.map((l) => l.toTitle).toList(), [
        'POI 1',
        'POI 2',
        'POI 3',
      ]);
    });

    test('stale and invalid off-route fixes never count toward confirmation', () async {
      await start();
      final stale = fix(
        60.00025,
        30.001,
        timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
      );
      final inaccurate = fix(60.00025, 30.001, accuracy: 200);
      final cached = fix(60.00025, 30.001, cached: true);
      for (var i = 0; i < 5; i++) {
        nav.injectLocationForTesting(stale);
        nav.injectLocationForTesting(inaccurate);
        nav.injectLocationForTesting(cached);
      }
      expect(nav.state.isOffRoute, isFalse);
      expect(routeService.calls, 0);
    });

    test('returning to route clears off-route without rerouting', () async {
      await start();
      confirmOffRouteLeg0();
      expect(nav.state.isOffRoute, isTrue);
      // Walk back to ~30 m from the line (inside the 35 m return band, but
      // >25 m from the endpoint so arrival detection cannot interfere):
      // two fixes accept the return, mid-band jitter resets the streak.
      send(60.00025, 30.00054, gap: const Duration(milliseconds: 500));
      expect(nav.state.isOffRoute, isTrue);
      send(60.00025, 30.0007, gap: const Duration(milliseconds: 500));
      send(60.00025, 30.00054, gap: const Duration(milliseconds: 500));
      expect(nav.state.isOffRoute, isTrue);
      send(60.00025, 30.00054, gap: const Duration(milliseconds: 500));
      expect(nav.state.isOffRoute, isFalse);
      expect(routeService.calls, 0);
    });

    test('explicit reroute requests a real route from fresh GPS to the leg target', () async {
      await start();
      confirmOffRouteLeg0();
      const origin = GeoCoord(60.00025, 30.0012);
      device.currentPositionResult = fix(origin.latitude, origin.longitude);
      await nav.rerouteToNextStop();

      expect(routeService.calls, 1);
      expect(routeService.starts.first.latitude, origin.latitude);
      expect(routeService.starts.first.longitude, origin.longitude);
      expect(routeService.starts.first.isPreset, isFalse);
      // Target is the current leg's destination anchor: the next stop POI 1.
      expect(routeService.destinations.first.title, 'POI 1');
      expect(routeService.destinations.first.latitude, b.latitude);
      expect(nav.status, NavigationStatus.active);
      expect(nav.state.isOffRoute, isFalse);
    });

    test('double tap reroute issues exactly one route request', () async {
      await start();
      confirmOffRouteLeg0();
      device.currentPositionResult = fix(60.00025, 30.0012);
      routeService.pending = Completer();
      final first = nav.rerouteToNextStop();
      await Future<void>.delayed(Duration.zero);
      final second = nav.rerouteToNextStop();
      routeService.pending!.complete(
        straightRoute(routeService.starts.first, routeService.destinations.first),
      );
      await first;
      await second;
      expect(routeService.calls, 1);
      expect(nav.status, NavigationStatus.active);
      expect(nav.state.isOffRoute, isFalse);
    });

    test('successful ordinary A→B reroute replaces geometry and rebases progress', () async {
      final single = PedestrianRouteModel(
        distanceMeters: 0,
        durationSeconds: 60,
        geometryPoints: [a, b],
        steps: const [],
        legs: [leg('Дворцовая площадь', 'Казанский собор', [a, b])],
        placesCount: 1,
      );
      device.currentPositionResult = fix(a.latitude, a.longitude);
      await nav.startNavigation(single);
      send(60.00025, 30.0);
      confirmOffRouteLeg0();
      const origin = GeoCoord(60.00025, 30.0012);
      device.currentPositionResult = fix(origin.latitude, origin.longitude);
      await nav.rerouteToNextStop();

      expect(nav.status, NavigationStatus.active);
      expect(nav.state.route!.legs, hasLength(1));
      expect(nav.state.nextStopTitle, 'Казанский собор');
      final newLeg = nav.state.route!.legs.first;
      expect(newLeg.geometryPoints.first.latitude, origin.latitude);
      expect(newLeg.geometryPoints.last.latitude, b.latitude);
      expect(nav.state.progressOnCurrentLegMeters, 0);
      expect(
        nav.state.remainingDistanceOnCurrentLegMeters,
        closeTo(RouteProjectionUtils.polylineLengthMeters(newLeg.geometryPoints), 1),
      );
      expect(nav.state.totalProgressMeters, 0);
      expect(
        nav.state.totalRemainingMeters,
        closeTo(nav.state.route!.distanceMeters, 1),
      );
      expect(nav.state.totalProgressFraction, lessThan(1));
      // Detector was reset: one new off-route fix cannot be instantly confirmed.
      send(60.0005, 30.001);
      expect(nav.state.isOffRoute, isFalse);
    });

    test('reroute failure preserves the old route and exits the loading state', () async {
      await start();
      confirmOffRouteLeg0();
      final routeBefore = nav.state.route!;
      routeService.error = StateError('MapKit failure');
      device.currentPositionResult = fix(60.00025, 30.0012);
      await nav.rerouteToNextStop();

      expect(nav.status, NavigationStatus.active);
      expect(nav.state.isRerouting, isFalse);
      expect(nav.state.errorMessage, isNotNull);
      expect(nav.state.route, same(routeBefore));
      expect(nav.state.route!.legs.map((l) => l.toTitle).toList(), [
        'POI 1',
        'POI 2',
        'POI 3',
      ]);
      // Still confirmed off-route: the user can retry with the same button.
      expect(nav.state.isOffRoute, isTrue);

      routeService.error = null;
      device.currentPositionResult = fix(60.00025, 30.0012);
      await nav.rerouteToNextStop();
      expect(nav.status, NavigationStatus.active);
      expect(nav.state.isOffRoute, isFalse);
      expect(routeService.calls, 2);
    });

    test('invalid reroute geometry is rejected and keeps the old route', () async {
      await start();
      confirmOffRouteLeg0();
      final routeBefore = nav.state.route!;
      routeService.result = const PedestrianRouteModel(
        distanceMeters: 10,
        durationSeconds: 10,
        geometryPoints: [GeoCoord(60.0003, 30.0012)],
        steps: [],
        legs: [
          RouteLegModel(
            fromTitle: 'Текущее местоположение',
            toTitle: 'POI 1',
            distanceMeters: 10,
            durationSeconds: 10,
            geometryPoints: [GeoCoord(60.0003, 30.0012)],
          ),
        ],
        placesCount: 1,
      );
      device.currentPositionResult = fix(60.00025, 30.0012);
      await nav.rerouteToNextStop();
      expect(nav.status, NavigationStatus.active);
      expect(nav.state.route, same(routeBefore));
      expect(nav.state.errorMessage, isNotNull);
      expect(nav.state.isOffRoute, isTrue);
    });

    test('cancel navigation during reroute: late result cannot resurrect the session', () async {
      await start();
      confirmOffRouteLeg0();
      device.currentPositionResult = fix(60.00025, 30.0012);
      routeService.pending = Completer();
      final reroute = nav.rerouteToNextStop();
      await Future<void>.delayed(Duration.zero);
      nav.stopNavigation();
      expect(nav.status, NavigationStatus.idle);
      // The native request contract: stopping cancels the in-flight request.
      expect(routeService.cancellations, 1);
      await reroute;
      expect(nav.status, NavigationStatus.idle);
      expect(nav.state.route, isNull);
      expect(routing.navigationLocked, isFalse);
    });

    test('new session during reroute: late result cannot replace the new route', () async {
      await start();
      confirmOffRouteLeg0();
      device.currentPositionResult = fix(60.00025, 30.0012);
      routeService
        ..pending = Completer()
        ..cancelCompletes = false; // lazier native layer than the real one
      final reroute = nav.rerouteToNextStop();
      await Future<void>.delayed(Duration.zero);
      nav.stopNavigation();
      device.currentPositionResult = fix(a.latitude, a.longitude);
      await nav.startNavigation(threeLegRoute());
      final newSessionRoute = nav.state.route!;
      // Late "successful" result of the old request must be ignored.
      routeService.pending!.complete(
        straightRoute(
          const RoutePointModel(
            id: 'x',
            title: 'Мусор',
            subtitle: '',
            latitude: 10,
            longitude: 10,
            isPreset: false,
          ),
          const RoutePointModel(
            id: 'y',
            title: 'Мусор 2',
            subtitle: '',
            latitude: 20,
            longitude: 20,
            isPreset: false,
          ),
        ),
      );
      await reroute;
      expect(nav.state.route, same(newSessionRoute));
      expect(nav.status, NavigationStatus.active);
      expect(nav.currentLegIndex, 0);
      expect(nav.state.nextStopTitle, 'POI 1');
    });

    test('background during reroute ignores late result and stays paused', () async {
      await start();
      confirmOffRouteLeg0();
      device.currentPositionResult = fix(60.00025, 30.0012);
      routeService
        ..pending = Completer()
        ..cancelCompletes = false;
      final reroute = nav.rerouteToNextStop();
      await Future<void>.delayed(Duration.zero);
      nav.pauseNavigation();
      expect(nav.status, NavigationStatus.paused);
      final pausedRoute = nav.state.route!;
      routeService.pending!.complete(
        straightRoute(routeService.starts.first, routeService.destinations.first),
      );
      await reroute;
      expect(nav.status, NavigationStatus.paused);
      expect(nav.state.route, same(pausedRoute));
      await nav.resumeNavigation();
      expect(nav.status, NavigationStatus.active);
    });

    test('multi-stop reroute keeps next unvisited POI, order and walked legs', () async {
      await start();
      // Arrive at POI 1 and continue: now navigating leg 1 (POI 1 → POI 2).
      send(b.latitude, b.longitude);
      send(b.latitude, b.longitude);
      send(b.latitude, b.longitude);
      expect(nav.state.isWaitingForNextLegConfirmation, isTrue);
      nav.continueToNextLeg();
      expect(nav.currentLegIndex, 1);
      expect(nav.state.nextStopTitle, 'POI 2');

      confirmOffRoute(60.00075, 30.001);
      const origin = GeoCoord(60.00075, 30.0012);
      device.currentPositionResult = fix(origin.latitude, origin.longitude);
      await nav.rerouteToNextStop();

      final legs = nav.state.route!.legs;
      expect(legs, hasLength(3));
      // Visited POI 1 is not restored: leg 0 keeps its original geometry.
      expect(legs[0].geometryPoints.first, a);
      expect(legs[0].geometryPoints.last, b);
      // Current leg is rebuilt to POI 2, not to a geometrically closer POI 3.
      expect(legs[1].toTitle, 'POI 2');
      expect(legs[1].fromTitle, 'Текущее местоположение');
      expect(legs[1].geometryPoints.first.latitude, origin.latitude);
      expect(legs[1].geometryPoints.last.latitude, c.latitude);
      expect(legs[1].geometryPoints.last.longitude, c.longitude);
      // Remaining leg keeps its original MapKit geometry and order.
      expect(legs[2].toTitle, 'POI 3');
      expect(legs[2].geometryPoints.first, c);
      expect(legs[2].geometryPoints.last, d);
      expect(nav.currentLegIndex, 1);
      expect(nav.state.nextStopTitle, 'POI 2');
    });

    test('progress rebases to the new geometry without absurd totals', () async {
      await start();
      send(b.latitude, b.longitude);
      send(b.latitude, b.longitude);
      send(b.latitude, b.longitude);
      nav.continueToNextLeg();
      confirmOffRoute(60.00075, 30.001);
      const origin = GeoCoord(60.00075, 30.0012);
      device.currentPositionResult = fix(origin.latitude, origin.longitude);
      await nav.rerouteToNextStop();

      final legs = nav.state.route!.legs;
      // Session progress counts only completed legs; the deviated metres of
      // the abandoned leg geometry are NOT carried over.
      expect(
        nav.state.totalProgressMeters,
        closeTo(RouteProjectionUtils.polylineLengthMeters(legs[0].geometryPoints), 1),
      );
      expect(nav.state.progressOnCurrentLegMeters, 0);
      expect(
        nav.state.remainingDistanceOnCurrentLegMeters,
        closeTo(RouteProjectionUtils.polylineLengthMeters(legs[1].geometryPoints), 1),
      );
      expect(
        nav.state.totalRemainingMeters,
        closeTo(
          RouteProjectionUtils.polylineLengthMeters(legs[1].geometryPoints) +
              RouteProjectionUtils.polylineLengthMeters(legs[2].geometryPoints),
          1,
        ),
      );
      expect(nav.state.totalProgressFraction, inInclusiveRange(0, 1));
      expect(nav.state.totalProgressMeters, lessThan(nav.state.route!.distanceMeters));
    });

    test('Smart Walk reroute preserves proposal state and remaining order', () async {
      routing.setProposedWalk(
        [place(1, 'Эрмитаж'), place(2, 'Русский музей')],
        timeBudgetMinutes: 120,
        categories: {PlaceCategoryEnum.historyArchitecture},
      );
      // The planned walk route comes from Smart Walk refinement; navigation
      // starts on it exactly like production does.
      final walkRoute = PedestrianRouteModel(
        distanceMeters: 0,
        durationSeconds: 300,
        geometryPoints: [a, b, c],
        steps: const [],
        legs: [
          leg('Старт', 'Эрмитаж', [a, b]),
          leg('Эрмитаж', 'Русский музей', [b, c]),
        ],
        placesCount: 2,
      );
      device.currentPositionResult = fix(a.latitude, a.longitude);
      await nav.startNavigation(walkRoute);
      // Reach POI 1, continue, then deviate on the current leg.
      send(b.latitude, b.longitude);
      send(b.latitude, b.longitude);
      send(b.latitude, b.longitude);
      nav.continueToNextLeg();
      confirmOffRoute(60.00075, 30.001);
      device.currentPositionResult = fix(60.00075, 30.0012);
      await nav.rerouteToNextStop();

      // No Smart Walk scoring, budget recalculation or POI shuffling happened.
      expect(routing.walkPlaces.map((p) => p.id).toList(), [1, 2]);
      expect(routing.walkBudgetMinutes, 120);
      expect(routing.isCalculating, isFalse);
      expect(routing.errorMessage, isNull);
      expect(routing.budgetWarningMessage, isNull);
      // Only the single point-to-point navigation request was made.
      expect(routeService.calls, 1);
      expect(routeService.destinations.first.title, 'Русский музей');
      expect(nav.state.route!.legs.map((l) => l.toTitle).toList(), [
        'Эрмитаж',
        'Русский музей',
      ]);
      expect(nav.state.route!.placesCount, 2);
    });

    test('arrival still works after reroute and completion releases resources', () async {
      final single = PedestrianRouteModel(
        distanceMeters: 0,
        durationSeconds: 60,
        geometryPoints: [a, b],
        steps: const [],
        legs: [leg('Дворцовая площадь', 'Казанский собор', [a, b])],
        placesCount: 1,
      );
      device.currentPositionResult = fix(a.latitude, a.longitude);
      await nav.startNavigation(single);
      confirmOffRouteLeg0();
      device.currentPositionResult = fix(60.00025, 30.0012);
      await nav.rerouteToNextStop();
      expect(nav.isActive, isTrue);

      // Walk the rebuilt geometry: intermediate fixes advance progress…
      send(60.0003, 30.0012);
      send(60.0003, 30.0012);
      // …and three fixes at the leg target confirm arrival: the first large
      // forward jump needs one consistent confirmation fix (v2.1 policy),
      // arrival itself needs two near fixes.
      send(b.latitude, b.longitude);
      send(b.latitude, b.longitude);
      send(b.latitude, b.longitude);
      expect(nav.isCompleted, isTrue);
      expect(nav.state.arrivedPlaceTitle, 'Казанский собор');
      expect(nav.state.totalProgressFraction, 1);
      expect(routing.navigationLocked, isFalse);
      expect(device.cancellations, greaterThanOrEqualTo(1));
    });

    test('location unavailable while off-route: fallback uses the last live fix', () async {
      await start();
      confirmOffRouteLeg0();
      device.failFix = true;
      // The last streamed deviation fix is a valid fresh live origin.
      await nav.rerouteToNextStop();
      expect(routeService.calls, 1);
      expect(routeService.starts.first.latitude, 60.00025);
      expect(nav.status, NavigationStatus.active);
      expect(nav.state.isOffRoute, isFalse);
    });

    test('fully stale origin fails the reroute without destroying the session', () async {
      await start();
      confirmOffRouteLeg0();
      final routeBefore = nav.state.route!;
      // No one-shot fix and a long gap past the last streamed fix invalidate
      // every origin. The freshness clock jumps 16 s beyond that fix instead
      // of sleeping in real time.
      device.failFix = true;
      final staleNow = clock.last.add(const Duration(seconds: 16));
      UserLocationSnapshot.clock = () => staleNow;
      await nav.rerouteToNextStop();
      expect(routeService.calls, 0);
      expect(nav.status, NavigationStatus.active);
      expect(nav.state.errorMessage, isNotNull);
      expect(nav.state.route, same(routeBefore));
      expect(nav.state.isOffRoute, isTrue);
    });

    test('reroute origin ignores cached snapshots and uses the fresh live fix', () async {
      await start();
      confirmOffRouteLeg0();
      // One-shot position arrives as a cached snapshot: must be rejected…
      device.currentPositionResult = fix(55.0, 25.0, cached: true);
      await nav.rerouteToNextStop();
      // …and the newest streamed fix becomes the origin instead.
      expect(routeService.calls, 1);
      expect(routeService.starts.first.latitude, 60.00025);
      expect(routeService.starts.first.longitude, closeTo(30.001, 1e-9));
    });

    test('planning mutations stay rejected while rerouting (lock sync)', () async {
      await start();
      confirmOffRouteLeg0();
      device.currentPositionResult = fix(60.00025, 30.0012);
      routeService.pending = Completer();
      final reroute = nav.rerouteToNextStop();
      await Future<void>.delayed(Duration.zero);
      expect(nav.locksPlanning, isTrue);
      expect(routing.navigationLocked, isTrue);
      final original = routing.startPoint;
      routing.setCustomStartPoint(12, 13);
      routing.beginStartSelection();
      routing.clearRoute();
      expect(routing.startPoint.latitude, original.latitude);
      expect(routing.isChoosingStart, isFalse);
      routeService.pending!.complete(
        straightRoute(routeService.starts.first, routeService.destinations.first),
      );
      await reroute;
      expect(nav.status, NavigationStatus.active);
      expect(routing.navigationLocked, isTrue);
      nav.stopNavigation();
      expect(routing.navigationLocked, isFalse);
    });

    test('lock changes notify listeners; teardown stays quiet', () async {
      var notifications = 0;
      routing.addListener(() => notifications++);
      device.currentPositionResult = fix(a.latitude, a.longitude);
      await nav.startNavigation(threeLegRoute());
      expect(routing.navigationLocked, isTrue);
      final afterStart = notifications;
      expect(afterStart, greaterThan(0));
      nav.stopNavigation();
      expect(routing.navigationLocked, isFalse);
      final afterStop = notifications;
      expect(afterStop, greaterThan(afterStart));
      // A separate provider's teardown must not notify routing listeners.
      final local = NavigationProvider(
        locationService: device,
        routingProvider: routing,
        routeService: routeService,
      );
      local.dispose();
      expect(notifications, afterStop, reason: 'dispose must not notify');
    });

    test('GPS loss during confirmed off-route pauses detection, not the session', () async {
      await start();
      confirmOffRouteLeg0();
      expect(nav.state.isOffRoute, isTrue);
      device.source.addError(StateError('gps gone'));
      await Future<void>.delayed(Duration.zero);
      expect(nav.status, NavigationStatus.waitingForGps);
      expect(nav.state.isGpsLost, isTrue);
      // Session and route survive. The stale off-route confirmation is
      // dropped: only fresh validated fixes may re-confirm a deviation.
      expect(nav.state.route, isNotNull);
      expect(nav.state.isOffRoute, isFalse);
      nav.injectLocationForTesting(fix(60.00025, 30.001, accuracy: 200));
      expect(nav.state.isOffRoute, isFalse);
      nav.stopNavigation();
    });
  });
}
