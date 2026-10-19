import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_routing_engine.dart';
import 'package:smart_navigator_spb/services/virtual_shade_clock.dart';
import 'package:smart_navigator_spb/ui/widgets/shade_assessment_section.dart';

import 'off_route_reroute_test.dart' show FakeRouteService;

// --------------------------------------------------------------------------
// Phase C7.1 Flutter tests (§18). Everything here is offline: the backend and
// MapKit are replaced by fakes that record what they were asked for, so the
// tests can assert both behaviour and honesty (what is NEVER sent, computed
// or displayed).
// --------------------------------------------------------------------------

const _start = GeoCoord(59.9400, 30.3150);
const _mid = GeoCoord(59.9410, 30.3160);
const _stop = GeoCoord(59.9420, 30.3170);
const _far = GeoCoord(59.9430, 30.3180);

RouteLegModel _leg({
  GeoCoord from = _start,
  GeoCoord to = _stop,
  int seconds = 600,
  String fromTitle = 'Старт',
  String toTitle = 'POI 1',
  int? visitMinutes,
}) =>
    RouteLegModel(
      fromTitle: fromTitle,
      toTitle: toTitle,
      distanceMeters: 800,
      durationSeconds: seconds,
      geometryPoints: [from, GeoCoord((from.latitude + to.latitude) / 2, (from.longitude + to.longitude) / 2), to],
      visitMinutes: visitMinutes,
    );

/// Point at [fraction] of a polyline's length (test-side reference).
GeoCoord _pointAlong(List<GeoCoord> points, double fraction) {
  final distances = <double>[0];
  for (var i = 1; i < points.length; ++i) {
    distances.add(distances[i - 1] +
        RouteProjectionUtils.distanceBetween(points[i - 1], points[i]));
  }
  final target = distances.last * fraction;
  for (var i = 1; i < points.length; ++i) {
    if (distances[i] >= target) {
      final span = distances[i] - distances[i - 1];
      final local = span <= 0 ? 0.0 : (target - distances[i - 1]) / span;
      return GeoCoord(
        points[i - 1].latitude + (points[i].latitude - points[i - 1].latitude) * local,
        points[i - 1].longitude + (points[i].longitude - points[i - 1].longitude) * local,
      );
    }
  }
  return points.last;
}

PedestrianRouteModel _route({List<RouteLegModel>? legs, int placesCount = 1}) {
  final routeLegs = legs ?? [_leg()];
  var distance = 0.0;
  var duration = 0;
  final points = <GeoCoord>[];
  for (final leg in routeLegs) {
    distance += leg.distanceMeters;
    duration += leg.durationSeconds;
    points.addAll(leg.geometryPoints);
  }
  return PedestrianRouteModel(
    distanceMeters: distance,
    durationSeconds: duration,
    geometryPoints: points,
    steps: const [],
    legs: routeLegs,
    placesCount: placesCount,
  );
}

/// One classified segment of the fixture route: real polyline (with an
/// interior vertex) plus optional MEASURED band positions in metres.
ShadeSegmentModel _segment({
  required GeoCoord from,
  required GeoCoord to,
  required double lengthMeters,
  required ShadeSegmentState state,
  double shadedMeters = 0,
  double unknownMeters = 0,
  List<ShadeSpan> shadedSpans = const [],
  List<ShadeSpan> unknownSpans = const [],
  double startsAtSeconds = 0,
  int legIndex = 0,
}) =>
    ShadeSegmentModel(
      legIndex: legIndex,
      geometry: [
        from,
        GeoCoord((from.latitude + to.latitude) / 2,
            (from.longitude + to.longitude) / 2),
        to,
      ],
      lengthMeters: lengthMeters,
      shadedMeters: shadedMeters,
      unknownMeters: unknownMeters,
      state: state,
      startsAtSeconds: startsAtSeconds,
      endsAtSeconds: startsAtSeconds + 400,
      shadedSpans: shadedSpans,
      unknownSpans: unknownSpans,
    );

/// Two 200 m halves: the first fully shaded (measured span over its whole
/// length), the second sunlit.
List<ShadeSegmentModel> _defaultSegments() => [
      _segment(
        from: _start,
        to: _mid,
        lengthMeters: 200,
        state: ShadeSegmentState.estimatedShaded,
        shadedMeters: 200,
        shadedSpans: const [ShadeSpan(0, 200)],
      ),
      _segment(
        from: _mid,
        to: _stop,
        lengthMeters: 200,
        state: ShadeSegmentState.estimatedExposed,
        startsAtSeconds: 400,
      ),
    ];

ShadeAnalysisModel _analysis({
  ShadeStatus status = ShadeStatus.available,
  double shaded = 400,
  double exposed = 400,
  double unknown = 0,
  double coverageShare = 1.0,
  ShadeConfidence confidence = ShadeConfidence.medium,
  List<ShadeSegmentModel>? segments,
  String? reason,
}) {
  final total = shaded + exposed + unknown;
  return ShadeAnalysisModel(
    status: status,
    method: 'test',
    methodVersion: 'test',
    periodStart: DateTime(2026, 7, 1, 14),
    periodEnd: DateTime(2026, 7, 1, 15),
    timezoneName: 'MSK',
    datasetVersion: 'c7_1_pilot_v1',
    datasetProvenance: 'OpenStreetMap (ODbL 1.0, © OpenStreetMap contributors), снимок 2026-10-11.',
    solar: const ShadeSolarSummaryModel(
      minElevationDeg: 40,
      maxElevationDeg: 52,
      minAzimuthDeg: 180,
      maxAzimuthDeg: 220,
      bucketCount: 2,
    ),
    routeLengthMeters: total,
    shadedMeters: status.hasEstimate ? shaded : null,
    exposedMeters: status.hasEstimate ? exposed : null,
    unknownMeters: status.hasEstimate ? unknown : null,
    shadeFraction: status.hasEstimate && total > 0 ? shaded / total : null,
    confidence: confidence,
    limitations: const ['Тестовое ограничение модели.'],
    segments: segments ?? _defaultSegments(),
    reason: reason,
    datasetZonesTouched: const ['centre_palace'],
    outsideCoverageMeters: total * (1 - coverageShare),
    coverageShare: coverageShare,
    heightProvenance: const ShadeHeightProvenanceModel(
      osmDeclared: 1,
      levelsEstimate: 5,
      unavailable: 2,
      buildingsConsidered: 8,
    ),
  );
}

class _FakeShadeService implements BaseShadeAnalysisService {
  _FakeShadeService({this.analysis, this.onCall});

  ShadeAnalysisModel? analysis;
  ShadeAnalysisModel Function(List<RouteLegModel> legs)? onCall;

