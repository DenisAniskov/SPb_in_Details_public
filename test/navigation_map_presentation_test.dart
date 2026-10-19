import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';

import 'off_route_reroute_test.dart' show threeLegRoute;

void main() {
  test('navigation emphasizes current leg and preserves native snapshots', () {
    final route = threeLegRoute().immutableSnapshot();
    final items = navigationMapLegs(route, currentLegIndex: 0).toList();
    expect(items.map((item) => item.role), [
      NavigationMapLegRole.current,
      NavigationMapLegRole.upcoming,
      NavigationMapLegRole.upcoming,
    ]);
    expect(items.first.leg, same(route.legs.first));
    expect(items.last.leg.geometryPoints, same(route.legs.last.geometryPoints));
    expect(
      () => items.first.leg.geometryPoints.clear(),
      throwsUnsupportedError,
    );
  });

  test('arrival marks visited stop before manual next-leg continuation', () {
    final route = threeLegRoute();
    final waiting = navigationMapLegs(
      route,
      currentLegIndex: 0,
      completedStops: 1,
    ).toList();
    expect(waiting.first.role, NavigationMapLegRole.completed);
    expect(waiting[1].role, NavigationMapLegRole.upcoming);
    final continued = navigationMapLegs(
      route,
      currentLegIndex: 1,
      completedStops: 1,
    ).toList();
    expect(continued[1].role, NavigationMapLegRole.current);
    final completed = navigationMapLegs(
      route,
      currentLegIndex: 2,
      completedStops: 3,
    );
    expect(
      completed.every((item) => item.role == NavigationMapLegRole.completed),
      isTrue,
    );
  });

  test(
    'disconnected reroute legs remain separate, with replacement endpoint',
    () {
      final original = threeLegRoute();
      final replacement = RouteLegModel(
        fromTitle: 'Новый старт',
        toTitle: original.legs[1].toTitle,
        distanceMeters: 100,
        durationSeconds: 80,
        geometryPoints: const [GeoCoord(60.01, 30.02), GeoCoord(60.02, 30.03)],
      );
      final route = PedestrianRouteModel(
        distanceMeters: 200,
        durationSeconds: 160,
        geometryPoints: const [],
        steps: const [],
        legs: [original.legs.first, replacement, original.legs.last],
      );
      final items = navigationMapLegs(
        route,
        currentLegIndex: 1,
        completedStops: 1,
      ).toList();
      expect(items[1].leg.geometryPoints, same(replacement.geometryPoints));
      expect(items[1].leg.geometryPoints.last.latitude, 60.02);
      expect(routePolylineGeometries(route).toList(), [
        original.legs.first.geometryPoints,
        replacement.geometryPoints,
        original.legs.last.geometryPoints,
      ]);
    },
  );

  test('ending navigation restores planned map appearance', () {
    final route = threeLegRoute();
    expect(
      navigationMapLegs(route)
          .every((item) => item.role == NavigationMapLegRole.planned),
      isTrue,
    );
  });
}
