// Explicit evidence replay, excluded from the default test/ directory.
// The files are captured real staging HTTP responses on recorded OSM geometry.
// This is NOT a native MapKit/device integration test.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/puddle_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/ui/controllers/guided_walk_environment_coordinator.dart';

const directory = String.fromEnvironment('C10_VALIDATION_DIR');
dynamic read(String filename) =>
    jsonDecode(File('$directory/$filename').readAsStringSync());

class CapturedShade implements BaseShadeAnalysisService {
  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async => ShadeAnalysisModel.tryFromJson(read('live_shade.json'))!;
}

class CapturedPuddle implements BasePuddleAnalysisService {
  @override
  Future<PuddleAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async => PuddleAnalysisModel.tryFromJson(read('live_puddle.json'))!;
}

class CapturedPollen implements BasePollenAnalysisService {
  @override
  Future<PollenAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async => PollenAnalysisModel.tryFromJson(read('live_pollen.json'))!;
}

/// Recorded OSM proxy adapter, never an Android MapKit measurement.
class CapturedOsmRoute extends MapKitService {
  CapturedOsmRoute(this.route);
  final PedestrianRouteModel route;
  @override
  void cancel() {}
  @override
  Future<PedestrianRouteModel> calculateBoundedWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
    required NativeWalkRequestBudget requestBudget,
  }) async {
    requestBudget.consume();
    return route;
  }
}

void main() {
  test('captured live Railway responses pass Flutter parsers and C7.4 gate on documented OSM proxy', () async {
    expect(
      directory,
      isNotEmpty,
      reason: 'Pass --dart-define=C10_VALIDATION_DIR=<artifact folder>',
    );
    final request = read('live_environment_request_osm_proxy.json') as Map;
    final leg = (request['legs'] as List).single as Map;
    final points = (leg['geometry'] as List)
        .map(
          (p) => GeoCoord(
            (p['latitude'] as num).toDouble(),
            (p['longitude'] as num).toDouble(),
          ),
        )
        .toList();
    final seconds = (leg['walking_duration_seconds'] as num).ceil();
    final route = PedestrianRouteModel(
      distanceMeters: 147.3,
      durationSeconds: seconds,
      geometryPoints: points,
      steps: const [],
      placesCount: 1,
      legs: [
        RouteLegModel(
          fromTitle: 'Дворцовая площадь (OSM proxy)',
          toTitle: 'Эрмитаж (OSM proxy)',
          distanceMeters: 147.3,
          durationSeconds: seconds,
          geometryPoints: points,
        ),
      ],
    );
    final routing = RoutingProvider(
      shadeAnalysisService: CapturedShade(),
      mapKitService: CapturedOsmRoute(route),
    );
    final catalog = read('live_catalog.json') as Map;
    final place = (catalog['items'] as List).firstWhere(
      (p) => p['catalog_key'] == 'hermitage-winter-palace',
    );
    routing.setProposedWalk([
      PlaceModel.fromJson(Map<String, dynamic>.from(place as Map)),
    ]);
    await routing.buildWalkRoute();
    final navigation = NavigationProvider(routingProvider: routing);
    final puddle = PuddleAssessmentProvider(
      CapturedPuddle(),
      routing: routing,
      navigation: navigation,
    );
    final pollen = PollenAssessmentProvider(
      CapturedPollen(),
      routing: routing,
      navigation: navigation,
    );
    final recommendations = ContextRecommendationProvider(
      routing: routing,
      navigation: navigation,
      puddle: puddle,
      pollen: pollen,
    );
    final coordinator = GuidedWalkEnvironmentCoordinator(
      routing: routing,
      navigation: navigation,
      recommendations: recommendations,
      puddle: puddle,
      pollen: pollen,
    );
    addTearDown(() {
      coordinator.dispose();
      recommendations.dispose();
      puddle.dispose();
      pollen.dispose();
      navigation.dispose();
      routing.dispose();
    });
    coordinator.selectDeparture(
      DateTime.parse(request['departure_at'] as String),
    );
    await coordinator.assess();
    final report = coordinator.report;
    expect(report, isNotNull);
    expect(report!.shade.data!.status, ShadeStatus.available);
    expect(report.puddle.data!.coverageShare, 0);
    expect(report.puddle.data!.riskIndex, isNull);
    expect(report.pollen.data!.species, hasLength(6));
    expect(
      report.pollen.data!.species.every((s) => s.meanConcentration == 0),
      true,
    );
    expect(report.context.shade, isNotNull);
    expect(report.context.pollen, isNotNull);
    expect(report.recommendations, isNotEmpty);
    expect(navigation.locksPlanning, false);
    expect(identical(routing.currentRoute, report.route), true);
  });
}