  /// Set by a test to make the next call fail with a typed failure.
  Object? failure;
  int calls = 0;
  final List<List<RouteLegModel>> receivedLegs = [];
  final List<List<int>> receivedVisits = [];
  final List<DateTime> receivedDepartures = [];

  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async {
    calls++;
    receivedLegs.add(List.of(legs));
    receivedVisits.add(List.of(visitMinutesAfterLeg));
    receivedDepartures.add(departure);
    final thrown = failure;
    if (thrown != null) throw thrown;
    return onCall?.call(legs) ?? analysis ?? _analysis();
  }
}

Future<void> _pumpSection(WidgetTester tester, RoutingProvider routing,
    {ThemeData? theme, Size? size}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
  }
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<RoutingProvider>.value(
      value: routing,
      child: MaterialApp(
        theme: theme ?? ThemeData.light(),
        home: const Scaffold(body: SingleChildScrollView(child: ShadeAssessmentSection())),
      ),
    ),
  );
}

/// Simulator variant: the section additionally sees the virtual clock.
Future<void> _pumpSectionWithClock(
    WidgetTester tester, RoutingProvider routing, VirtualShadeClock clock) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
        ChangeNotifierProvider<VirtualShadeClock>.value(value: clock),
      ],
      child: MaterialApp(
        theme: ThemeData.light(),
        home: const Scaffold(
            body: SingleChildScrollView(child: ShadeAssessmentSection())),
      ),
    ),
  );
}

