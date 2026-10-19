import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';
import 'package:smart_navigator_spb/services/quiet_route_engine.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/ui/controllers/guided_walk_controller.dart';

import 'smart_walk_audit_test.dart' show poi;

class _NoopShade implements BaseShadeAnalysisService {
  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async => throw StateError('shade not exercised');
}

class _QuietService implements BaseQuietAnalysisService {
  int normalCalls = 0;
  int candidateCalls = 0;

  @override
  Future<QuietAnalysisModel> analyzeWalk({
    required DateTime assessedAt,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeLegs = false,
  }) async {
    final isCandidate = normalCalls > 0;
    if (isCandidate) {
      candidateCalls++;
    } else {
      normalCalls++;
    }
    final distance = isCandidate ? 1100.0 : 1000.0;
    return QuietAnalysisModel(
      status: QuietStatus.available,
      estimate: true,
      confidence: 'low',
      method: 'relative_road_noise_exposure_proxy',
      methodVersion: 'c11_1',
      evaluatedAt: assessedAt,
      temporalModel: 'static_osm_network',
      trafficTimeModeled: false,
      routeLengthMeters: distance,
      knownMeters: distance,
      unknownMeters: 0,
      coverageShare: 1,
      roadNoiseExposureIndex: isCandidate ? 0.30 : 0.55,
      lowExposureShare: 0.6,
      majorRoadAdjacentShare: 0.1,
      meanNearestRoadDistanceM: 50,
      maxRoadClassNearby: 'secondary',
      legs: null,
      reasons: const [],
      limitations: const ['Не дБ.'],
      assumptions: const ['Прокси.'],
      sourceProvenance: const {'license': 'ODbL-1.0'},
      datasetVersion: 'c11_quiet_spb_central_v1',
      datasetSha256: 'a' * 64,
    );
  }
}

class _QuietNative extends MapKitService {
  _QuietNative({this.charge = 1});

  final int charge;
  int variantCalls = 0;
  final List<NativeWalkRequestBudget> budgets = [];

  @override
  Future<PedestrianRouteModel> calculateBoundedWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
    required NativeWalkRequestBudget requestBudget,
  }) async {
    budgets.add(requestBudget);
    for (var i = 0; i < charge; i++) {
      requestBudget.consume();
    }
    final destination = places.last;
    final geometry = [
      GeoCoord(startPoint.latitude, startPoint.longitude),
      GeoCoord(destination.routeLatitude, destination.routeLongitude),
    ];
    const distance = 1000.0;
    return PedestrianRouteModel(
      distanceMeters: distance,
      durationSeconds: 600,
      geometryPoints: geometry,
      steps: const [],
      placesCount: places.length,
      legs: [
        RouteLegModel(
          fromTitle: startPoint.title,
          toTitle: destination.title,
          distanceMeters: distance,
          durationSeconds: 600,
          geometryPoints: geometry,
          visitMinutes: destination.recommendedVisitMinutes,
        ),
      ],
    );
  }

  @override
  Future<List<RouteLegModel>> requestLegVariants({
    required double fromLat,
    required double fromLon,
    required String fromTitle,
    required double toLat,
    required double toLon,
    required String toTitle,
    NativeWalkRequestBudget? requestBudget,
    int legIndex = 0,
    int? visitMinutes,
    int maxVariants = 2,
  }) async {
    variantCalls++;
    requestBudget?.consume();
    final quietGeometry = [
      GeoCoord(fromLat, fromLon),
      GeoCoord((fromLat + toLat) / 2 + 0.0008, (fromLon + toLon) / 2),
      GeoCoord(toLat, toLon),
    ];
    return [
      RouteLegModel(
        fromTitle: fromTitle,
        toTitle: toTitle,
        distanceMeters: 1000,
        durationSeconds: 600,
        geometryPoints: [GeoCoord(fromLat, fromLon), GeoCoord(toLat, toLon)],
        visitMinutes: visitMinutes,
      ),
      RouteLegModel(
        fromTitle: fromTitle,
        toTitle: toTitle,
        distanceMeters: 1100,
        durationSeconds: 650,
        geometryPoints: quietGeometry,
        visitMinutes: visitMinutes,
      ),
    ];
  }

  @override
  void cancel() {}
}

void main() {
  test(
    'guided wizard finds, verifies and explicitly selects a quiet route',
    () async {
      final native = _QuietNative();
      final quiet = _QuietService();
      final source = RoutingProvider(
        mapKitService: native,
        shadeAnalysisService: _NoopShade(),
        quietAnalysisService: quiet,
      );
      final nav = NavigationProvider(routingProvider: source);
      final controller = GuidedWalkController(
        source: source,
        repository: PlacesRepository(),
        navigation: nav,
        quietService: quiet,
      );
      addTearDown(() {
        controller.dispose();
        nav.dispose();
        source.dispose();
      });
      controller.setMode(GuidedWalkMode.manual);
      controller.routing.addPlaceToWalk(poi(1));
      await controller.buildPreview();
      expect(controller.routing.verifiedQuietRoute, isNotNull);
      expect(controller.routing.quietDecision!.offersAlternative, isTrue);
      expect(
        controller.routing.quietDecision!.improvement,
        greaterThanOrEqualTo(0.05),
      );
      expect(
        controller.routing.quietDecision!.candidateRoute!.walkKind.name,
        'quiet',
      );
      expect(native.variantCalls, 1);
      expect(native.budgets.single.requests, lessThanOrEqualTo(12));
      expect(quiet.normalCalls, 1);
      expect(quiet.candidateCalls, 1);

      expect(controller.routeChoiceConfirmed, isFalse);
      expect(controller.canContinueScenic, isFalse);
      controller.selectRoute(WalkKind.quiet);
      expect(controller.selectedKind, WalkKind.quiet);
      expect(controller.routing.currentRoute!.walkKind, WalkKind.quiet);
      expect(controller.canContinueScenic, isTrue);
    },
  );

  test(
    'exhausted shared budget leaves the normal route and an honest reason',
    () async {
      final native = _QuietNative(charge: 12);
      final quiet = _QuietService();
      final source = RoutingProvider(
        mapKitService: native,
        shadeAnalysisService: _NoopShade(),
        quietAnalysisService: quiet,
      );
      final nav = NavigationProvider(routingProvider: source);
      final controller = GuidedWalkController(
        source: source,
        repository: PlacesRepository(),
        navigation: nav,
        quietService: quiet,
      );
      addTearDown(() {
        controller.dispose();
        nav.dispose();
        source.dispose();
      });
      controller.setMode(GuidedWalkMode.manual);
      controller.routing.addPlaceToWalk(poi(1));
      await controller.buildPreview();

      expect(controller.routing.verifiedQuietRoute, isNull);
      expect(
        controller.routing.quietDecision?.fallbackReason,
        QuietFallbackReason.insufficientBudget,
      );
      expect(native.variantCalls, 0);
      expect(controller.routing.currentRoute!.walkKind.name, 'normal');
    },
  );
}
