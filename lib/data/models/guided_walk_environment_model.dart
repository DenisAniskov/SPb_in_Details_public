import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/services/recommendation_context.dart';

enum GuidedWalkEnvironmentalFactor { shade, puddle, pollen, quiet }

enum GuidedWalkEnvironmentPhase {
  idle,
  shade,
  puddle,
  pollen,
  quiet,
  preparingReport,
  complete,
  cancelled,
  stale,
}

enum GuidedWalkEnvironmentalStatus {
  notAssessed,
  running,
  available,
  partial,
  unavailable,
  failed,
  timedOut,
  cancelled,
  stale,
  skipped,
}

/// Keeps absence distinct from a valid zero returned by an existing model.
/// [data] is the provider's original model, including provenance and unknowns.
class GuidedWalkEnvironmentalResult<T> {
  const GuidedWalkEnvironmentalResult({
    this.status = GuidedWalkEnvironmentalStatus.notAssessed,
    this.data,
    this.message,
    this.evaluatedFor,
  });

  final GuidedWalkEnvironmentalStatus status;
  final T? data;
  final String? message;
  final DateTime? evaluatedFor;

  bool get hasEstimate =>
      status == GuidedWalkEnvironmentalStatus.available ||
      status == GuidedWalkEnvironmentalStatus.partial;
}

/// One whole-walk report for an exact native route and evaluation instant.
/// No physical quantity or recommendation is calculated by this model.
class GuidedWalkEnvironmentReport {
  GuidedWalkEnvironmentReport({
    required this.route,
    required this.routeVersion,
    required this.selectedDeparture,
    required this.evaluatedFor,
    required this.shade,
    required this.puddle,
    required this.pollen,
    required this.quiet,
    required this.context,
    required List<ContextRecommendation> recommendations,
  }) : recommendations = List.unmodifiable(recommendations);

  final PedestrianRouteModel route;
  final int routeVersion;
  final DateTime selectedDeparture;
  final DateTime evaluatedFor;
  final GuidedWalkEnvironmentalResult<ShadeAnalysisModel> shade;
  final GuidedWalkEnvironmentalResult<PuddleAnalysisModel> puddle;
  final GuidedWalkEnvironmentalResult<PollenAnalysisModel> pollen;
  final GuidedWalkEnvironmentalResult<QuietAnalysisModel> quiet;
  final RecommendationContext context;
  final List<ContextRecommendation> recommendations;

  /// Geographic evidence only: a missing forecast or unknown surface is not
  /// evidence that a long route is outside the pilot geography.
  String? get coverageWarning {
    final shadeData = shade.data;
    final pollenData = pollen.data;
    final outside =
        shadeData?.status == ShadeStatus.outsideCoverage ||
        (shadeData?.outsideCoverageMeters ?? 0) > 0 ||
        puddle.data?.status == PuddleStatus.outsideCoverage ||
        pollenData?.status == PollenStatus.outsideCoverage ||
        (pollenData?.legs?.any((leg) => !leg.insideSourceCell) ?? false) ||
        quiet.data?.status == QuietStatus.outsideCoverage;
    if (!outside) return null;
    return 'Часть маршрута выходит за пределы покрытия дополнительных моделей. '
        'Пешеходный маршрут готов, но некоторые оценки для него недоступны.';
  }
}
