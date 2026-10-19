import 'guided_walk_test_helpers.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/location_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/start_point_selector_dialog.dart';
import 'package:smart_navigator_spb/ui/widgets/my_location_button.dart';

import 'location_foundation_test.dart' show MockDeviceLocationService;
import 'smart_walk_audit_test.dart' as walk;

UserLocationSnapshot fix({
  double lat = 59.935,
  double lon = 30.325,
  Duration age = Duration.zero,
  bool cached = false,
}) => UserLocationSnapshot(
  coordinate: GeoCoord(lat, lon),
  timestamp: DateTime.now().subtract(age),
  isCached: cached,
);

class PendingDevice extends MockDeviceLocationService {
  final result = Completer<UserLocationSnapshot>();
  int fixes = 0;
  int checks = 0;
  @override
  Future<LocationPermissionStatus> checkPermission() async {
    checks++;
    return checkPermissionResult;
  }

  @override
  Future<UserLocationSnapshot> getCurrentPosition({
    Duration timeLimit = const Duration(seconds: 10),
  }) {
    fixes++;
    return result.future;
  }
}

class OrdinaryAdapter extends walk.NativeRouteAdapter {
  @override
  Future<PedestrianRouteModel> calculatePedestrianRoute({
    required RoutePointModel startPoint,
    required PlaceModel destination,
  }) async {
    calls.add((startPoint, [destination]));
    return walk.route(120, 1);
  }
}

class SnapshotRepository extends walk.PendingRepository {
  double? longitude;
  @override
  Future<AutoWalkProposalResponseModel> proposeWalk({
    required double startLatitude,
    required double startLongitude,
    required int timeBudgetMinutes,
    List<PlaceCategoryEnum>? categories,
    bool preferUnusual = false,
    int maxPlaces = 6,
  }) {
    longitude = startLongitude;
    return super.proposeWalk(
      startLatitude: startLatitude,
      startLongitude: startLongitude,
      timeBudgetMinutes: timeBudgetMinutes,
      categories: categories,
      preferUnusual: preferUnusual,
      maxPlaces: maxPlaces,
    );
  }
}

