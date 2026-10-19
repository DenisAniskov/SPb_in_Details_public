import 'dart:math' as math;

import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';
import 'package:smart_navigator_spb/services/scenic_stage_builder.dart';

enum QuietFallbackReason {
  none,
  noBaseline,
  noAlternatives,
  invalidAlternative,
  insufficientBudget,
  analysisUnavailable,
  insufficientCoverage,
  notQuieter,
  tooMuchDetour,
  cancelled,
}

String? quietFallbackReasonText(QuietFallbackReason reason) => switch (reason) {
  QuietFallbackReason.none => null,
  QuietFallbackReason.noBaseline =>
    'Не удалось получить базовую оценку дорожной сети для обычного маршрута.',
  QuietFallbackReason.noAlternatives => 'MapKit не предложил подтверждённых пешеходных альтернатив для этой прогулки.',
  QuietFallbackReason.invalidAlternative =>
    'MapKit предложил альтернативу, которая не сходится с маршрутом по геометрии '
        'или манёврам. Обычный маршрут сохранён.',
  QuietFallbackReason.insufficientBudget =>
    'Для проверки более тихого варианта не осталось доступных запросов MapKit. '
        'Обычный маршрут сохранён.',
  QuietFallbackReason.analysisUnavailable =>
    'Сервис оценки тишины не ответил. Обычный маршрут сохранён.',
  QuietFallbackReason.insufficientCoverage =>
    'У альтернатив нет сопоставимого покрытия проверенными дорожными данными, '
        'поэтому сравнение было бы нечестным.',
  QuietFallbackReason.notQuieter => 'Подтверждённого более тихого варианта с сопоставимым покрытием не нашлось.',
  QuietFallbackReason.tooMuchDetour =>
    'Найденные альтернативы требуют слишком большого дополнительного времени '
        'или расстояния.',
  QuietFallbackReason.cancelled => 'Проверка отменена.',
};

/// One transparent normal-vs-quieter comparison. It stores only real native
/// candidates and backend estimates; it never synthesises geometry.
class QuietRoutingDecision {
  const QuietRoutingDecision({
    required this.normalRoute,
    required this.normalAnalysis,
    required this.candidateRoute,
    required this.candidateAnalysis,
    required this.improvement,
    required this.extraDistanceMeters,
    required this.extraWalkingSeconds,
    required this.normalCoverageShare,
    required this.candidateCoverageShare,
    required this.fallbackReason,
  });

  final PedestrianRouteModel normalRoute;
  final QuietAnalysisModel normalAnalysis;
  final PedestrianRouteModel? candidateRoute;
  final QuietAnalysisModel? candidateAnalysis;
  final double? improvement;
  final double extraDistanceMeters;
  final int extraWalkingSeconds;
  final double normalCoverageShare;
  final double? candidateCoverageShare;
  final QuietFallbackReason fallbackReason;

  bool get offersAlternative => candidateRoute != null;
  String? get fallbackText => quietFallbackReasonText(fallbackReason);
  String get evidenceNote =>
      'Оценка основана на карте дорожной сети и не заменяет измерение шума.';
}

typedef QuietVariantRequest = Future<List<RouteLegModel>> Function(
  int legIndex,
  RouteLegModel leg,
  NativeWalkRequestBudget budget,
);

typedef QuietCandidateAnalyzer = Future<QuietAnalysisModel> Function(
  PedestrianRouteModel route,
);

/// Searches real MapKit variants and offers one only when the backend proxy is
/// better by a documented minimum, coverage is comparable, and the detour fits
/// the walk budget. Any missing evidence keeps the normal route.
class QuietRouteEngine {
  QuietRouteEngine({
    this.maxProbeLegs = 3,
    this.maxVariantsPerLeg = 2,
    this.minimumImprovement = 0.05,
    this.minimumCoverageShare = 0.80,
    this.coverageTolerance = 0.05,
    this.maxExtraSecondsFloor = 180,
    this.maxExtraDistanceMetersFloor = 300.0,
    this.maxExtraSecondsShare = 0.10,
    this.maxExtraDistanceShare = 0.15,
  });

  final int maxProbeLegs;
  final int maxVariantsPerLeg;

