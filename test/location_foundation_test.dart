import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/location_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/device_location_service.dart';
import 'package:smart_navigator_spb/services/location_service.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/widgets/start_point_selector_dialog.dart';

class MockDeviceLocationService implements BaseDeviceLocationService {
  bool serviceEnabled = true;
  LocationPermissionStatus checkPermissionResult = LocationPermissionStatus.notRequested;
  LocationPermissionStatus requestPermissionResult = LocationPermissionStatus.grantedPrecise;
  UserLocationSnapshot? lastKnownPositionResult;
  UserLocationSnapshot? currentPositionResult;
  Exception? currentPositionException;

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermissionStatus> checkPermission() async => checkPermissionResult;

  @override
  Future<LocationPermissionStatus> requestPermission() async {
    checkPermissionResult = requestPermissionResult;
    return requestPermissionResult;
  }

  @override
  Future<UserLocationSnapshot?> getLastKnownPosition() async => lastKnownPositionResult;

  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) async {
    if (currentPositionException != null) {
      throw currentPositionException!;
    }
    return currentPositionResult ??
        UserLocationSnapshot(
          coordinate: const GeoCoord(59.9343, 30.3351), // Spb Nevsky
          accuracy: 5.0,
          timestamp: DateTime.now(),
        );
  }

  final StreamController<UserLocationSnapshot> positionStreamController =
      StreamController<UserLocationSnapshot>.broadcast();

  @override
  Stream<UserLocationSnapshot> getPositionStream({
    int distanceFilterMeters = 3,
    int intervalDurationMs = 2000,
  }) => positionStreamController.stream;

  @override
  Stream<bool> getServiceStatusStream() => const Stream<bool>.empty();
}

