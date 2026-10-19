import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/location_provider.dart';
import 'package:smart_navigator_spb/services/device_location_service.dart';

class _FakeDeviceLocation implements BaseDeviceLocationService {
  LocationPermissionStatus permission =
      LocationPermissionStatus.grantedPrecise;
  UserLocationSnapshot? fix;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermissionStatus> checkPermission() async => permission;

  @override
  Future<LocationPermissionStatus> requestPermission() async => permission;

  @override
  Future<UserLocationSnapshot?> getLastKnownPosition() async => null;

  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) async => fix!;

  @override
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  }) => const Stream<UserLocationSnapshot>.empty();

  @override
  Stream<bool> getServiceStatusStream() => const Stream<bool>.empty();
}

UserLocationSnapshot _snapshot(double? accuracy) => UserLocationSnapshot(
  coordinate: const GeoCoord(59.9343, 30.3351),
  accuracy: accuracy,
  timestamp: DateTime.now(),
);

Future<LocationProvider> _locate(
  _FakeDeviceLocation device,
  double? accuracy,
) async {
  device.fix = _snapshot(accuracy);
  final provider = LocationProvider(locationService: device);
  addTearDown(provider.dispose);
  await provider.requestLocationAndLocate();
  return provider;
}

void main() {
  test('a small reported radius is precise and keeps the old wording', () async {
    final provider = await _locate(_FakeDeviceLocation(), 12);

    expect(provider.locationQuality, LocationQuality.precise);
    expect(provider.locationQualityMessage, isNull);
  });

  test('a 120 m radius is approximate and is stated honestly', () async {
    final provider = await _locate(_FakeDeviceLocation(), 120);

    expect(provider.locationQuality, LocationQuality.approximate);
    expect(
      provider.locationQualityMessage,
      'Местоположение приблизительное. Точность около 120 м.',
    );
  });

  test('a 150.6 m radius is classified as poor and reported in metres',
      () async {
    final provider = await _locate(_FakeDeviceLocation(), 150.6);

    expect(provider.locationQuality, LocationQuality.poor);
    expect(provider.locationQualityMessage, contains('неточное'));
    expect(provider.locationQualityMessage, contains('около 151 м'));
  });

  test('coarse permission is never reported as precise', () async {
    final device = _FakeDeviceLocation()
      ..permission = LocationPermissionStatus.grantedCoarse;
    final provider = await _locate(device, 8);

    expect(provider.locationQuality, LocationQuality.approximate);
    expect(
      provider.locationQualityMessage,
      contains('Разрешено только приблизительное местоположение'),
    );
    expect(provider.locationQualityMessage, contains('около 8 м'));
  });

  test('an unknown accuracy is not presented as a precise fix', () async {
    final provider = await _locate(_FakeDeviceLocation(), null);

    expect(provider.locationQuality, LocationQuality.unknown);
    expect(
      provider.locationQualityMessage,
      'Точность местоположения неизвестна.',
    );
  });

  test('no accepted fix means no quality claim', () async {
    final provider = LocationProvider(locationService: _FakeDeviceLocation());
    addTearDown(provider.dispose);

    expect(provider.locationQuality, LocationQuality.unknown);
    expect(provider.locationQualityMessage, isNotNull);
  });

  test('the start snapshot keeps coarse wording separate from accuracy',
      () async {
    final device = _FakeDeviceLocation()
      ..permission = LocationPermissionStatus.grantedCoarse;
    final provider = await _locate(device, 60);

    final point = provider.createUserLocationRoutePoint();
    expect(point, isNotNull);
    expect(point!.subtitle, contains('Приблизительная позиция'));
  });
}
