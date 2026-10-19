import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/data/scenic/scenic_dataset.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';

import 'context_recommendation_fixtures.dart' show shadeFixture, fixtureInstant;
import 'smart_walk_audit_test.dart' show poi;

class _Shade implements BaseShadeAnalysisService {
  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async => shadeFixture();
}

/// Labelled synthetic native adapter; these fixtures prove provider ownership
/// and budgets, never live MapKit or Railway availability.
class GuidedNativeRoutes extends MapKitService {
  int walkCalls = 0;
  int pointCalls = 0;
  int cancellations = 0;
  int charge = 1;
  bool fail = false;
  bool onPath = true;
  bool detour = false;
  bool oversizeDetour = false;
  Completer<void>? gate;
  Completer<void>? scenicGate;
  final budgets = <NativeWalkRequestBudget>[];

  @override
  Future<PedestrianRouteModel> calculateBoundedWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
    required NativeWalkRequestBudget requestBudget,
  }) async {
    walkCalls++;
    budgets.add(requestBudget);
    for (var i = 0; i < charge; i++) {
      requestBudget.consume();
    }
    if (gate != null) await gate!.future;
    if (fail) {
      throw const RouteCalculationFailure(RouteFailureKind.serviceUnavailable);
    }
    final geometry = detour
        ? _detourFeature.line!
              .map(
                (point) => GeoCoord(point.latitude + 0.0013, point.longitude),
              )
              .toList()
        : onPath
        ? spbScenicDataset.features
              .firstWhere(
                (feature) =>
                    feature.name == 'набережная Зимней канавки' &&
                    (feature.line?.length ?? 0) >= 5,
              )
              .line!
        : const [GeoCoord(60.2, 30.8), GeoCoord(60.21, 30.81)];
    final distance = RouteProjectionUtils.polylineLengthMeters(geometry);
    return PedestrianRouteModel(
      distanceMeters: distance,
      durationSeconds: detour ? 600 : 100,
      geometryPoints: geometry,
      steps: const [],
      placesCount: places.length,
      legs: [
        for (final place in places)
          RouteLegModel(
            fromTitle: startPoint.title,
            toTitle: place.title,
            distanceMeters: distance / places.length,
            durationSeconds: (detour ? 600 : 100) ~/ places.length,
            geometryPoints: geometry,
            visitMinutes: place.recommendedVisitMinutes,
          ),
      ],
    );
  }

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    pointCalls++;
    if (scenicGate != null) await scenicGate!.future;
    if (detour) {
      final feature = _detourFeature;
      final fromWaypoint =
          startPoint.latitude == feature.waypoint.latitude &&
          startPoint.longitude == feature.waypoint.longitude;
      final geometry = [
        GeoCoord(startPoint.latitude, startPoint.longitude),
        ...fromWaypoint ? feature.line!.skip(7) : feature.line!.take(7),
        GeoCoord(destinationPoint.latitude, destinationPoint.longitude),
      ];
      final distance =
          RouteProjectionUtils.polylineLengthMeters(geometry) *
          (oversizeDetour ? 4 : 1);
      return PedestrianRouteModel(
        distanceMeters: distance,
        durationSeconds: 400,
        geometryPoints: geometry,
        steps: const [],
        legs: [
          RouteLegModel(
            fromTitle: startPoint.title,
            toTitle: destinationPoint.title,
            distanceMeters: distance,
            durationSeconds: 400,
            geometryPoints: geometry,
          ),
        ],
      );
    }
    throw StateError('Unexpected scenic request in this zero-detour fixture');
  }

  @override
  void cancel() => cancellations++;

  ScenicFeature get _detourFeature => spbScenicDataset.features.firstWhere(
    (feature) => feature.id == 'spb-scenic-central-way-4460706',
  );
}

RoutingProvider _routing(GuidedNativeRoutes native) {
  final routing = RoutingProvider(mapKitService: native);
  addTearDown(routing.dispose);
  return routing;
}

RoutingProvider _draft(RoutingProvider owner) {
  final draft = owner.createGuidedDraft()!;
  addTearDown(draft.dispose);
  return draft;
}

Future<void> _build(RoutingProvider routing, {int place = 1}) async {
  routing.setProposedWalk([poi(place)], timeBudgetMinutes: 120);
  await routing.buildWalkRoute();
}

