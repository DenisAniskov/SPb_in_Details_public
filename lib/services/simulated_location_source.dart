import 'dart:async';
import 'dart:math' as math;

import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/services/device_location_service.dart';

/// Virtual walker position at [distanceMeters] along [points], interpolated
/// on the same Haversine meter scale the GPS projection uses.
GeoCoord positionAlongPolyline(List<GeoCoord> points, double distanceMeters) {
  if (points.isEmpty) return const GeoCoord(0, 0);
  if (points.length == 1) return points.first;
  var remaining = math.max(0.0, distanceMeters);
  for (var i = 0; i < points.length - 1; i++) {
    final segment = RouteProjectionUtils.distanceBetween(points[i], points[i + 1]);
    if (remaining <= segment || i == points.length - 2) {
      final t = segment <= 0 ? 0.0 : (remaining / segment).clamp(0.0, 1.0);
      return GeoCoord(
        points[i].latitude +
            t * (points[i + 1].latitude - points[i].latitude),
        points[i].longitude +
            t * (points[i + 1].longitude - points[i].longitude),
      );
    }
    remaining -= segment;
  }
  return points.last;
}

/// Approximate local-meters offset (east/north) used for deviation injection.
GeoCoord offsetByLocalMeters(GeoCoord point, double eastMeters, double northMeters) {
  final latRad = point.latitude * math.pi / 180.0;
  final dLat = northMeters / 111194.93;
  final dLon = eastMeters / (111194.93 * math.max(0.1, math.cos(latRad)));
  return GeoCoord(point.latitude + dLat, point.longitude + dLon);
}

