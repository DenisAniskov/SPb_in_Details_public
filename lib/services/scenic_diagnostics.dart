import 'package:flutter/foundation.dart';

/// Walk-level fields a diagnostics report needs from the routing provider
/// (the engine only knows the scenic part of the operation). Supplying this
/// context is what makes the engine record a report at all.
class ScenicAttemptContext {
  final String requestedWalkKind;
  final int visitSeconds;
  final int? presetBudgetSeconds;
  final String datasetVersion;
  final int datasetFeaturesCount;

  const ScenicAttemptContext({
    this.requestedWalkKind = 'scenic',
    required this.visitSeconds,
    required this.presetBudgetSeconds,
    required this.datasetVersion,
    required this.datasetFeaturesCount,
  });
}

/// Debug-only Scenic Walk diagnostics (Phase C4/C5 runtime fixes §3).
///
/// Records one bounded report per scenic enhancement attempt: request shape,
/// candidate funnel counters, the rejection distribution per pipeline gate,
/// per-candidate measurements and the final outcome. No route coordinates, no
/// GPS history, no API keys — only ids of public dataset features, enum names
/// and aggregate numbers.
///
/// Opt-in: nothing is computed or stored unless [ScenicDiagnostics.enabled]
/// is set (wired to `--dart-define=SCENIC_DIAGNOSTICS=true` in
/// `app_bootstrap.dart`; default false). Recording is hard-disabled in profile
/// and release builds. The buffer is bounded; the oldest report is dropped past
/// [maxReports].
class ScenicDiagnostics {
  ScenicDiagnostics._();

  static bool _requested = false;

  // Keep the build-mode guard at the diagnostics boundary as well as at
  // bootstrap: assigning the flag directly cannot enable a profile report.
  static bool get enabled => kDebugMode && _requested;
  static set enabled(bool requested) => _requested = requested;

  /// Bounded memory: at most this many most-recent reports are retained.
  static const int maxReports = 8;

  /// Per report, at most this many rejected-candidate records are kept.
  static const int maxRejectedCandidatesPerReport = 12;

  /// Per report, at most this many junction measurements are kept.
  static const int maxJunctionMeasurementsPerReport = 8;

  static final List<ScenicAttemptReport> _reports = [];

  /// Unmodifiable view of captured reports, newest last.
  static List<ScenicAttemptReport> get reports => List.unmodifiable(_reports);

  static void record(ScenicAttemptReport report) {
    if (!enabled || !kDebugMode) return;
    _reports.add(report);
    while (_reports.length > maxReports) {
      _reports.removeAt(0);
    }
    // Development console visibility for device walkthroughs; never reached in
    // profile or release builds. Structural fields only (see toDebugMap).
    debugPrint('ScenicDiagnostics: ${report.toDebugMap()}');
  }

  @visibleForTesting
  static void clear() => _reports.clear();
}

/// Pipeline gate that rejected a scenic candidate (§3.2/§3.3). Coarse typed
/// categories only — never coordinates.
enum ScenicRejectionCategory {
  /// Fewer than two native requests remained in the shared per-build cap.
  requestBudget,

  /// Native routing failed or returned an unusable leg for A→W / W→B.
  mapkitUnavailable,

  /// Measured geometry did not meaningfully engage the verified feature
  /// (coverage below the nearby band).
  coverage,

  /// Scenic geometry exceeded the per-stage detour limits (distance share).
  detour,

  /// Scenic geometry exceeded the walking time limits (per-stage extra
  /// minutes or the whole-walk budget).
  walkingBudget,

  /// The deterministic score stayed below the acceptance threshold.
  score,

  /// The combined chain failed structural validation (junction continuity or
  /// maneuver rebase) — no invented connector was drawn.
  continuity,
}

/// Measurements of one rejected candidate plan.
class ScenicCandidateRejection {
  final String featureId;
  final String featureType;
  final double? coverageShare;
  final double? score;
  final double? extraMinutes;
  final double? extraMeters;
  final ScenicRejectionCategory category;

