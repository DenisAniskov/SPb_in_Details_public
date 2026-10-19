import 'dart:math' as math;

import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/scenic_diagnostics.dart';
import 'package:smart_navigator_spb/services/scenic_stage_builder.dart';

/// Deterministic, documented, testable scoring and acceptance thresholds
/// (Phase C5 §5–6).
class ScenicScoringConfig {
  /// A scenic stage may not exceed the normal stage distance by this share.
  final double maxDetourShare;

  /// Hard cap on extra walking time per stage (minutes).
  final double maxExtraMinutes;

  /// A route point within this distance of a verified feature line/point
  /// counts as scenic coverage (meters).
  final double featureProximityMeters;

  /// Coverage share that certifies «проходит по» (verified on path).
  final double verifiedOnPathShare;

  /// Coverage share below which the geometry is considered ambiguous.
  final double verifiedNearbyShare;

  /// Minimum share of the stage that must engage the feature to matter.
  final double minCoverageShare;

  /// Candidate waypoints must lie within this distance of the direct
  /// stage line (Haversine pre-filter only — never a walkability proof).
  final double maxCandidateCorridorMeters;

  /// Waypoints must be at least this far from both stage endpoints.
  final double minWaypointSeparationMeters;

  /// Maximum verified features engaged by one stage.
  final int maxWaypointsPerStage;

  /// Maximum shortlisted candidates evaluated per insertion step.
  final int maxCandidatesPerStep;

  final double benefitWeight;
  final double penaltyPerExtraMinute;
  final double uncertaintyPenaltyWeight;
  final double acceptanceThreshold;

  const ScenicScoringConfig({
    this.maxDetourShare = 1.6,
    this.maxExtraMinutes = 15,
    this.featureProximityMeters = 60,
    this.verifiedOnPathShare = 0.5,
    this.verifiedNearbyShare = 0.15,
    this.minCoverageShare = 0.1,
    this.maxCandidateCorridorMeters = 400,
    this.minWaypointSeparationMeters = 150,
    this.maxWaypointsPerStage = 2,
    this.maxCandidatesPerStep = 3,
    this.benefitWeight = 2.0,
    // Rebalanced in Phase C4/C5 runtime fixes §6.1: with the historical
    // 0.8/min any detour from ≈2 minutes was mathematically unacceptable at
    // ANY coverage (see test/scenic_scoring_calibration_test.dart). Hard
    // limits are unchanged.
    this.penaltyPerExtraMinute = 0.2,
    this.uncertaintyPenaltyWeight = 1.0,
    this.acceptanceThreshold = 0.25,
  });
}

extension ScenicFeatureTypeX on ScenicFeatureType {
  double get weight => switch (this) {
        ScenicFeatureType.embankment => 0.95,
        ScenicFeatureType.pedestrianStreet => 0.85,
        ScenicFeatureType.square => 0.75,
      };

  String get label => switch (this) {
        ScenicFeatureType.embankment => 'набережную',
        ScenicFeatureType.pedestrianStreet => 'пешеходную улицу',
        ScenicFeatureType.square => 'площадь',
      };
}

/// Why the scenic request honestly fell back to the normal route.
enum ScenicFallbackReason {
  /// Scenic enhancement accepted (no fallback).
  none,

  /// No dataset feature near any stage.
  noCandidates,

  /// The shared MapKit request budget could not afford scenic segments.
  requestBudgetExhausted,

  /// Every candidate exceeded the walk time budget (or both time and length).
  budgetExceeded,

  /// The measured detour share alone exceeded the allowed stage length.
  detourLimitExceeded,

  /// The normal path misses every verified scenic feature, and a detour to
  /// the nearest one would exceed the allowed length. A short route stays
  /// normal instead of being stretched just to claim a scenic label.
  noScenicOnPath,

  /// Built geometries did not meaningfully engage any verified feature.
  noVerifiedGeometry,

  /// Geometry was verified, but its measured benefit did not pass scoring.
  insufficientBenefit,

  /// Candidates were rejected for different independent kinds of obstacle.
  mixedRejections,

  /// Native routing failed for the scenic segments.
  mapkitUnavailable,
}

/// User-facing explanation of one honest fallback (§8). Technical diagnostic
/// codes never appear; the normal route stays available in every case.
String scenicFallbackReasonText(ScenicFallbackReason reason) =>
    switch (reason) {
      // The engine never reports `none` as a fallback; defensive wording in
      // case a caller asks anyway.
      ScenicFallbackReason.none =>
        'Построен пешеходный маршрут с проверенными живописными участками.',
      ScenicFallbackReason.noCandidates =>
        'Для этой прогулки пока нет подтверждённых живописных участков. '
            'Построен обычный пешеходный маршрут.',
      ScenicFallbackReason.requestBudgetExhausted =>
        'Для проверки живописного варианта не хватило лимита обращений '
            'к сервису маршрутов. Построен обычный пешеходный маршрут.',
      ScenicFallbackReason.budgetExceeded =>
        'Живописный вариант получился слишком длинным или не помещается '
            'в выбранное время прогулки. Построен обычный пешеходный маршрут.',
      ScenicFallbackReason.detourLimitExceeded =>
        'Объезд к живописному участку превысил допустимое удлинение '
            'маршрута. Построен обычный пешеходный маршрут.',
      ScenicFallbackReason.noScenicOnPath =>
        'Обычный маршрут не проходит по подтверждённым живописным участкам, '
            'а объезд к ближайшему из них превысил бы допустимое удлинение. '
            'Построен обычный пешеходный маршрут.',
      ScenicFallbackReason.noVerifiedGeometry =>
        'Найденные варианты не удалось достаточно надёжно подтвердить. '
            'Построен обычный пешеходный маршрут.',
      ScenicFallbackReason.insufficientBenefit =>
        'Проверенные живописные участки не дали достаточно преимуществ '
            'для этой прогулки. Построен обычный пешеходный маршрут.',
      ScenicFallbackReason.mixedRejections =>
        'Найденные живописные варианты не прошли все условия проверки. '
            'Построен обычный пешеходный маршрут.',
      ScenicFallbackReason.mapkitUnavailable =>
        'Не удалось проверить пешеходный проход через живописные участки. '
            'Построен обычный пешеходный маршрут.',
    };

/// Diagnostics of one bounded scenic enhancement operation.
class ScenicEnhancementStats {
  final int candidatesConsidered;
  final int candidatesVerified;
  final int stagesEnhanced;
  final int waypointsAccepted;
  final int scenicRequests;

  /// Features recognized on the already-built normal geometry (zero extra
  /// waypoints/requests) and the features that passed its evidence/score
  /// gates. Additive diagnostics; existing callers may ignore them.
  final int zeroDetourCandidates;
  final int zeroDetourFeaturesAccepted;

  final ScenicFallbackReason fallbackReason;

  const ScenicEnhancementStats({
    required this.candidatesConsidered,
    required this.candidatesVerified,
    required this.stagesEnhanced,
    required this.waypointsAccepted,
    required this.scenicRequests,
    this.zeroDetourCandidates = 0,
    this.zeroDetourFeaturesAccepted = 0,
    required this.fallbackReason,
  });
}

/// Result of one scenic enhancement attempt.
class ScenicEnhancementResult {
  /// The scenic route (combined stages), or null when the operation honestly
  /// fell back to the normal route.
  final PedestrianRouteModel? route;

  /// Normal-vs-scenic comparison for the UI (§7.2), when scenic was built.
  final RouteComparison? comparison;
  final ScenicFallbackReason fallbackReason;
  final ScenicEnhancementStats stats;

  const ScenicEnhancementResult({
    required this.route,
    required this.comparison,
    required this.fallbackReason,
    required this.stats,
  });

  bool get isScenic => route != null;
}

/// One candidate insertion plan under evaluation.
class _Candidate {
  final ScenicFeature feature;
  final int subSegmentIndex; // which leg piece receives the waypoint
  final double lineDistanceMeters;

  const _Candidate(this.feature, this.subSegmentIndex, this.lineDistanceMeters);
}

/// Phase C5 Scenic Walk Engine.
///
/// Given an already-built NORMAL walk (real MapKit stages between the
/// selected tourist stops), the engine evaluates a bounded set of scenic
/// alternatives: real MapKit pedestrian segments through verified scenic
/// waypoints, checked against the verified feature geometry, scored with an
/// explainable deterministic model, and accepted only when they respect the
/// walk time budget. It never invents geometry and never re-routes per GPS
/// tick — it runs once per route build operation. A junction that MapKit
/// snapped apart is bridged by a real native route between the two
/// projections, and that route's own geometry, time, distance and maneuvers
/// are spliced into the stage (see [_resolveJunctions]).
class ScenicWalkEngine {
  /// The routing service (real MapKit in production, deterministic fakes in
  /// tests). Shared with the walk build; scenic requests consume the same
  /// per-build request budget.
  final BasePedestrianRouteService routeService;
  final List<ScenicFeature> features;
  final ScenicScoringConfig config;

  /// Operation state for the current enhance() run (engines are created per
  /// build operation; no cross-operation state is kept).
  late NativeWalkRequestBudget _activeBudget;

  ScenicWalkEngine({
    required this.routeService,
    required List<ScenicFeature> datasetFeatures,
    this.config = const ScenicScoringConfig(),
  }) : features = List.unmodifiable(datasetFeatures);


