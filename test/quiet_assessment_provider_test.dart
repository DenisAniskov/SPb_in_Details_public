import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/quiet_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';

import 'off_route_reroute_test.dart' show FakeRouteService;

const _p0 = GeoCoord(59.9300, 30.3100);
const _v0 = GeoCoord(59.9435, 30.3200);
const _p1 = GeoCoord(59.9525, 30.3270);
const _p2 = GeoCoord(59.9705, 30.3400);

final _departure = DateTime(2026, 10, 17, 14);

PedestrianRouteModel _walkRoute({GeoCoord first = _p0}) {
  final legs = [
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'POI 1',
      distanceMeters: 2500,
      durationSeconds: 1800,
      geometryPoints: [first, _v0, _p1],
      visitMinutes: 15,
    ),
    const RouteLegModel(
      fromTitle: 'POI 1',
      toTitle: 'Финиш',
      distanceMeters: 2000,
      durationSeconds: 1440,
      geometryPoints: [_p1, _p2],
    ),
  ];
  return PedestrianRouteModel(
    distanceMeters: legs.fold(0.0, (sum, leg) => sum + leg.distanceMeters),
    durationSeconds: legs.fold(0, (sum, leg) => sum + leg.durationSeconds),
    geometryPoints: [first, _v0, _p1, _p2],
    steps: const [],
    legs: legs,
    placesCount: 2,
  );
}

QuietAnalysisModel _analysis({double index = 0.35}) => QuietAnalysisModel(
  status: QuietStatus.available,
  estimate: true,
  confidence: 'low',
  method: 'relative_road_noise_exposure_proxy',
  methodVersion: 'c11_1',
  evaluatedAt: _departure,
  temporalModel: 'static_osm_network',
  trafficTimeModeled: false,
  routeLengthMeters: 4500,
  knownMeters: 4500,
  unknownMeters: 0,
  coverageShare: 1,
  roadNoiseExposureIndex: index,
  lowExposureShare: 0.6,
  majorRoadAdjacentShare: 0.1,
  meanNearestRoadDistanceM: 55,
  maxRoadClassNearby: 'secondary',
  legs: null,
  reasons: const [],
  limitations: const ['Не дБ.'],
  assumptions: const ['Прокси.'],
  sourceProvenance: const {'license': 'ODbL-1.0'},
  datasetVersion: 'c11_quiet_spb_central_v1',
  datasetSha256: 'a' * 64,
);

class _NoopShadeService implements BaseShadeAnalysisService {
  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async => throw StateError('shade not exercised');
}

class _RecordingQuietService implements BaseQuietAnalysisService {
  final List<DateTime> departures = [];
  final List<List<RouteLegModel>> legs = [];
  final List<List<int>> visits = [];
  Object? failure;
  Completer<QuietAnalysisModel>? pending;

  @override
  Future<QuietAnalysisModel> analyzeWalk({
    required DateTime assessedAt,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeLegs = false,
  }) async {
    departures.add(assessedAt);
    this.legs.add(legs);
    visits.add(visitMinutesAfterLeg);
    if (failure != null) throw failure!;
    if (pending != null) return pending!.future;
    return _analysis();
  }
}

void main() {
  late _RecordingQuietService service;
  late RoutingProvider routing;
  late NavigationProvider nav;
  late QuietAssessmentProvider provider;

  setUp(() {
    service = _RecordingQuietService();
    routing = RoutingProvider(shadeAnalysisService: _NoopShadeService())
      ..setProposedWalkForScenicTest(
        scenic: false,
        comparison: null,
        walkKind: WalkKind.normal,
        route: _walkRoute(),
      );
    nav = NavigationProvider(
      locationService: null,
      routingProvider: routing,
      routeService: FakeRouteService(),
    );
    provider = QuietAssessmentProvider(
      service,
      routing: routing,
      navigation: nav,
      now: () => _departure,
    );
  });

  tearDown(() {
    provider.dispose();
    nav.dispose();
    routing.dispose();
  });

  test('without a route nothing is sent', () async {
    final bare = QuietAssessmentProvider(
      service,
      routing: RoutingProvider(shadeAnalysisService: _NoopShadeService()),
      navigation: nav,
    );
    expect(bare.canAssess, isFalse);
    await bare.assess();
    expect(service.departures, isEmpty);
    bare.dispose();
  });

  test('the whole walk is analyzed with real legs and visit times', () async {
    await provider.assess();
    expect(provider.scope, QuietAssessmentScope.wholeWalk);
    expect(provider.analysis, isNotNull);
    expect(provider.failure, isNull);
    expect(service.departures.single, _departure);
    expect(service.legs.single, hasLength(2));
    expect(service.visits.single, [15, 0]);
    expect(provider.evaluatedFor, _departure);
    expect(provider.assessedRoute, same(routing.currentRoute));
    expect(provider.assessedSessionVersion, routing.navigationRouteVersion);
  });

  test('an in-flight response is discarded after clear', () async {
    service.pending = Completer<QuietAnalysisModel>();
    final future = provider.assess();
    expect(provider.isLoading, isTrue);
    provider.clear();
    service.pending!.complete(_analysis());
    await future;
    expect(provider.analysis, isNull);
    expect(provider.isLoading, isFalse);
  });

  test('a rebuilt route invalidates the published result', () async {
    final rebuiltRouting =
        RoutingProvider(
          mapKitService: _FakeMapKit(
            _walkRoute(first: const GeoCoord(59.9350, 30.3150)),
          ),
          shadeAnalysisService: _NoopShadeService(),
        )..setProposedWalkForScenicTest(
          scenic: false,
          comparison: null,
          walkKind: WalkKind.normal,
          route: _walkRoute(),
        );
    final rebuiltProvider = QuietAssessmentProvider(
      service,
      routing: rebuiltRouting,
      navigation: nav,
      now: () => _departure,
    );
    await rebuiltProvider.assess();
    expect(rebuiltProvider.analysis, isNotNull);
    await rebuiltRouting.buildRouteToExternalPoint(
      const ExternalMapPoint(
        title: 'Новая цель',
        latitude: 59.9500,
        longitude: 30.3300,
      ),
    );
    expect(rebuiltProvider.analysis, isNull);
    rebuiltProvider.dispose();
    rebuiltRouting.dispose();
  });

  test('a failure leaves the walk and lock untouched', () async {
    service.failure = const QuietAnalysisFailure(
      QuietAnalysisFailureKind.serviceUnavailable,
      'Оценка тишины сейчас недоступна. Обычная навигация работает.',
    );
    final blueprint = routing.currentRoute;
    await provider.assess();
    expect(provider.analysis, isNull);
    expect(provider.failure, isNotNull);
    expect(provider.failure!.message, contains('Обычная навигация работает'));
    expect(routing.currentRoute, same(blueprint));
    expect(routing.navigationLocked, isFalse);
  });

  test('adoption requires the exact route and exposes provenance', () async {
    await provider.assess();
    final target = QuietAssessmentProvider(
      service,
      routing: routing,
      navigation: nav,
    );
    expect(target.adoptWholeWalkAssessmentFrom(provider), isTrue);
    expect(target.analysis, same(provider.analysis));
    expect(target.assessedRoute, same(routing.currentRoute));
    expect(
      service.departures,
      hasLength(1),
      reason: 'adoption is not a request',
    );
    target.dispose();
  });
}

class _FakeMapKit extends MapKitService {
  _FakeMapKit(this.route);
  final PedestrianRouteModel route;

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async => route;
}
