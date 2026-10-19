import 'package:flutter/material.dart' show Color;

import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';

/// Typed fallback reasons (§13.2). Every one maps to one Russian sentence in
/// the UI; the UI never shows a technical code and never offers a "shaded"
/// route that was not actually built and verified.
enum ShadeRoutingFallback {
  /// No real MapKit alternative existed for any leg (or none was requested).
  noAlternatives,

  /// An alternative existed, but its shade could not be estimated.
  insufficientShadeData,

  /// The alternative would need more walking than the configured allowance.
  detourTooLong,

  /// The alternative would break the selected Smart Walk budget.
  budgetExceeded,

  /// The shade gain is too small to justify a different route.
  trivialGain,

  /// The alternative's data coverage is worse — the comparison would be unfair.
  coverageNotComparable,

  /// The shade service could not be reached.
  serviceUnavailable,
}

extension ShadeRoutingFallbackMessage on ShadeRoutingFallback {
  String get message => switch (this) {
    ShadeRoutingFallback.noAlternatives =>
      'MapKit не предложил альтернативных пешеходных маршрутов — доступен обычный маршрут.',
    ShadeRoutingFallback.insufficientShadeData =>
      'Не удалось надёжно подобрать более затенённый пешеходный маршрут: данных о зданиях недостаточно. Доступен обычный маршрут.',
    ShadeRoutingFallback.detourTooLong =>
      'Более затенённый вариант требует слишком большой дополнительной ходьбы. Доступен обычный маршрут.',
    ShadeRoutingFallback.budgetExceeded =>
      'Более затенённый вариант не укладывается в выбранный бюджет прогулки. Доступен обычный маршрут.',
    ShadeRoutingFallback.trivialGain =>
      'Разница в тени незначительна — оставлен обычный маршрут.',
    ShadeRoutingFallback.coverageNotComparable =>
      'Сравнение невозможно: у вариантов разное качество данных о зданиях. Доступен обычный маршрут.',
    ShadeRoutingFallback.serviceUnavailable =>
      'Сервис оценки тени недоступен. Доступен обычный маршрут.',
  };
}

/// The comparison's documented, explainable constants (§13). They are
/// decision thresholds, not measurements: each one is a product decision that
/// is stated here so a reviewer can change it in one place.
class ShadeRoutingTuning {
  /// Minimum shade gain (fraction of comparable length) worth a detour.
  static const double minShadeGain = 0.10;

  /// Disutility of one extra minute of walking, in shade-fraction units.
  static const double timePenaltyPerMinute = 0.01;

  /// Absolute allowance for extra walking time on any smaller detour.
  static const double maxExtraMinutes = 10.0;

  /// Relative allowance: the alternative may not exceed this share of the
  /// normal walking time.
  static const double maxExtraMinutesShare = 0.25;

  /// Coverage difference above which two routes are not comparable (§13).
  static const double maxCoverageDelta = 0.10;

  /// A candidate whose confidence is lower than the normal route's needs this
  /// much extra gain to be offered anyway.
  static const double lowerConfidenceGainMargin = 0.20;
}

/// One evaluated alternative: the REAL route produced by MapKit plus the
/// backend's estimate for it.
class ShadeRouteCandidate {
  final String label;
  final PedestrianRouteModel route;
  final ShadeAnalysisModel analysis;

  /// Extra walking time versus the normal route, in minutes (can be negative).
  final double extraMinutes;

  /// Extra walking distance versus the normal route, in metres.
  final double extraMeters;

  /// Utility used for ranking; higher is better. Null when rejected.
  final double? utility;

  /// Why this candidate was rejected, if it was.
  final ShadeRoutingFallback? rejection;

  const ShadeRouteCandidate({
    required this.label,
    required this.route,
    required this.analysis,
    required this.extraMinutes,
    required this.extraMeters,
    required this.utility,
    this.rejection,
  });

  bool get isOfferable => rejection == null && utility != null;
}

/// Outcome of the comparison: either an offerable candidate or a typed reason
/// why the normal route stays.
class ShadeRoutingDecision {
  final ShadeAnalysisModel normalAnalysis;
  final ShadeRouteCandidate? best;
  final ShadeRoutingFallback? fallback;
  final List<ShadeRouteCandidate> evaluated;