/// Simulated GPS source implementing the exact production contract
/// ([BaseDeviceLocationService]) so it can be injected into the unchanged
/// Phase C4 [NavigationProvider]. It never touches Android system GPS and
/// only ever emits positions derived from the route geometry the operator
/// loaded — no user location history is recorded anywhere.
///
/// Error injections deliberately reuse the engine's own quality gates: the
/// source produces imperfect fixes, and the provider must reject or recover
/// from them exactly as it would with real hardware.
class SimulatedLocationSource implements BaseDeviceLocationSourceControl {
  SimulatedLocationSource({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  // Synchronous broadcast: a delivered fix is processed by the engine
  // immediately (same contract as injectLocationForTesting), so replay and
  // seek decisions observe updated session state deterministically.
  final StreamController<UserLocationSnapshot> _streamController =
      StreamController<UserLocationSnapshot>.broadcast(sync: true);

  List<GeoCoord> _geometry = const [];
  double _distanceMeters = 0;
  double _speedMps = 5 / 3.6;
  final double _defaultAccuracyMeters = 8;
  DateTime? _lastTimestamp;

  // Error-injection state.
  DateTime? _lossUntil;
  double? _lowAccuracyMeters;
  bool _staleNext = false;
  double? _jumpForwardMeters;
  double _deviationMeters = 0;

  /// Injectable clock keeps tests deterministic; production always uses the
  /// real clock so fix timestamps behave like hardware ones.
  DateTime Function() get clock => _clock;

  double get distanceMeters => _distanceMeters;
  set distanceMeters(double value) =>
      _distanceMeters = value.isFinite ? math.max(0, value) : 0;

  double get speedMps => _speedMps;
  set speedMps(double value) =>
      _speedMps = value.isFinite && value >= 0 ? value : 0;

  double get geometryLengthMeters =>
      RouteProjectionUtils.polylineLengthMeters(_geometry);

  bool get isGpsLossActive =>
      _lossUntil != null && _clock().isBefore(_lossUntil!);

  bool get hasDeviation => _deviationMeters != 0;

  /// Load the real MapKit polyline of a leg (production) or a deterministic
  /// fixture (offline tests). Resets progress and injections.
  @override
  void loadGeometry(List<GeoCoord> points) {
    _geometry = List.unmodifiable(points);
    _distanceMeters = 0;
    resetInjections();
  }

  void resetInjections() {
    _lossUntil = null;
    _lowAccuracyMeters = null;
    _staleNext = false;
    _jumpForwardMeters = null;
    _deviationMeters = 0;
  }

  /// Advance the virtual walker and emit one fix. The walker keeps moving
  /// during injected GPS loss (delivery is down, the person is not frozen).
  @override
  void tick(double deltaSeconds) {
    if (_geometry.isEmpty || deltaSeconds <= 0 || deltaSeconds.isNaN) return;
    _distanceMeters += _speedMps * deltaSeconds;
    emitCurrent();
  }

  /// Emit a fix at the current virtual distance without advancing it. A
  /// pending jump injection teleports exactly one streamed fix forward.
  @override
  void emitCurrent() {
    if (_geometry.isEmpty) return;
    if (isGpsLossActive) return; // delivery suppressed, distance preserved
    final jump = _jumpForwardMeters;
    _jumpForwardMeters = null;
    final baseDistance = _distanceMeters + (jump ?? 0);
    final coordinate = positionAlongPolyline(_geometry, baseDistance);
    var shifted = coordinate;
    if (_deviationMeters != 0) {
      // Right-hand perpendicular offset in local meters from the local
      // segment bearing, so the walker keeps advancing while standing a
      // fixed distance off the line.
      final ahead = positionAlongPolyline(_geometry, baseDistance + 5);
      final latRad = coordinate.latitude * math.pi / 180.0;
      final northM = (ahead.latitude - coordinate.latitude) * 111194.93;
      final eastM = (ahead.longitude - coordinate.longitude) *
          111194.93 *
          math.max(0.1, math.cos(latRad));
      final norm = math.sqrt(northM * northM + eastM * eastM);
      if (norm > 0) {
        // (north, east) rotated -90°: right normal is (east, -north).
        shifted = offsetByLocalMeters(
          coordinate,
          eastM / norm * _deviationMeters,
          -northM / norm * _deviationMeters,
        );
      }
    }
    _publish(shifted);
  }

  void _publish(GeoCoord coordinate) {
    var timestamp = _clock();
    final last = _lastTimestamp;
    if (last != null && !timestamp.isAfter(last)) {
      // A real device never produces two fixes inside the same clock
      // millisecond, and the engine's freshness gate rejects future-dated
      // fixes. Skip this emission instead of fabricating a timestamp; the
      // next tick — real time later — delivers a valid one.
      return;
    }
    if (_staleNext) {
      timestamp = timestamp.subtract(const Duration(seconds: 60));
      _staleNext = false;
    }
    _lastTimestamp = timestamp;
    _streamController.add(UserLocationSnapshot(
      coordinate: coordinate,
      accuracy: _lowAccuracyMeters ?? _defaultAccuracyMeters,
      speed: _speedMps,
      timestamp: timestamp,
      isCached: false,
    ));
  }

  // Error injections (Section 4). All of them produce imperfect DATA; none
  // of them weakens the provider's quality gates.
  void injectGpsLoss({Duration duration = const Duration(seconds: 10)}) {
    final until = _clock().add(duration);
    _lossUntil = _lossUntil == null || until.isAfter(_lossUntil!)
        ? until
        : _lossUntil;
  }

  void clearGpsLoss() => _lossUntil = null;

  /// Subsequent fixes carry the given (poor) accuracy until cleared. Values
  /// above the engine's 50 m gate test rejection; values under it test
  /// degraded-but-accepted behavior.
  void injectLowAccuracy({double accuracyMeters = 45}) {
    _lowAccuracyMeters = accuracyMeters;
  }

  void clearLowAccuracy() => _lowAccuracyMeters = null;

  /// One-shot: the next published fix (stream or one-shot request) carries a
  /// backdated timestamp the engine must treat as stale.
  void injectStaleFix() => _staleNext = true;

  /// One-shot: the next streamed fix teleports forward along the route.
  void injectJump({double forwardMeters = 120}) {
    _jumpForwardMeters = forwardMeters;
  }

  /// Persistent lateral deviation until [returnToRoute].
  void injectDeviation({double meters = 80}) {
    _deviationMeters = meters;
  }

  void returnToRoute() {
    _deviationMeters = 0;
  }

  void reset() {
    _geometry = const [];
    _distanceMeters = 0;
    _lastTimestamp = null;
    resetInjections();
  }

  /// BaseDeviceLocationService contract: a simulated device always looks
  /// permission-granted and service-enabled; there is never a cached fix.
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
  }) async {
    // One-shot: same virtual position without advancing the walker.
    final coordinate = positionAlongPolyline(_geometry, _distanceMeters);
    final snapshot = UserLocationSnapshot(
      coordinate: coordinate,
      accuracy: _lowAccuracyMeters ?? _defaultAccuracyMeters,
      speed: _speedMps,
      timestamp: _clock(),
      isCached: false,
    );
    _lastTimestamp = snapshot.timestamp;
    return snapshot;
  }

  @override
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  }) =>
      // The controller's ticker drives emission cadence; the engine's stream
      // parameters are irrelevant to the simulation and are ignored.
      _streamController.stream;

  @override
  Stream<bool> getServiceStatusStream() => const Stream<bool>.empty();

  /// Closes the stream. Idempotent: double disposal (controller teardown
  // plus explicit test disposal) is safe.
  @override
  Future<void> dispose() {
    if (_streamController.isClosed) return Future<void>.value();
    return _streamController.close();
  }
}

/// The source contract extended with the simulator control surface. Keeping
/// the control methods off [BaseDeviceLocationService] guarantees the
/// production engine can never depend on simulator internals.
abstract class BaseDeviceLocationSourceControl
    implements BaseDeviceLocationService {
  void loadGeometry(List<GeoCoord> points);
  void tick(double deltaSeconds);
  void emitCurrent();
  Future<void> dispose();
}