void main() {
  test(
    'published scenic evidence and comparison lists are immutable',
    () async {
      final draft = _draft(_routing(GuidedNativeRoutes()));
      await _build(draft);
      await draft.checkScenicForCurrentWalk();
      final stage = draft.verifiedScenicRoute!.legs.single.scenic!;
      expect(() => stage.featureIds.clear(), throwsUnsupportedError);
      expect(
        () => stage.featureNames.add('Неподтверждённый парк'),
        throwsUnsupportedError,
      );
      expect(
        () => draft.routeComparison!.benefitLines.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test('draft preserves an existing explicit shade-layer preference', () async {
    final owner = RoutingProvider(
      mapKitService: GuidedNativeRoutes(),
      shadeAnalysisService: _Shade(),
    );
    addTearDown(owner.dispose);
    await _build(owner);
    await owner.assessShade(
      departure: fixtureInstant,
      exploreAlternatives: false,
    );
    owner.setShadeOverlayEnabled(true);
    final previousAnalysis = owner.shadeAnalysis;
    final draft = _draft(owner);
    expect(draft.shadeAnalysis, isNull);
    expect(draft.shadeOverlayEnabled, isFalse);
    await _build(draft, place: 2);
    await draft.assessShade(
      departure: fixtureInstant,
      exploreAlternatives: false,
    );
    expect(draft.shadeOverlayEnabled, isTrue);
    expect(owner.shadeAnalysis, same(previousAnalysis));
    expect(owner.shadeOverlayEnabled, isTrue);
  });

  test(
    'verified native detour stores distinct geometry for explicit selection',
    () async {
      final native = GuidedNativeRoutes()..detour = true;
      final draft = _draft(_routing(native));
      await _build(draft);
      final normal = draft.currentRoute;
      await draft.checkScenicForCurrentWalk();
      expect(draft.verifiedScenicRoute, isNotNull);
      expect(draft.routeComparison!.extraDistanceMeters, greaterThan(0));
      expect(draft.routeComparison!.extraWalkingSeconds, greaterThan(0));
      expect(native.pointCalls, greaterThanOrEqualTo(2));
      final calls = native.pointCalls;
      final scenic = draft.verifiedScenicRoute;
      expect(draft.currentRoute, same(normal));
      expect(draft.selectVerifiedWalkVariant(WalkKind.scenic), isTrue);
      expect(draft.currentRoute, same(scenic));
      expect(draft.selectVerifiedWalkVariant(WalkKind.normal), isTrue);
      expect(draft.currentRoute, same(normal));
      expect(native.pointCalls, calls);
      expect(native.budgets.single.requests, lessThanOrEqualTo(12));
    },
  );

  test(
    'native detour outside the unchanged distance cap has no alternative',
    () async {
      final native = GuidedNativeRoutes()
        ..detour = true
        ..oversizeDetour = true;
      final draft = _draft(_routing(native));
      await _build(draft);
      await draft.checkScenicForCurrentWalk();
      expect(draft.verifiedScenicRoute, isNull);
      expect(draft.scenicFallbackMessage, contains('удлинение'));
      expect(draft.currentRoute, same(draft.verifiedNormalRoute));
      expect(native.budgets.single.requests, lessThanOrEqualTo(12));
    },
  );

  test('cancelled scenic segment cannot schedule more native work', () async {
    final native = GuidedNativeRoutes()
      ..detour = true
      ..scenicGate = Completer<void>();
    final draft = _draft(_routing(native));
    await _build(draft);
    final normal = draft.currentRoute;
    final pending = draft.checkScenicForCurrentWalk();
    expect(native.pointCalls, 1);
    final reservations = native.budgets.single.requests;
    draft.cancelPendingWalkBuild();
    native.scenicGate!.complete();
    await pending;
    expect(native.pointCalls, 1);
    expect(draft.currentRoute, same(normal));
    expect(draft.isCheckingScenic, isFalse);
    expect(draft.verifiedScenicRoute, isNull);
    expect(native.budgets.single.requests, reservations);
  });

  test('a new guided transaction invalidates the previous draft', () {
    final owner = _routing(GuidedNativeRoutes());
    final first = _draft(owner);
    final second = _draft(owner);
    expect(first.guidedDraftIsCurrent, isFalse);
    expect(first.navigationLocked, isTrue);
    expect(second.guidedDraftIsCurrent, isTrue);
  });

  test(
    'whole-walk shade adoption preserves route identity and overlay choice',
    () async {
      final owner = RoutingProvider(
        mapKitService: GuidedNativeRoutes(),
        shadeAnalysisService: _Shade(),
      );
      addTearDown(owner.dispose);
      final draft = _draft(owner);
      await _build(draft);
      await draft.assessShade(
        departure: fixtureInstant,
        exploreAlternatives: false,
      );
      final analysis = draft.shadeAnalysis;
      final selected = draft.currentRoute;
      expect(owner.commitGuidedDraft(draft), isTrue);
      expect(owner.currentRoute, same(selected));
      expect(owner.adoptWholeWalkShadeAssessmentFrom(draft), isTrue);
      expect(owner.shadeAnalysis, same(analysis));
      expect(owner.shadeAnalysisRoute, same(selected));
      expect(owner.shadeEvaluatedFor, fixtureInstant);
      expect(owner.shadeOverlayEnabled, isFalse);
    },
  );

  test(
    'shade adoption rejects a different route even with equal geometry',
    () async {
      final source = RoutingProvider(
        mapKitService: GuidedNativeRoutes(),
        shadeAnalysisService: _Shade(),
      );
      addTearDown(source.dispose);
      final target = _routing(GuidedNativeRoutes());
      await _build(source);
      await _build(target);
      await source.assessShade(
        departure: fixtureInstant,
        exploreAlternatives: false,
      );
      expect(target.adoptWholeWalkShadeAssessmentFrom(source), isFalse);
      expect(target.shadeAnalysis, isNull);
    },
  );

  test(
    'shade adoption requires the exact pre-armed virtual clock instant',
    () async {
      final owner = RoutingProvider(
        mapKitService: GuidedNativeRoutes(),
        shadeAnalysisService: _Shade(),
      );
      addTearDown(owner.dispose);
      final draft = _draft(owner);
      await _build(draft);
      await draft.assessShade(
        departure: fixtureInstant,
        exploreAlternatives: false,
      );
      expect(owner.commitGuidedDraft(draft), isTrue);
      final clock = VirtualShadeClock();
      addTearDown(clock.dispose);
      owner.attachShadeClock(clock);
      expect(owner.adoptWholeWalkShadeAssessmentFrom(draft), isFalse);
      clock.arm(fixtureInstant.add(const Duration(seconds: 1)));
      expect(owner.adoptWholeWalkShadeAssessmentFrom(draft), isFalse);
      expect(clock.departure, fixtureInstant.add(const Duration(seconds: 1)));
      clock.arm(fixtureInstant);
      expect(owner.adoptWholeWalkShadeAssessmentFrom(draft), isTrue);
      expect(clock.analyzedFor, fixtureInstant);
      expect(clock.overlayRequested, isFalse);
      owner.setNavigationLocked(true);
      expect(owner.adoptWholeWalkShadeAssessmentFrom(draft), isFalse);
    },
  );

  test(
    'opening and closing a draft preserves the published route and places',
    () async {
      final native = GuidedNativeRoutes();
      final owner = _routing(native);
      await _build(owner);
      final previous = owner.currentRoute;
      final draft = owner.createGuidedDraft()!;
      expect(draft.currentRoute, isNull);
      expect(draft.walkPlaces.single.id, 1);
      expect(draft.startPoint, same(owner.startPoint));
      draft.setProposedWalk([poi(2)], timeBudgetMinutes: 60);
      final cancellations = native.cancellations;
      draft.dispose();
      expect(native.cancellations, cancellations);
      expect(owner.currentRoute, same(previous));
      expect(owner.walkPlaces.single.id, 1);
      expect(owner.walkBudgetMinutes, 120);
    },
  );

  test(
    'native failure in a draft leaves the previous map route intact',
    () async {
      final native = GuidedNativeRoutes();
      final owner = _routing(native);
      await _build(owner);
      final previous = owner.currentRoute;
      final draft = _draft(owner);
      native.fail = true;
      await _build(draft, place: 2);
      expect(draft.status, RoutingStatus.error);
      expect(draft.errorMessage, isNotEmpty);
      expect(owner.currentRoute, same(previous));
      expect(owner.hasRoute, isTrue);
      expect(owner.commitGuidedDraft(draft), isFalse);
    },
  );

  test(
    'cancel releases loading and late native results cannot publish',
    () async {
      final native = GuidedNativeRoutes();
      final owner = _routing(native);
      await _build(owner);
      final previous = owner.currentRoute;
      final draft = _draft(owner);
      draft.setProposedWalk([poi(2)], timeBudgetMinutes: 120);
      native.gate = Completer<void>();
      final pending = draft.buildWalkRoute();
      expect(draft.isCalculating, isTrue);
      draft.cancelPendingWalkBuild();
      expect(draft.isCalculating, isFalse);
      native.gate!.complete();
      await pending;
      expect(draft.currentRoute, isNull);
      expect(draft.verifiedNormalRoute, isNull);
      expect(owner.currentRoute, same(previous));
    },
  );

  test(
    'draft start and order edits invalidate without automatic native work',
    () async {
      final native = GuidedNativeRoutes();
      final owner = _routing(native);
      final draft = _draft(owner);
      draft.setProposedWalk([poi(1), poi(2)]);
      await draft.buildWalkRoute();
      draft.reorderWalkPlaces(0, 2);
      expect(draft.walkPlaces.map((p) => p.id), [2, 1]);
      expect(draft.currentRoute, isNull);
      expect(native.walkCalls, 1);
      await draft.buildWalkRoute();
      draft.setCustomStartPoint(59.95, 30.33);
      expect(draft.currentRoute, isNull);
      expect(draft.verifiedNormalRoute, isNull);
      expect(native.walkCalls, 2);
      await draft.buildWalkRoute();
      draft.setStartPoint(RoutePointModel.defaultStart);
      expect(native.walkCalls, 3);
      expect(draft.walkPlaces.map((p) => p.id), [2, 1]);
      expect(owner.startPoint, same(RoutePointModel.defaultStart));
    },
  );

  test(
    'navigation start invalidates pending draft even if navigation stops',
    () async {
      final native = GuidedNativeRoutes()..gate = Completer<void>();
      final owner = _routing(native);
      final draft = _draft(owner);
      draft.setProposedWalk([poi(1)]);
      final pending = draft.buildWalkRoute();
      owner.setNavigationLocked(true);
      owner.setNavigationLocked(false);
      native.gate!.complete();
      await pending;
      expect(draft.guidedDraftIsCurrent, isFalse);
      expect(draft.isCalculating, isFalse);
      expect(draft.currentRoute, isNull);
      expect(owner.commitGuidedDraft(draft), isFalse);
    },
  );

  test('source mutation prevents stale draft commit', () async {
    final native = GuidedNativeRoutes();
    final owner = _routing(native);
    final draft = _draft(owner);
    await _build(draft);
    owner.setCustomStartPoint(59.96, 30.34);
    expect(owner.commitGuidedDraft(draft), isFalse);
    expect(draft.navigationLocked, isTrue);
    expect(owner.startPoint.latitude, 59.96);
  });

  test('a provider cannot commit another provider\'s draft', () async {
    final owner = _routing(GuidedNativeRoutes());
    final other = _routing(GuidedNativeRoutes());
    final draft = _draft(owner);
    await _build(draft);
    expect(other.commitGuidedDraft(draft), isFalse);
    expect(other.currentRoute, isNull);
  });

  test(
    'normal snapshot is native and no Scenic claim exists before checking',
    () async {
      final native = GuidedNativeRoutes();
      final draft = _draft(_routing(native));
      await _build(draft);
      expect(draft.verifiedNormalRoute, same(draft.currentRoute));
      expect(draft.verifiedNormalRoute!.durationSeconds, 100);
      expect(draft.verifiedNormalRoute!.walkKind, WalkKind.normal);
      expect(draft.verifiedScenicRoute, isNull);
      expect(draft.routeComparison, isNull);
      expect(draft.scenicChecked, isFalse);
      expect(draft.selectVerifiedWalkVariant(WalkKind.scenic), isFalse);
    },
  );

  test(
    'verified zero-detour variant requires explicit choice and no reroute',
    () async {
      final native = GuidedNativeRoutes();
      final owner = _routing(native);
      final draft = _draft(owner);
      await _build(draft);
      final normal = draft.currentRoute;
      await draft.checkScenicForCurrentWalk();
      expect(draft.currentRoute, same(normal));
      expect(draft.scenicChecked, isTrue);
      expect(draft.verifiedScenicRoute!.walkKind, WalkKind.scenic);
      expect(draft.verifiedScenicRoute!.legs.single.scenic, isNotNull);
      expect(draft.routeComparison!.extraDistanceMeters, 0);
      expect(draft.routeComparison!.extraWalkingSeconds, 0);
      expect(draft.selectVerifiedWalkVariant(WalkKind.scenic), isTrue);
      final scenic = draft.currentRoute;
      expect(draft.selectVerifiedWalkVariant(WalkKind.normal), isTrue);
      expect(draft.currentRoute, same(normal));
      expect(draft.selectVerifiedWalkVariant(WalkKind.scenic), isTrue);
      expect(draft.currentRoute, same(scenic));
      await draft.checkScenicForCurrentWalk();
      expect(native.walkCalls, 1);
      expect(native.pointCalls, 0);
      expect(native.budgets.single.requests, 1);
      expect(owner.commitGuidedDraft(draft), isTrue);
      expect(owner.currentRoute, same(scenic));
      expect(owner.walkScenicRequested, isTrue);
      expect(owner.navigationLocked, isFalse);
      expect(owner.commitGuidedDraft(draft), isFalse);
    },
  );

  test('a rejected Scenic pass keeps normal with an honest reason', () async {
    final native = GuidedNativeRoutes()..onPath = false;
    final draft = _draft(_routing(native));
    await _build(draft);
    final normal = draft.currentRoute;
    await draft.checkScenicForCurrentWalk();
    expect(draft.scenicChecked, isTrue);
    expect(draft.verifiedScenicRoute, isNull);
    expect(draft.scenicFallbackMessage, isNotEmpty);
    expect(draft.currentRoute, same(normal));
    expect(draft.selectVerifiedWalkVariant(WalkKind.scenic), isFalse);
    expect(native.walkCalls, 1);
  });

  test(
    'staged scenic keeps the original 12-request native allowance',
    () async {
      final native = GuidedNativeRoutes()
        ..charge = 12
        ..onPath = false;
      final draft = _draft(_routing(native));
      await _build(draft);
      await draft.checkScenicForCurrentWalk();
      expect(native.budgets.single.maximumRequests, 12);
      expect(native.budgets.single.requests, 12);
      expect(native.pointCalls, 0);
      expect(draft.currentRoute, same(draft.verifiedNormalRoute));
    },
  );

  test('legacy scenic build still selects its verified scenic route', () async {
    final native = GuidedNativeRoutes();
    final routing = _routing(native);
    routing.setProposedWalk([poi(1)], timeBudgetMinutes: 120, scenic: true);
    await routing.buildWalkRoute();
    expect(routing.currentRoute, same(routing.verifiedScenicRoute));
    expect(routing.currentRoute!.walkKind, WalkKind.scenic);
    expect(routing.selectVerifiedWalkVariant(WalkKind.normal), isTrue);
    expect(native.walkCalls, 1);
    expect(native.pointCalls, 0);
  });

  test(
    'guided legacy scenic option still waits for explicit selection',
    () async {
      final draft = _draft(_routing(GuidedNativeRoutes()));
      draft.setProposedWalk([poi(1)], timeBudgetMinutes: 120, scenic: true);
      await draft.buildWalkRoute();
      expect(draft.verifiedScenicRoute, isNotNull);
      expect(draft.currentRoute, same(draft.verifiedNormalRoute));
      expect(draft.currentRoute!.walkKind, WalkKind.normal);
    },
  );

  test(
    'locked navigation blocks draft creation and variant switching',
    () async {
      final routing = _routing(GuidedNativeRoutes());
      await _build(routing);
      final previous = routing.currentRoute;
      routing.setNavigationLocked(true);
      expect(routing.createGuidedDraft(), isNull);
      expect(routing.selectVerifiedWalkVariant(WalkKind.normal), isFalse);
      expect(routing.currentRoute, same(previous));
    },
  );
}
