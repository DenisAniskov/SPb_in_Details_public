import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/context_recommendation_provider.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/pollen_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/puddle_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/pollen_analysis_service.dart';
import 'package:smart_navigator_spb/services/puddle_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';

import 'context_recommendation_fixtures.dart';
import 'live_navigation_test.dart' show MockNavigationLocationService;

class _Memory implements GuestKeyValueStore {
  String? value;
  @override
  Future<String?> read(String key) async => value;
  @override
  Future<void> write(String key, String next) async => value = next;
}

class _Catalog extends PlacesRepository {
  final requests =
      <({Set<PlaceCategoryEnum> categories, bool? unusual, String? query})>[];
  final responses = <Completer<List<PlaceModel>>>[];
  bool deferred = false;
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) {
    requests.add((
      categories: {...?categories},
      unusual: isUnusual,
      query: searchQuery,
    ));
    if (!deferred) return Future.value([]);
    final response = Completer<List<PlaceModel>>();
    responses.add(response);
    return response.future;
  }

  @override
  Future<List<CategoryModel>> getCategories() async => [];
}

class _Native extends MapKitService {
  int calls = 0;
  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    calls++;
    throw StateError('C8.1 must not request native routing');
  }
}

class _Shade implements BaseShadeAnalysisService {
  int calls = 0;
  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async {
    calls++;
    return shadeFixture();
  }
}

class _Puddle implements BasePuddleAnalysisService {
  int calls = 0;
  @override
  Future<PuddleAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    calls++;
    return puddleHighFixture();
  }
}

class _Pollen implements BasePollenAnalysisService {
  int calls = 0;
  @override
  Future<PollenAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    calls++;
    return pollenConcentrationsFixture();
  }
}

const _place = PlaceModel(
  id: 1,
  catalogKey: 'museum',
  title: 'Музей',
  shortDescription: '',
  category: PlaceCategoryEnum.art,
  latitude: 59.93,
  longitude: 30.31,
  address: '',
);

PedestrianRouteModel _route() => const PedestrianRouteModel(
  distanceMeters: 500,
  durationSeconds: 360,
  geometryPoints: [GeoCoord(59.93, 30.31), GeoCoord(59.9345, 30.31)],
  steps: [],
  placesCount: 1,
  legs: [
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'Музей',
      distanceMeters: 500,
      durationSeconds: 360,
      geometryPoints: [GeoCoord(59.93, 30.31), GeoCoord(59.9345, 30.31)],
    ),
  ],
);