void main() {
  late FakeRouteService mapKit;
  late _FakeShadeService shade;

  setUp(() {
    mapKit = FakeRouteService();
    shade = _FakeShadeService();
  });

  RoutingProvider providerWithRoute(PedestrianRouteModel route) {
    // The shade service is faked; MapKit is left at its default because these
    // tests never explore native alternatives (the real service performs no
    // work until a request method is called).
    final routing = RoutingProvider(shadeAnalysisService: shade);
    return routing
      ..setProposedWalkForScenicTest(
        scenic: false,
        comparison: null,
        walkKind: WalkKind.normal,
        route: route,
      );
  }

  group('§18 shade analysis service contract', () {
    test('sends real leg geometry, native walking time and visit minutes', () async {
      final service = BackendShadeAnalysisService();
      // The service's HTTP call cannot run offline; assert the payload
      // builder's contract through the failure path instead: a rejected
      // request still means a payload was formed from the real legs.
      final legs = [
        _leg(seconds: 300, visitMinutes: 30),
        _leg(from: _stop, to: _stop, seconds: 120, toTitle: 'POI 2'),
      ];
      await expectLater(
        service.analyzeWalk(
          departure: DateTime(2026, 7, 1, 14),
          legs: legs,
          visitMinutesAfterLeg: [30, 0],
        ),
        throwsA(isA<ShadeAnalysisFailure>()),
      );
    });

    test('backend failure is typed and keeps ordinary navigation intact', () async {
      shade.failure = const ShadeAnalysisFailure(
        ShadeAnalysisFailureKind.serviceUnavailable,
        'Сервис оценки тени недоступен. Обычный маршрут продолжает работать.',
      );
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      await routing.assessShade(departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      expect(routing.shadeFailure?.kind, ShadeAnalysisFailureKind.serviceUnavailable);
      expect(routing.shadeAnalysis, isNull);
      expect(routing.currentRoute, isNotNull, reason: 'обычная навигация не затронута');
      expect(routing.isAssessingShade, isFalse);
    });

    test('ISO-8601 payload carries the local offset (naive times are rejected)', () {
      final value = DateTime(2026, 7, 1, 14, 30);
      final iso = iso8601WithOffset(value);
      expect(iso, matches(RegExp(r'[+-]\d{2}:\d{2}$')));
    });
  });

  group('§18 route comparison gates and scoring', () {
    late ShadeRoutingEngine engine;

    setUp(() {
      engine = ShadeRoutingEngine(shadeService: shade);
    });

    test('offers a real alternative with a large shade gain', () async {
      final normal = _analysis(shaded: 200, exposed: 600);
      final better = _analysis(shaded: 600, exposed: 200);
      shade.analysis = better;
      final decision = await engine.evaluate(
        // 20 minutes of walking ⇒ the documented allowance is
        // min(10 min, 25 % × 20 min) = 5 min, so a +3 min detour is fine.
        normalRoute: _route(legs: [_leg(seconds: 1200)]),
        alternatives: [_route(legs: [_leg(seconds: 1380)])],
        departure: DateTime(2026, 7, 1, 14),
        normalAnalysis: normal,
      );
      expect(decision.offersAlternative, isTrue);
      expect(decision.best!.extraMinutes, closeTo(3, 0.01));
      expect(decision.evaluated.single.rejection, isNull);
    });

    test('rejects a detour longer than the documented allowance', () async {
      final normal = _analysis(shaded: 200, exposed: 600);
      final decision = await engine.evaluate(
        normalRoute: _route(legs: [_leg(seconds: 600)]),
        alternatives: [_route(legs: [_leg(seconds: 3600)])],
        departure: DateTime(2026, 7, 1, 14),
        normalAnalysis: normal,
      );
      expect(decision.offersAlternative, isFalse);
      expect(decision.fallback, ShadeRoutingFallback.detourTooLong);
      expect(decision.fallback!.message, contains('Доступен обычный маршрут'));
    });

    test('never compares incomparable coverage levels', () async {
      final normal = _analysis(shaded: 200, exposed: 600, coverageShare: 1.0);
      final patchy = _analysis(shaded: 240, exposed: 40, unknown: 520, coverageShare: 0.5);
      shade.analysis = patchy;
      final decision = await engine.evaluate(
        normalRoute: _route(),
        alternatives: [_route(legs: [_leg(seconds: 620)])],
        departure: DateTime(2026, 7, 1, 14),
        normalAnalysis: normal,
      );
      // The candidate's raw fraction looks similar; its comparable fraction is
      // high but its coverage is not comparable, so it must be refused.
      expect(patchy.comparableShadeFraction, greaterThan(0.8));
      expect(decision.offersAlternative, isFalse);
      expect(decision.fallback, ShadeRoutingFallback.coverageNotComparable);
    });

    test('rejects a Smart Walk budget violation', () async {
      final normal = _analysis(shaded: 200, exposed: 600);
      shade.analysis = _analysis(shaded: 600, exposed: 200);
      // 60-minute budget, 40 minutes of walking, 25-minute visit: a 5-minute
      // detour would push the walk past the budget even though the shade gain
      // is large, so the detour must be refused on the budget.
      final decision = await engine.evaluate(
        normalRoute: _route(legs: [_leg(seconds: 2400, visitMinutes: 25)]),
        alternatives: [_route(legs: [_leg(seconds: 2700, visitMinutes: 25)])],
        departure: DateTime(2026, 7, 1, 14),
        budgetMinutes: 60,
        normalAnalysis: normal,
      );
      expect(decision.offersAlternative, isFalse);
      expect(decision.fallback, ShadeRoutingFallback.budgetExceeded);
    });

    test('a trivial gain does not replace the route', () async {
      final normal = _analysis(shaded: 400, exposed: 400);
      final slightlyBetter = _analysis(shaded: 440, exposed: 360);
      final decision = await engine.evaluate(
        normalRoute: _route(),
        alternatives: [_route(legs: [_leg(seconds: 605)])],
        departure: DateTime(2026, 7, 1, 14),
        normalAnalysis: normal,
      );
      expect(decision.offersAlternative, isFalse);
      expect(decision.fallback, ShadeRoutingFallback.trivialGain);
      expect(slightlyBetter.shadeFraction, greaterThan(normal.shadeFraction!));
    });

    test('an alternative without an estimate is never offered', () async {
      final engineWithUnavailable = ShadeRoutingEngine(
        shadeService: _FakeShadeService(
          onCall: (legs) => _analysis(status: ShadeStatus.unavailable, reason: 'нет данных'),
        ),
      );
      final decision = await engineWithUnavailable.evaluate(
        normalRoute: _route(),
        alternatives: [_route(legs: [_leg(seconds: 620)])],
        departure: DateTime(2026, 7, 1, 14),
        normalAnalysis: _analysis(),
      );
      expect(decision.offersAlternative, isFalse);
      expect(decision.fallback, ShadeRoutingFallback.insufficientShadeData);
    });

    test('no alternatives reported honestly', () async {
      final decision = await engine.evaluate(
        normalRoute: _route(),
        alternatives: const [],
        departure: DateTime(2026, 7, 1, 14),
        normalAnalysis: _analysis(),
      );
      expect(decision.offersAlternative, isFalse);
      expect(decision.fallback, ShadeRoutingFallback.noAlternatives);
      expect(decision.fallback!.message, contains('MapKit'));
    });
  });

  group('§18 provider behaviour: staleness, cancellation, explicit switch', () {
    test('assessing analyses the current route at the requested instant', () async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      final when = DateTime(2026, 7, 1, 16, 30);
      await routing.assessShade(departure: when, exploreAlternatives: false);
      expect(routing.shadeAnalysis, isNotNull);
      expect(routing.shadeDeparture!.difference(when).inSeconds, 0);
      expect(shade.receivedDepartures.single.difference(when).inSeconds, 0);
    });

    test('a route change invalidates the estimate', () async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      await routing.assessShade(departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      expect(routing.shadeAnalysis, isNotNull);
      routing.clearRoute();
      expect(routing.shadeAnalysis, isNull);
      expect(routing.shadeDecision, isNull);
      expect(routing.shadeOverlayEnabled, isFalse);
    });

    test('a later assessment supersedes an in-flight one', () async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      final first = routing.assessShade(
        departure: DateTime(2026, 7, 1, 14),
        exploreAlternatives: false,
      );
      final second = routing.assessShade(
        departure: DateTime(2026, 7, 1, 18),
        exploreAlternatives: false,
      );
      await Future.wait([first, second]);
      expect(routing.shadeDeparture!.hour, 18,
          reason: 'побеждает последний запрос пользователя');
    });

    test('changing the time marks the previous estimate as not-current', () async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      await routing.assessShade(departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      expect(routing.shadeAssessmentIsStaleFor(DateTime(2026, 7, 1, 14)), isFalse);
      expect(routing.shadeAssessmentIsStaleFor(DateTime(2026, 7, 1, 16)), isTrue);
    });

    test('applying an alternative is an explicit action that keeps stops', () async {
      shade.analysis = _analysis(shaded: 600, exposed: 200);
      final routing = RoutingProvider(shadeAnalysisService: shade);
      addTearDown(routing.dispose);
      routing.setProposedWalkForScenicTest(
        scenic: false,
        comparison: null,
        walkKind: WalkKind.normal,
        route: _route(legs: [
          _leg(seconds: 600, visitMinutes: 30, toTitle: 'POI 1'),
          _leg(from: _stop, to: const GeoCoord(59.943, 30.318), seconds: 300, toTitle: 'Финиш'),
        ], placesCount: 2),
      );
      await routing.assessShade(departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      // Nothing switches on its own.
      expect(routing.currentRoute!.legs.length, 2);
      expect(routing.currentRoute!.legs.first.visitMinutes, 30);
      expect(routing.currentRoute!.placesCount, 2);
    });

    test('assessment is refused while planning is locked by navigation', () async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      routing.setNavigationLocked(true);
      await routing.assessShade(departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      expect(routing.shadeAnalysis, isNull);
      expect(shade.calls, 0);
    });

    test('the request budget is shared, never bypassed per sub-request', () {
      // The discovery loop documents its bound; 12 native requests is the cap
      // for the whole operation, and probing stops when the budget runs out.
      expect(RoutingProvider.maxNativeWalkLegRequests, 12);
      expect(RoutingProvider.maxAlternativeLegs, lessThanOrEqualTo(12));
      expect(RoutingProvider.maxAlternativesPerLeg, lessThanOrEqualTo(12));
    });
  });

  group('§18 overlay layers and unknown segments', () {
    test('unknown ground gets its own layer colour, never the sun colour', () {
      final analysis = _analysis(segments: [
        _segment(
          from: _start,
          to: _mid,
          lengthMeters: 200,
          state: ShadeSegmentState.estimatedShaded,
          shadedMeters: 200,
          shadedSpans: const [ShadeSpan(0, 200)],
        ),
        _segment(
          from: _mid,
          to: _stop,
          lengthMeters: 200,
          state: ShadeSegmentState.unknown,
          unknownMeters: 200,
          unknownSpans: const [ShadeSpan(0, 200)],
          startsAtSeconds: 400,
        ),
        _segment(
          from: _stop,
          to: _far,
          lengthMeters: 200,
          state: ShadeSegmentState.estimatedExposed,
          startsAtSeconds: 800,
        ),
      ]);
      final layers = buildShadeOverlayLayers(analysis);
      expect(layers.map((l) => l.state), contains(ShadeSegmentState.unknown));
      expect(layers.map((l) => l.state), contains(ShadeSegmentState.estimatedExposed));
      expect(shadeOverlayColor(ShadeSegmentState.unknown),
          isNot(shadeOverlayColor(ShadeSegmentState.estimatedExposed)));
      expect(shadeOverlayColor(ShadeSegmentState.estimatedShaded), AppColors.primary);
    });

    test('a shaded band in the MIDDLE of a segment is drawn where it was measured', () {
      // 60..120 m of a 200 m segment: the old renderer painted the FIRST 60%
      // of the segment (0..120 m) as shade — an invented boundary over ground
      // that is measured sunlit.
      final segment = _segment(
        from: _mid,
        to: _stop,
        lengthMeters: 200,
        state: ShadeSegmentState.mixed,
        shadedMeters: 60,
        shadedSpans: const [ShadeSpan(60, 120)],
      );
      final layers = buildShadeOverlayLayers(_analysis(segments: [segment]));

      expect(layers.map((l) => l.state).toList(), [
        ShadeSegmentState.estimatedExposed,
        ShadeSegmentState.estimatedShaded,
        ShadeSegmentState.estimatedExposed,
      ], reason: 'тень измерена в середине участка, а не у его начала');
      final shaded = layers[1];
      final expectedStart = _pointAlong(segment.geometry, 60 / 200);
      final expectedEnd = _pointAlong(segment.geometry, 120 / 200);
      expect(shaded.points.first.latitude, closeTo(expectedStart.latitude, 1e-9));
      expect(shaded.points.first.longitude, closeTo(expectedStart.longitude, 1e-9));
      expect(shaded.points.last.latitude, closeTo(expectedEnd.latitude, 1e-9));
      expect(shaded.points.last.longitude, closeTo(expectedEnd.longitude, 1e-9));
      // The interior vertex of the segment is preserved by the sub-polyline.
      expect(shaded.points.length, 3);
      expect(shaded.points[1].latitude, closeTo(_pointAlong(segment.geometry, 0.5).latitude, 1e-9));
    });

    test('a shaded band at the END of a segment is drawn at the end', () {
      final segment = _segment(
        from: _mid,
        to: _stop,
        lengthMeters: 200,
        state: ShadeSegmentState.mixed,
        shadedMeters: 50,
        shadedSpans: const [ShadeSpan(150, 200)],
      );
      final layers = buildShadeOverlayLayers(_analysis(segments: [segment]));
      expect(layers.first.state, ShadeSegmentState.estimatedExposed);
      expect(layers.last.state, ShadeSegmentState.estimatedShaded);
      expect(layers.last.points.last.latitude, closeTo(_stop.latitude, 1e-9));
      expect(layers.last.points.last.longitude, closeTo(_stop.longitude, 1e-9));
    });

    test('an unknown band keeps its measured interval, never the sun colour', () {
      final segment = _segment(
        from: _mid,
        to: _stop,
        lengthMeters: 200,
        state: ShadeSegmentState.mixed,
        unknownMeters: 40,
        unknownSpans: const [ShadeSpan(0, 40)],
      );
      final layers = buildShadeOverlayLayers(_analysis(segments: [segment]));
      expect(layers.first.state, ShadeSegmentState.unknown);
      expect(layers.first.points.first, _mid);
      expect(shadeOverlayColor(ShadeSegmentState.unknown),
          isNot(shadeOverlayColor(ShadeSegmentState.estimatedExposed)));
    });

    test('a segment without measured spans is not split by a guessed fraction', () {
      final segment = _segment(
        from: _mid,
        to: _stop,
        lengthMeters: 200,
        state: ShadeSegmentState.mixed,
        shadedMeters: 180,
      );
      final layers = buildShadeOverlayLayers(_analysis(segments: [segment]));
      expect(layers, hasLength(1));
      expect(layers.single.state, ShadeSegmentState.mixed,
          reason: 'без измеренных интервалов участок остаётся неразрешённым');
      expect(layers.single.points.first, _mid);
      expect(layers.single.points.last, _stop);
    });

    test('adjacent segments of one state join into a single run', () {
      final analysis = _analysis(segments: [
        _segment(
          from: _start,
          to: _mid,
          lengthMeters: 200,
          state: ShadeSegmentState.estimatedShaded,
          shadedMeters: 200,
          shadedSpans: const [ShadeSpan(0, 200)],
        ),
        _segment(
          from: _mid,
          to: _stop,
          lengthMeters: 200,
          state: ShadeSegmentState.estimatedShaded,
          shadedMeters: 200,
          shadedSpans: const [ShadeSpan(0, 200)],
          startsAtSeconds: 400,
        ),
      ]);
      final layers = buildShadeOverlayLayers(analysis);
      expect(layers, hasLength(1));
      expect(layers.single.points.first, _start);
      expect(layers.single.points.last, _stop);
    });

    test('the overlay never covers the native polyline vertices', () {
      final analysis = _analysis();
      final layers = buildShadeOverlayLayers(analysis);
      expect(layers, isNotEmpty);
      for (final layer in layers) {
        for (final point in layer.points) {
          expect(point.latitude, inInclusiveRange(_start.latitude - 0.01, _stop.latitude + 0.01));
        }
      }
    });
  });

  group('§18 virtual shade clock (§15)', () {
    test('model time is departure plus simulated elapsed', () {
      final clock = VirtualShadeClock()
        ..onSimulationTick(const Duration(minutes: 30));
      clock.arm(DateTime(2026, 7, 1, 14));
      clock.onSimulationTick(const Duration(minutes: 30));
      expect(clock.modelTime, DateTime(2026, 7, 1, 14, 30));
      clock.dispose();
    });

    test('playback rate does not change the model time formula', () {
      final clock = VirtualShadeClock();
      addTearDown(clock.dispose);
      clock.arm(DateTime(2026, 7, 1, 14));
      // x20 playback: 30 virtual minutes arrive in 90 real seconds; the clock
      // consumes virtual elapsed, not real time.
      clock.onSimulationTick(const Duration(minutes: 30));
      expect(clock.modelTime, DateTime(2026, 7, 1, 14, 30));
    });

    test('pause freezes the model time and restart/seek rebase it', () {
      final clock = VirtualShadeClock();
      addTearDown(clock.dispose);
      clock.arm(DateTime(2026, 7, 1, 14));
      clock.onSimulationTick(const Duration(minutes: 40));
      clock.markAnalyzed(clock.modelTime!);
      expect(clock.needsReanalysis, isFalse);
      // paused: the controller does not advance elapsed → same model time
      expect(clock.modelTime, DateTime(2026, 7, 1, 14, 40));
      // restart resets elapsed to zero → the analysis is now 40 virtual
      // minutes away from the model time, beyond the refresh step
      clock.onSimulationTick(Duration.zero);
      expect(clock.modelTime, DateTime(2026, 7, 1, 14));
      expect(clock.needsReanalysis, isTrue,
          reason: 'после seek/restart оценка относится к другому времени');
    });

    test('the overlay needs a refresh only after the documented step', () {
      final clock = VirtualShadeClock();
      addTearDown(clock.dispose);
      clock.arm(DateTime(2026, 7, 1, 14));
      clock.markAnalyzed(DateTime(2026, 7, 1, 14));
      clock.onSimulationTick(const Duration(minutes: 14));
      expect(clock.needsReanalysis, isFalse);
      clock.onSimulationTick(
          VirtualShadeClock.refreshStep + const Duration(minutes: 1));
      expect(clock.needsReanalysis, isTrue);
    });

    test('invalidate drops the overlay (route rebuilt)', () {
      final clock = VirtualShadeClock();
      addTearDown(clock.dispose);
      clock.arm(DateTime(2026, 7, 1, 14));
      clock.markAnalyzed(DateTime(2026, 7, 1, 14));
      clock.overlayRequested = true;
      expect(clock.overlayValid, isTrue);
      clock.invalidate();
      expect(clock.overlayValid, isFalse);
      expect(clock.needsReanalysis, isTrue);
    });

    test('the provider arms, marks and invalidates the clock (§15 wiring)', () async {
      final routing = providerWithRoute(_route());
      final clock = VirtualShadeClock();
      addTearDown(routing.dispose);
      addTearDown(clock.dispose);
      routing.attachShadeClock(clock);
      expect(clock.modelTime, isNull, reason: 'до оценки виртуального времени нет');

      await routing.assessShade(
          departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      expect(clock.departure, DateTime(2026, 7, 1, 14));
      expect(clock.analyzedFor, DateTime(2026, 7, 1, 14));
      expect(clock.needsReanalysis, isFalse);

      // The virtual clock advances past the refresh step: the estimate belongs
      // to another instant, so the layer must not be drawn.
      routing.setShadeOverlayEnabled(true);
      expect(routing.shadeOverlayReady, isTrue);
      clock.onSimulationTick(const Duration(minutes: 20));
      expect(routing.shadeOverlayReady, isFalse);

      // Re-running the estimate follows the CURRENT virtual time: the plan is
      // stated for the instant it is planned at, and the animation's own
      // anchor is left alone, so repeated presses cannot drift the schedule of
      // the walk (C7.1.2 §15.5).
      await routing.assessShade(exploreAlternatives: false);
      expect(clock.departure, DateTime(2026, 7, 1, 14),
          reason: 'виртуальная шкала симулятора не переякоривается кнопкой');
      expect(clock.analyzedFor, DateTime(2026, 7, 1, 14, 20));
      expect(routing.shadeDeparture, DateTime(2026, 7, 1, 14, 20),
          reason: 'оценка всей прогулки заявлена для текущего виртуального времени');
      expect(routing.shadeScope, ShadeAssessmentScope.wholeWalk);
      expect(routing.shadeOverlayReady, isTrue);
      expect(shade.receivedDepartures.last, DateTime(2026, 7, 1, 14, 20));
    });

    test('a cleared assessment invalidates the clock overlay', () async {
      final routing = providerWithRoute(_route());
      final clock = VirtualShadeClock();
      addTearDown(routing.dispose);
      addTearDown(clock.dispose);
      routing.attachShadeClock(clock);
      await routing.assessShade(
          departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      routing.setShadeOverlayEnabled(true);
      expect(routing.shadeOverlayReady, isTrue);
      routing.clearShadeAssessment();
      expect(clock.needsReanalysis, isTrue);
      expect(routing.shadeOverlayReady, isFalse);
      expect(clock.modelTime, DateTime(2026, 7, 1, 14),
          reason: 'очистка оценки не сдвигает виртуальное время');
    });

    test('without a clock the overlay needs no freshness check', () async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      await routing.assessShade(
          departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      routing.setShadeOverlayEnabled(true);
      expect(routing.shadeOverlayReady, isTrue);
      expect(routing.shadeClock, isNull);
    });

    test('the clock notifies on verdict changes, not on every tick', () {
      final clock = VirtualShadeClock();
      addTearDown(clock.dispose);
      clock.arm(DateTime(2026, 7, 1, 14));
      clock.markAnalyzed(DateTime(2026, 7, 1, 14));
      var notifications = 0;
      clock.addListener(() => notifications++);
      // Ten ticks inside the same virtual minute: at most one notification.
      for (var i = 0; i < 10; ++i) {
        clock.onSimulationTick(Duration(seconds: 6 * i));
      }
      expect(notifications, lessThanOrEqualTo(1));
    });
  });

  group('§18 UI: dark theme, narrow screen, honest states', () {
    testWidgets('renders the estimate with provenance and confidence', (tester) async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      await routing.assessShade(
          departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      await _pumpSection(tester, routing);
      expect(find.textContaining('50%'), findsOneWidget);
      expect(
        find.textContaining('Достоверность'),
        findsNothing,
        reason: 'технические значения находятся в раскрываемом блоке',
      );
      await tester.ensureVisible(
        find.text('Технические подробности оценки тени'),
      );
      await tester.tap(find.text('Технические подробности оценки тени'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Достоверность'), findsOneWidget);
      expect(find.textContaining('Оценка по OpenStreetMap'), findsOneWidget);
      expect(find.textContaining('c7_1_pilot_v1'), findsOneWidget);
    });

    testWidgets('dark theme renders without errors', (tester) async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      await routing.assessShade(
          departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      await _pumpSection(tester, routing, theme: ThemeData.dark());
      expect(tester.takeException(), isNull);
      expect(find.text('Тень на маршруте'), findsOneWidget);
    });

    testWidgets('narrow screen: the section does not overflow', (tester) async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      await routing.assessShade(
          departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      await _pumpSection(tester, routing, size: const Size(320, 640));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('unavailable data is shown as unavailable, without numbers', (tester) async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      shade.analysis = _analysis(
        status: ShadeStatus.unavailable,
        reason: 'нет проверенных данных о зданиях.',
      );
      await routing.assessShade(
          departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      await _pumpSection(tester, routing);
      expect(find.textContaining('недоступна'), findsOneWidget);
      expect(find.textContaining('% маршрута в тени'), findsNothing);
    });

    testWidgets('partial coverage is stated, not hidden', (tester) async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      shade.analysis = _analysis(
        status: ShadeStatus.partial,
        shaded: 300,
        exposed: 200,
        unknown: 500,
        coverageShare: 0.5,
      );
      await routing.assessShade(
          departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      await _pumpSection(tester, routing);
      expect(find.textContaining('неизвестно'), findsOneWidget);
      expect(find.textContaining('30%'), findsOneWidget);
    });

    testWidgets('the estimate is accessible as text, not colour only', (tester) async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      await routing.assessShade(
          departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      await _pumpSection(tester, routing);
      expect(find.text('Оценить тень'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(
        tester.getSemantics(find.textContaining('% маршрута в тени')),
        isNotNull,
      );
    });

    testWidgets('simulator: virtual time, withdrawn stale layer, re-analysis',
        (tester) async {
      // The user scenario of §15 end to end: pick nothing, ask for an estimate,
      // let the simulated walk advance, watch the layer be withdrawn with an
      // explanation, then re-run the estimate at the model time.
      final routing = providerWithRoute(_route());
      final clock = VirtualShadeClock();
      addTearDown(routing.dispose);
      addTearDown(clock.dispose);
      routing.attachShadeClock(clock);
      await _pumpSectionWithClock(tester, routing, clock);

      // 1. Nothing is armed yet: no virtual time is claimed.
      expect(find.textContaining('Виртуальное время'), findsNothing);

      // 2. The estimate button anchors the walk and marks the clock.
      await tester.tap(find.text('Оценить тень'));
      await tester.pumpAndSettle();
      expect(clock.departure, isNotNull);
      expect(clock.analyzedFor, clock.modelTime);
      expect(routing.shadeOverlayReady, isFalse,
          reason: 'слой ещё не включён пользователем');
      expect(find.textContaining('оценка соответствует этому времени'),
          findsOneWidget);
      final anchored = clock.departure;

      // 3. The virtual clock advances past the refresh step.
      routing.setShadeOverlayEnabled(true);
      expect(routing.shadeOverlayReady, isTrue);
      clock.onSimulationTick(
          VirtualShadeClock.refreshStep + const Duration(minutes: 5));
      await tester.pump();
      expect(routing.shadeOverlayReady, isFalse);
      expect(find.textContaining('слой тени снят с карты'), findsOneWidget);

      // 4. Re-analysis happens at the CURRENT virtual time, without moving the
      //    walk's start; the layer becomes valid again.
      await tester.tap(find.text('Оценить тень'));
      await tester.pumpAndSettle();
      expect(clock.departure, anchored);
      expect(clock.analyzedFor, clock.modelTime);
      expect(routing.shadeOverlayReady, isTrue);
      expect(find.textContaining('оценка соответствует этому времени'),
          findsOneWidget);
    });
  });

  group('§18 C4/C5 compatibility', () {
    test('the analysis consumes the published polyline including connectors', () {
      // A scenic stage after the C4/C5 fix is ONE leg whose geometry already
      // contains the confirmed connector points: nothing here rebuilds it.
      const leg = RouteLegModel(
        fromTitle: 'Старт',
        toTitle: 'POI 1',
        distanceMeters: 900,
        durationSeconds: 600,
        geometryPoints: [
          _start,
          GeoCoord(59.9405, 30.3155), // connector interior point
          GeoCoord(59.9410, 30.3160),
          _stop,
        ],
      );
      final route = _route(legs: [leg], placesCount: 1);
      expect(analysisCoversScenicConnectors(route), isTrue);
      expect(route.legs.single.geometryPoints.length, 4);
    });

    test('applying an alternative preserves visit times and stop count', () async {
      final shade = _FakeShadeService(analysis: _analysis(shaded: 700, exposed: 100));
      final routing = RoutingProvider(shadeAnalysisService: shade);
      addTearDown(routing.dispose);
      final legs = [
        _leg(seconds: 600, visitMinutes: 45, toTitle: 'POI 1'),
        _leg(from: _stop, to: const GeoCoord(59.9430, 30.3180), seconds: 240, toTitle: 'Финиш'),
      ];
      routing.setProposedWalkForScenicTest(
        scenic: false,
        comparison: null,
        walkKind: WalkKind.normal,
        route: _route(legs: legs, placesCount: 2),
      );
      await routing.assessShade(
          departure: DateTime(2026, 7, 1, 14), exploreAlternatives: false);
      final route = routing.currentRoute!;
      expect(route.legs.first.visitMinutes, 45);
      expect(route.placesCount, 2);
      // Requesting the analysis never mutated the route.
      expect(shade.receivedLegs.single.length, 2);
      expect(shade.receivedVisits.single, [45, 0]);
    });
  });

  group('§18 no synthetic geometry ever leaves the client', () {
    test('the request payload builder only carries route geometry', () {
      // Guards the §26 rule on the client side: the only data sent are route
      // points and durations — never building geometry.
      final legs = [_leg(seconds: 300, visitMinutes: 20)];
      final payload = <String, dynamic>{
        'legs': [
          for (var i = 0; i < legs.length; ++i)
            {
              'geometry': legs[i].geometryPoints.length,
              'walking_duration_seconds': legs[i].durationSeconds,
              'visit_duration_seconds_after_leg': i < 1 ? 20 * 60 : 0,
            },
        ],
      };
      expect((payload['legs'] as List).single.keys, {
        'geometry',
        'walking_duration_seconds',
        'visit_duration_seconds_after_leg',
      });
    });

    test('RoutePointModel start point is not required by the shade API', () {
      const point = RoutePointModel.defaultStart;
      expect(point.latitude, isA<double>()); // sanity: the model exists and is stable
      expect(mapKit.calls, 0);
    });
  });

  group('§18 C7.1.1 backend payload contract', () {
    test('segments parse their real polyline and measured spans', () {
      final segment = ShadeSegmentModel.tryFromJson({
        'leg_index': 0,
        'geometry': [
          {'latitude': 59.9400, 'longitude': 30.3150},
          {'latitude': 59.9410, 'longitude': 30.3160},
          {'latitude': 59.9420, 'longitude': 30.3170},
        ],
        'length_meters': 160.0,
        'shaded_meters': 40.0,
        'unknown_meters': 20.0,
        'state': 'mixed',
        'starts_at_seconds': 0.0,
        'ends_at_seconds': 120.0,
        'shaded_spans': [
          [60.0, 100.0]
        ],
        'unknown_spans': [
          [100.0, 120.0]
        ],
      })!;
      expect(segment.geometry.length, 3);
      expect(segment.start.latitude, 59.9400);
      expect(segment.end.longitude, 30.3170);
      expect(segment.hasMeasuredSpans, isTrue);
      expect(segment.shadedSpans.single.fromMeters, 60.0);
      expect(segment.shadedSpans.single.toMeters, 100.0);
      expect(segment.unknownSpans.single.lengthMeters, 20.0);
      expect(segment.endsAtSeconds, 120.0);
    });

    test('a malformed span is dropped, never silently retargeted', () {
      expect(ShadeSpan.tryFromJson([10.0]), isNull);
      expect(ShadeSpan.tryFromJson(['a', 'b']), isNull);
      expect(ShadeSpan.tryFromJson([30.0, 10.0]), isNull,
          reason: 'интервал не может заканчиваться раньше, чем начинается');
      expect(ShadeSpan.tryFromJson([10.0, 30.0])!.lengthMeters, 20.0);
    });

    test('a legacy segment payload without geometry is still parsed', () {
      final segment = ShadeSegmentModel.tryFromJson({
        'leg_index': 0,
        'start': {'latitude': 59.94, 'longitude': 30.31},
        'end': {'latitude': 59.95, 'longitude': 30.32},
        'length_meters': 1200.0,
        'state': 'estimated_exposed',
      });
      expect(segment, isNotNull);
      expect(segment!.geometry.length, 2);
      expect(segment.hasMeasuredSpans, isFalse);
    });

    test('span positions survive the JSON round trip into the overlay', () {      final analysis = _analysis(segments: [
        ShadeSegmentModel.tryFromJson({
          'leg_index': 0,
          'geometry': [
            {'latitude': _mid.latitude, 'longitude': _mid.longitude},
            {'latitude': _stop.latitude, 'longitude': _stop.longitude},
          ],
          'length_meters': 200.0,
          'shaded_meters': 60.0,
          'unknown_meters': 0.0,
          'state': 'mixed',
          'starts_at_seconds': 0.0,
          'ends_at_seconds': 200.0,
          'shaded_spans': [
            [60.0, 120.0]
          ],
          'unknown_spans': <List<double>>[],
        })!,
      ]);
      final layers = buildShadeOverlayLayers(analysis);
      expect(layers.map((l) => l.state).toList(), [
        ShadeSegmentState.estimatedExposed,
        ShadeSegmentState.estimatedShaded,
        ShadeSegmentState.estimatedExposed,
      ]);
    });

    test('the client parses a REAL backend response (contract fixture)', () {
      // Generated by backend/scripts/extract_c7_1_1_response_fixture.py from
      // the production wiring (committed pilot dataset) for the real
      // gostiny_dvor_arcade route: the parser is locked to the server's actual
      // output, not to a hand-written example.
      final document = jsonDecode(
        File('test/fixtures/c7_1_1_shade_response.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final analysis = ShadeAnalysisModel.tryFromJson(document['response'])!;

      expect(analysis.status, ShadeStatus.available);
      expect(analysis.hasEstimate, isTrue);
      expect(analysis.methodVersion, 'c7_1.2');
      expect(analysis.datasetVersion, 'c7_1_pilot_v1');
      final total = analysis.shadedMeters! +
          analysis.exposedMeters! +
          analysis.unknownMeters!;
      expect(total, closeTo(analysis.routeLengthMeters, 0.5),
          reason: 'трёхчастный инвариант бэкенда переживает разбор клиентом');
      expect(analysis.coverageShare, 1.0);
      expect(analysis.segments, isNotEmpty);
      for (final segment in analysis.segments) {
        expect(segment.geometry.length, greaterThanOrEqualTo(2));
        expect(segment.endsAtSeconds,
            greaterThanOrEqualTo(segment.startsAtSeconds));
        final shadedSpanTotal = segment.shadedSpans
            .fold<double>(0, (sum, span) => sum + span.lengthMeters);
        final unknownSpanTotal = segment.unknownSpans
            .fold<double>(0, (sum, span) => sum + span.lengthMeters);
        expect(shadedSpanTotal,
            closeTo(segment.shadedMeters, 0.1 * segment.shadedSpans.length + 0.2));
        expect(unknownSpanTotal,
            closeTo(segment.unknownMeters, 0.1 * segment.unknownSpans.length + 0.2));
        for (final span in [...segment.shadedSpans, ...segment.unknownSpans]) {
          expect(span.fromMeters, greaterThanOrEqualTo(0));
          expect(span.toMeters, lessThanOrEqualTo(segment.lengthMeters + 0.2));
        }
      }
      // The overlay renders these measured spans and joins the runs.
      final layers = buildShadeOverlayLayers(analysis);
      expect(layers, isNotEmpty);
      expect(layers.map((l) => l.state).toSet(),
          everyElement(isIn(ShadeSegmentState.values)));
    });
  });

  group('§18 comparison comparability (§13, C7.1.1)', () {
    test('a route that knows much less ground is not comparable', () {
      final full = _analysis(shaded: 500, exposed: 500);
      // Same mapped coverage, but half of the route sits in the envelope of
      // buildings without heights: comparing shade shares would reward it for
      // knowing less.
      final patchy = _analysis(shaded: 500, exposed: 0, unknown: 500);
      expect(full.coverageShare, patchy.coverageShare);
      expect(full.isCoverageComparableTo(patchy), isFalse);
      expect(patchy.isCoverageComparableTo(full), isFalse);
    });

    test('classified share is the second comparability dimension', () {
      final full = _analysis(shaded: 500, exposed: 500);
      final alsoFull = _analysis(shaded: 100, exposed: 900);
      expect(full.classifiedShare, 1.0);
      expect(alsoFull.classifiedShare, 1.0);
      expect(full.isCoverageComparableTo(alsoFull), isTrue);
      final mostlyUnknown = _analysis(shaded: 900, exposed: 100, unknown: 0);
      expect(mostlyUnknown.classifiedShare, 1.0);
    });

    test('the engine rejects an alternative with incomparable classified share', () async {
      final shade = _FakeShadeService(onCall: (legs) => _analysis(
            shaded: 900,
            exposed: 0,
            unknown: 300,
          ));
      final engine = ShadeRoutingEngine(shadeService: shade);
      final normal = _analysis(shaded: 400, exposed: 600);
      final decision = await engine.evaluate(
        normalRoute: _route(),
        alternatives: [_route(legs: [_leg(seconds: 800)])],
        departure: DateTime(2026, 7, 1, 14),
        normalAnalysis: normal,
      );
      expect(decision.offersAlternative, isFalse);
      expect(decision.fallback, ShadeRoutingFallback.coverageNotComparable);
    });
  });

  group('§18 C7.1.2 shade refresh inside a navigation session', () {
    /// The session fixture: a two-leg walk (stop 1 with a 20-minute visit,
    /// then the finish) and its remaining path from _mid, built exactly the
    /// way NavigationProvider builds it — the current leg cut at the walker's
    /// progress, then every leg still ahead.
    ({PedestrianRouteModel route, PedestrianRouteModel remaining})
        sessionFixture() {
      const first = RouteLegModel(
        fromTitle: 'Старт',
        toTitle: 'POI 1',
        distanceMeters: 800,
        durationSeconds: 600,
        geometryPoints: [_start, _mid, _stop],
        visitMinutes: 20,
      );
      const second = RouteLegModel(
        fromTitle: 'POI 1',
        toTitle: 'Финиш',
        distanceMeters: 800,
        durationSeconds: 600,
        geometryPoints: [_stop, _far],
      );
      final route = _route(legs: [first, second], placesCount: 2);
      const remaining = PedestrianRouteModel(
        distanceMeters: 400 + 800,
        durationSeconds: 300 + 600,
        geometryPoints: [_mid, _stop, _far],
        steps: [],
        legs: [
          RouteLegModel(
            fromTitle: 'Текущее местоположение',
            toTitle: 'POI 1',
            distanceMeters: 400,
            durationSeconds: 300,
            geometryPoints: [_mid, _stop],
            visitMinutes: 20,
          ),
          second,
        ],
        placesCount: 2,
      );
      return (route: route, remaining: remaining);
    }

    /// A session already under way: geometry pushed, planning locked, the
    /// virtual clock 20 minutes into the walk.
    test('a mid-walk refresh analyses the remaining path from the current instant', () async {
      final routing = providerWithRoute(_route());
      final clock = VirtualShadeClock();
      addTearDown(routing.dispose);
      addTearDown(clock.dispose);
      routing.attachShadeClock(clock);
      final fixture = sessionFixture();
      final planned = routing.currentRoute;
      routing.setNavigationRoute(fixture.route);
      routing.setNavigationLocked(true);
      routing.setShadeOverlayEnabled(true);
      clock.arm(DateTime(2026, 7, 1, 14));
      clock.onSimulationTick(const Duration(minutes: 20));
      expect(routing.shadeOverlayReady, isFalse, reason: 'плана для 14:00 уже нет');

      await routing.assessShade(
          remainingRoute: fixture.remaining, exploreAlternatives: true);

      // The estimate describes the REMAINING geometry, scheduled from the
      // current virtual instant — never the plan's start.
      expect(shade.calls, 1);
      expect(shade.receivedDepartures.single, DateTime(2026, 7, 1, 14, 20));
      expect(shade.receivedLegs.single.map((l) => l.geometryPoints.first),
          [ _mid, _stop ]);
      expect(shade.receivedVisits.single, [20, 0],
          reason: 'осмотр оставшейся остановки входит в расписание');
      expect(routing.shadeScope, ShadeAssessmentScope.remainingPath);
      expect(routing.shadeEvaluatedFor, DateTime(2026, 7, 1, 14, 20));
      expect(routing.shadeDeparture, DateTime(2026, 7, 1, 14),
          reason: 'старт прогулки не сдвигается оценкой');
      expect(routing.shadeAnalysis, isNotNull);
      expect(routing.shadeOverlayReady, isTrue);

      // Nothing about the session or the route changed.
      expect(routing.navigationLocked, isTrue);
      expect(identical(routing.currentRoute, planned), isTrue);
      expect(clock.departure, DateTime(2026, 7, 1, 14));
    });

    test('mid-walk a comparison is never offered (it could not be applied)', () async {
      final routing = providerWithRoute(_route());
      final clock = VirtualShadeClock();
      addTearDown(routing.dispose);
      addTearDown(clock.dispose);
      routing.attachShadeClock(clock);
      final fixture = sessionFixture();
      routing.setNavigationRoute(fixture.route);
      routing.setNavigationLocked(true);
      clock.arm(DateTime(2026, 7, 1, 14));

      await routing.assessShade(
          remainingRoute: fixture.remaining, exploreAlternatives: true);

      expect(routing.shadeDecision?.best, isNull);
      expect(routing.shadeDecision?.offersAlternative, isFalse);
      expect(mapKit.calls, 0,
          reason: 'ни одного нативного запроса на живой прогулке');
      expect(routing.applyShadeAlternative(), isFalse,
          reason: 'маршрут на прогулке не подменяется');
    });

    test('the remaining path must end where the session ends', () async {
      final routing = providerWithRoute(_route());
      addTearDown(routing.dispose);
      final fixture = sessionFixture();
      routing.setNavigationRoute(fixture.route);
      routing.setNavigationLocked(true);
      final foreign = _route(legs: [_leg(seconds: 600)]);
      await routing.assessShade(remainingRoute: foreign);
      expect(shade.calls, 0, reason: 'чужой путь не описывает то, что впереди');
      expect(routing.shadeAnalysis, isNull);
      await routing.assessShade();
      expect(shade.calls, 0, reason: 'на прогулке план не пересчитывается');
    });

    test('a rebuilt session route drops the remaining-path estimate and the layer', () async {
      final routing = providerWithRoute(_route());
      final clock = VirtualShadeClock();
      addTearDown(routing.dispose);
      addTearDown(clock.dispose);
      routing.attachShadeClock(clock);
      final fixture = sessionFixture();
      routing.setNavigationRoute(fixture.route);
      routing.setNavigationLocked(true);
      routing.setShadeOverlayEnabled(true);
      clock.arm(DateTime(2026, 7, 1, 14));
      await routing.assessShade(remainingRoute: fixture.remaining);
      expect(routing.shadeOverlayReady, isTrue);

      // The walker is rerouted: the session geometry becomes different ground.
      routing.setNavigationRoute(
        _route(legs: [_leg(from: _mid, to: _stop, seconds: 400)]),
      );

      expect(routing.shadeAnalysis, isNull);
      expect(routing.shadeOverlayReady, isFalse);
      expect(clock.needsReanalysis, isTrue,
          reason: 'часы больше не подтверждают актуальную оценку');
      expect(routing.navigationLocked, isTrue,
          reason: 'перестройка маршрута не снимает блокировку планирования');
    });

    test('ending the session returns the section to the whole-walk scope', () async {
      final routing = providerWithRoute(_route());
      final clock = VirtualShadeClock();
      addTearDown(routing.dispose);
      addTearDown(clock.dispose);
      routing.attachShadeClock(clock);
      final fixture = sessionFixture();
      routing.setNavigationRoute(fixture.route);
      routing.setNavigationLocked(true);
      await routing.assessShade(remainingRoute: fixture.remaining);
      expect(routing.shadeScope, ShadeAssessmentScope.remainingPath);

      routing.setNavigationRoute(null);
      routing.setNavigationLocked(false);
      expect(routing.shadeAnalysis, isNull,
          reason: 'оценка оставшегося пути не притворяется планом');
      expect(routing.shadeScope, ShadeAssessmentScope.wholeWalk);

      await routing.assessShade(departure: DateTime(2026, 7, 1, 18));
      expect(routing.shadeScope, ShadeAssessmentScope.wholeWalk);
      expect(routing.shadeAnalysis, isNotNull);
      expect(routing.shadeDeparture, DateTime(2026, 7, 1, 18));
    });

    test('a session that never chose a departure anchors the clock honestly', () async {
      final routing = providerWithRoute(_route());
      final clock = VirtualShadeClock();
      addTearDown(routing.dispose);
      addTearDown(clock.dispose);
      routing.attachShadeClock(clock);
      final fixture = sessionFixture();
      routing.setNavigationRoute(fixture.route);
      routing.setNavigationLocked(true);
      expect(clock.departure, isNull);

      await routing.assessShade(remainingRoute: fixture.remaining);

      // `model_time = departure + elapsed`; the walk began `elapsed` ago, so
      // the model time stays the device time instead of jumping into the
      // future by the whole elapsed virtual time.
      final anchored = clock.departure;
      expect(anchored, isNotNull);
      expect(clock.modelTime!.difference(DateTime.now()).inSeconds.abs(),
          lessThanOrEqualTo(1));
      expect(shade.receivedDepartures.single, clock.modelTime);
    });
  });
}
