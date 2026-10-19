import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/location_provider.dart';

import 'location_foundation_test.dart' show MockDeviceLocationService;

class _PendingLocation extends MockDeviceLocationService {
  final pendingFix = Completer<UserLocationSnapshot>();

  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) => pendingFix.future;
}

UserLocationSnapshot _fix({double? accuracy = 5}) => UserLocationSnapshot(
  coordinate: const GeoCoord(59.9343, 30.3351),
  timestamp: DateTime.now(),
  accuracy: accuracy,
);

void main() {
  for (final status in [
    LocationPermissionStatus.denied,
    LocationPermissionStatus.permanentlyDenied,
    LocationPermissionStatus.serviceDisabled,
  ]) {
    test('late fix cannot restore access after $status', () async {
      final device = _PendingLocation();
      final location = LocationProvider(locationService: device);
      addTearDown(location.dispose);
      final pending = location.requestLocationAndLocate();
      await Future<void>.delayed(Duration.zero);
      expect(location.state.phase, LocationPhase.locating);
      device.checkPermissionResult = status;
      device.pendingFix.complete(_fix());

      expect(await pending, isNull);
      expect(location.permissionStatus, status);
      expect(location.state.phase, LocationPhase.unavailable);
      expect(location.lastKnownLocation, isNull);
      expect(location.createUserLocationRoutePoint(), isNull);
    });
  }

  test(
    'precision reduction during acquisition labels the start as approximate',
    () async {
      final device = _PendingLocation();
      final location = LocationProvider(locationService: device);
      addTearDown(location.dispose);
      final pending = location.requestLocationAndLocate();
      await Future<void>.delayed(Duration.zero);
      device.checkPermissionResult = LocationPermissionStatus.grantedCoarse;
      device.pendingFix.complete(_fix(accuracy: 500));

      expect(await pending, isNotNull);
      expect(location.permissionStatus, LocationPermissionStatus.grantedCoarse);
      expect(
        location.createUserLocationRoutePoint()!.subtitle,
        contains('Приблизительная'),
      );
    },
  );

  for (final accuracy in [double.nan, double.infinity, -1.0]) {
    test('invalid accuracy $accuracy cannot become a planning start', () async {
      final device = MockDeviceLocationService()
        ..currentPositionResult = _fix(accuracy: accuracy);
      final location = LocationProvider(locationService: device);
      addTearDown(location.dispose);

      expect(await location.requestLocationAndLocate(), isNull);
      expect(location.createUserLocationRoutePoint(), isNull);
      expect(location.state.phase, LocationPhase.unavailable);
    });
  }
}
