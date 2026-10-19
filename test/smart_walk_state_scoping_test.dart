import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';

import 'smart_walk_audit_test.dart' show poi;

/// Smart Walk parameter scoping (Controller Round 2, I-1).
///
/// The Smart Walk budget/category/unusual preferences belong to the proposal
/// that created them. Leaving that planning context — an ordinary POI route,
/// an external route, a cleared route — must reset them; otherwise a later
/// manual walk silently inherits a stale budget and starts dropping stops.
/// The place list itself is the user's editing scratchpad and legitimately
/// survives route dismissal, so every scenario below uses ONE long-lived
/// RoutingProvider and rebuilds manual walks on top of it.
class FixedRoutes extends MapKitService {
  // 10 min of walking per leg: with three 20-minute visits a 60-minute
  // budget cannot hold all three places, which forces the budget-driven
  // removal path that makes stale state observable.
  @override
  void cancel() {}

  @override
  Future<PedestrianRouteModel> calculateWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
  }) async {
    return _route(600 * places.length, places.length);
  }

  @override
  Future<PedestrianRouteModel> calculatePedestrianRoute({
    required RoutePointModel startPoint,
    required PlaceModel destination,
  }) async {
    return _route(600, 1);
  }

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    return _route(600, 1);
  }

  PedestrianRouteModel _route(int seconds, int count) => PedestrianRouteModel(
    distanceMeters: count * 750,
    durationSeconds: seconds,
    geometryPoints: const [GeoCoord(59.94, 30.31), GeoCoord(59.95, 30.31)],
    steps: const [],
    placesCount: count,
    legs: [
      RouteLegModel(
        fromTitle: 'Старт',
        toTitle: 'Финиш',
        distanceMeters: count * 750,
        durationSeconds: seconds,
        geometryPoints: const [GeoCoord(59.94, 30.31), GeoCoord(59.95, 30.31)],
      ),
    ],
  );
}

void main() {
  group('Smart Walk parameter scoping (I-1)', () {
    late RoutingProvider routing;

    setUp(() {
      routing = RoutingProvider(mapKitService: FixedRoutes());
    });

    tearDown(() {
      routing.dispose();
    });

    /// Applies a Smart Walk proposal: three places, 60-minute budget,
    /// category interests and unusual preference — then builds it. The
    /// budget forces one stop to be removed (90 min > 60 min).
    Future<void> applySmartWalk() async {
      routing.setProposedWalk(
        [poi(1), poi(2), poi(3)],
        reasons: const {
          1: ['Рядом'],
          2: ['Рядом'],
          3: ['Рядом'],
        },
        timeBudgetMinutes: 60,
        categories: {PlaceCategoryEnum.historyArchitecture},
        preferUnusual: true,
      );
      await routing.buildWalkRoute();
      expect(routing.walkBudgetMinutes, 60);
      expect(routing.walkPlaces.length, 2,
          reason: 'precondition: the budget removed one stop');
      expect(routing.budgetWarningMessage, isNotNull);
    }

    test('smart walk → ordinary POI route → manual walk has no stale budget',
        () async {
      await applySmartWalk();

      await routing.buildRouteTo(poi(9));

      expect(routing.walkBudgetMinutes, isNull);
      expect(routing.walkCategories, isEmpty);
      expect(routing.walkPreferUnusual, isFalse);

      routing.addPlaceToWalk(poi(4));
      await routing.buildWalkRoute();

      expect(routing.walkPlaces.length, 3,
          reason: 'a manual walk must not silently inherit the stale budget');
      expect(routing.budgetWarningMessage, isNull);
    });

    test('smart walk → external route → manual walk has no stale budget',
        () async {
      await applySmartWalk();

      await routing.buildRouteToExternalPoint(const ExternalMapPoint(
        title: 'Внешняя точка',
        latitude: 59.96,
        longitude: 30.33,
      ));

      expect(routing.walkPlaces, isEmpty);
      expect(routing.walkBudgetMinutes, isNull);
      expect(routing.walkCategories, isEmpty);
      expect(routing.walkPreferUnusual, isFalse);

      routing.addPlaceToWalk(poi(5));
      await routing.buildWalkRoute();

      expect(routing.walkPlaces.length, 1);
      expect(routing.budgetWarningMessage, isNull);
    });

    test('smart walk → clear route → manual walk has no stale budget',
        () async {
      await applySmartWalk();

      routing.clearRoute();

      expect(routing.walkBudgetMinutes, isNull);
      expect(routing.walkCategories, isEmpty);
      expect(routing.walkPreferUnusual, isFalse);
      expect(routing.walkPlaces, isNotEmpty,
          reason: 'the place list is the editing scratchpad and survives '
              'route dismissal');

      routing.addPlaceToWalk(poi(4));
      await routing.buildWalkRoute();

      expect(routing.walkPlaces.length, 3);
      expect(routing.budgetWarningMessage, isNull);
    });

    test('manual walk rebuild keeps the state that belongs to it', () async {
      routing.addPlaceToWalk(poi(1));
      routing.addPlaceToWalk(poi(2));
      routing.addPlaceToWalk(poi(3));

      await routing.buildWalkRoute();
      expect(routing.walkPlaces.length, 3);
      expect(routing.walkBudgetMinutes, isNull);

      await routing.buildWalkRoute();
      expect(routing.walkPlaces.length, 3,
          reason: 'rebuilding the same manual walk must not lose stops');
      expect(routing.walkBudgetMinutes, isNull);

      // An explicitly chosen budget belongs to THIS walk until the planning
      // context changes (documented «Бюджет сохраняется при изменении»).
      await routing.buildWalkRoute(timeBudgetMinutes: 60);
      expect(routing.walkBudgetMinutes, 60);
      expect(routing.walkPlaces.length, 2, reason: 'the budget applies');

      await routing.buildWalkRoute();
      expect(routing.walkBudgetMinutes, 60,
          reason: 'the same walk context keeps its explicit budget');
      expect(routing.walkPlaces.length, 2);
    });

    test('clearWalk resets everything including the place list', () async {
      await applySmartWalk();

      routing.clearWalk();

      expect(routing.walkPlaces, isEmpty);
      expect(routing.walkBudgetMinutes, isNull);
      expect(routing.walkCategories, isEmpty);
      expect(routing.walkPreferUnusual, isFalse);
      expect(routing.hasRoute, isFalse);
    });
  });
}