void main() {
  late _Memory memory;
  late _Catalog catalog;
  late GuestExperienceProvider guest;
  late _Native native;
  late _Shade shadeService;
  late _Puddle puddleService;
  late _Pollen pollenService;
  late RoutingProvider routing;
  late MockNavigationLocationService location;
  late NavigationProvider nav;
  late PuddleAssessmentProvider puddle;
  late PollenAssessmentProvider pollen;
  late ContextRecommendationProvider recommendations;

  GuestExperienceProvider restored() => GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: memory),
    repository: catalog,
    catalogScope: 'https://staging.example/api/v1',
  );

  setUp(() async {
    memory = _Memory();
    catalog = _Catalog();
    guest = restored();
    await guest.initialize();
    native = _Native();
    shadeService = _Shade();
    puddleService = _Puddle();
    pollenService = _Pollen();
    routing =
        RoutingProvider(
          mapKitService: native,
          shadeAnalysisService: shadeService,
        )..setProposedWalkForScenicTest(
          scenic: false,
          comparison: null,
          walkKind: WalkKind.normal,
          route: _route(),
        );
    location = MockNavigationLocationService();
    nav = NavigationProvider(
      locationService: location,
      routingProvider: routing,
      routeService: native,
    );
    puddle = PuddleAssessmentProvider(
      puddleService,
      routing: routing,
      navigation: nav,
    );
    pollen = PollenAssessmentProvider(
      pollenService,
      routing: routing,
      navigation: nav,
    );
    recommendations = ContextRecommendationProvider(
      routing: routing,
      navigation: nav,
      puddle: puddle,
      pollen: pollen,
      guest: guest,
    );
  });

  tearDown(() {
    recommendations.dispose();
    pollen.dispose();
    puddle.dispose();
    nav.dispose();
    routing.dispose();
    location.close();
    guest.dispose();
  });

  void noExtraRequests() {
    expect(native.calls, 0);
    expect(shadeService.calls, 0);
    expect(puddleService.calls, 0);
    expect(pollenService.calls, 0);
  }

  test(
    'restoring all preferences never starts an assessment or native route',
    () async {
      await guest.setCatalogPreferences(
        categories: {PlaceCategoryEnum.nature},
        preferUnusual: true,
      );
      await guest.setRecommendationPreference(RecommendationPreference.scenic);
      await guest.setShowRecommendations(false);
      final next = restored();
      await next.initialize();
      final panel = ContextRecommendationProvider(
        routing: routing,
        navigation: nav,
        guest: next,
      );
      expect(panel.preference, RecommendationPreference.scenic);
      expect(panel.panelVisible, isFalse);
      expect(catalog.requests, isEmpty);
      noExtraRequests();
      panel.dispose();
      next.dispose();
    },
  );

  test(
    'recommendation chips persist their preference without analysis',
    () async {
      recommendations.setPreference(RecommendationPreference.shade);
      await Future<void>.delayed(Duration.zero);
      final next = restored();
      await next.initialize();
      expect(next.recommendationPreference, RecommendationPreference.shade);
      expect(recommendations.preference, RecommendationPreference.shade);
      noExtraRequests();
      next.dispose();
    },
  );

  test('temporary hide keeps route and every completed model result', () async {
    await routing.assessShade(
      departure: DateTime(2026, 7, 1, 14),
      exploreAlternatives: false,
    );
    await puddle.assess();
    await pollen.assess();
    final route = routing.currentRoute;
    final shade = routing.shadeAnalysis;
    final wet = puddle.analysis;
    final pollen0 = pollen.analysis;
    recommendations.hideForCurrentWalk();
    expect(recommendations.panelVisible, isFalse);
    await guest.setRecommendationPreference(RecommendationPreference.scenic);
    expect(routing.currentRoute, same(route));
    expect(routing.shadeAnalysis, same(shade));
    expect(puddle.analysis, same(wet));
    expect(pollen.analysis, same(pollen0));
    expect(
      [
        shadeService.calls,
        puddleService.calls,
        pollenService.calls,
        native.calls,
      ],
      [1, 1, 1, 0],
    );
    recommendations.showForCurrentWalk();
    expect(recommendations.panelVisible, isTrue);
  });

  test(
    'ending a session restores temporary panel on the same retained plan',
    () async {
      final plan = routing.currentRoute;
      location.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.93, 30.31),
        timestamp: DateTime.now(),
      );
      recommendations.hideForCurrentWalk();
      await nav.startNavigation(plan!);
      expect(recommendations.panelVisible, isFalse);
      nav.stopNavigation();
      expect(routing.currentRoute, same(plan));
      expect(recommendations.panelVisible, isTrue);
      noExtraRequests();
    },
  );

  test('temporary hide is session local and new walk is shown', () {
    recommendations.hideForCurrentWalk();
    final nextPanel = ContextRecommendationProvider(
      routing: routing,
      navigation: nav,
      guest: guest,
    );
    expect(nextPanel.panelVisible, isTrue);
    nextPanel.dispose();
    routing.clearRoute();
    expect(recommendations.panelVisible, isTrue);
    noExtraRequests();
  });

  test(
    'permanent hiding and re-enabling survive provider recreation',
    () async {
      await guest.setShowRecommendations(false);
      var next = restored();
      await next.initialize();
      expect(next.showRecommendations, isFalse);
      next.dispose();
      await guest.setShowRecommendations(true);
      next = restored();
      await next.initialize();
      expect(next.showRecommendations, isTrue);
      next.dispose();
      noExtraRequests();
    },
  );

  test(
    'settings changes preserve active navigation route lock and status',
    () async {
      location.currentPositionResult = UserLocationSnapshot(
        coordinate: const GeoCoord(59.93, 30.31),
        timestamp: DateTime.now(),
      );
      await nav.startNavigation(routing.currentRoute!);
      final route = nav.state.route;
      final status = nav.status;
      recommendations.hideForCurrentWalk();
      await guest.setShowRecommendations(false);
      await guest.setRecommendationPreference(RecommendationPreference.shade);
      await guest.addFavorite(_place);
      expect(nav.state.route, same(route));
      expect(nav.status, status);
      expect(nav.locksPlanning, isTrue);
      expect(routing.navigationLocked, isTrue);
      noExtraRequests();
    },
  );

  test('guest catalog search and selection stay available without onboarding or account', () async {
    final places = PlacesProvider(repository: catalog, guest: guest);
    await Future<void>.delayed(Duration.zero);
    expect(guest.onboardingCompleted, isFalse);
    expect(places.status, PlacesStatus.success);
    places.setSearchQuery('музей');
    await places.loadPlaces();
    expect(catalog.requests.last.query, 'музей');
    places.selectPlace(_place);
    expect(places.selectedPlace, _place);
    expect(routing.addPlaceToWalk(_place), isTrue);
    noExtraRequests();
    places.dispose();
  });

  test(
    'restored catalog preferences apply to first existing repository request',
    () async {
      await guest.setCatalogPreferences(
        categories: {PlaceCategoryEnum.art},
        preferUnusual: true,
      );
      final places = PlacesProvider(repository: catalog, guest: guest);
      await Future<void>.delayed(Duration.zero);
      expect(catalog.requests, hasLength(1));
      expect(catalog.requests.single.categories, {PlaceCategoryEnum.art});
      expect(catalog.requests.single.unusual, isTrue);
      noExtraRequests();
      places.dispose();
    },
  );

  test('recommendation and favorite writes never reload map catalog', () async {
    final places = PlacesProvider(repository: catalog, guest: guest);
    await Future<void>.delayed(Duration.zero);
    await guest.setShowRecommendations(false);
    await guest.addFavorite(_place);
    await guest.completeOnboarding();
    expect(catalog.requests, hasLength(1));
    noExtraRequests();
    places.dispose();
  });

  test('restored preference filters retain stale-response guard and error handling', () async {
    catalog.deferred = true;
    final places = PlacesProvider(repository: catalog, guest: guest);
    await guest.setCategories({PlaceCategoryEnum.art});
    expect(catalog.responses, hasLength(2));
    catalog.responses.last.complete([_place]);
    await Future<void>.delayed(Duration.zero);
    catalog.responses.first.complete([]);
    await Future<void>.delayed(Duration.zero);
    expect(places.places, [_place]);
    await guest.setPreferUnusual(true);
    catalog.responses.last.completeError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
    expect(places.hasError, isTrue);
    expect(guest.categories, {PlaceCategoryEnum.art});
    noExtraRequests();
    places.dispose();
  });

  test(
    'map category choices persist and reset filters is one atomic reload',
    () async {
      final places = PlacesProvider(repository: catalog, guest: guest);
      await Future<void>.delayed(Duration.zero);
      places.toggleCategory(PlaceCategoryEnum.art);
      await Future<void>.delayed(Duration.zero);
      places.toggleUnusualOnly();
      await Future<void>.delayed(Duration.zero);
      final count = catalog.requests.length;
      places.clearFilters();
      await Future<void>.delayed(Duration.zero);
      expect(catalog.requests.length, count + 1);
      final next = restored();
      await next.initialize();
      expect(next.categories, isEmpty);
      expect(next.preferUnusual, isFalse);
      next.dispose();
      places.dispose();
      noExtraRequests();
    },
  );
}