  const ShadeRoutingDecision({
    required this.normalAnalysis,
    required this.best,
    required this.fallback,
    required this.evaluated,
  });

  bool get offersAlternative => best != null;
}

/// Compares real MapKit walking alternatives by shade and decides, with
/// documented gates, whether one may be offered to the tourist.
///
/// Honesty rules encoded here:
/// * only REAL MapKit geometry is ever compared — the engine never invents a
///   route, a detour or a shade number;
/// * routes with incomparable data coverage are not compared (§13);
/// * the Smart Walk budget invariant (walking + visits ≤ budget) is enforced;
/// * a tiny gain does not justify a different route.
class ShadeRoutingEngine {
  final BaseShadeAnalysisService _shadeService;

  ShadeRoutingEngine({BaseShadeAnalysisService? shadeService})
    : _shadeService = shadeService ?? BackendShadeAnalysisService();

  List<int> _visitMinutes(List<RouteLegModel> legs) => [
    // A visit belongs after every leg except the last, which ends the walk at
    // the destination stop.
    for (var i = 0; i < legs.length; ++i)
      i < legs.length - 1 ? (legs[i].visitMinutes ?? 0) : 0,
  ];

  /// Evaluates the normal route and every real alternative against the
  /// departure time and the selected budget.
  ///
  /// [budgetMinutes] is the Smart Walk budget the user selected (nullable for
  /// a plain point-to-point route, where only the detour allowance applies).
  Future<ShadeRoutingDecision> evaluate({
    required PedestrianRouteModel normalRoute,
    required List<PedestrianRouteModel> alternatives,
    required DateTime departure,
    int? budgetMinutes,
    ShadeAnalysisModel? normalAnalysis,
  }) async {
    final normal = normalAnalysis ??
        await _shadeService.analyzeWalk(
          departure: departure,
          legs: normalRoute.legs,
          visitMinutesAfterLeg: _visitMinutes(normalRoute.legs),
        );

    if (alternatives.isEmpty) {
      return ShadeRoutingDecision(
        normalAnalysis: normal,
        best: null,
        fallback: ShadeRoutingFallback.noAlternatives,
        evaluated: const [],
      );
    }

    final normalWalkSeconds = _walkingSeconds(normalRoute);
    final normalVisitSeconds = _visitSeconds(normalRoute);
    final evaluated = <ShadeRouteCandidate>[];
    var sawFailure = false;

    for (var index = 0; index < alternatives.length; ++index) {
      final alternative = alternatives[index];
      final label = 'Вариант ${index + 1}';
      ShadeAnalysisModel analysis;
      try {
        analysis = await _shadeService.analyzeWalk(
          departure: departure,
          legs: alternative.legs,
          visitMinutesAfterLeg: _visitMinutes(alternative.legs),
        );
      } on ShadeAnalysisFailure catch (failure) {
        sawFailure = true;
        evaluated.add(ShadeRouteCandidate(
          label: label,
          route: alternative,
          analysis: normal, // placeholder: never offerable without real data
          extraMinutes: 0,
          extraMeters: 0,
          utility: null,
          rejection: failure.kind == ShadeAnalysisFailureKind.serviceUnavailable
              ? ShadeRoutingFallback.serviceUnavailable
              : ShadeRoutingFallback.insufficientShadeData,
        ));
        continue;
      }

      final extraSeconds = _walkingSeconds(alternative) - normalWalkSeconds;
      final extraMeters = alternative.distanceMeters - normalRoute.distanceMeters;
      final extraMinutes = extraSeconds / 60.0;
      final rejection = _reject(
        normal: normal,
        candidate: analysis,
        extraMinutes: extraMinutes,
        budgetMinutes: budgetMinutes,
        normalWalkSeconds: normalWalkSeconds,
        normalVisitSeconds: normalVisitSeconds,
      );
      evaluated.add(ShadeRouteCandidate(
        label: label,
        route: alternative,
        analysis: analysis,
        extraMinutes: extraMinutes,
        extraMeters: extraMeters,
        utility: rejection == null ? _utility(normal, analysis, extraMinutes) : null,
        rejection: rejection,
      ));
    }

    final offerable = evaluated.where((c) => c.isOfferable).toList()
      ..sort((a, b) => b.utility!.compareTo(a.utility!));

    if (offerable.isNotEmpty) {
      return ShadeRoutingDecision(
        normalAnalysis: normal,
        best: offerable.first,
        fallback: null,
        evaluated: evaluated,
      );
    }

    return ShadeRoutingDecision(
      normalAnalysis: normal,
      best: null,
      fallback: _fallbackOf(evaluated, sawFailure: sawFailure),
      evaluated: evaluated,
    );
  }