void main() {
  test('initial phase idle; cached fix cannot become route input', () async {
    final device = MockDeviceLocationService()
      ..checkPermissionResult = LocationPermissionStatus.grantedPrecise
      ..lastKnownPositionResult = fix(cached: true);
    final location = LocationProvider(locationService: device);
    addTearDown(location.dispose);
    expect(location.state.phase, LocationPhase.idle);
    await location.checkPermissionStatus();
    expect(location.lastKnownLocation!.isCached, true);
    expect(location.createUserLocationRoutePoint(), isNull);
  });

  for (final sample in ['stale', 'cached', 'future', 'invalid']) {
    test('rejects $sample fix instead of routing it as current', () async {
      final device = MockDeviceLocationService()
        ..currentPositionResult = switch (sample) {
          'stale' => fix(age: const Duration(minutes: 20)),
          'cached' => fix(cached: true),
          'future' => fix(age: const Duration(minutes: -20)),
          _ => fix(lat: double.nan),
        };
      final location = LocationProvider(locationService: device);
      addTearDown(location.dispose);
      expect(await location.requestLocationAndLocate(), isNull);
      expect(location.state.phase, LocationPhase.unavailable);
      expect(location.createUserLocationRoutePoint(), isNull);
    });
  }

  test('timeout never falls back to last known position', () async {
    final device = MockDeviceLocationService()
      ..checkPermissionResult = LocationPermissionStatus.grantedPrecise
      ..lastKnownPositionResult = fix(cached: true)
      ..currentPositionException = TimeoutException('secret latitude 59.999');
    final location = LocationProvider(locationService: device);
    addTearDown(location.dispose);
    await location.checkPermissionStatus();
    expect(await location.requestLocationAndLocate(), isNull);
    expect(location.lastKnownLocation, isNull);
    expect(location.errorMessage, isNot(contains('59.999')));
    expect(location.isLocating, false);
  });

  test('approximate permission remains explicit in current start', () async {
    final device = MockDeviceLocationService()
      ..requestPermissionResult = LocationPermissionStatus.grantedCoarse;
    final location = LocationProvider(locationService: device);
    addTearDown(location.dispose);
    await location.requestLocationAndLocate();
    expect(location.permissionStatus, LocationPermissionStatus.grantedCoarse);
    expect(
      location.createUserLocationRoutePoint()!.subtitle,
      contains('Приблизительная'),
    );
  });

  test('double tap shares one bounded acquisition', () async {
    final device = PendingDevice();
    final location = LocationProvider(locationService: device);
    addTearDown(location.dispose);
    final first = location.requestLocationAndLocate();
    final second = location.requestLocationAndLocate();
    await Future<void>.delayed(Duration.zero);
    expect(device.fixes, 1);
    expect(location.state.phase, LocationPhase.locating);
    device.result.complete(fix());
    expect(await first, isNotNull);
    expect(await second, isNotNull);
  });

  test('late fix after disposal is discarded without notification', () async {
    final device = PendingDevice();
    final location = LocationProvider(locationService: device);
    final pending = location.requestLocationAndLocate();
    await Future<void>.delayed(Duration.zero);
    location.dispose();
    device.result.complete(fix());
    expect(await pending, isNull);
  });

  test('background discards pending fix; resume rechecks revoked permission silently', () async {
    final device = PendingDevice();
    final location = LocationProvider(locationService: device);
    addTearDown(location.dispose);
    final pending = location.requestLocationAndLocate();
    await Future<void>.delayed(Duration.zero);
    location.setForeground(false);
    expect(location.isForeground, false);
    device.result.complete(fix());
    expect(await pending, isNull);
    expect(location.lastKnownLocation, isNull);
    device.checkPermissionResult = LocationPermissionStatus.denied;
    location.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(device.checks, 1);
    expect(location.permissionStatus, LocationPermissionStatus.denied);
    expect(location.createUserLocationRoutePoint(), isNull);
  });

  test('service switched off during acquisition rejects fix', () async {
    final device = PendingDevice();
    final location = LocationProvider(locationService: device);
    addTearDown(location.dispose);
    final pending = location.requestLocationAndLocate();
    await Future<void>.delayed(Duration.zero);
    device.serviceEnabled = false;
    device.result.complete(fix());
    expect(await pending, isNull);
    expect(location.permissionStatus, LocationPermissionStatus.serviceDisabled);
  });

  test('ordinary and manual adapters receive stable selected coordinates despite later fixes', () async {
    final device = MockDeviceLocationService()..currentPositionResult = fix();
    final location = LocationProvider(locationService: device);
    final native = OrdinaryAdapter();
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(location.dispose);
    addTearDown(routing.dispose);
    await location.requestLocationAndLocate();
    routing.setStartPoint(location.createUserLocationRoutePoint()!);
    device.currentPositionResult = fix(lat: 60, lon: 31);
    await location.requestLocationAndLocate();
    await routing.buildRouteTo(walk.poi(1));
    routing.addPlaceToWalk(walk.poi(1));
    routing.addPlaceToWalk(walk.poi(2));
    await routing.buildWalkRoute();
    expect(native.calls.length, 2);
    for (final call in native.calls) {
      expect(call.$1.latitude, 59.935);
      expect(call.$1.longitude, 30.325);
    }
  });

  testWidgets(
    'Smart Walk API and native refinement receive GPS snapshot, not later device fix',
    (tester) async {
      final device = MockDeviceLocationService()..currentPositionResult = fix();
      final location = LocationProvider(locationService: device);
      addTearDown(location.dispose);
      final native = walk.NativeRouteAdapter();
      final routing = RoutingProvider(mapKitService: native);
      await location.requestLocationAndLocate();
      routing.setStartPoint(location.createUserLocationRoutePoint()!);
      final repository = SnapshotRepository();
      await walk.mountWizard(tester, repository, routing);
      await guidedToInterests(tester);
      await walk.tapVisible(tester, find.text('Сформировать прогулку'));
      expect(repository.parameters.single.$4, 59.935);
      expect(repository.longitude, 30.325);
      device.currentPositionResult = fix(lat: 60, lon: 31);
      await location.requestLocationAndLocate();
      repository.pending.single.complete(walk.proposal());
      await tester.pumpAndSettle();
      await walk.tapVisible(tester, find.text('Построить прогулку'));
      await tester.pumpAndSettle();
      expect(native.calls.single.$1.latitude, 59.935);
      expect(native.calls.single.$1.longitude, 30.325);
      await guidedPublish(tester);
      expect(routing.hasRoute, true);
    },
  );

  for (final close in [false, true]) {
    testWidgets(
      close
          ? 'closed selector discards late location'
          : 'manual start change wins over pending GPS selection',
      (tester) async {
        final device = PendingDevice();
        final location = LocationProvider(locationService: device);
        final routing = RoutingProvider();
        addTearDown(location.dispose);
        addTearDown(routing.dispose);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<LocationProvider>.value(value: location),
              ChangeNotifierProvider<RoutingProvider>.value(value: routing),
            ],
            child: const MaterialApp(
              home: Scaffold(body: StartPointSelectorDialog()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Моё местоположение'));
        await tester.pump();
        routing.setCustomStartPoint(60, 31);
        if (close) await tester.pumpWidget(const SizedBox());
        device.result.complete(fix());
        await tester.pumpAndSettle();
        expect(routing.startPoint.latitude, 60);
        expect(routing.startPoint.longitude, 31);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('successful GPS retry replaces old error notification', (
    tester,
  ) async {
    final device = MockDeviceLocationService()
      ..requestPermissionResult = LocationPermissionStatus.denied;
    final location = LocationProvider(locationService: device);
    final routing = RoutingProvider();
    addTearDown(location.dispose);
    addTearDown(routing.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LocationProvider>.value(value: location),
          ChangeNotifierProvider<RoutingProvider>.value(value: routing),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const StartPointSelectorDialog(),
                ),
                child: const Text('Открыть старт'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть старт'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Моё местоположение'));
    await tester.pumpAndSettle();
    expect(find.textContaining('отклонён'), findsOneWidget);
    device.requestPermissionResult = LocationPermissionStatus.grantedPrecise;
    await tester.tap(find.text('Моё местоположение'));
    await tester.pumpAndSettle();
    expect(routing.startPoint.id, 'user_location');
    expect(find.textContaining('отклонён'), findsNothing);
    expect(find.text('Точка старта: Моё местоположение'), findsOneWidget);
  });

  testWidgets(
    'production location button fits narrow dark screen and disables repeated taps',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final device = PendingDevice();
      final location = LocationProvider(locationService: device);
      addTearDown(location.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<LocationProvider>.value(
          value: location,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: Consumer<LocationProvider>(
                  builder: (_, p, _) => MyLocationButton(
                    isLocating: p.isLocating,
                    onPressed: () {
                      p.requestLocationAndLocate();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.my_location));
      await tester.pump();
      expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNull,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(device.fixes, 1);
      device.result.complete(fix());
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.my_location), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('manifest contains only foreground location permissions', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, contains('android.permission.ACCESS_FINE_LOCATION'));
    expect(manifest, contains('android.permission.ACCESS_COARSE_LOCATION'));
    expect(
      manifest,
      isNot(contains('android.permission.ACCESS_BACKGROUND_LOCATION')),
    );
    expect(manifest, isNot(contains('android.permission.FOREGROUND_SERVICE')));
  });
}