  /// Five index points on the 0..1 proxy. This is an engineering threshold,
  /// not a measured acoustic difference.
  final double minimumImprovement;
  final double minimumCoverageShare;
  final double coverageTolerance;
  final int maxExtraSecondsFloor;
  final double maxExtraDistanceMetersFloor;
  final double maxExtraSecondsShare;
  final double maxExtraDistanceShare;

  /// MapKit may snap a requested waypoint to the nearest pedestrian-accessible
  /// point. This is the same 15 m evidence band ScenicStageBuilder already
  /// uses for verified waypoints; it is an allowance for native snapping, not
  /// a tolerance for inventing a connector. The candidate keeps the native
  /// coordinates unchanged and is rejected when any endpoint or leg junction
  /// exceeds this distance.
  static const double maxNativeEndpointSnapMeters =
      ScenicStageBuilder.maxSnapFromWaypointMeters;

  Future<QuietRoutingDecision> enhance({
    required PedestrianRouteModel normalRoute,
    required QuietAnalysisModel normalAnalysis,
    required NativeWalkRequestBudget requestBudget,
    required QuietVariantRequest requestVariants,
    required QuietCandidateAnalyzer analyze,
    int? walkBudgetSeconds,
    bool Function()? isCurrent,
  }) async {
    bool current() => isCurrent?.call() ?? true;
    QuietRoutingDecision unchanged(QuietFallbackReason reason) =>
        QuietRoutingDecision(
          normalRoute: normalRoute,
          normalAnalysis: normalAnalysis,
          candidateRoute: null,
          candidateAnalysis: null,
          improvement: null,
          extraDistanceMeters: 0,
          extraWalkingSeconds: 0,
          normalCoverageShare: normalAnalysis.coverageShare,
          candidateCoverageShare: null,
          fallbackReason: reason,
        );

    if (!current()) return unchanged(QuietFallbackReason.cancelled);
    if (!normalAnalysis.hasEstimate ||
        normalAnalysis.roadNoiseExposureIndex == null ||
        normalAnalysis.coverageShare < minimumCoverageShare) {
      return unchanged(QuietFallbackReason.noBaseline);
    }
    if (normalRoute.legs.isEmpty) {
      return unchanged(QuietFallbackReason.noBaseline);
    }

    final seen = <String>{};
    QuietRoutingDecision? best;
    var candidatesAnalyzed = 0;
    var foundVariants = false;
    var invalidAlternative = false;
    var budgetExhausted = false;
    var insufficientCoverage = false;
    var notQuieter = false;
    var tooMuchDetour = false;

    final legCount = math.min(maxProbeLegs, normalRoute.legs.length);
    for (var index = 0; index < legCount; ++index) {
      if (!current()) return unchanged(QuietFallbackReason.cancelled);
      if (requestBudget.remaining <= 0) {
        budgetExhausted = true;
        break;
      }
      final leg = normalRoute.legs[index];
      if (leg.geometryPoints.length < 2) continue;
      List<RouteLegModel> variants;
      try {
        variants = await requestVariants(index, leg, requestBudget);
      } on RouteCalculationFailure catch (failure) {
        if (failure.kind == RouteFailureKind.requestLimitReached) {
          budgetExhausted = true;
          break;
        }
        continue;
      }
      if (variants.length <= 1) continue;
      foundVariants = true;
      for (final variant in variants.skip(1).take(maxVariantsPerLeg - 1)) {
        if (!current()) return unchanged(QuietFallbackReason.cancelled);
        final candidate = _routeWithReplacedLeg(normalRoute, index, variant);
        if (candidate == null) {
          invalidAlternative = true;
          continue;
        }
        final key = _fingerprint(candidate);
        if (!seen.add(key)) continue;
        QuietAnalysisModel analysis;
        try {
          analysis = await analyze(candidate);
        } on QuietAnalysisFailure {
          continue;
        }
        if (!current()) return unchanged(QuietFallbackReason.cancelled);
        if (!analysis.hasEstimate || analysis.roadNoiseExposureIndex == null) {
          continue;
        }
        ++candidatesAnalyzed;
        if (analysis.coverageShare < minimumCoverageShare ||
            analysis.coverageShare <
                normalAnalysis.coverageShare - coverageTolerance) {
          insufficientCoverage = true;
          continue;
        }
        final extraDistance =
            candidate.distanceMeters - normalRoute.distanceMeters;
        final extraSeconds =
            candidate.durationSeconds - normalRoute.durationSeconds;
        final allowedSeconds = math.max(
          maxExtraSecondsFloor,
          (normalRoute.durationSeconds * maxExtraSecondsShare).round(),
        );
        final allowedDistance = math.max(
          maxExtraDistanceMetersFloor,
          normalRoute.distanceMeters * maxExtraDistanceShare,
        );
        if (extraDistance < -1 || extraSeconds < -1) {
          // A "quieter" candidate that is shorter/faster is suspicious for a
          // real pedestrian alternative; never advertise it from bad data.
          tooMuchDetour = true;
          continue;
        }
        if (extraDistance > allowedDistance || extraSeconds > allowedSeconds) {
          tooMuchDetour = true;
          continue;
        }
        if (walkBudgetSeconds != null &&
            candidate.durationSeconds > walkBudgetSeconds) {
          tooMuchDetour = true;
          continue;
        }
        final improvement =
            normalAnalysis.roadNoiseExposureIndex! -
            analysis.roadNoiseExposureIndex!;
        if (improvement < minimumImprovement) {
          notQuieter = true;
          continue;
        }
        final decision = QuietRoutingDecision(
          normalRoute: normalRoute,
          normalAnalysis: normalAnalysis,
          candidateRoute: candidate,
          candidateAnalysis: analysis,
          improvement: improvement,
          extraDistanceMeters: extraDistance,
          extraWalkingSeconds: extraSeconds.toInt(),
          normalCoverageShare: normalAnalysis.coverageShare,
          candidateCoverageShare: analysis.coverageShare,
          fallbackReason: QuietFallbackReason.none,
        );
        if (best == null ||
            improvement > best.improvement! ||
            (improvement == best.improvement &&
                extraSeconds < best.extraWalkingSeconds)) {
          best = decision;
        }
      }
    }

    if (best != null) return best;
    if (budgetExhausted) {
      return unchanged(QuietFallbackReason.insufficientBudget);
    }
    if (candidatesAnalyzed == 0) {
      if (invalidAlternative) {
        return unchanged(QuietFallbackReason.invalidAlternative);
      }
      return unchanged(
        foundVariants
            ? QuietFallbackReason.analysisUnavailable
            : QuietFallbackReason.noAlternatives,
      );
    }
    if (tooMuchDetour) return unchanged(QuietFallbackReason.tooMuchDetour);
    if (insufficientCoverage) {
      return unchanged(QuietFallbackReason.insufficientCoverage);
    }
    if (notQuieter) return unchanged(QuietFallbackReason.notQuieter);
    return unchanged(QuietFallbackReason.notQuieter);
  }