  /// Shared native-request slots reserved for this candidate, including
  /// junction confirmations. A failed first call still reserves both legs;
  /// this is conservative budget accounting, not a successful-route count.
  final int nativeRequests;

  /// For continuity rejections: the specific structural check that failed
  /// (a [ScenicStageFailure] name). Null elsewhere.
  final String? detail;

  const ScenicCandidateRejection({
    required this.featureId,
    required this.featureType,
    required this.coverageShare,
    required this.score,
    required this.extraMinutes,
    required this.extraMeters,
    required this.category,
    required this.nativeRequests,
    this.detail,
  });

  Map<String, Object> toDebugMap() => {
        'feature': featureId,
        'type': featureType,
        if (coverageShare != null)
          'coverage': coverageShare!.toStringAsFixed(3),
        if (score != null) 'score': score!.toStringAsFixed(3),
        if (extraMinutes != null) 'extraMin': extraMinutes!.toStringAsFixed(2),
        if (extraMeters != null) 'extraM': extraMeters!.round(),
        'rejectedBy': category.name,
        if (detail != null) 'check': detail!,
        'requests': nativeRequests,
      };
}

/// Measured distance between the endpoint of one native segment and the start
/// of the next one at a scenic junction (§5: real MapKit endpoint behaviour),
/// plus the outcome of the native confirmation of that junction.
class ScenicJunctionMeasurement {
  final double gapMeters;

  /// Whether this intermediate check passed: eligibility for confirmation
  /// before routing, or the native connector length check after routing.
  /// This is never a final junction or stage acceptance verdict. A measured
  /// connector can still fail endpoint validation or later stage checks;
  /// consult the report's rejection details and accepted-stage counters.
  final bool accepted;

  /// Whether both endpoints sit within the waypoint snap radius.
  final bool bothWithinSnapRadius;

  /// Length returned by the native connector request, even if a later check
  /// rejects it. Zero means no connector length was recorded (including
  /// exact junctions, which need no request); nonzero does not imply a join.
  final double connectorMeters;

  const ScenicJunctionMeasurement({
    required this.gapMeters,
    required this.accepted,
    required this.bothWithinSnapRadius,
    this.connectorMeters = 0,
  });

  Map<String, Object> toDebugMap() => {
        'gapM': double.parse(gapMeters.toStringAsFixed(3)),
        'accepted': accepted,
        'snapOk': bothWithinSnapRadius,
        if (connectorMeters > 0)
          'connectorM': double.parse(connectorMeters.toStringAsFixed(2)),
      };
}

/// One scenic enhancement attempt, in vocabulary of §3.2.
class ScenicAttemptReport {
  final String requestedWalkKind;
  final String datasetVersion;
  final int datasetFeaturesCount;
  final int routeLegsCount;
  final int normalWalkingSeconds;
  final double normalDistanceMeters;
  final int visitSeconds;
  final int? selectedPresetBudgetSeconds;

  /// Walking budget left after the normal walk (preset budget minus the
  /// editorial visit time minus the normal walking time). `-1` when no preset
  /// walking budget applies.
  final int remainingWalkBudgetSeconds;

  /// Features with any measured coverage of the already-built normal path,
  /// and how many passed the unchanged evidence/score gates without an extra
  /// waypoint or native request.
  final int zeroDetourCandidates;
  final int zeroDetourFeaturesAccepted;

  /// Shared request-budget slots used before scenic evaluation. Scenic
  /// evaluation conservatively reserves both leg slots before either call.
  final int nativeRequestsUsedBeforeScenic;
  final int nativeRequestsRemainingBeforeScenic;