  /// [walkBudgetSeconds] is the WALKING part of the chosen budget: the full
  /// preset budget minus the editorial visit time (§6: native MapKit walking
  /// + visit ≤ budget). The engine compares walking totals only — never a
  /// geometric estimate.
  ///
  /// [diagnosticsContext] is only supplied by the routing provider when
  /// `SCENIC_DIAGNOSTICS` is enabled; with it the engine records one debug
  /// report per attempt (rejection distribution + measured junctions).
  Future<ScenicEnhancementResult> enhance({
    required PedestrianRouteModel normalRoute,
    required int? walkBudgetSeconds,
    required NativeWalkRequestBudget requestBudget,
    ScenicAttemptContext? diagnosticsContext,

    /// Recognize verified scenery already present on the normal MapKit
    /// geometry before attempting any insertion. The routing provider enables
    /// this for every scenic build; the default stays false so direct callers
    /// that exercise the bounded insertion engine keep that contract.
    bool recognizeOnPath = false,
  }) async {
    final budgetSeconds = walkBudgetSeconds;
    // Walking total of the CURRENT accepted state (§6): every accepted
    // insertion adds its extra seconds here, so later candidates are checked
    // against the whole walk built so far — never against the original
    // normal total alone.
    var currentTotalSeconds = normalRoute.durationSeconds;
    final requestsUsedBefore = requestBudget.requests;
    var candidatesInCorridor = 0;
    var candidatesShortlisted = 0;
    var candidatesEndpointExcluded = 0;
    var candidatesNameDeduplicated = 0;
    var considered = 0;
    var verified = 0;
    var nativeRouted = 0;
    var waypoints = 0;
    var zeroDetourCandidates = 0;
    var zeroDetourFeaturesAccepted = 0;
    final rejectionCounts = <ScenicRejectionCategory, int>{};
    final rejectedCandidates = <ScenicCandidateRejection>[];
    final junctionMeasurements = <ScenicJunctionMeasurement>[];
    var legs = List<RouteLegModel>.of(normalRoute.legs);
    final engagedNames = <String>[];
    _activeBudget = requestBudget;

    void countRejection(ScenicCandidateRejection rejection) {
      rejectionCounts.update(
        rejection.category,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      if (rejectedCandidates.length <
          ScenicDiagnostics.maxRejectedCandidatesPerReport) {
        rejectedCandidates.add(rejection);
      }
    }

    void measureJunction(ScenicJunctionMeasurement measurement) {
      if (junctionMeasurements.length <
          ScenicDiagnostics.maxJunctionMeasurementsPerReport) {
        junctionMeasurements.add(measurement);
      }
    }

    for (var index = 0; index < legs.length; index++) {
      final stage = legs[index];
      var currentStage = stage;
      final stageFeatures = <ScenicFeature>[];

      // Zero-detour recognition: the normal MapKit geometry may already walk
      // along a verified feature. Measure it before considering any insertion;
      // a stage that already qualifies is kept exactly as built — no extra
      // waypoint, request, second or metre — and no detour is attempted for it.
      if (recognizeOnPath) {
        final onPath = _recognizeOnPath(stage);
        zeroDetourCandidates += onPath.candidates;
        if (onPath.features.isNotEmpty) {
          zeroDetourFeaturesAccepted += onPath.features.length;
          currentStage = _withScenic(stage, _onPathStageInfo(onPath.coverage));
          legs = List<RouteLegModel>.of(legs)..[index] = currentStage;
          engagedNames.addAll(onPath.features.map((feature) => feature.name));
          continue;
        }
      }

      // Piece geometries currently composing the stage (start: one piece —
      // the normal leg; each accepted waypoint splits one piece in two).
      var pieces = <List<GeoCoord>>[stage.geometryPoints];
      var pieceTitles = <(String, String)>[(stage.fromTitle, stage.toTitle)];
      var pieceDurations = <int>[stage.durationSeconds];
      var pieceDistances = <double>[stage.distanceMeters];
      var pieceManeuvers = <List<PedestrianManeuverModel>>[stage.maneuvers];
      // Verified waypoint at each junction between consecutive pieces
      // (length: pieces.length − 1), re-validated at every assembly.
      var pieceJunctions = <GeoCoord>[];

      for (var level = 0; level < config.maxWaypointsPerStage; level++) {
        final shortlist = _shortlist(pieces, stage, stageFeatures);
        final candidates = shortlist.candidates;
        candidatesInCorridor += shortlist.inCorridor;
        candidatesShortlisted += candidates.length;
        candidatesEndpointExcluded += shortlist.endpointExcluded;
        candidatesNameDeduplicated += shortlist.namesDeduplicated;
        if (candidates.isEmpty) {
          break;
        }
        final evaluated = <_StageCandidate>[];
        var attemptedHere = 0;
        for (final candidate in candidates) {
          if (attemptedHere >= config.maxCandidatesPerStep) break;
          // Keep enough of the shared cap to finish at least one evaluated
          // chain. Spending the last requests on more A→W/W→B pairs can
          // otherwise leave every snapped candidate unconfirmable.
          if (evaluated.isNotEmpty) {
            final confirmable = evaluated
                .where(_junctionsEligibleForConfirmation)
                .map(_confirmationRequestsNeeded)
                .toList();
            final confirmationsReserved = confirmable.isEmpty
                ? 0
                : confirmable.reduce(math.min);
            if (_activeBudget.remaining < 2 + confirmationsReserved) break;
          }
          if (_activeBudget.remaining < 2) {
            countRejection(ScenicCandidateRejection(
              featureId: candidate.feature.id,
              featureType: candidate.feature.type.name,
              coverageShare: null,
              score: null,
              extraMinutes: null,
              extraMeters: null,
              category: ScenicRejectionCategory.requestBudget,
              nativeRequests: 0,
            ));
            break;
          }
          considered++;
          attemptedHere++;
          final outcome = await _evaluateCandidate(
            pieces: pieces,
            pieceTitles: pieceTitles,
            pieceDurations: pieceDurations,
            pieceDistances: pieceDistances,
            pieceManeuvers: pieceManeuvers,
            pieceJunctions: pieceJunctions,
            candidate: candidate,
            normalStage: stage,
            legIndex: index,
            currentTotalSeconds: currentTotalSeconds,
            budgetSeconds: budgetSeconds,
            onJunctionMeasured: measureJunction,
          );
          if (outcome.nativeLegsObtained) {
            nativeRouted++;
          }
          if (outcome.rejection != null) {
            countRejection(outcome.rejection!);
            continue;
          }
          verified++;
          evaluated.add(outcome.candidate!);
        }
        if (evaluated.isEmpty) {
          break;
        }
        // Exact chains can be checked for free. Establish their final score
        // before spending requests on confirmations, then prefer cheaper
        // confirmations while retaining any already valid alternative.
        evaluated.sort((x, y) {
          final byRequests = _confirmationRequestsNeeded(x)
              .compareTo(_confirmationRequestsNeeded(y));
          return byRequests != 0 ? byRequests : _compareCandidates(x, y);
        });
        _StageCandidate? best;
        RouteLegModel? assembled;
        _JunctionResolution? resolved;
        for (final candidate in evaluated) {
          // Coverage cannot exceed one and the time penalty cannot be
          // negative. This universal upper bound stays valid for shorter
          // stages too; pre-confirmation coverage itself is not an upper
          // bound because a connector may improve it.
          final upperScore = score(
            feature: candidate.feature,
            coverageShare: 1,
            extraMinutes: 0,
          );
          if (best != null && upperScore < best.score) continue;
          // §5: every non-exact junction must be confirmed by a real MapKit
          // route between the two projections. Only a shorter-than-cap native
          // connector grants the join, and its own geometry is spliced into
          // the stage (so the shared coordinate is bit-identical and the
          // walked path is the confirmed one).
          final resolution = await _resolveJunctions(
            candidate: candidate,
            onJunctionMeasured: measureJunction,
          );
          if (!resolution.ok) {
            countRejection(ScenicCandidateRejection(
              featureId: candidate.feature.id,
              featureType: candidate.feature.type.name,
              coverageShare: candidate.coverageShare,
              score: candidate.score,
              extraMinutes: (candidate.durations.fold(0, (sum, s) => sum + s) -
                      stage.durationSeconds) / 60,
              extraMeters: candidate.distances.fold(0.0, (sum, s) => sum + s) -
                  stage.distanceMeters,
              category: resolution.category!,
              // Two evaluation requests plus whatever the junction
              // confirmations consumed.
              nativeRequests: 2 + resolution.requestsUsed,
              detail: resolution.detail,
            ));
            continue;
          }
          // The confirmed chain may be longer than the evaluated plan, so
          // every limit is re-measured before assembly (§5 final fix).
          final recheck = _recheckAfterJunctions(
            candidate: candidate,
            resolution: resolution,
            normalStage: stage,
            baseDurations: pieceDurations,
            baseDistances: pieceDistances,
            currentTotalSeconds: currentTotalSeconds,
            budgetSeconds: budgetSeconds,
            nativeRequests: 2 + resolution.requestsUsed,
          );
          if (recheck.rejection != null) {
            countRejection(recheck.rejection!);
            continue;
          }
          final outcome = _assembleStage(
            pieces: resolution.pieces,
            titles: resolution.titles,
            durations: resolution.durations,
            distances: resolution.distances,
            maneuvers: resolution.maneuvers,
            stage: stage,
            engaged: [...stageFeatures, candidate.feature],
            legIndex: index,
            junctions: resolution.junctions,
          );
          if (outcome.leg != null) {
            final confirmed = recheck.candidate!;
            if (best == null || _compareCandidates(confirmed, best) < 0) {
              best = confirmed;
              assembled = outcome.leg;
              resolved = resolution;
            }
            continue;
          }
          // Continuity rejection: the chain failed structural validation
          // (maneuver rebase / ordering) after its junctions were resolved.
          countRejection(ScenicCandidateRejection(
            featureId: candidate.feature.id,
            featureType: candidate.feature.type.name,
            coverageShare: recheck.candidate!.coverageShare,
            score: recheck.candidate!.score,
            extraMinutes: (resolution.durations.fold(0, (sum, s) => sum + s) -
                    stage.durationSeconds) / 60,
            extraMeters: resolution.distances.fold(0.0, (sum, s) => sum + s) -
                stage.distanceMeters,
            category: ScenicRejectionCategory.continuity,
            nativeRequests: 2 + resolution.requestsUsed,
            detail: outcome.failure?.name ??
                ScenicRejectionCategory.continuity.name,
          ));
        }
        if (best == null || assembled == null || resolved == null) {
          // Assembly rejected (ambiguous geometry) — keep the previous state.
          break;
        }
        pieces = resolved.pieces;
        pieceTitles = resolved.titles;
        pieceDurations = resolved.durations;
        pieceDistances = resolved.distances;
        pieceManeuvers = resolved.maneuvers;
        pieceJunctions = resolved.junctions;
        stageFeatures.add(best.feature);
        engagedNames.add(best.feature.name);
        waypoints++;
        currentTotalSeconds += best.extraSeconds;
        currentStage = assembled;
      }
      if (!identical(currentStage, stage)) {
        legs = List.of(legs)..[index] = currentStage;
      }
    }

    final finalReason = engagedNames.isNotEmpty
        ? ScenicFallbackReason.none
        : _finalFallbackReason(
            rejectionCounts,
            considered,
            zeroDetourCandidates,
          );

    // Any successfully assembled stage keeps the enhancement (§10 honest
    // partial success): a later budget exhaustion or candidate rejection
    // must not discard the scenic stages that were already built.
    if (engagedNames.isNotEmpty) {
      final scenicRoute = _buildRoute(normalRoute, legs);
      _recordDiagnostics(
        context: diagnosticsContext,
        normalRoute: normalRoute,
        legs: legs,
        candidatesInCorridor: candidatesInCorridor,
        candidatesShortlisted: candidatesShortlisted,
        candidatesEndpointExcluded: candidatesEndpointExcluded,
        candidatesNameDeduplicated: candidatesNameDeduplicated,
        considered: considered,
        nativeRouted: nativeRouted,
        rejectionCounts: rejectionCounts,
        rejectedCandidates: rejectedCandidates,
        junctionMeasurements: junctionMeasurements,
        waypoints: waypoints,
        zeroDetourCandidates: zeroDetourCandidates,
        zeroDetourFeaturesAccepted: zeroDetourFeaturesAccepted,
        requestsUsedBefore: requestsUsedBefore,
        requestBudget: requestBudget,
        finalReason: ScenicFallbackReason.none,
      );
      return ScenicEnhancementResult(
        route: scenicRoute,
        comparison: _comparison(normalRoute, scenicRoute, engagedNames),
        fallbackReason: ScenicFallbackReason.none,
        stats: ScenicEnhancementStats(
          candidatesConsidered: considered,
          candidatesVerified: verified,
          stagesEnhanced: legs.where((l) => l.scenic != null).length,
          waypointsAccepted: waypoints,
          scenicRequests: requestBudget.requests,
          zeroDetourCandidates: zeroDetourCandidates,
          zeroDetourFeaturesAccepted: zeroDetourFeaturesAccepted,
          fallbackReason: ScenicFallbackReason.none,
        ),
      );
    }

    _recordDiagnostics(
      context: diagnosticsContext,
      normalRoute: normalRoute,
      legs: legs,
      candidatesInCorridor: candidatesInCorridor,
      candidatesShortlisted: candidatesShortlisted,
      candidatesEndpointExcluded: candidatesEndpointExcluded,
      candidatesNameDeduplicated: candidatesNameDeduplicated,
      considered: considered,
      nativeRouted: nativeRouted,
      rejectionCounts: rejectionCounts,
      rejectedCandidates: rejectedCandidates,
      junctionMeasurements: junctionMeasurements,
      waypoints: waypoints,
      zeroDetourCandidates: zeroDetourCandidates,
      zeroDetourFeaturesAccepted: zeroDetourFeaturesAccepted,
      requestsUsedBefore: requestsUsedBefore,
      requestBudget: requestBudget,
      finalReason: finalReason,
    );
    return ScenicEnhancementResult(
      route: null,
      comparison: null,
      fallbackReason: finalReason,
      stats: ScenicEnhancementStats(
        candidatesConsidered: considered,
        candidatesVerified: verified,
        stagesEnhanced: 0,
        waypointsAccepted: waypoints,
        scenicRequests: _activeBudget.requests,
        zeroDetourCandidates: zeroDetourCandidates,
        zeroDetourFeaturesAccepted: zeroDetourFeaturesAccepted,
        fallbackReason: finalReason,
      ),
    );
  }

  /// A specific explanation is honest only when every observed rejection
  /// supports that explanation. Related gates share one reason (distance
  /// and time limits; coverage and continuity), while independent obstacles
  /// produce a mixed outcome. The distribution remains in diagnostics, so
  /// one failed native call cannot label other verified candidates as a
  /// service outage, and score alone never implies unverified geometry.
  ScenicFallbackReason _finalFallbackReason(
    Map<ScenicRejectionCategory, int> counts,
    int considered,
    int zeroDetourCandidates,
  ) {
    final reasons = <ScenicFallbackReason>{
      for (final entry in counts.entries)
        if (entry.value > 0)
          switch (entry.key) {
            ScenicRejectionCategory.requestBudget =>
              ScenicFallbackReason.requestBudgetExhausted,
            ScenicRejectionCategory.mapkitUnavailable =>
              ScenicFallbackReason.mapkitUnavailable,
            ScenicRejectionCategory.detour =>
              ScenicFallbackReason.detourLimitExceeded,
            ScenicRejectionCategory.walkingBudget =>
              ScenicFallbackReason.budgetExceeded,
            ScenicRejectionCategory.coverage ||
            ScenicRejectionCategory.continuity =>
              ScenicFallbackReason.noVerifiedGeometry,
            ScenicRejectionCategory.score =>
              ScenicFallbackReason.insufficientBenefit,
          },
    };
    if (reasons.length == 1) {
      final single = reasons.single;
      // The normal path is not merely too long to reach a feature: it does
      // not follow any verified scenic way at all. Say exactly that, instead
      // of implying that a longer preset would unlock a scenic option.
      if (single == ScenicFallbackReason.detourLimitExceeded &&
          zeroDetourCandidates == 0) {
        return ScenicFallbackReason.noScenicOnPath;
      }
      return single;
    }
    if (reasons.length > 1) {
      // Length and time limits are two faces of the same rejected insertion.
      if (reasons.length == 2 &&
          reasons.contains(ScenicFallbackReason.detourLimitExceeded) &&
          reasons.contains(ScenicFallbackReason.budgetExceeded)) {
        return ScenicFallbackReason.budgetExceeded;
      }
      return ScenicFallbackReason.mixedRejections;
    }
    if (considered > 0) {
      return ScenicFallbackReason.noVerifiedGeometry;
    }
    return ScenicFallbackReason.noCandidates;
  }

  void _recordDiagnostics({
    required ScenicAttemptContext? context,
    required PedestrianRouteModel normalRoute,
    required List<RouteLegModel> legs,
    required int candidatesInCorridor,
    required int candidatesShortlisted,
    required int candidatesEndpointExcluded,
    required int candidatesNameDeduplicated,
    required int considered,
    required int nativeRouted,
    required Map<ScenicRejectionCategory, int> rejectionCounts,
    required List<ScenicCandidateRejection> rejectedCandidates,
    required List<ScenicJunctionMeasurement> junctionMeasurements,
    required int waypoints,
    required int zeroDetourCandidates,
    required int zeroDetourFeaturesAccepted,
    required int requestsUsedBefore,
    required NativeWalkRequestBudget requestBudget,
    required ScenicFallbackReason finalReason,
  }) {
    final attemptContext = context;
    if (attemptContext == null || !ScenicDiagnostics.enabled) return;
    final budgetSeconds = attemptContext.presetBudgetSeconds;
    final remainingWalkBudgetSeconds = budgetSeconds == null
        ? -1
        : budgetSeconds - attemptContext.visitSeconds - normalRoute.durationSeconds;
    ScenicDiagnostics.record(ScenicAttemptReport(
      requestedWalkKind: attemptContext.requestedWalkKind,
      datasetVersion: attemptContext.datasetVersion,
      datasetFeaturesCount: attemptContext.datasetFeaturesCount,
      routeLegsCount: normalRoute.legs.length,
      normalWalkingSeconds: normalRoute.durationSeconds,
      normalDistanceMeters: normalRoute.distanceMeters,
      visitSeconds: attemptContext.visitSeconds,
      selectedPresetBudgetSeconds: attemptContext.presetBudgetSeconds,
      remainingWalkBudgetSeconds: remainingWalkBudgetSeconds,
      zeroDetourCandidates: zeroDetourCandidates,
      zeroDetourFeaturesAccepted: zeroDetourFeaturesAccepted,
      nativeRequestsUsedBeforeScenic: requestsUsedBefore,
      nativeRequestsRemainingBeforeScenic:
          requestBudget.maximumRequests - requestsUsedBefore,
      candidatesInCorridor: candidatesInCorridor,
      candidatesShortlisted: candidatesShortlisted,
      candidatesEndpointExcluded: candidatesEndpointExcluded,
      candidatesNameDeduplicated: candidatesNameDeduplicated,
      candidatesConsidered: considered,
      candidatesNativeRouted: nativeRouted,
      rejectionCounts: Map.unmodifiable(rejectionCounts),
      rejectedCandidates: List.unmodifiable(rejectedCandidates),
      junctionMeasurements: List.unmodifiable(junctionMeasurements),
      scenicStagesAccepted: legs.where((l) => l.scenic != null).length,
      scenicWaypointsAccepted: waypoints,
      nativeRequestsUsedAfterScenic: requestBudget.requests,
      finalFallbackReason: finalReason.name,
      finalWalkKind:
          legs.any((l) => l.scenic != null) ? WalkKind.scenic.name : WalkKind.normal.name,
    ));
  }

  /// Measures the geometry MapKit already returned against the verified
  /// dataset, without adding a waypoint or issuing any request. A feature is
  /// eligible only under the same coverage bands and score threshold used by
  /// the insertion path; the resulting scenic stage keeps the normal route's
  /// real geometry, distance, duration and maneuvers verbatim (extra = 0).
  ///
  /// This never turns a nearby landmark into a scenic claim: coverage is the
  /// measured share of the stage length inside the feature's 60 m band, and
  /// the score still includes the model's confidence/uncertainty term.
  ({
    List<ScenicFeature> features,
    List<(ScenicFeature, double)> coverage,
    int candidates,
  }) _recognizeOnPath(RouteLegModel stage) {
    final eligible = <(ScenicFeature, double, double)>[];
    var candidates = 0;
    if (stage.geometryPoints.length >= 2) {
      for (final feature in features) {
        final coverage = _coverageShare(stage.geometryPoints, feature);
        if (coverage <= 0) continue;
        candidates++;
        if (coverage < config.minCoverageShare ||
            coverage < config.verifiedNearbyShare) {
          continue;
        }
        final opportunityScore = score(
          feature: feature,
          coverageShare: coverage,
          extraMinutes: 0,
        );
        if (opportunityScore < config.acceptanceThreshold) continue;
        eligible.add((feature, coverage, opportunityScore));
      }
    }
    eligible.sort((x, y) {
      var order = y.$3.compareTo(x.$3);
      if (order == 0) order = y.$2.compareTo(x.$2);
      if (order == 0) order = x.$1.id.compareTo(y.$1.id);
      return order;
    });
    final seenNames = <String>{};
    final selected = <(ScenicFeature, double)>[];
    for (final entry in eligible) {
      if (!seenNames.add(entry.$1.name)) continue;
      selected.add((entry.$1, entry.$2));
      if (selected.length >= config.maxWaypointsPerStage) break;
    }
    return (
      features: [for (final entry in selected) entry.$1],
      coverage: selected,
      candidates: candidates,
    );
  }

  ScenicStageInfo _onPathStageInfo(List<(ScenicFeature, double)> coverage) {
    var strongest = 0.0;
    var totalScore = 0.0;
    for (final (feature, share) in coverage) {
      strongest = math.max(strongest, share);
      totalScore += score(
        feature: feature,
        coverageShare: share,
        extraMinutes: 0,
      );
    }
    final evidence = strongest >= config.verifiedOnPathShare
        ? ScenicEvidenceLevel.verifiedOnPath
        : strongest >= config.verifiedNearbyShare
            ? ScenicEvidenceLevel.verifiedNearby
            : ScenicEvidenceLevel.ambiguous;
    return ScenicStageInfo(
      featureIds: [for (final (feature, _) in coverage) feature.id],
      featureNames: [for (final (feature, _) in coverage) feature.name],
      evidence: evidence,
      coverageShare: strongest,
      extraSeconds: 0,
      extraMeters: 0,
      score: totalScore,
      explanation: _explanation(coverage),
    );
  }

  RouteLegModel _withScenic(RouteLegModel leg, ScenicStageInfo scenic) =>
      RouteLegModel(
        fromTitle: leg.fromTitle,
        toTitle: leg.toTitle,
        distanceMeters: leg.distanceMeters,
        durationSeconds: leg.durationSeconds,
        geometryPoints: leg.geometryPoints,
        maneuvers: leg.maneuvers,
        visitMinutes: leg.visitMinutes,
        scenic: scenic,
      );

  /// Corridor pre-filter measured against the REAL piece polyline (Phase
  /// C4/C5 runtime fixes §4): the old chord-distance filter lost features
  /// lying near a bend of the actual MapKit geometry. The corridor width is
  /// unchanged; only the measured distance is honest now. Still a candidate
  /// economisation only — never a walkability proof. Deterministic ranking;
  /// duplicates by feature name are dropped AFTER ranking so dataset order
  /// cannot discard the better geographic representative of one public way.
  ({
    List<_Candidate> candidates,
    int inCorridor,
    int endpointExcluded,
    int namesDeduplicated,
  }) _shortlist(
    List<List<GeoCoord>> pieces,
    RouteLegModel stage,
    List<ScenicFeature> engaged,
  ) {
    final result = <_Candidate>[];
    var inCorridor = 0;
    var endpointExcluded = 0;
    final engagedIds = engaged.map((f) => f.id).toSet();
    for (var pieceIndex = 0; pieceIndex < pieces.length; pieceIndex++) {
      final piece = pieces[pieceIndex];
      if (piece.length < 2) continue;
      final a = piece.first;
      final b = piece.last;
      for (final feature in features) {
        if (engagedIds.contains(feature.id)) continue;
        final w = feature.waypoint;
        final lineDistance = _minDistanceToPolyline(w, piece);
        if (lineDistance > config.maxCandidateCorridorMeters) {
          continue;
        }
        inCorridor++;
        if (RouteProjectionUtils.distanceBetween(w, a) <
                config.minWaypointSeparationMeters ||
            RouteProjectionUtils.distanceBetween(w, b) <
                config.minWaypointSeparationMeters) {
          endpointExcluded++;
          continue;
        }
        result.add(_Candidate(feature, pieceIndex, lineDistance));
      }
    }
    result.sort((x, y) {
      final priorityX = x.feature.type.weight * x.feature.confidence;
      final priorityY = y.feature.type.weight * y.feature.confidence;
      var comparison = priorityY.compareTo(priorityX);
      if (comparison == 0) {
        comparison = x.lineDistanceMeters.compareTo(y.lineDistanceMeters);
      }
      if (comparison == 0) comparison = x.feature.id.compareTo(y.feature.id);
      if (comparison == 0) {
        comparison = x.subSegmentIndex.compareTo(y.subSegmentIndex);
      }
      return comparison;
    });
    final seenNames = <String>{};
    final candidates = result.where((c) => seenNames.add(c.feature.name)).toList();
    return (
      candidates: candidates,
      inCorridor: inCorridor,
      endpointExcluded: endpointExcluded,
      namesDeduplicated: result.length - candidates.length,
    );
  }

  Future<_CandidateOutcome> _evaluateCandidate({
    required List<List<GeoCoord>> pieces,
    required List<(String, String)> pieceTitles,
    required List<int> pieceDurations,
    required List<double> pieceDistances,
    required List<List<PedestrianManeuverModel>> pieceManeuvers,
    required List<GeoCoord> pieceJunctions,
    required _Candidate candidate,
    required RouteLegModel normalStage,
    required int legIndex,
    required int currentTotalSeconds,
    required int? budgetSeconds,
    required void Function(ScenicJunctionMeasurement) onJunctionMeasured,
  }) async {
    final feature = candidate.feature;
    // Conservative reservation policy, identical to the walk build: both
    // scenic requests are consumed before the calls, so failures still
    // count against the shared per-build cap.
    if (_activeBudget.remaining < 2) {
      return _CandidateOutcome.rejected(
        _rejection(
          feature,
          ScenicRejectionCategory.requestBudget,
          nativeRequests: 0,
        ),
        nativeLegsObtained: false,
      );
    }
    _activeBudget.consume();
    _activeBudget.consume();
    final pieceIndex = candidate.subSegmentIndex;
    final piece = pieces[pieceIndex];
    final a = piece.first;
    final b = piece.last;
    final w = feature.waypoint;

    final PedestrianRouteModel toWaypoint;
    final PedestrianRouteModel fromWaypoint;
    try {
      toWaypoint = await routeService.calculatePointToPointRoute(
        startPoint: _point(a, 'Сценарная точка'),
        destinationPoint: _point(w, feature.name),
      );
      fromWaypoint = await routeService.calculatePointToPointRoute(
        startPoint: _point(w, feature.name),
        destinationPoint: _point(b, 'Сценарная точка'),
      );
    } on RouteCalculationFailure {
      return _CandidateOutcome.rejected(
        _rejection(
          feature,
          ScenicRejectionCategory.mapkitUnavailable,
          nativeRequests: 2,
        ),
        nativeLegsObtained: false,
      );
    } catch (_) {
      return _CandidateOutcome.rejected(
        _rejection(
          feature,
          ScenicRejectionCategory.mapkitUnavailable,
          nativeRequests: 2,
        ),
        nativeLegsObtained: false,
      );
    }
    final toLeg = toWaypoint.legs.isNotEmpty ? toWaypoint.legs.first : null;
    final fromLeg = fromWaypoint.legs.isNotEmpty ? fromWaypoint.legs.first : null;
    if (toLeg == null || fromLeg == null) {
      return _CandidateOutcome.rejected(
        _rejection(
          feature,
          ScenicRejectionCategory.mapkitUnavailable,
          nativeRequests: 2,
        ),
        nativeLegsObtained: false,
      );
    }
    if (toLeg.geometryPoints.length < 2 || fromLeg.geometryPoints.length < 2 ||
        !toLeg.distanceMeters.isFinite || !fromLeg.distanceMeters.isFinite ||
        toLeg.distanceMeters < 0 || fromLeg.distanceMeters < 0 ||
        toLeg.durationSeconds < 0 || fromLeg.durationSeconds < 0) {
      return _CandidateOutcome.rejected(
        _rejection(
          feature,
          ScenicRejectionCategory.mapkitUnavailable,
          nativeRequests: 2,
        ),
        nativeLegsObtained: false,
      );
    }

    // §5 measurement: the real gap between the two native segments at the
    // shared waypoint and how far each snapped endpoint sits from it. Always
    // recorded (also for candidates rejected later), so the merge policy can
    // be decided from real MapKit behaviour, never from assumption.
    final junctionGap = RouteProjectionUtils.distanceBetween(
      toLeg.geometryPoints.last,
      fromLeg.geometryPoints.first,
    );
    final snapToWaypoint = RouteProjectionUtils.distanceBetween(
      toLeg.geometryPoints.last,
      w,
    );
    final snapFromWaypoint = RouteProjectionUtils.distanceBetween(
      fromLeg.geometryPoints.first,
      w,
    );
    onJunctionMeasured(ScenicJunctionMeasurement(
      gapMeters: junctionGap,
      accepted: ScenicStageBuilder.junctionEligibleForConfirmation(
        gapMeters: junctionGap,
        snapFromEndMeters: snapToWaypoint,
        snapFromStartMeters: snapFromWaypoint,
      ),
      bothWithinSnapRadius:
          snapToWaypoint <= ScenicStageBuilder.maxSnapFromWaypointMeters &&
              snapFromWaypoint <= ScenicStageBuilder.maxSnapFromWaypointMeters,
    ));

    // Replace the chosen piece with the two routed segments.
    final newPieces = List<List<GeoCoord>>.of(pieces)
      ..[pieceIndex] = toLeg.geometryPoints
      ..insert(pieceIndex + 1, fromLeg.geometryPoints);
    final newTitles = List<(String, String)>.of(pieceTitles)
      ..[pieceIndex] = (pieceTitles[pieceIndex].$1, feature.name)
      ..insert(pieceIndex + 1, (feature.name, pieceTitles[pieceIndex].$2));
    final newDurations = List<int>.of(pieceDurations)
      ..[pieceIndex] = toLeg.durationSeconds
      ..insert(pieceIndex + 1, fromLeg.durationSeconds);
    final newDistances = List<double>.of(pieceDistances)
      ..[pieceIndex] = toLeg.distanceMeters
      ..insert(pieceIndex + 1, fromLeg.distanceMeters);
    final newManeuvers = List<List<PedestrianManeuverModel>>.of(pieceManeuvers)
      ..[pieceIndex] = toLeg.maneuvers
      ..insert(pieceIndex + 1, fromLeg.maneuvers);
    final newJunctions = List<GeoCoord>.of(pieceJunctions)
      ..insert(pieceIndex, w);

    final combinedGeometry = <GeoCoord>[
      ...newPieces.first,
      for (var i = 1; i < newPieces.length; i++) ...newPieces[i].skip(1),
    ];
    final scenicSeconds = newDurations.fold(0, (sum, s) => sum + s);
    final normalSeconds = pieceDurations.fold(0, (sum, s) => sum + s);
    final extraSeconds = scenicSeconds - normalSeconds;
    final scenicMeters = newDistances.fold(0.0, (sum, s) => sum + s);
    final normalMeters = pieceDistances.fold(0.0, (sum, s) => sum + s);
    final extraMeters = scenicMeters - normalMeters;
    final stageExtraSeconds = scenicSeconds - normalStage.durationSeconds;

    ScenicCandidateRejection rejection(ScenicRejectionCategory category) =>
        ScenicCandidateRejection(
          featureId: feature.id,
          featureType: feature.type.name,
          coverageShare: _coverageShare(combinedGeometry, feature),
          score: null,
          extraMinutes: stageExtraSeconds / 60,
          extraMeters: scenicMeters - normalStage.distanceMeters,
          category: category,
          nativeRequests: 2,
        );

    // Geometry verification against the verified feature (§4.3).
    final coverage = _coverageShare(combinedGeometry, feature);
    final evidence = coverage >= config.verifiedOnPathShare
        ? ScenicEvidenceLevel.verifiedOnPath
        : coverage >= config.verifiedNearbyShare
            ? ScenicEvidenceLevel.verifiedNearby
            : ScenicEvidenceLevel.ambiguous;
    if (evidence == ScenicEvidenceLevel.ambiguous ||
        coverage < config.minCoverageShare) {
      return _CandidateOutcome.rejected(
        ScenicCandidateRejection(
          featureId: feature.id,
          featureType: feature.type.name,
          coverageShare: coverage,
          score: null,
          extraMinutes: stageExtraSeconds / 60,
          extraMeters: scenicMeters - normalStage.distanceMeters,
          category: ScenicRejectionCategory.coverage,
          nativeRequests: 2,
        ),
      );
    }

    // Hard detour and budget limits.
    // Per-stage caps always use the ORIGINAL normal leg. Comparing with the
    // already enhanced chain would compound the allowance on every insertion.
    // A shorter native alternative is valid; maxDetourShare is an upper cap.
    if (normalStage.distanceMeters > 0 &&
        scenicMeters > normalStage.distanceMeters * config.maxDetourShare) {
      return _CandidateOutcome.rejected(
        rejection(ScenicRejectionCategory.detour),
      );
    }
    // The whole walk (native MapKit walking + editorial visit time) must
    // still respect the chosen preset budget (§6) — the total is the sum of
    // native stage durations, never a geometric estimate.
    if (stageExtraSeconds > config.maxExtraMinutes * 60 ||
        (budgetSeconds != null &&
            currentTotalSeconds - normalSeconds + scenicSeconds >
                budgetSeconds)) {
      return _CandidateOutcome.rejected(
        rejection(ScenicRejectionCategory.walkingBudget),
      );
    }

    final candidateScore = score(
      feature: feature,
      coverageShare: coverage,
      extraMinutes: stageExtraSeconds / 60,
    );
    if (candidateScore < config.acceptanceThreshold) {
      return _CandidateOutcome.rejected(
        ScenicCandidateRejection(
          featureId: feature.id,
          featureType: feature.type.name,
          coverageShare: coverage,
          score: candidateScore,
          extraMinutes: stageExtraSeconds / 60,
          extraMeters: scenicMeters - normalStage.distanceMeters,
          category: ScenicRejectionCategory.score,
          nativeRequests: 2,
        ),
      );
    }

    return _CandidateOutcome.accepted(_StageCandidate(
      feature: feature,
      pieces: newPieces,
      titles: newTitles,
      durations: newDurations,
      distances: newDistances,
      maneuvers: newManeuvers,
      junctions: newJunctions,
      coverageShare: coverage,
      evidence: evidence,
      extraSeconds: extraSeconds,
      extraMeters: extraMeters,
      score: candidateScore,
    ));
  }

  ScenicCandidateRejection _rejection(
    ScenicFeature feature,
    ScenicRejectionCategory category, {
    required int nativeRequests,
  }) =>
      ScenicCandidateRejection(
        featureId: feature.id,
        featureType: feature.type.name,
        coverageShare: null,
        score: null,
        extraMinutes: null,
        extraMeters: null,
        category: category,
        nativeRequests: nativeRequests,
      );

  double score({
    required ScenicFeature feature,
    required double coverageShare,
    required double extraMinutes,
  }) =>
      config.benefitWeight *
          feature.type.weight *
          feature.confidence *
          coverageShare -
      config.penaltyPerExtraMinute * math.max(0, extraMinutes) -
      config.uncertaintyPenaltyWeight * (1 - feature.confidence);

  /// Final scores decide selection; equal scores prefer less extra walking
  /// time, then the stable dataset id.
  int _compareCandidates(_StageCandidate x, _StageCandidate y) {
    var order = y.score.compareTo(x.score);
    if (order == 0) order = x.extraSeconds.compareTo(y.extraSeconds);
    if (order == 0) order = x.feature.id.compareTo(y.feature.id);
    return order;
  }

  int _confirmationRequestsNeeded(_StageCandidate candidate) {
    var needed = 0;
    for (var i = 0; i + 1 < candidate.pieces.length; i++) {
      if (!ScenicStageBuilder.sameCoordinate(
        candidate.pieces[i].last,
        candidate.pieces[i + 1].first,
      )) {
        needed++;
      }
    }
    return needed;
  }

  bool _junctionsEligibleForConfirmation(_StageCandidate candidate) {
    for (var i = 0; i + 1 < candidate.pieces.length; i++) {
      final end = candidate.pieces[i].last;
      final start = candidate.pieces[i + 1].first;
      if (ScenicStageBuilder.sameCoordinate(end, start)) continue;
      final waypoint = candidate.junctions[i];
      if (!ScenicStageBuilder.junctionEligibleForConfirmation(
        gapMeters: RouteProjectionUtils.distanceBetween(end, start),
        snapFromEndMeters: RouteProjectionUtils.distanceBetween(end, waypoint),
        snapFromStartMeters: RouteProjectionUtils.distanceBetween(start, waypoint),
      )) {
        return false;
      }
    }
    return true;
  }

  /// §5 junction resolution. Verifies every junction between consecutive
  /// pieces of one candidate before assembly:
  ///
  /// - exact (bit-identical) junctions need no confirmation and no request;
  /// - a junction inside the confirmation band ([maxJoinGapMeters] and the
  ///   waypoint snap radius) is confirmed with ONE native MapKit request
  ///   between the two projections. A native route within
  ///   [ScenicStageBuilder.maxConnectorMeters] proves the walkway is
  ///   continuous, and its REAL geometry is spliced into the chain as its own
  ///   piece verbatim. Its own endpoints must match the two native
  ///   projections within the builder's coordinate exactness band: a nearby
  ///   parallel route cannot prove that the missing connection exists.
  ///   The connector carries its
  ///   own title pair, native seconds/meters and maneuvers, and the maneuver
  ///   rebasing treats it as one more real segment, so indices and offsets of
  ///   every later maneuver stay correct;
  /// - a gap beyond the band, a failed confirmation request, a connector that
  ///   has to go around something, drifted connector endpoints, or an
  ///   exhausted request budget all reject the candidate with their own
  ///   honest category. No join is ever accepted by tolerance alone.
  Future<_JunctionResolution> _resolveJunctions({
    required _StageCandidate candidate,
    required void Function(ScenicJunctionMeasurement) onJunctionMeasured,
  }) async {
    final pieces = <List<GeoCoord>>[];
    final titles = <(String, String)>[];
    final durations = <int>[];
    final distances = <double>[];
    final maneuvers = <List<PedestrianManeuverModel>>[];
    final junctions = <GeoCoord>[];
    var requestsUsed = 0;
    for (var i = 0; i < candidate.pieces.length; i++) {
      pieces.add(candidate.pieces[i]);
      titles.add(candidate.titles[i]);
      durations.add(candidate.durations[i]);
      distances.add(candidate.distances[i]);
      maneuvers.add(candidate.maneuvers[i]);
      if (i + 1 == candidate.pieces.length) break;
      final end = candidate.pieces[i].last;
      final start = candidate.pieces[i + 1].first;
      final waypoint = candidate.junctions[i];
      // One junction per ordinary piece boundary; a confirmed connector adds
      // a second one (its far side, at the same verified waypoint).
      junctions.add(waypoint);
      if (ScenicStageBuilder.sameCoordinate(end, start)) continue;
      final gap = RouteProjectionUtils.distanceBetween(end, start);
      final snapEnd = RouteProjectionUtils.distanceBetween(end, waypoint);
      final snapStart = RouteProjectionUtils.distanceBetween(start, waypoint);
      final snapOk =
          snapEnd <= ScenicStageBuilder.maxSnapFromWaypointMeters &&
              snapStart <= ScenicStageBuilder.maxSnapFromWaypointMeters;
      onJunctionMeasured(ScenicJunctionMeasurement(
        gapMeters: gap,
        accepted: snapOk && gap <= ScenicStageBuilder.maxJoinGapMeters,
        bothWithinSnapRadius: snapOk,
      ));
      if (!snapOk || gap > ScenicStageBuilder.maxJoinGapMeters) {
        // A > band gap is a real detour between different walkways, not a
        // snapping artifact — reject without spending a request.
        return _JunctionResolution.failure(
          category: ScenicRejectionCategory.continuity,
          detail: 'junctionNotContinuous'
              '(gap=${gap.toStringAsFixed(2)}m,'
              'snap=${snapOk ? 'ok' : 'far'})',
          requestsUsed: requestsUsed,
        );
      }
      if (_activeBudget.remaining < 1) {
        return _JunctionResolution.failure(
          category: ScenicRejectionCategory.requestBudget,
          detail: 'junctionConfirmation',
          requestsUsed: requestsUsed,
        );
      }
      _activeBudget.consume();
      requestsUsed++;
      final PedestrianRouteModel connector;
      try {
        connector = await routeService.calculatePointToPointRoute(
          startPoint: _point(end, 'Сценарная точка'),
          destinationPoint: _point(start, 'Сценарная точка'),
        );
      } catch (_) {
        return _JunctionResolution.failure(
          category: ScenicRejectionCategory.mapkitUnavailable,
          detail: 'junctionConnector',
          requestsUsed: requestsUsed,
        );
      }
      final connectorLeg =
          connector.legs.isNotEmpty ? connector.legs.first : null;
      if (connectorLeg == null ||
          connectorLeg.geometryPoints.length < 2 ||
          !connectorLeg.distanceMeters.isFinite ||
          connectorLeg.distanceMeters <= 0 ||
          connectorLeg.durationSeconds < 0 ||
          connectorLeg.geometryPoints.any((point) =>
              !point.latitude.isFinite ||
              !point.longitude.isFinite ||
              point.latitude.abs() > 90 ||
              point.longitude.abs() > 180)) {
        return _JunctionResolution.failure(
          category: ScenicRejectionCategory.mapkitUnavailable,
          detail: 'junctionConnector',
          requestsUsed: requestsUsed,
        );
      }
      // Inspect the original native geometry. A route
      // snapped to a single point proves no connection: pinning its two
      // endpoints would manufacture the entire missing link.
      if (RouteProjectionUtils.polylineLengthMeters(
            connectorLeg.geometryPoints,
          ) <= 0 ||
          ScenicStageBuilder.sameCoordinate(
            connectorLeg.geometryPoints.first,
            connectorLeg.geometryPoints.last,
          )) {
        return _JunctionResolution.failure(
          category: ScenicRejectionCategory.continuity,
          detail: 'junctionConnectorDegenerate',
          requestsUsed: requestsUsed,
        );
      }
      final allowed = ScenicStageBuilder.maxConnectorMeters(gap);
      onJunctionMeasured(ScenicJunctionMeasurement(
        gapMeters: gap,
        accepted: connectorLeg.distanceMeters <= allowed,
        bothWithinSnapRadius: snapOk,
        connectorMeters: connectorLeg.distanceMeters,
      ));
      if (connectorLeg.distanceMeters > allowed) {
        return _JunctionResolution.failure(
          category: ScenicRejectionCategory.continuity,
          detail: 'junctionConnectorTooLong'
              '(gap=${gap.toStringAsFixed(2)}m,'
              'connector=${connectorLeg.distanceMeters.toStringAsFixed(1)}m)',
          requestsUsed: requestsUsed,
        );
      }
      // A confirming route must actually reach both existing native pieces.
      // Replacing nearby connector endpoints could create a different line
      // (or cross an obstruction), so retain its geometry and require the
      // same exactness policy as the builder.
      final headDeviation = RouteProjectionUtils.distanceBetween(
        connectorLeg.geometryPoints.first,
        end,
      );
      final tailDeviation = RouteProjectionUtils.distanceBetween(
        connectorLeg.geometryPoints.last,
        start,
      );
      if (!ScenicStageBuilder.sameCoordinate(
            connectorLeg.geometryPoints.first,
            end,
          ) ||
          !ScenicStageBuilder.sameCoordinate(
            connectorLeg.geometryPoints.last,
            start,
          )) {
        return _JunctionResolution.failure(
          category: ScenicRejectionCategory.continuity,
          detail: 'junctionConnectorEndpoints'
              '(head=${headDeviation.toStringAsFixed(1)}m,'
              'tail=${tailDeviation.toStringAsFixed(1)}m)',
          requestsUsed: requestsUsed,
        );
      }
      pieces.add(List<GeoCoord>.of(connectorLeg.geometryPoints));
      titles.add((candidate.titles[i].$2, candidate.titles[i + 1].$1));
      durations.add(connectorLeg.durationSeconds);
      distances.add(connectorLeg.distanceMeters);
      maneuvers.add(List<PedestrianManeuverModel>.of(connectorLeg.maneuvers));
      junctions.add(waypoint);
    }
    return _JunctionResolution.ok(
      pieces: pieces,
      titles: titles,
      durations: durations,
      distances: distances,
      maneuvers: maneuvers,
      junctions: junctions,
      requestsUsed: requestsUsed,
    );
  }

  /// §5 final fix, condition 2: junction confirmation is part of the stage.
  /// A spliced connector adds its own native seconds and meters AFTER every
  /// acceptance gate has already run, so the whole battery is re-measured on
  /// the chain that will actually be walked: coverage/evidence, the detour
  /// share, the extra-time cap, the whole-walk preset budget and the score
  /// threshold. A confirmed junction that pushes the stage over a limit is
  /// rejected exactly like a candidate that never respected it — the walk
  /// budget is never silently exceeded by a connector. Returns the candidate
  /// with post-confirmation metrics, or the honest rejection to record.
  _CandidateOutcome _recheckAfterJunctions({
    required _StageCandidate candidate,
    required _JunctionResolution resolution,
    required RouteLegModel normalStage,
    required List<int> baseDurations,
    required List<double> baseDistances,
    required int currentTotalSeconds,
    required int? budgetSeconds,
    required int nativeRequests,
  }) {
    final normalSeconds = baseDurations.fold(0, (sum, s) => sum + s);
    final normalMeters = baseDistances.fold(0.0, (sum, s) => sum + s);
    final scenicSeconds = resolution.durations.fold(0, (sum, s) => sum + s);
    final scenicMeters = resolution.distances.fold(0.0, (sum, s) => sum + s);
    final extraSeconds = scenicSeconds - normalSeconds;
    final extraMeters = scenicMeters - normalMeters;
    final stageExtraSeconds = scenicSeconds - normalStage.durationSeconds;
    final combinedGeometry = <GeoCoord>[
      ...resolution.pieces.first,
      for (var i = 1; i < resolution.pieces.length; i++)
        ...resolution.pieces[i].skip(1),
    ];
    final coverage = _coverageShare(combinedGeometry, candidate.feature);
    final evidence = coverage >= config.verifiedOnPathShare
        ? ScenicEvidenceLevel.verifiedOnPath
        : coverage >= config.verifiedNearbyShare
            ? ScenicEvidenceLevel.verifiedNearby
            : ScenicEvidenceLevel.ambiguous;

    ScenicCandidateRejection rejection(
      ScenicRejectionCategory category, {
      double? candidateScore,
    }) =>
        ScenicCandidateRejection(
          featureId: candidate.feature.id,
          featureType: candidate.feature.type.name,
          coverageShare: coverage,
          score: candidateScore,
          extraMinutes: stageExtraSeconds / 60,
          extraMeters: scenicMeters - normalStage.distanceMeters,
          category: category,
          nativeRequests: nativeRequests,
          detail: 'junctionRecheck',
        );

    if (evidence == ScenicEvidenceLevel.ambiguous ||
        coverage < config.minCoverageShare) {
      return _CandidateOutcome.rejected(
        rejection(ScenicRejectionCategory.coverage),
      );
    }
    if (normalStage.distanceMeters > 0 &&
        scenicMeters > normalStage.distanceMeters * config.maxDetourShare) {
      return _CandidateOutcome.rejected(
        rejection(ScenicRejectionCategory.detour),
      );
    }
    if (stageExtraSeconds > config.maxExtraMinutes * 60 ||
        (budgetSeconds != null &&
            currentTotalSeconds - normalSeconds + scenicSeconds >
                budgetSeconds)) {
      return _CandidateOutcome.rejected(
        rejection(ScenicRejectionCategory.walkingBudget),
      );
    }
    final candidateScore = score(
      feature: candidate.feature,
      coverageShare: coverage,
      extraMinutes: stageExtraSeconds / 60,
    );
    if (candidateScore < config.acceptanceThreshold) {
      return _CandidateOutcome.rejected(
        rejection(ScenicRejectionCategory.score, candidateScore: candidateScore),
      );
    }
    return _CandidateOutcome.accepted(candidate.withMetrics(
      coverageShare: coverage,
      evidence: evidence,
      extraSeconds: extraSeconds,
      extraMeters: extraMeters,
      score: candidateScore,
    ));
  }

  ScenicStageBuildOutcome _assembleStage({
    required List<List<GeoCoord>> pieces,
    required List<(String, String)> titles,
    required List<int> durations,
    required List<double> distances,
    required List<List<PedestrianManeuverModel>> maneuvers,
    required RouteLegModel stage,
    required List<ScenicFeature> engaged,
    required int legIndex,
    required List<GeoCoord> junctions,
  }) {
    final segments = <RouteLegModel>[];
    for (var i = 0; i < pieces.length; i++) {
      segments.add(RouteLegModel(
        fromTitle: titles[i].$1,
        toTitle: titles[i].$2,
        distanceMeters: distances[i],
        durationSeconds: durations[i],
        geometryPoints: pieces[i],
        maneuvers: maneuvers[i],
        // The stage endpoint is the tourist stop: only the last piece
        // carries its visit time through ScenicStageBuilder.combine.
        visitMinutes: i == pieces.length - 1 ? stage.visitMinutes : null,
      ));
    }
    final combinedGeometry = <GeoCoord>[
      ...pieces.first,
      for (var i = 1; i < pieces.length; i++) ...pieces[i].skip(1),
    ];
    // Per-feature coverage over the FULL combined stage geometry: evidence
    // and wording follow this measured share, never the feature type weight.
    final perFeatureCoverage = <(ScenicFeature, double)>[
      for (final f in engaged) (f, _coverageShare(combinedGeometry, f)),
    ];
    final evidence = _stageEvidence(perFeatureCoverage);
    final coverage = engaged.isEmpty
        ? 0.0
        : perFeatureCoverage.map((e) => e.$2).reduce(math.max);
    final stageExtraSeconds = durations.fold(0, (sum, s) => sum + s) -
        stage.durationSeconds;
    final scenic = ScenicStageInfo(
      featureIds: engaged.map((f) => f.id).toList(),
      featureNames: engaged.map((f) => f.name).toList(),
      evidence: evidence,
      coverageShare: coverage,
      extraSeconds: stageExtraSeconds,
      extraMeters: distances.fold(0.0, (sum, s) => sum + s) -
          stage.distanceMeters,
      score: perFeatureCoverage.fold(
        0.0,
        (sum, e) =>
            sum +
            score(
              feature: e.$1,
              coverageShare: e.$2,
              extraMinutes: 0,
            ),
      ) - config.penaltyPerExtraMinute * math.max(0, stageExtraSeconds / 60),
      explanation: _explanation(perFeatureCoverage),
    );
    return const ScenicStageBuilder().combineDetailed(
      segments: segments,
      legIndex: legIndex,
      scenic: scenic,
      junctionWaypoints: junctions,
    );
  }

  /// Stage evidence is the strongest claim the measured geometry supports:
  /// the best-engaged feature's share of the FULL stage length decides the
  /// band — never the feature type weight.
  ScenicEvidenceLevel _stageEvidence(List<(ScenicFeature, double)> coverage) {
    var strongest = 0.0;
    for (final (_, share) in coverage) {
      strongest = math.max(strongest, share);
    }
    return strongest >= config.verifiedOnPathShare
        ? ScenicEvidenceLevel.verifiedOnPath
        : strongest >= config.verifiedNearbyShare
            ? ScenicEvidenceLevel.verifiedNearby
            : ScenicEvidenceLevel.ambiguous;
  }

  /// «Проходит по» only for features the stage actually follows (measured
  /// share ≥ [ScenicScoringConfig.verifiedOnPathShare]); «Проходит рядом с»
  /// for the nearby band. Features below the nearby band stay in the stage
  /// metadata but are never claimed as a benefit.
  String _explanation(List<(ScenicFeature, double)> coverage) {
    final onPath = <String>[];
    final nearby = <String>[];
    for (final (feature, share) in coverage) {
      if (share >= config.verifiedOnPathShare) {
        onPath.add(feature.name);
      } else if (share >= config.verifiedNearbyShare) {
        nearby.add(feature.name);
      }
    }
    final parts = <String>[];
    if (onPath.isNotEmpty) {
      parts.add('Проходит по ${onPath.join(', ')}');
    }
    if (nearby.isNotEmpty) {
      parts.add('Проходит рядом с ${nearby.join(', ')}');
    }
    return parts.join('. ');
  }

  PedestrianRouteModel _buildRoute(
    PedestrianRouteModel normalRoute,
    List<RouteLegModel> legs,
  ) {
    final legsSnapshot = List<RouteLegModel>.unmodifiable(legs);
    return PedestrianRouteModel(
      distanceMeters:
          legsSnapshot.fold(0.0, (sum, l) => sum + l.distanceMeters),
      durationSeconds:
          legsSnapshot.fold(0, (sum, l) => sum + l.durationSeconds),
      geometryPoints:
          List.unmodifiable(legsSnapshot.expand((l) => l.geometryPoints)),
      steps: normalRoute.steps,
      legs: legsSnapshot,
      placesCount: normalRoute.placesCount,
      walkKind: WalkKind.scenic,
    );
  }

  RouteComparison _comparison(
    PedestrianRouteModel normalRoute,
    PedestrianRouteModel scenicRoute,
    List<String> engagedNames,
  ) {
    final benefits = <String>[];
    for (final leg in scenicRoute.legs) {
      final scenic = leg.scenic;
      if (scenic == null) continue;
      if (scenic.explanation.isNotEmpty) {
        benefits.add(scenic.explanation);
      }
    }
    return RouteComparison(
      normalWalkingSeconds: normalRoute.durationSeconds,
      scenicWalkingSeconds: scenicRoute.durationSeconds,
      normalDistanceMeters: normalRoute.distanceMeters,
      scenicDistanceMeters: scenicRoute.distanceMeters,
      stopCount: normalRoute.legs.length,
      benefitLines: List.unmodifiable(benefits),
    );
  }

  /// Fraction of [route] LENGTH inside the verified feature's proximity band.
  /// A band is the union of capsules around the feature's segments (or a
  /// circle for point features). Intersect each route segment with that union
  /// analytically and weight its covered fraction by its Haversine length.
  /// Unlike vertex sampling this is independent of MapKit vertex density,
  /// does not miss a band crossed between sparse vertices, and never counts
  /// an entire segment merely because one sampled point lies inside it.
  double _coverageShare(List<GeoCoord> route, ScenicFeature feature) {
    if (route.length < 2) return 0;
    final radius = config.featureProximityMeters;
    if (radius <= 0) return 0;
    // One shared local plane also makes collinear subdivision invariant.
    final reference = route.first;
    final line = (feature.line == null || feature.line!.length < 2
            ? [feature.waypoint]
            : feature.line!)
        .map((p) => RouteProjectionUtils.toLocalMeters(p, reference))
        .toList();
    var totalMeters = 0.0;
    var coveredMeters = 0.0;
    for (var i = 0; i + 1 < route.length; i++) {
      final meters = RouteProjectionUtils.distanceBetween(route[i], route[i + 1]);
      if (meters == 0) continue;
      final a = RouteProjectionUtils.toLocalMeters(route[i], reference);
      final b = RouteProjectionUtils.toLocalMeters(route[i + 1], reference);
      totalMeters += meters;
      coveredMeters += meters * _coveredSegmentFraction(a, b, line, radius);
    }
    return totalMeters == 0 ? 0 : (coveredMeters / totalMeters).clamp(0.0, 1.0);
  }

  double _coveredSegmentFraction(
    ({double x, double y}) a,
    ({double x, double y}) b,
    List<({double x, double y})> line,
    double radius,
  ) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared == 0) return 0;
    final intervals = <(double, double)>[];
    // Circular end caps, including a point-only feature or repeated vertices.
    for (final point in line) {
      final px = a.x - point.x;
      final py = a.y - point.y;
      final center = -(px * dx + py * dy) / lengthSquared;
      final ex = px + center * dx;
      final ey = py + center * dy;
      final remaining = radius * radius - ex * ex - ey * ey;
      if (remaining <= 0) continue; // Tangency has zero covered length.
      final half = math.sqrt(remaining / lengthSquared);
      final low = math.max(0.0, center - half);
      final high = math.min(1.0, center + half);
      if (high > low) intervals.add((low, high));
    }
    // Rectangular middle of each capsule: the feature projection is within
    // the segment and its perpendicular distance is no greater than radius.
    for (var i = 0; i + 1 < line.length; i++) {
      final from = line[i];
      final fx = line[i + 1].x - from.x;
      final fy = line[i + 1].y - from.y;
      final featureLengthSquared = fx * fx + fy * fy;
      if (featureLengthSquared == 0) continue;
      final px = a.x - from.x;
      final py = a.y - from.y;
      var interval = _clipCoverageInterval(
        (0.0, 1.0), px * fx + py * fy, dx * fx + dy * fy,
        0, featureLengthSquared,
      );
      if (interval == null) continue;
      final band = radius * math.sqrt(featureLengthSquared);
      interval = _clipCoverageInterval(
        interval, px * fy - py * fx, dx * fy - dy * fx, -band, band,
      );
      if (interval != null) intervals.add(interval);
    }
    if (intervals.isEmpty) return 0;
    intervals.sort((x, y) => x.$1.compareTo(y.$1));
    var low = intervals.first.$1;
    var high = intervals.first.$2;
    var covered = 0.0;
    for (final interval in intervals.skip(1)) {
      if (interval.$1 > high) {
        covered += high - low;
        low = interval.$1;
        high = interval.$2;
      } else {
        high = math.max(high, interval.$2);
      }
    }
    return (covered + high - low).clamp(0.0, 1.0);
  }

  /// Clip t to lower <= origin + t * slope <= upper. No geometric tolerance
  /// expands the band; numerical tangencies contribute zero length.
  (double, double)? _clipCoverageInterval(
    (double, double) interval,
    double origin,
    double slope,
    double lower,
    double upper,
  ) {
    if (slope == 0) {
      return origin >= lower && origin <= upper ? interval : null;
    }
    final first = (lower - origin) / slope;
    final second = (upper - origin) / slope;
    final low = math.max(interval.$1, math.min(first, second));
    final high = math.min(interval.$2, math.max(first, second));
    return high > low ? (low, high) : null;
  }

  double _minDistanceToPolyline(GeoCoord point, List<GeoCoord> line) {
    var min = double.infinity;
    for (var i = 0; i + 1 < line.length; i++) {
      min = math.min(min, _distancePointToSegmentLine(point, line[i], line[i + 1]));
    }
    return min;
  }

  /// Local-tangent-plane point-to-segment distance in meters (accuracy is
  /// more than sufficient for corridor and proximity bands).
  double _distancePointToSegmentLine(GeoCoord p, GeoCoord a, GeoCoord b) {
    final ref = a;
    final pLocal = RouteProjectionUtils.toLocalMeters(p, ref);
    final aLocal = RouteProjectionUtils.toLocalMeters(a, ref);
    final bLocal = RouteProjectionUtils.toLocalMeters(b, ref);
    final dx = bLocal.x - aLocal.x;
    final dy = bLocal.y - aLocal.y;
    final lengthSq = dx * dx + dy * dy;
    var t = 0.0;
    if (lengthSq > 1e-9) {
      t = ((pLocal.x - aLocal.x) * dx + (pLocal.y - aLocal.y) * dy) / lengthSq;
      t = t.clamp(0.0, 1.0);
    }
    final projX = aLocal.x + t * dx;
    final projY = aLocal.y + t * dy;
    return math.sqrt(
      (pLocal.x - projX) * (pLocal.x - projX) +
          (pLocal.y - projY) * (pLocal.y - projY),
    );
  }

  RoutePointModel _point(GeoCoord coordinate, String title) => RoutePointModel(
        id: 'scenic_${coordinate.latitude}_${coordinate.longitude}',
        title: title,
        subtitle: '',
        latitude: coordinate.latitude,
        longitude: coordinate.longitude,
        isPreset: false,
      );
}

