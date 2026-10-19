import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/scenic/scenic_dataset.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';

import 'smart_walk_audit_test.dart' show poi;

/// The normal MapKit walk already follows a real verified scenic feature.
PedestrianRouteModel _onPathWalk(String toTitle, int visitMinutes) {
  final feature = spbScenicDataset.features.firstWhere(
    (candidate) =>
        candidate.name == 'набережная Зимней канавки' &&
        (candidate.line?.length ?? 0) >= 5,
  );
  final geometry = feature.line!;
  final meters = RouteProjectionUtils.polylineLengthMeters(geometry);
  return PedestrianRouteModel(
    distanceMeters: meters,
    durationSeconds: 100,
    geometryPoints: geometry,
    steps: const [],
    legs: [
      RouteLegModel(
        fromTitle: 'Старт',
        toTitle: toTitle,
        distanceMeters: meters,
        durationSeconds: 100,
        geometryPoints: geometry,
        visitMinutes: visitMinutes,
      ),
    ],
    placesCount: 1,
  );
}

class _OnPathMapKit extends MapKitService {
  int walkCalls = 0;
  int scenicPointCalls = 0;
  Completer<void>? gate;

  @override
  Future<PedestrianRouteModel> calculateBoundedWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
    required NativeWalkRequestBudget requestBudget,
  }) async {
    walkCalls++;
    requestBudget.consume();
    if (gate != null) await gate!.future;
    final place = places.single;
    return _onPathWalk(place.title, place.recommendedVisitMinutes);
  }

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    scenicPointCalls++;
    throw StateError('zero-detour must not request an extra native route');
  }

  @override
  void cancel() {}
}

void main() {
  test(
    'the provider enables zero-detour recognition for a scenic walk',
    () async {
      final native = _OnPathMapKit();
      final routing = RoutingProvider(mapKitService: native);
      routing.setProposedWalk([poi(1)], timeBudgetMinutes: 120, scenic: true);

      await routing.buildWalkRoute();

      expect(native.walkCalls, 1);
      expect(native.scenicPointCalls, 0);
      expect(routing.currentRoute, isNotNull);
      expect(routing.currentRoute!.walkKind, WalkKind.scenic);
      expect(routing.routeComparison, isNotNull);
      expect(routing.routeComparison!.extraWalkingSeconds, 0);
      expect(routing.routeComparison!.extraDistanceMeters, 0);
      expect(routing.scenicFallbackMessage, isNull);
      expect(routing.currentRoute!.legs.single.scenic, isNotNull);
    },
  );

  test('a normal walk request does not gain scenic metadata', () async {
    final native = _OnPathMapKit();
    final routing = RoutingProvider(mapKitService: native);
    routing.setProposedWalk([poi(1)], timeBudgetMinutes: 120);

    await routing.buildWalkRoute();

    expect(native.walkCalls, 1);
    expect(native.scenicPointCalls, 0);
    expect(routing.currentRoute!.walkKind, WalkKind.normal);
    expect(routing.currentRoute!.legs.single.scenic, isNull);
    expect(routing.routeComparison, isNull);
  });

  test('a route that changed during the native call cannot publish scenic '
      'metadata from the stale result', () async {
    final native = _OnPathMapKit()..gate = Completer<void>();
    final routing = RoutingProvider(mapKitService: native);
    routing.setProposedWalk([poi(1)], timeBudgetMinutes: 120, scenic: true);

    final pending = routing.buildWalkRoute();
    // A new plan supersedes the in-flight build before MapKit answers.
    routing.setProposedWalk([poi(2)], timeBudgetMinutes: 120, scenic: true);
    native.gate!.complete();
    await pending;

    expect(native.walkCalls, 1);
    expect(native.scenicPointCalls, 0);
    expect(routing.currentRoute, isNull);
    expect(routing.routeComparison, isNull);
    expect(routing.scenicFallbackMessage, isNull);
  });
}