  /// Feature-piece pairs inside the real-polyline corridor, accumulated over
  /// insertion steps; a feature revisited at another step is counted again.
  final int candidatesInCorridor;
  final int candidatesShortlisted;
  final int candidatesEndpointExcluded;
  final int candidatesNameDeduplicated;
  final int candidatesConsidered;

  /// Candidates for which both usable native legs were actually obtained.
  /// Reservations and failures alone never increment this counter.
  final int candidatesNativeRouted;
  final Map<ScenicRejectionCategory, int> rejectionCounts;
  final List<ScenicCandidateRejection> rejectedCandidates;
  final List<ScenicJunctionMeasurement> junctionMeasurements;
  final int scenicStagesAccepted;
  final int scenicWaypointsAccepted;
  final int nativeRequestsUsedAfterScenic;
  final String finalFallbackReason;
  final String finalWalkKind;

  const ScenicAttemptReport({
    required this.requestedWalkKind,
    required this.datasetVersion,
    required this.datasetFeaturesCount,
    required this.routeLegsCount,
    required this.normalWalkingSeconds,
    this.normalDistanceMeters = 0,
    required this.visitSeconds,
    required this.selectedPresetBudgetSeconds,
    this.remainingWalkBudgetSeconds = -1,
    this.zeroDetourCandidates = 0,
    this.zeroDetourFeaturesAccepted = 0,
    required this.nativeRequestsUsedBeforeScenic,
    required this.nativeRequestsRemainingBeforeScenic,
    required this.candidatesInCorridor,
    this.candidatesShortlisted = 0,
    this.candidatesEndpointExcluded = 0,
    this.candidatesNameDeduplicated = 0,
    required this.candidatesConsidered,
    required this.candidatesNativeRouted,
    required this.rejectionCounts,
    required this.rejectedCandidates,
    required this.junctionMeasurements,
    required this.scenicStagesAccepted,
    required this.scenicWaypointsAccepted,
    required this.nativeRequestsUsedAfterScenic,
    required this.finalFallbackReason,
    required this.finalWalkKind,
  });

  Map<String, Object> toDebugMap() => {
        'requestedWalkKind': requestedWalkKind,
        'datasetVersion': datasetVersion,
        'datasetFeatures': datasetFeaturesCount,
        'routeLegs': routeLegsCount,
        'normalWalkingSeconds': normalWalkingSeconds,
        'normalDistanceMeters': double.parse(normalDistanceMeters.toStringAsFixed(1)),
        'visitSeconds': visitSeconds,
        'presetBudgetSeconds': selectedPresetBudgetSeconds ?? -1,
        'remainingWalkBudgetSeconds': remainingWalkBudgetSeconds,
        'zeroDetourCandidates': zeroDetourCandidates,
        'zeroDetourFeaturesAccepted': zeroDetourFeaturesAccepted,
        'nativeUsedBeforeScenic': nativeRequestsUsedBeforeScenic,
        'nativeRemainingBeforeScenic': nativeRequestsRemainingBeforeScenic,
        'candidatesInCorridor': candidatesInCorridor,
        'candidatesShortlisted': candidatesShortlisted,
        'candidatesEndpointExcluded': candidatesEndpointExcluded,
        'candidatesNameDeduplicated': candidatesNameDeduplicated,
        'candidatesConsidered': candidatesConsidered,
        'candidatesNativeRouted': candidatesNativeRouted,
        for (final entry in rejectionCounts.entries)
          entry.key.name: entry.value,
        'junctions': [
          for (final measurement in junctionMeasurements)
            measurement.toDebugMap(),
        ],
        'scenicStagesAccepted': scenicStagesAccepted,
        'scenicWaypointsAccepted': scenicWaypointsAccepted,
        'nativeUsedAfterScenic': nativeRequestsUsedAfterScenic,
        'finalFallbackReason': finalFallbackReason,
        'finalWalkKind': finalWalkKind,
        'rejectedSample': [
          for (final rejection in rejectedCandidates) rejection.toDebugMap(),
        ],
      };
}