  double _walkingSeconds(PedestrianRouteModel route) {
    final legs = route.legs;
    if (legs.isEmpty) return route.durationSeconds.toDouble();
    return legs.fold<double>(0, (sum, leg) => sum + leg.durationSeconds);
  }

  double _visitSeconds(PedestrianRouteModel route) {
    // Budget semantics: the Smart Walk invariant is
    // `native walking + ALL POI visits <= budget`, and the destination's visit
    // counts (RoutingProvider.visitDurationMinutes sums every walk place).
    // The shade PAYLOAD still sends 0 for the last leg — nothing is walked
    // after it, so its visit cannot shade anything — but the budget gate here
    // must not under-count it.
    return route.legs.fold<double>(
        0, (sum, leg) => sum + (leg.visitMinutes ?? 0) * 60);
  }

  /// Null when the candidate passes every gate, otherwise the typed reason.
  ShadeRoutingFallback? _reject({
    required ShadeAnalysisModel normal,
    required ShadeAnalysisModel candidate,
    required double extraMinutes,
    required int? budgetMinutes,
    required double normalWalkSeconds,
    required double normalVisitSeconds,
  }) {
    if (!candidate.hasEstimate) {
      return ShadeRoutingFallback.insufficientShadeData;
    }
    if (!candidate.isCoverageComparableTo(normal)) {
      return ShadeRoutingFallback.coverageNotComparable;
    }
    final allowance = extraMinutes < 0
        ? ShadeRoutingTuning.maxExtraMinutes
        : (normalWalkSeconds / 60.0 * ShadeRoutingTuning.maxExtraMinutesShare)
            .clamp(0.0, ShadeRoutingTuning.maxExtraMinutes);
    if (extraMinutes > allowance) {
      return ShadeRoutingFallback.detourTooLong;
    }
    if (budgetMinutes != null) {
      final totalSeconds =
          normalWalkSeconds + normalVisitSeconds + extraMinutes * 60.0;
      if (totalSeconds > budgetMinutes * 60.0 + 0.5) {
        return ShadeRoutingFallback.budgetExceeded;
      }
    }
    final gain = _shadeGain(normal, candidate);
    if (gain < ShadeRoutingTuning.minShadeGain) {
      return ShadeRoutingFallback.trivialGain;
    }
    if (_confidenceRank(candidate.confidence) < _confidenceRank(normal.confidence) &&
        gain < ShadeRoutingTuning.lowerConfidenceGainMargin) {
      return ShadeRoutingFallback.trivialGain;
    }
    return null;
  }

  double _shadeGain(ShadeAnalysisModel normal, ShadeAnalysisModel candidate) {
    final normalShade = normal.comparableShadeFraction;
    final candidateShade = candidate.comparableShadeFraction;
    if (normalShade == null || candidateShade == null) return 0.0;
    return candidateShade - normalShade;
  }

  /// Utility = shade gain on comparable ground − walking time penalty.
  ///
  /// Both terms are in the same units (shade fraction), so the trade-off is
  /// legible: 10 extra minutes cost 0.10 of shade gain, which is exactly the
  /// minimum gain worth offering.
  double _utility(ShadeAnalysisModel normal, ShadeAnalysisModel candidate,
      double extraMinutes) {
    final gain = _shadeGain(normal, candidate);
    final penalty = extraMinutes > 0
        ? extraMinutes * ShadeRoutingTuning.timePenaltyPerMinute
        : 0.0;
    return gain - penalty;
  }

  int _confidenceRank(ShadeConfidence confidence) => switch (confidence) {
    ShadeConfidence.high => 3,
    ShadeConfidence.medium => 2,
    ShadeConfidence.low => 1,
    ShadeConfidence.unavailable => 0,
  };

