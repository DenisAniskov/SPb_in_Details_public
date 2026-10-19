import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/services/quiet_route_engine.dart';
import 'package:smart_navigator_spb/services/scenic_stage_builder.dart';

const _a = GeoCoord(59.9400, 30.3150);
const _b = GeoCoord(59.9410, 30.3160);
const _c = GeoCoord(59.9420, 30.3170);
const _d = GeoCoord(59.9405, 30.3155);

GeoCoord _offset(
  GeoCoord origin, {
  double northMeters = 0,
  double eastMeters = 0,
}) {
  final latitude = origin.latitude + northMeters / 111195.0;
  final longitude =
      origin.longitude +
      eastMeters / (111195.0 * math.cos(origin.latitude * math.pi / 180.0));
  return GeoCoord(latitude, longitude);
}

RouteLegModel _leg(
  GeoCoord from,
  GeoCoord to, {
  double distance = 500,
  int duration = 300,
  String fromTitle = 'from',
  String toTitle = 'to',
  int? visitMinutes,
  List<GeoCoord>? geometryPoints,
  List<PedestrianManeuverModel> maneuvers = const [],
}) => RouteLegModel(
  fromTitle: fromTitle,
  toTitle: toTitle,
  distanceMeters: distance,
  durationSeconds: duration,
  geometryPoints: geometryPoints ?? [from, to],
  visitMinutes: visitMinutes,
  maneuvers: maneuvers,
);

PedestrianRouteModel _route({List<RouteLegModel>? legs}) {
  final value = legs ?? [_leg(_a, _b), _leg(_b, _c)];
  return PedestrianRouteModel(
    distanceMeters: value.fold(0.0, (sum, leg) => sum + leg.distanceMeters),
    durationSeconds: value.fold(0, (sum, leg) => sum + leg.durationSeconds),
    geometryPoints: [for (final leg in value) ...leg.geometryPoints],
    steps: const [],
    legs: value,
    placesCount: 2,
  );
}

QuietAnalysisModel _analysis({
  double index = 0.50,
  double coverage = 1.0,
  QuietStatus status = QuietStatus.available,
}) => QuietAnalysisModel(
  status: status,
  estimate: status == QuietStatus.available || status == QuietStatus.partial,
  confidence: 'low',
  method: 'relative_road_noise_exposure_proxy',
  methodVersion: 'c11_1',
  evaluatedAt: DateTime(2026, 10, 17, 12),
  temporalModel: 'static_osm_network',
  trafficTimeModeled: false,
  routeLengthMeters: 1000,
  knownMeters: 1000 * coverage,
  unknownMeters: 1000 * (1 - coverage),
  coverageShare: coverage,
  roadNoiseExposureIndex:
      status == QuietStatus.available || status == QuietStatus.partial
      ? index
      : null,
  lowExposureShare: 0.4,
  majorRoadAdjacentShare: 0.2,
  meanNearestRoadDistanceM: 40,
  maxRoadClassNearby: 'primary',
  legs: null,
  reasons: const [],
  limitations: const ['Не дБ.'],
  assumptions: const ['Прокси.'],
  sourceProvenance: const {'license': 'ODbL-1.0'},
  datasetVersion: 'c11_quiet_spb_central_v1',
  datasetSha256: 'a' * 64,
);

typedef _VariantResult = List<RouteLegModel>;

Future<QuietRoutingDecision> _run({
  PedestrianRouteModel? normalRoute,
  QuietAnalysisModel? normalAnalysis,
  _VariantResult? variants,
  QuietAnalysisModel? candidateAnalysis,
  int budget = 3,
  int? walkBudgetSeconds,
  bool Function()? isCurrent,
  QuietAnalysisModel? Function(PedestrianRouteModel route)? analyzeByRoute,
  void Function(PedestrianRouteModel route)? onAnalyze,
}) {
  final normal = normalRoute ?? _route();
  final normalValue = normalAnalysis ?? _analysis();
  final candidate = _analysis(index: 0.35);
  final budgetValue = NativeWalkRequestBudget(budget);
  return QuietRouteEngine().enhance(
    normalRoute: normal,
    normalAnalysis: normalValue,
    requestBudget: budgetValue,
    walkBudgetSeconds: walkBudgetSeconds,
    isCurrent: isCurrent,
    requestVariants: (index, leg, requestBudget) async {
      if (variants == null) return [leg];
      requestBudget.consume();
      return variants;
    },
    analyze: (route) async {
      onAnalyze?.call(route);
      if (analyzeByRoute != null) return analyzeByRoute(route)!;
      return route.distanceMeters > normal.distanceMeters
          ? (candidateAnalysis ?? candidate)
          : normalValue;
    },
  );
}