/// Result of the §5 junction resolution for one candidate: the complete
/// parallel chain (pieces, titles, durations, distances, maneuvers,
/// junctions) with every junction carrying a bit-identical shared coordinate.
/// Confirmed connectors appear as their own piece with their own native
/// metrics and maneuvers.
class _JunctionResolution {
  final List<List<GeoCoord>> pieces;
  final List<(String, String)> titles;
  final List<int> durations;
  final List<double> distances;
  final List<List<PedestrianManeuverModel>> maneuvers;
  final List<GeoCoord> junctions;

  /// Set when the resolution failed; null on success.
  final ScenicRejectionCategory? category;
  final String? detail;

  /// Native requests consumed by junction confirmations (0–n).
  final int requestsUsed;

  const _JunctionResolution._({
    required this.pieces,
    required this.titles,
    required this.durations,
    required this.distances,
    required this.maneuvers,
    required this.junctions,
    required this.category,
    required this.detail,
    required this.requestsUsed,
  });

  const _JunctionResolution.ok({
    required List<List<GeoCoord>> pieces,
    required List<(String, String)> titles,
    required List<int> durations,
    required List<double> distances,
    required List<List<PedestrianManeuverModel>> maneuvers,
    required List<GeoCoord> junctions,
    required int requestsUsed,
  }) : this._(
          pieces: pieces,
          titles: titles,
          durations: durations,
          distances: distances,
          maneuvers: maneuvers,
          junctions: junctions,
          category: null,
          detail: null,
          requestsUsed: requestsUsed,
        );