  ShadeRoutingFallback _fallbackOf(List<ShadeRouteCandidate> evaluated,
      {required bool sawFailure}) {
    if (evaluated.isEmpty) return ShadeRoutingFallback.noAlternatives;
    final rejections = evaluated
        .map((c) => c.rejection)
        .whereType<ShadeRoutingFallback>()
        .toSet();
    if (rejections.isEmpty) return ShadeRoutingFallback.noAlternatives;
    // The most concrete reason wins: a service failure is more informative
    // than a generic trivial gain, and an uncomparable coverage more than a
    // detour length.
    for (final preferred in const [
      ShadeRoutingFallback.serviceUnavailable,
      ShadeRoutingFallback.coverageNotComparable,
      ShadeRoutingFallback.budgetExceeded,
      ShadeRoutingFallback.detourTooLong,
      ShadeRoutingFallback.insufficientShadeData,
      ShadeRoutingFallback.trivialGain,
    ]) {
      if (rejections.contains(preferred)) return preferred;
    }
    return sawFailure
        ? ShadeRoutingFallback.insufficientShadeData
        : ShadeRoutingFallback.noAlternatives;
  }
}

/// Shade overlay rendering model: one polyline per visual state.
///
/// Unknown segments are their own class on purpose — drawing them as sun
/// would be a fabricated claim, and there are no data to draw them as shade.
class ShadeOverlayLayer {
  final ShadeSegmentState state;
  final List<GeoCoord> points;

  const ShadeOverlayLayer({required this.state, required this.points});
}

/// One drawn piece of a classified segment: a measured interval and its state.
class _OverlayPiece {
  final ShadeSegmentState state;
  final double fromMeters;
  final double toMeters;

  const _OverlayPiece(this.state, this.fromMeters, this.toMeters);
}

bool _samePosition(GeoCoord a, GeoCoord b) =>
    a.latitude == b.latitude && a.longitude == b.longitude;

/// Builds the overlay polylines from the MEASURED band positions.
///
/// The map draws what the backend measured: `shaded_spans` / `unknown_spans`
/// give the intervals of each segment in metres from its start, and the
/// remainder of the segment is `estimated_exposed`. Nothing here splits a
/// segment by a fraction — 20 m of shade in a 40 m segment may sit at its
/// start, its middle or its end, and only the spans know which.
///
/// A segment without spans (an older backend) is drawn as its whole-slice
/// state in the mixed/undetermined colour: an honest "not resolved further"
/// instead of a guessed boundary.
List<ShadeOverlayLayer> buildShadeOverlayLayers(ShadeAnalysisModel analysis) {
  final layers = <ShadeOverlayLayer>[];
  final runPoints = <GeoCoord>[];
  ShadeSegmentState? runState;

  void closeRun() {
    if (runState != null && runPoints.length >= 2) {
      layers.add(ShadeOverlayLayer(
          state: runState!, points: List.unmodifiable(runPoints)));
    }
    runPoints.clear();
    runState = null;
  }

  void addPiece(ShadeSegmentState state, List<GeoCoord> points) {
    if (points.length < 2) return;
    if (runState != state) {
      closeRun();
      runState = state;
    }
    for (final point in points) {
      if (runPoints.isEmpty || !_samePosition(point, runPoints.last)) {
        runPoints.add(point);
      }
    }
  }

  for (final segment in analysis.segments) {
    if (!segment.hasMeasuredSpans) {
      addPiece(
        segment.state == ShadeSegmentState.mixed
            ? ShadeSegmentState.mixed
            : segment.state,
        segment.geometry,
      );
      continue;
    }
    final cumulative = _cumulativeLengths(segment.geometry);
    final total = cumulative.last;
    if (total <= 0 || segment.lengthMeters <= 0) continue;
    for (final piece in _measuredPieces(segment)) {
      final from = piece.fromMeters / segment.lengthMeters * total;
      final to = piece.toMeters / segment.lengthMeters * total;
      addPiece(piece.state, _subPolyline(segment.geometry, cumulative, from, to));
    }
  }
  closeRun();
  return layers;
}