void main() {
  test(
    'real native variant is offered only after a meaningful improvement',
    () async {
      final normal = _route();
      final variant = _leg(_a, _b, distance: 600, duration: 320);
      final decision = await _run(variants: [normal.legs.first, variant]);
      expect(decision.offersAlternative, isTrue);
      expect(decision.fallbackReason, QuietFallbackReason.none);
      expect(decision.candidateRoute!.walkKind, WalkKind.quiet);
      expect(decision.candidateRoute!.legs.length, normal.legs.length);
      expect(
        decision.candidateRoute!.legs[1].fromTitle,
        normal.legs[1].fromTitle,
      );
      expect(
        decision.candidateRoute!.legs[1].distanceMeters,
        normal.legs[1].distanceMeters,
      );
      expect(decision.improvement, closeTo(0.15, 1e-9));
      expect(decision.extraDistanceMeters, closeTo(100, 1e-9));
      expect(decision.extraWalkingSeconds, 20);
      expect(decision.candidateCoverageShare, 1.0);
      expect(decision.evidenceNote, contains('не заменяет измерение шума'));
    },
  );

  test(
    'small native endpoint snapping is accepted without synthetic points',
    () async {
      final normal = _route();
      final snappedStart = _offset(_a, northMeters: 2, eastMeters: 3);
      final snappedEnd = _offset(_b, northMeters: -3, eastMeters: 4);
      final halfOffset =
          RouteProjectionUtils.polylineLengthMeters([
            snappedStart,
            snappedEnd,
          ]) /
          2;
      final variant = _leg(
        snappedStart,
        snappedEnd,
        distance: 600,
        duration: 320,
        maneuvers: [
          PedestrianManeuverModel(
            kind: PedestrianManeuverKind.crosswalk,
            segmentIndex: 0,
            segmentPosition: 0.5,
            offsetMeters: halfOffset,
            legIndex: 0,
          ),
        ],
      );
      final decision = await _run(variants: [normal.legs.first, variant]);

      expect(decision.offersAlternative, isTrue);
      final candidate = decision.candidateRoute!;
      // Exactly the native replacement followed by the untouched next leg:
      // no connector or interpolated endpoint was added.
      expect(candidate.geometryPoints.length, 4);
      expect(candidate.geometryPoints[0].latitude, snappedStart.latitude);
      expect(candidate.geometryPoints[0].longitude, snappedStart.longitude);
      expect(candidate.geometryPoints[1].latitude, snappedEnd.latitude);
      expect(candidate.geometryPoints[1].longitude, snappedEnd.longitude);
      expect(candidate.geometryPoints[2].latitude, _b.latitude);
      expect(candidate.geometryPoints[2].longitude, _b.longitude);
      expect(
        RouteProjectionUtils.distanceBetween(
          candidate.geometryPoints.first,
          _a,
        ),
        lessThanOrEqualTo(QuietRouteEngine.maxNativeEndpointSnapMeters),
      );
    },
  );

  test(
    'alternative ending at a different stop is rejected before analysis',
    () async {
      final normal = _route();
      var analyses = 0;
      final decision = await _run(
        variants: [
          normal.legs.first,
          _leg(_a, _d, distance: 600, duration: 320),
        ],
        onAnalyze: (_) => analyses++,
      );

      expect(decision.offersAlternative, isFalse);
      expect(decision.fallbackReason, QuietFallbackReason.invalidAlternative);
      expect(decision.fallbackText, contains('Обычный маршрут сохранён'));
      expect(analyses, 0);
    },
  );

  test('alternative starting away from the original leg is rejected', () async {
    final normal = _route();
    var analyses = 0;
    final decision = await _run(
      variants: [
        normal.legs.first,
        _leg(_offset(_a, northMeters: 40), _b, distance: 600, duration: 320),
      ],
      onAnalyze: (_) => analyses++,
    );

    expect(decision.fallbackReason, QuietFallbackReason.invalidAlternative);
    expect(analyses, 0);
  });

  test('a gap to the next original leg is rejected fail-closed', () async {
    final normal = _route(
      legs: [_leg(_a, _b), _leg(_offset(_b, northMeters: 40), _c)],
    );
    var analyses = 0;
    final decision = await _run(
      normalRoute: normal,
      variants: [normal.legs.first, _leg(_a, _b, distance: 600, duration: 320)],
      onAnalyze: (_) => analyses++,
    );

    expect(decision.fallbackReason, QuietFallbackReason.invalidAlternative);
    expect(analyses, 0);
  });

  test(
    'a gap from the previous original leg is rejected fail-closed',
    () async {
      final replacementStart = _offset(_b, northMeters: 40);
      final normal = _route(legs: [_leg(_a, _b), _leg(replacementStart, _c)]);
      var analyses = 0;
      final decision = await QuietRouteEngine().enhance(
        normalRoute: normal,
        normalAnalysis: _analysis(),
        requestBudget: NativeWalkRequestBudget(3),
        requestVariants: (index, leg, budget) async {
          if (index == 0) return [leg];
          budget.consume();
          return [
            leg,
            _leg(replacementStart, _c, distance: 600, duration: 320),
          ];
        },
        analyze: (route) async {
          analyses++;
          return _analysis(index: 0.35);
        },
      );

      expect(decision.fallbackReason, QuietFallbackReason.invalidAlternative);
      expect(analyses, 0);
    },
  );

  test('corrupted replacement geometry is rejected before analysis', () async {
    final normal = _route();
    final invalidGeometries = <List<GeoCoord>>[
      [_a],
      [_a, GeoCoord(double.nan, _b.longitude)],
      [_a, GeoCoord(double.infinity, _b.longitude)],
      [_a, _a],
    ];
    var analyses = 0;
    for (final geometry in invalidGeometries) {
      final decision = await _run(
        variants: [
          normal.legs.first,
          _leg(_a, _b, distance: 600, duration: 320, geometryPoints: geometry),
        ],
        onAnalyze: (_) => analyses++,
      );
      expect(
        decision.fallbackReason,
        QuietFallbackReason.invalidAlternative,
        reason: '$geometry',
      );
    }
    expect(analyses, 0);
  });

  test('replacement metadata must preserve names and visit time', () async {
    final normal = _route();
    final invalidVariants = [
      _leg(_a, _b, distance: 600, duration: 320, toTitle: 'other stop'),
      _leg(_a, _b, distance: 600, duration: 320, visitMinutes: 5),
      _leg(_a, _b, distance: 600, duration: 0),
      _leg(_a, _b, distance: double.nan, duration: 320),
    ];
    var analyses = 0;
    for (final variant in invalidVariants) {
      final decision = await _run(
        variants: [normal.legs.first, variant],
        onAnalyze: (_) => analyses++,
      );
      expect(decision.fallbackReason, QuietFallbackReason.invalidAlternative);
    }
    expect(analyses, 0);
  });

  test('inconsistent native maneuvers reject the alternative', () async {
    final normal = _route();
    final halfOffset = RouteProjectionUtils.polylineLengthMeters([_a, _b]) / 2;
    final invalidVariants = [
      _leg(
        _a,
        _b,
        distance: 600,
        duration: 320,
        maneuvers: [
          PedestrianManeuverModel(
            kind: PedestrianManeuverKind.left,
            segmentIndex: 0,
            segmentPosition: 0.5,
            offsetMeters: halfOffset,
            legIndex: 1,
          ),
        ],
      ),
      _leg(
        _a,
        _b,
        distance: 600,
        duration: 320,
        maneuvers: [
          const PedestrianManeuverModel(
            kind: PedestrianManeuverKind.left,
            segmentIndex: 0,
            segmentPosition: 0.5,
            offsetMeters: 999,
          ),
        ],
      ),
      _leg(
        _a,
        _b,
        distance: 600,
        duration: 320,
        maneuvers: [
          const PedestrianManeuverModel(
            kind: PedestrianManeuverKind.left,
            segmentIndex: 99,
            segmentPosition: 0,
            offsetMeters: 0,
          ),
        ],
      ),
    ];
    var analyses = 0;
    for (final variant in invalidVariants) {
      final decision = await _run(
        variants: [normal.legs.first, variant],
        onAnalyze: (_) => analyses++,
      );
      expect(decision.fallbackReason, QuietFallbackReason.invalidAlternative);
    }
    expect(analyses, 0);
  });

  test('Quiet uses the documented Scenic waypoint snap radius', () {
    expect(QuietRouteEngine.maxNativeEndpointSnapMeters, 15.0);
    expect(
      QuietRouteEngine.maxNativeEndpointSnapMeters,
      ScenicStageBuilder.maxSnapFromWaypointMeters,
    );
  });

  test(
    'no native variants keeps the normal route with an honest reason',
    () async {
      final decision = await _run(variants: null);
      expect(decision.offersAlternative, isFalse);
      expect(decision.fallbackReason, QuietFallbackReason.noAlternatives);
      expect(decision.fallbackText, contains('альтернатив'));
    },
  );

  test('a tiny index difference is not advertised as quieter', () async {
    final decision = await _run(
      variants: [_leg(_a, _b), _leg(_a, _b, distance: 600, duration: 320)],
      candidateAnalysis: _analysis(index: 0.47),
    );
    expect(decision.offersAlternative, isFalse);
    expect(decision.fallbackReason, QuietFallbackReason.notQuieter);
  });

  test('incomparable coverage is rejected, not compared', () async {
    final decision = await _run(
      variants: [_leg(_a, _b), _leg(_a, _b, distance: 600, duration: 320)],
      candidateAnalysis: _analysis(index: 0.2, coverage: 0.5),
    );
    expect(decision.offersAlternative, isFalse);
    expect(decision.fallbackReason, QuietFallbackReason.insufficientCoverage);
  });

  test(
    'too much extra time is rejected even when the index is better',
    () async {
      final decision = await _run(
        variants: [_leg(_a, _b), _leg(_a, _b, distance: 600, duration: 3000)],
      );
      expect(decision.offersAlternative, isFalse);
      expect(decision.fallbackReason, QuietFallbackReason.tooMuchDetour);
    },
  );

  test('exhausted native budget is refused before another request', () async {
    final normal = _route();
    var requests = 0;
    final decision = await QuietRouteEngine().enhance(
      normalRoute: normal,
      normalAnalysis: _analysis(),
      requestBudget: NativeWalkRequestBudget(0),
      requestVariants: (index, leg, budget) async {
        requests++;
        budget.consume();
        return [leg];
      },
      analyze: (route) async => _analysis(),
    );
    expect(requests, 0);
    expect(decision.fallbackReason, QuietFallbackReason.insufficientBudget);
  });

  test('cancellation never publishes a late candidate', () async {
    final decision = await _run(
      variants: [_leg(_a, _b), _leg(_a, _b, distance: 600, duration: 320)],
      isCurrent: () => false,
    );
    expect(decision.offersAlternative, isFalse);
    expect(decision.fallbackReason, QuietFallbackReason.cancelled);
  });

  test('a baseline without an estimate cannot be compared', () async {
    final decision = await _run(
      normalAnalysis: _analysis(
        index: 0,
        coverage: 0,
        status: QuietStatus.outsideCoverage,
      ),
    );
    expect(decision.offersAlternative, isFalse);
    expect(decision.fallbackReason, QuietFallbackReason.noBaseline);
  });

  test('walk budget rejects a candidate that exceeds the whole walk', () async {
    final decision = await _run(
      variants: [_leg(_a, _b), _leg(_a, _b, distance: 600, duration: 400)],
      walkBudgetSeconds: 650,
    );
    expect(decision.offersAlternative, isFalse);
    expect(decision.fallbackReason, QuietFallbackReason.tooMuchDetour);
  });
}