void main() {
  group('Location Foundation Unit Tests', () {
    test('checkPermissionStatus updates state without prompt', () async {
      final mock = MockDeviceLocationService()
        ..checkPermissionResult = LocationPermissionStatus.grantedPrecise
        ..lastKnownPositionResult = UserLocationSnapshot(
          coordinate: const GeoCoord(59.93, 30.33),
          timestamp: DateTime.now(),
        );

      final provider = LocationProvider(locationService: mock);
      expect(provider.permissionStatus, LocationPermissionStatus.notRequested);
      expect(provider.lastKnownLocation, isNull);

      await provider.checkPermissionStatus();

      expect(provider.permissionStatus, LocationPermissionStatus.grantedPrecise);
      expect(provider.lastKnownLocation, isNotNull);
      expect(provider.lastKnownLocation!.coordinate.latitude, 59.93);
    });

    test('requestLocationAndLocate handles serviceDisabled', () async {
      final mock = MockDeviceLocationService()..serviceEnabled = false;
      final provider = LocationProvider(locationService: mock);

      final snapshot = await provider.requestLocationAndLocate();

      expect(snapshot, isNull);
      expect(provider.permissionStatus, LocationPermissionStatus.serviceDisabled);
      expect(provider.errorMessage, contains('Службы геолокации отключены'));
    });

    test('requestLocationAndLocate handles permission denied', () async {
      final mock = MockDeviceLocationService()
        ..serviceEnabled = true
        ..requestPermissionResult = LocationPermissionStatus.denied;
      final provider = LocationProvider(locationService: mock);

      final snapshot = await provider.requestLocationAndLocate();

      expect(snapshot, isNull);
      expect(provider.permissionStatus, LocationPermissionStatus.denied);
      expect(provider.errorMessage, contains('отклонён'));
    });

    test('requestLocationAndLocate handles permission permanentlyDenied', () async {
      final mock = MockDeviceLocationService()
        ..serviceEnabled = true
        ..requestPermissionResult = LocationPermissionStatus.permanentlyDenied;
      final provider = LocationProvider(locationService: mock);

      final snapshot = await provider.requestLocationAndLocate();

      expect(snapshot, isNull);
      expect(provider.permissionStatus, LocationPermissionStatus.permanentlyDenied);
      expect(provider.errorMessage, contains('заблокирован'));
    });

    test('requestLocationAndLocate returns fresh coordinate snapshot when granted', () async {
      final now = DateTime.now();
      final mock = MockDeviceLocationService()
        ..serviceEnabled = true
        ..requestPermissionResult = LocationPermissionStatus.grantedPrecise
        ..currentPositionResult = UserLocationSnapshot(
          coordinate: const GeoCoord(59.9390, 30.3158),
          accuracy: 4.2,
          timestamp: now,
        );
      final provider = LocationProvider(locationService: mock);

      final snapshot = await provider.requestLocationAndLocate();

      expect(snapshot, isNotNull);
      expect(snapshot!.coordinate.latitude, 59.9390);
      expect(snapshot.coordinate.longitude, 30.3158);
      expect(provider.errorMessage, isNull);

      final routePoint = provider.createUserLocationRoutePoint();
      expect(routePoint, isNotNull);
      expect(routePoint!.id, 'user_location');
      expect(routePoint.title, 'Моё местоположение');
      expect(routePoint.latitude, 59.9390);
      expect(routePoint.longitude, 30.3158);
      expect(routePoint.isPreset, isFalse);
    });
  });

  group('Start Point Selector Dialog with GPS tests', () {
    testWidgets('renders "Моё местоположение" in StartPointSelectorDialog and selects it as snapshot',
        (tester) async {
      final mock = MockDeviceLocationService()
        ..serviceEnabled = true
        ..requestPermissionResult = LocationPermissionStatus.grantedPrecise
        ..currentPositionResult = UserLocationSnapshot(
          coordinate: const GeoCoord(59.9350, 30.3250),
          accuracy: 8.0,
          timestamp: DateTime.now(),
        );

      final locationProvider = LocationProvider(locationService: mock);
      final routingProvider = RoutingProvider(
        locationService: LocationService(),
        mapKitService: MapKitService(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<LocationProvider>.value(value: locationProvider),
              ChangeNotifierProvider<RoutingProvider>.value(value: routingProvider),
            ],
            child: const Scaffold(
              body: StartPointSelectorDialog(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify the tile is rendered
      expect(find.text('Моё местоположение'), findsOneWidget);
      expect(find.text('GPS'), findsOneWidget);

      // Tap on "Моё местоположение"
      await tester.tap(find.text('Моё местоположение'));
      await tester.pumpAndSettle();

      // RoutingProvider must have recorded user_location snapshot
      expect(routingProvider.startPoint.id, 'user_location');
      expect(routingProvider.startPoint.title, 'Моё местоположение');
      expect(routingProvider.startPoint.latitude, 59.9350);
      expect(routingProvider.startPoint.longitude, 30.3250);
    });

    testWidgets('shows error snackbar when location permission denied in dialog',
        (tester) async {
      final mock = MockDeviceLocationService()
        ..serviceEnabled = true
        ..requestPermissionResult = LocationPermissionStatus.denied;

      final locationProvider = LocationProvider(locationService: mock);
      final routingProvider = RoutingProvider(
        locationService: LocationService(),
        mapKitService: MapKitService(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<LocationProvider>.value(value: locationProvider),
              ChangeNotifierProvider<RoutingProvider>.value(value: routingProvider),
            ],
            child: const Scaffold(
              body: StartPointSelectorDialog(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Моё местоположение'));
      await tester.pumpAndSettle();

      // Start point remains default
      expect(routingProvider.startPoint.id, isNot('user_location'));
      // Error message in snackbar or provider
      expect(find.textContaining('отклонён'), findsOneWidget);
    });

    test('snapshot semantics: route calculation retains immutable start point snapshot regardless of subsequent GPS moves', () async {
      final mock = MockDeviceLocationService()
        ..serviceEnabled = true
        ..currentPositionResult = UserLocationSnapshot(
          coordinate: const GeoCoord(59.9310, 30.3600), // Moscow station
          timestamp: DateTime.now(),
        );

      final locationProvider = LocationProvider(locationService: mock);
      final routingProvider = RoutingProvider(
        locationService: LocationService(),
        mapKitService: MapKitService(),
      );

      final snapshot = await locationProvider.requestLocationAndLocate();
      expect(snapshot, isNotNull);

      final startSnapshot = RoutePointModel(
        id: 'user_location',
        title: 'Моё местоположение',
        subtitle: '59.9310, 30.3600',
        latitude: snapshot!.coordinate.latitude,
        longitude: snapshot.coordinate.longitude,
        isPreset: false,
      );
      routingProvider.setStartPoint(startSnapshot);

      expect(routingProvider.startPoint.latitude, 59.9310);
      expect(routingProvider.startPoint.longitude, 30.3600);

      // Now simulate device coordinates updating in provider
      mock.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.9500, 30.4000), // User moved
        timestamp: DateTime.now(),
      );
      await locationProvider.requestLocationAndLocate();

      // Routing provider start point remains unchanged (immutable snapshot semantics)
      expect(routingProvider.startPoint.latitude, 59.9310);
      expect(routingProvider.startPoint.longitude, 30.3600);
      expect(routingProvider.startPoint.id, 'user_location');
    });
  });
}