  const _JunctionResolution.failure({
    required ScenicRejectionCategory category,
    required String detail,
    required int requestsUsed,
  }) : this._(
          pieces: const [],
          titles: const [],
          durations: const [],
          distances: const [],
          maneuvers: const [],
          junctions: const [],
          category: category,
          detail: detail,
          requestsUsed: requestsUsed,
        );

  bool get ok => category == null;
}

/// Internal evaluation outcome for one candidate insertion. Exactly one of
/// [candidate] / [rejection] is set.
class _CandidateOutcome {
  final _StageCandidate? candidate;
  final ScenicCandidateRejection? rejection;

  /// Whether both native A→W and W→B legs were obtained for this candidate
  /// (even if the plan was rejected later).
  final bool nativeLegsObtained;

  const _CandidateOutcome._({
    required this.candidate,
    required this.rejection,
    required this.nativeLegsObtained,
  });

  const _CandidateOutcome.accepted(_StageCandidate candidate)
      : this._(
          candidate: candidate,
          rejection: null,
          nativeLegsObtained: true,
        );

  _CandidateOutcome.rejected(
    ScenicCandidateRejection rejection, {
    bool nativeLegsObtained = true,
  })
      : this._(
          candidate: null,
          rejection: rejection,
          nativeLegsObtained: nativeLegsObtained,
        );
}