/// The measured partition of a segment: shaded and unknown intervals as
/// reported, the gaps between them as exposed. Spans are disjoint, so the
/// order is well defined and the whole segment is covered exactly once.
List<_OverlayPiece> _measuredPieces(ShadeSegmentModel segment) {
  final marked = <_OverlayPiece>[
    for (final span in segment.shadedSpans)
      _OverlayPiece(ShadeSegmentState.estimatedShaded, span.fromMeters, span.toMeters),
    for (final span in segment.unknownSpans)
      _OverlayPiece(ShadeSegmentState.unknown, span.fromMeters, span.toMeters),
  ]..sort((a, b) => a.fromMeters.compareTo(b.fromMeters));

  final pieces = <_OverlayPiece>[];
  var cursor = 0.0;
  for (final piece in marked) {
    if (piece.fromMeters > cursor + 1e-6) {
      pieces.add(_OverlayPiece(
          ShadeSegmentState.estimatedExposed, cursor, piece.fromMeters));
    }
    pieces.add(piece);
    cursor = piece.toMeters > cursor ? piece.toMeters : cursor;
  }
  if (cursor < segment.lengthMeters - 1e-6) {
    pieces.add(_OverlayPiece(
        ShadeSegmentState.estimatedExposed, cursor, segment.lengthMeters));
  }
  return pieces;
}

List<double> _cumulativeLengths(List<GeoCoord> points) {
  final cumulative = <double>[0];
  for (var i = 1; i < points.length; ++i) {
    cumulative.add(cumulative[i - 1] +
        RouteProjectionUtils.distanceBetween(points[i - 1], points[i]));
  }
  return cumulative;
}

/// The part of a polyline between two distances, keeping every interior vertex
/// and interpolating the ends — the overlay follows the real walkway turns.
List<GeoCoord> _subPolyline(
    List<GeoCoord> points, List<double> cumulative, double from, double to) {
  if (points.length < 2 || to - from <= 0) return const [];
  final total = cumulative.last;
  final start = from.clamp(0.0, total);
  final end = to.clamp(0.0, total);
  if (end - start <= 0) return const [];
  final out = <GeoCoord>[_pointAtDistance(points, cumulative, start)];
  for (var i = 1; i < points.length - 1; ++i) {
    if (cumulative[i] > start && cumulative[i] < end) {
      out.add(points[i]);
    }
  }
  final endPoint = _pointAtDistance(points, cumulative, end);
  if (!_samePosition(out.last, endPoint)) out.add(endPoint);
  return out;
}

GeoCoord _pointAtDistance(
    List<GeoCoord> points, List<double> cumulative, double distance) {
  if (distance <= 0) return points.first;
  if (distance >= cumulative.last) return points.last;
  for (var i = 1; i < points.length; ++i) {
    if (cumulative[i] >= distance) {
      final segment = cumulative[i] - cumulative[i - 1];
      final fraction = segment <= 0 ? 0.0 : (distance - cumulative[i - 1]) / segment;
      return GeoCoord(
        points[i - 1].latitude +
            (points[i].latitude - points[i - 1].latitude) * fraction,
        points[i - 1].longitude +
            (points[i].longitude - points[i - 1].longitude) * fraction,
      );
    }
  }
  return points.last;
}

/// Scenic compatibility helper: shade analysis consumes the PUBLISHED
/// polyline including confirmed scenic connectors, because every leg in the
/// snapshot carries its post-confirmation geometry (C4/C5 fix 521b0c1).
/// Nothing here rebuilds or re-derives a route.
bool analysisCoversScenicConnectors(PedestrianRouteModel route) =>
    route.legs.every((leg) => leg.geometryPoints.length >= 2);

/// Overlay colours (§14.4), taken from the app palette: royal navy for
/// estimated shade, warm amber for estimated sun, muted grey for unknown.
/// Unknown gets its own colour on purpose — it is neither shade nor sun.
Color shadeOverlayColor(ShadeSegmentState state) => switch (state) {
  ShadeSegmentState.estimatedShaded => AppColors.primary,
  ShadeSegmentState.mixed => AppColors.primaryLight,
  ShadeSegmentState.estimatedExposed => const Color(0xFFF59E0B),
  ShadeSegmentState.unknown => const Color(0xFF94A3B8),
};