  /// The normal walk with exactly ONE leg replaced by real native geometry.
  /// Stops, other legs, visit times and maneuvers remain those of the walk.
  ///
  /// Returns null — before any backend analysis — when the native alternative
  /// is not a continuable replacement for the original leg. Endpoint snapping
  /// and junction gaps are measured against [maxNativeEndpointSnapMeters]; no
  /// point is inserted, moved or interpolated to make a candidate valid.
  PedestrianRouteModel? _routeWithReplacedLeg(
    PedestrianRouteModel route,
    int legIndex,
    RouteLegModel replacement,
  ) {
    if (legIndex < 0 || legIndex >= route.legs.length) return null;
    final original = route.legs[legIndex];
    if (!_hasValidGeometry(original.geometryPoints) ||
        !_hasValidGeometry(replacement.geometryPoints)) {
      return null;
    }
    if (replacement.fromTitle != original.fromTitle ||
        replacement.toTitle != original.toTitle ||
        replacement.visitMinutes != original.visitMinutes ||
        !replacement.distanceMeters.isFinite ||
        replacement.distanceMeters <= 0 ||
        replacement.durationSeconds <= 0) {
      return null;
    }
    if (!_hasConsistentManeuvers(
      replacement.maneuvers,
      replacement.geometryPoints,
      legIndex,
    )) {
      return null;
    }

    final start = replacement.geometryPoints.first;
    final end = replacement.geometryPoints.last;
    if (!_withinNativeSnap(original.geometryPoints.first, start) ||
        !_withinNativeSnap(original.geometryPoints.last, end)) {
      return null;
    }
    if (legIndex > 0) {
      final previous = route.legs[legIndex - 1];
      if (previous.geometryPoints.isEmpty ||
          !_withinNativeSnap(previous.geometryPoints.last, start)) {
        return null;
      }
    }
    if (legIndex + 1 < route.legs.length) {
      final next = route.legs[legIndex + 1];
      if (next.geometryPoints.isEmpty ||
          !_withinNativeSnap(end, next.geometryPoints.first)) {
        return null;
      }
    }

    final legs = <RouteLegModel>[
      for (var i = 0; i < route.legs.length; ++i)
        i == legIndex ? replacement : route.legs[i],
    ];
    var distance = 0.0;
    var duration = 0;
    final points = <GeoCoord>[];
    for (final leg in legs) {
      distance += leg.distanceMeters;
      duration += leg.durationSeconds;
      points.addAll(leg.geometryPoints);
    }
    if (!distance.isFinite || distance <= 0 || duration <= 0) return null;
    return PedestrianRouteModel(
      distanceMeters: distance,
      durationSeconds: duration,
      geometryPoints: points,
      steps: const [],
      legs: legs,
      placesCount: route.placesCount,
      walkKind: WalkKind.quiet,
    );
  }