/// Internal evaluation outcome for one candidate insertion.
class _StageCandidate {
  final ScenicFeature feature;
  final List<List<GeoCoord>> pieces;
  final List<(String, String)> titles;
  final List<int> durations;
  final List<double> distances;
  final List<List<PedestrianManeuverModel>> maneuvers;

  /// Verified waypoint at every junction between consecutive pieces.
  final List<GeoCoord> junctions;
  final double coverageShare;
  final ScenicEvidenceLevel evidence;
  final int extraSeconds;
  final double extraMeters;
  final double score;

  const _StageCandidate({
    required this.feature,
    required this.pieces,
    required this.titles,
    required this.durations,
    required this.distances,
    required this.maneuvers,
    required this.junctions,
    required this.coverageShare,
    required this.evidence,
    required this.extraSeconds,
    required this.extraMeters,
    required this.score,
  });

  /// The same plan with its acceptance metrics re-measured after junction
  /// confirmation (confirmed connectors add their own native time and
  /// distance). The assembled geometry is the confirmation's
  /// [_JunctionResolution] — the chain that actually gets built; this copy
  /// carries the measured numbers into the accepted state.
  _StageCandidate withMetrics({
    required double coverageShare,
    required ScenicEvidenceLevel evidence,
    required int extraSeconds,
    required double extraMeters,
    required double score,
  }) =>
      _StageCandidate(
        feature: feature,
        pieces: pieces,
        titles: titles,
        durations: durations,
        distances: distances,
        maneuvers: maneuvers,
        junctions: junctions,
        coverageShare: coverageShare,
        evidence: evidence,
        extraSeconds: extraSeconds,
        extraMeters: extraMeters,
        score: score,
      );
}
