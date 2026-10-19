import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/services/simulated_location_source.dart';

/// Phase C4.1 Section 1/4: the simulated GPS source — geometry math,
/// sequential timestamps, error injections. Deterministic only; no MapKit.
class SimClock {
  SimClock() : _now = DateTime.now();
  DateTime _now;
  DateTime call() => _now;
  void advance(Duration duration) => _now = _now.add(duration);
}

void main() {
  // ~556 m northward line.
  const geometry = [
    GeoCoord(60.0, 30.0),
    GeoCoord(60.0050, 30.0),
  ];

  group('positionAlongPolyline (virtual walker math)', () {
    test('interpolates inside a segment', () {
      final point = positionAlongPolyline(geometry, 111.2);
      expect(point.latitude, closeTo(60.001, 0.00001));
      expect(point.longitude, 30.0);
    });

    test('clamps before the start and beyond the end', () {
      final before = positionAlongPolyline(geometry, -5);
      expect(before.latitude, 60.0);
      final after = positionAlongPolyline(geometry, 9999);
      expect(after.latitude, closeTo(60.005, 0.00001));
    });

    test('handles degenerate geometry honestly', () {
      expect(positionAlongPolyline(const [], 10), const GeoCoord(0, 0));
      final single = positionAlongPolyline(const [GeoCoord(60.0, 30.0)], 10);
      expect(single, const GeoCoord(60.0, 30.0));
    });
  });

  group('SimulatedLocationSource streaming', () {
    late SimClock clock;
    late SimulatedLocationSource source;
    final received = <UserLocationSnapshot>[];
    StreamSubscription<UserLocationSnapshot>? subscription;

    setUp(() {
      clock = SimClock();
      source = SimulatedLocationSource(clock: clock.call);
      received.clear();
      subscription = source.getPositionStream().listen(received.add);
    });

    tearDown(() async {
      await subscription?.cancel();
      await source.dispose();
    });

    test('tick advances the walker at the configured speed', () {
      source.loadGeometry(geometry);
      source.speedMps = 5 / 3.6;
      source.tick(10); // 10 s at 5 km/h = 13.9 m
      expect(source.distanceMeters, closeTo(13.9, 0.1));
      expect(received, hasLength(1));
      final emitted = received.single.coordinate;
      expect(
        RouteProjectionUtils.distanceBetween(
          geometry.first,
          emitted,
        ),
        closeTo(13.9, 0.2),
      );
    });

    test('timestamps are strictly sequential; same-millisecond fixes collapse', () {
      source.loadGeometry(geometry);
      source.tick(1);
      source.tick(1);
      // A frozen clock cannot produce a second valid fix: the engine rejects
      // non-increasing timestamps and future-dated fixes alike.
      expect(received, hasLength(1));

      clock.advance(const Duration(seconds: 2));
      source.tick(1);
      expect(received, hasLength(2));
      expect(received[1].timestamp.isAfter(received[0].timestamp), isTrue);
      expect(
        received[1].timestamp.difference(received[0].timestamp),
        lessThanOrEqualTo(const Duration(seconds: 3)),
      );
    });

    test('snapshots are never marked cached and carry walking speed', () {
      source.loadGeometry(geometry);
      source.speedMps = 3 / 3.6;
      source.tick(1);
      expect(received.single.isCached, isFalse);
      expect(received.single.speed, closeTo(3 / 3.6, 0.001));
      expect(received.single.accuracy, isNotNull);
    });
  });

  group('Error injections (Section 4)', () {
    late SimClock clock;
    late SimulatedLocationSource source;
    final received = <UserLocationSnapshot>[];
    StreamSubscription<UserLocationSnapshot>? subscription;

    setUp(() {
      clock = SimClock();
      source = SimulatedLocationSource(clock: clock.call);
      received.clear();
      subscription = source.getPositionStream().listen(received.add);
    });

    tearDown(() async {
      await subscription?.cancel();
      await source.dispose();
    });

    test('GPS loss suppresses delivery while the walker keeps moving', () {
      source.loadGeometry(geometry);
      source.injectGpsLoss(duration: const Duration(seconds: 10));
      source.tick(5);
      expect(received, isEmpty);
      expect(source.distanceMeters, greaterThan(0));
      expect(source.isGpsLossActive, isTrue);

      // Recovery after the loss window expires.
      clock.advance(const Duration(seconds: 11));
      source.tick(5);
      expect(received, hasLength(1));
      expect(source.isGpsLossActive, isFalse);
    });

    test('low accuracy is applied until cleared', () {
      source.loadGeometry(geometry);
      source.injectLowAccuracy(accuracyMeters: 45);
      source.tick(1);
      expect(received.single.accuracy, 45);
      source.clearLowAccuracy();
      clock.advance(const Duration(seconds: 2));
      source.tick(1);
      expect(received.last.accuracy, 8);
    });

    test('stale injection backdates exactly one streamed fix', () {
      source.loadGeometry(geometry);
      source.injectStaleFix();
      source.tick(1);
      final staleAge =
          clock().difference(received.first.timestamp).inMinutes;
      expect(staleAge, greaterThanOrEqualTo(1));
      source.tick(1);
      expect(
        clock().difference(received.last.timestamp).inMinutes,
        lessThanOrEqualTo(1),
      );
    });

    test('jump teleports exactly one fix forward', () {
      source.loadGeometry(geometry);
      source.distanceMeters = 50;
      source.injectJump(forwardMeters: 120);
      source.tick(1);
      expect(
        RouteProjectionUtils.distanceBetween(
          geometry.first,
          received.first.coordinate,
        ),
        closeTo(171.4, 0.5),
      );
      // One-shot: the jump is consumed; the clock must move for the next fix.
      clock.advance(const Duration(seconds: 2));
      source.tick(1);
      expect(
        RouteProjectionUtils.distanceBetween(
          geometry.first,
          received.last.coordinate,
        ),
        closeTo(52.8, 0.5),
      );
    });

    test('deviation offsets the walker laterally until return', () {
      source.loadGeometry(geometry);
      source.injectDeviation(meters: 80);
      source.tick(1);
      final offRoute = RouteProjectionUtils.distanceBetween(
        received.first.coordinate,
        positionAlongPolyline(geometry, source.distanceMeters),
      );
      expect(offRoute, closeTo(80, 5));
      source.returnToRoute();
      clock.advance(const Duration(seconds: 2));
      source.tick(1);
      final backOnRoute = RouteProjectionUtils.distanceBetween(
        received.last.coordinate,
        positionAlongPolyline(geometry, source.distanceMeters),
      );
      expect(backOnRoute, lessThan(1));
    });

    test('one-shot fix is fresh and at the current position', () async {
      source.loadGeometry(geometry);
      source.distanceMeters = 100;
      final fix = await source.getCurrentPosition();
      expect(
        RouteProjectionUtils.distanceBetween(
          geometry.first,
          fix.coordinate,
        ),
        closeTo(100, 0.5),
      );
      expect(fix.isFresh(maxAge: const Duration(seconds: 15)), isTrue);
    });

    test('device contract: enabled, granted, never a cached fix', () async {
      expect(await source.isLocationServiceEnabled(), isTrue);
      expect(
        await source.checkPermission(),
        LocationPermissionStatus.grantedPrecise,
      );
      expect(
        await source.requestPermission(),
        LocationPermissionStatus.grantedPrecise,
      );
      expect(await source.getLastKnownPosition(), isNull);
    });

    test('loadGeometry resets progress and injections', () {
      source.loadGeometry(geometry);
      source.injectDeviation(meters: 80);
      source.injectLowAccuracy();
      source.distanceMeters = 200;
      source.loadGeometry(geometry);
      expect(source.distanceMeters, 0);
      expect(source.hasDeviation, isFalse);
      source.tick(1);
      expect(received.single.accuracy, 8);
    });

    test('dispose closes the stream for listeners', () async {
      final done = Completer<void>();
      final sub = source.getPositionStream().listen((_) {}, onDone: done.complete);
      source.loadGeometry(geometry);
      await source.dispose();
      await done.future.timeout(const Duration(seconds: 1));
      await sub.cancel();
    });
  });
}