  static bool _hasValidGeometry(List<GeoCoord> points) {
    if (points.length < 2) return false;
    for (final point in points) {
      if (!point.latitude.isFinite ||
          !point.longitude.isFinite ||
          point.latitude.abs() > 90 ||
          point.longitude.abs() > 180) {
        return false;
      }
    }
    final length = RouteProjectionUtils.polylineLengthMeters(points);
    return length.isFinite && length > 0;
  }

  static bool _withinNativeSnap(GeoCoord expected, GeoCoord actual) {
    final distance = RouteProjectionUtils.distanceBetween(expected, actual);
    return distance.isFinite && distance <= maxNativeEndpointSnapMeters;
  }

  /// Native annotations must describe THIS replacement leg and its geometry.
  /// Empty maneuvers are valid (the honest guidance fallback); any supplied
  /// maneuver must be ordered, in range, and its offset must match the same
  /// polyline measurement navigation uses.
  static bool _hasConsistentManeuvers(
    List<PedestrianManeuverModel> maneuvers,
    List<GeoCoord> geometry,
    int legIndex,
  ) {
    var previousOffset = 0.0;
    for (final maneuver in maneuvers) {
      if (maneuver.legIndex != legIndex ||
          maneuver.source != PedestrianManeuverSource.nativeAnnotation ||
          !maneuver.offsetMeters.isFinite ||
          maneuver.offsetMeters < 0 ||
          maneuver.offsetMeters < previousOffset ||
          maneuver.coordinateOnLeg(geometry) == null) {
        return false;
      }
      final measured = _measuredManeuverOffset(maneuver, geometry);
      if (measured == null || (measured - maneuver.offsetMeters).abs() > 1.0) {
        return false;
      }
      previousOffset = maneuver.offsetMeters;
    }
    return true;
  }

  static double? _measuredManeuverOffset(
    PedestrianManeuverModel maneuver,
    List<GeoCoord> geometry,
  ) {
    if (geometry.length < 2 ||
        maneuver.segmentIndex < 0 ||
        maneuver.segmentIndex >= geometry.length ||
        !maneuver.segmentPosition.isFinite ||
        maneuver.segmentPosition < 0 ||
        maneuver.segmentPosition > 1) {
      return null;
    }
    var offset = 0.0;
    for (var i = 0; i < geometry.length - 1; ++i) {
      final segment = RouteProjectionUtils.distanceBetween(
        geometry[i],
        geometry[i + 1],
      );
      if (i == maneuver.segmentIndex) {
        return offset + segment * maneuver.segmentPosition;
      }
      offset += segment;
    }
    // The adapter's terminal position is the final point at fraction 0.
    if (maneuver.segmentIndex == geometry.length - 1 &&
        maneuver.segmentPosition == 0) {
      return offset;
    }
    return null;
  }

  static String _fingerprint(PedestrianRouteModel route) {
    if (route.geometryPoints.isEmpty) return 'empty';
    final first = route.geometryPoints.first;
    final last = route.geometryPoints.last;
    return '${route.distanceMeters.toStringAsFixed(1)}|'
        '${route.durationSeconds}|${route.geometryPoints.length}|'
        '${first.latitude.toStringAsFixed(6)},${first.longitude.toStringAsFixed(6)}|'
        '${last.latitude.toStringAsFixed(6)},${last.longitude.toStringAsFixed(6)}';
  }
}
