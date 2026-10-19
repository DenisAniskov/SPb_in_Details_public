import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';

/// A copy of [base] with another species list — the C7.4 tests need one model
/// with a species the source did not cover, and the parser-level fixtures
/// already pin the wire shapes.
class PollenAnalysisModelWithSpecies extends PollenAnalysisModel {
  PollenAnalysisModelWithSpecies(
    PollenAnalysisModel base,
    List<PollenSpeciesModel> species,
  ) : super(
        status: base.status,
        method: base.method,
        methodVersion: base.methodVersion,
        confidence: base.confidence,
        periodStart: base.periodStart,
        periodEnd: base.periodEnd,
        timezoneName: base.timezoneName,
        routeLengthMeters: base.routeLengthMeters,
        knownMeters: base.knownMeters,
        unknownMeters: base.unknownMeters,
        coverageShare: base.coverageShare,
        walkingDurationSeconds: base.walkingDurationSeconds,
        elapsedDurationSeconds: base.elapsedDurationSeconds,
        concentrationUnit: base.concentrationUnit,
        species: species,
        legs: base.legs,
        reasons: base.reasons,
        limitations: base.limitations,
        assumptions: base.assumptions,
        source: base.source,
      );
}

/// A copy of [base] with another concentration unit, to prove the engine
/// propagates the unit the source stated instead of a hardcoded one.
class PollenAnalysisModelWithUnit extends PollenAnalysisModel {
  PollenAnalysisModelWithUnit(PollenAnalysisModel base, String unit)
    : super(
        status: base.status,
        method: base.method,
        methodVersion: base.methodVersion,
        confidence: base.confidence,
        periodStart: base.periodStart,
        periodEnd: base.periodEnd,
        timezoneName: base.timezoneName,
        routeLengthMeters: base.routeLengthMeters,
        knownMeters: base.knownMeters,
        unknownMeters: base.unknownMeters,
        coverageShare: base.coverageShare,
        walkingDurationSeconds: base.walkingDurationSeconds,
        elapsedDurationSeconds: base.elapsedDurationSeconds,
        concentrationUnit: unit,
        species: [
          for (final item in base.species)
            PollenSpeciesModel(
              code: item.code,
              name: item.name,
              unit: unit,
              state: item.state,
              knownSeconds: item.knownSeconds,
              totalSeconds: item.totalSeconds,
              knownShare: item.knownShare,
              meanConcentration: item.meanConcentration,
              peakConcentration: item.peakConcentration,
              peakAt: item.peakAt,
              exposureGrainsHoursPerM3: item.exposureGrainsHoursPerM3,
            ),
        ],
        legs: base.legs,
        reasons: base.reasons,
        limitations: base.limitations,
        assumptions: base.assumptions,
        source: base.source,
      );
}

/// A copy of [base] whose weather source states another validity deadline.
/// The C7.4.1 live-walk tests need a forecast that has already expired while
/// the values themselves stay complete.
class PuddleAnalysisModelWithWeatherValidity extends PuddleAnalysisModel {
  PuddleAnalysisModelWithWeatherValidity(
    PuddleAnalysisModel base,
    DateTime? validUntil,
  ) : super(
        status: base.status,
        method: base.method,
        methodVersion: base.methodVersion,
        risk: base.risk,
        riskIndex: base.riskIndex,
        routeLengthMeters: base.routeLengthMeters,
        knownMeters: base.knownMeters,
        unknownMeters: base.unknownMeters,
        lowMeters: base.lowMeters,
        moderateMeters: base.moderateMeters,
        highMeters: base.highMeters,
        coverageShare: base.coverageShare,
        confidence: base.confidence,
        periodStart: base.periodStart,
        periodEnd: base.periodEnd,
        timezoneName: base.timezoneName,
        datasetVersion: base.datasetVersion,
        datasetSource: base.datasetSource,
        datasetLicense: base.datasetLicense,
        weather: PuddleWeatherSource(
          provider: base.weather.provider,
          kind: base.weather.kind,
          model: base.weather.model,
          license: base.weather.license,
          attribution: base.weather.attribution,
          sourceUrl: base.weather.sourceUrl,
          available: base.weather.available,
          retrievedAt: base.weather.retrievedAt,
          validUntil: validUntil,
          temporalResolutionSeconds: base.weather.temporalResolutionSeconds,
          spatialResolutionMeters: base.weather.spatialResolutionMeters,
        ),
        reasons: base.reasons,
        limitations: base.limitations,
        sensitivity: base.sensitivity,
      );
}

/// A copy of [base] whose pollen SOURCE states another validity deadline.
class PollenAnalysisModelWithSourceValidity extends PollenAnalysisModel {
  PollenAnalysisModelWithSourceValidity(
    PollenAnalysisModel base,
    DateTime? validUntil,
  ) : super(
        status: base.status,
        method: base.method,
        methodVersion: base.methodVersion,
        confidence: base.confidence,
        periodStart: base.periodStart,
        periodEnd: base.periodEnd,
        timezoneName: base.timezoneName,
        routeLengthMeters: base.routeLengthMeters,
        knownMeters: base.knownMeters,
        unknownMeters: base.unknownMeters,
        coverageShare: base.coverageShare,
        walkingDurationSeconds: base.walkingDurationSeconds,
        elapsedDurationSeconds: base.elapsedDurationSeconds,
        concentrationUnit: base.concentrationUnit,
        species: base.species,
        legs: base.legs,
        reasons: base.reasons,
        limitations: base.limitations,
        assumptions: base.assumptions,
        source: PollenSourceModel(
          available: base.source.available,
          provider: base.source.provider,
          model: base.source.model,
          modelName: base.source.modelName,
          kind: base.source.kind,
          license: base.source.license,
          attribution: base.source.attribution,
          sourceUrl: base.source.sourceUrl,
          retrievedAt: base.source.retrievedAt,
          validUntil: validUntil,
          intervalStart: base.source.intervalStart,
          intervalEnd: base.source.intervalEnd,
          temporalResolutionSeconds: base.source.temporalResolutionSeconds,
          spatialResolutionMeters: base.source.spatialResolutionMeters,
          gridStepDegrees: base.source.gridStepDegrees,
          cellLatitude: base.source.cellLatitude,
          cellLongitude: base.source.cellLongitude,
          cellBounds: base.source.cellBounds,
          timeSemantics: base.source.timeSemantics,
          reason: base.source.reason,
        ),
      );
}

/// Shared C7.4 fixtures. The three analysis models are large value objects;
/// building them once with documented defaults keeps the C7.4 tests about the
/// RECOMMENDATION rules instead of about constructor plumbing. Every default
/// is internally consistent (sums agree, coverage matches the metres), so a
/// test only overrides what it is actually about.

/// The instant every fixture is evaluated for unless a test says otherwise.
final fixtureInstant = DateTime(2026, 7, 1, 14);

ShadeAnalysisModel shadeFixture({
  ShadeStatus status = ShadeStatus.available,
  double routeLengthMeters = 1000,
  double? shadedMeters = 600,
  double? exposedMeters = 400,
  double? unknownMeters = 0,
  double? shadeFraction = 0.6,
  ShadeConfidence confidence = ShadeConfidence.medium,
  String method = 'building_shadow_projection',
  String methodVersion = 'c7_1_2',
  String? datasetVersion = 'spb-buildings-2026-05',
  double coverageShare = 1,
  List<String> limitations = const [
    'Тени от деревьев и навесов не учитываются.',
  ],
}) => ShadeAnalysisModel(
  status: status,
  method: method,
  methodVersion: methodVersion,
  periodStart: fixtureInstant,
  periodEnd: fixtureInstant.add(const Duration(minutes: 54)),
  timezoneName: '+03:00',
  datasetVersion: datasetVersion,
  datasetProvenance: 'OpenStreetMap buildings with height tags, ODbL.',
  solar: const ShadeSolarSummaryModel(
    minElevationDeg: 30,
    maxElevationDeg: 40,
    minAzimuthDeg: 180,
    maxAzimuthDeg: 220,
    bucketCount: 4,
  ),
  routeLengthMeters: routeLengthMeters,
  shadedMeters: shadedMeters,
  exposedMeters: exposedMeters,
  unknownMeters: unknownMeters,
  shadeFraction: shadeFraction,
  confidence: confidence,
  limitations: limitations,
  segments: const [],
  reason: null,
  datasetZonesTouched: const ['centre'],
  outsideCoverageMeters: 0,
  coverageShare: coverageShare,
  heightProvenance: const ShadeHeightProvenanceModel(
    osmDeclared: 40,
    levelsEstimate: 10,
    buildingsConsidered: 50,
  ),
);

/// The puddle model's "high sections exist" case: 1 km walk, 700 m classified
/// (80 low / 100 moderate / 520 high), 300 m unknown, and one parameter variant
/// that disagrees with the baseline.
PuddleAnalysisModel puddleHighFixture() => PuddleAnalysisModel(
  status: PuddleStatus.partial,
  method: 'experimental_relative_wetness',
  methodVersion: 'c7_2_3',
  risk: PuddleRisk.high,
  riskIndex: 0.66,
  routeLengthMeters: 1000,
  knownMeters: 700,
  unknownMeters: 300,
  lowMeters: 80,
  moderateMeters: 100,
  highMeters: 520,
  coverageShare: 0.7,
  confidence: 'low',
  periodStart: fixtureInstant,
  periodEnd: fixtureInstant.add(const Duration(minutes: 54)),
  timezoneName: '+03:00',
  datasetVersion: 'spb-pilot-2026-04',
  datasetSource: 'OpenStreetMap',
  datasetLicense: 'ODbL',
  weather: PuddleWeatherSource(
    provider: 'Open-Meteo',
    kind: 'modeled',
    model: 'ICON',
    license: 'CC-BY-4.0',
    attribution: 'Weather data by Open-Meteo.com',
    sourceUrl: 'https://open-meteo.com/',
    available: true,
    retrievedAt: fixtureInstant,
    validUntil: fixtureInstant.add(const Duration(hours: 1)),
    temporalResolutionSeconds: 3600,
    spatialResolutionMeters: 2000,
  ),
  reasons: const ['experimental_uncalibrated', 'model_precipitation_history'],
  limitations: const ['Модель не откалибрована и не подтверждает наличие луж.'],
  sensitivity: const PuddleSensitivity(
    baseline: PuddleRisk.high,
    variants: {
      'drying_faster_0_5x': PuddleRisk.moderate,
      'drying_slower_2x': PuddleRisk.high,
    },
    variantIndexes: {'drying_faster_0_5x': 0.4, 'drying_slower_2x': 0.7},
    note: 'Пороговые параметры экспериментальны.',
  ),
);

/// The model's own "no classification" case: nothing was classified, so no
/// conclusion about dryness is possible at all.
PuddleAnalysisModel puddleUnknownFixture() => PuddleAnalysisModel(
  status: PuddleStatus.unavailable,
  method: 'experimental_relative_wetness',
  methodVersion: 'c7_2_3',
  risk: PuddleRisk.unknown,
  riskIndex: null,
  routeLengthMeters: 1000,
  knownMeters: 0,
  unknownMeters: 1000,
  lowMeters: 0,
  moderateMeters: 0,
  highMeters: 0,
  coverageShare: 0,
  confidence: 'unavailable',
  periodStart: fixtureInstant,
  periodEnd: fixtureInstant.add(const Duration(minutes: 54)),
  timezoneName: '+03:00',
  datasetVersion: null,
  datasetSource: 'OpenStreetMap',
  datasetLicense: 'ODbL',
  weather: const PuddleWeatherSource(
    provider: '',
    kind: '',
    license: '',
    available: false,
  ),
  reasons: const ['weather_incomplete', 'model_precipitation_history'],
  limitations: const ['История осадков неполная.'],
);

/// A classified walk in which the model found NO high-risk stretch: the case
/// that must never be presented as "the surface is dry".
PuddleAnalysisModel puddleNoHighFixture() => PuddleAnalysisModel(
  status: PuddleStatus.available,
  method: 'experimental_relative_wetness',
  methodVersion: 'c7_2_3',
  risk: PuddleRisk.low,
  riskIndex: 0.12,
  routeLengthMeters: 1000,
  knownMeters: 1000,
  unknownMeters: 0,
  lowMeters: 940,
  moderateMeters: 60,
  highMeters: 0,
  coverageShare: 1,
  confidence: 'low',
  periodStart: fixtureInstant,
  periodEnd: fixtureInstant.add(const Duration(minutes: 54)),
  timezoneName: '+03:00',
  datasetVersion: 'spb-pilot-2026-04',
  datasetSource: 'OpenStreetMap',
  datasetLicense: 'ODbL',
  weather: PuddleWeatherSource(
    provider: 'Open-Meteo',
    kind: 'modeled',
    model: 'ICON',
    license: 'CC-BY-4.0',
    attribution: 'Weather data by Open-Meteo.com',
    sourceUrl: 'https://open-meteo.com/',
    available: true,
    retrievedAt: fixtureInstant,
    validUntil: fixtureInstant.add(const Duration(hours: 1)),
    temporalResolutionSeconds: 3600,
    spatialResolutionMeters: 2000,
  ),
  reasons: const ['experimental_uncalibrated'],
  limitations: const ['Модель не откалибрована и не подтверждает наличие луж.'],
  sensitivity: const PuddleSensitivity(
    baseline: PuddleRisk.low,
    variants: {
      'drying_faster_0_5x': PuddleRisk.low,
      'drying_slower_2x': PuddleRisk.low,
    },
    variantIndexes: {'drying_faster_0_5x': 0.1, 'drying_slower_2x': 0.15},
    note: 'Пороговые параметры экспериментальны.',
  ),
);

PollenSpeciesModel pollenSpecies(
  String code,
  String name, {
  double? mean,
  double knownShare = 1,
  String unit = 'grains/m³',
}) => PollenSpeciesModel(
  code: code,
  name: name,
  unit: unit,
  state: mean == null
      ? PollenSpeciesState.unknown
      : (knownShare >= 1
            ? PollenSpeciesState.available
            : PollenSpeciesState.partial),
  knownSeconds: 3240 * knownShare,
  totalSeconds: 3240,
  knownShare: knownShare,
  meanConcentration: mean,
  peakConcentration: mean,
  peakAt: mean == null ? null : '2026-07-01T13:00:00+00:00',
  exposureGrainsHoursPerM3: mean == null ? null : mean * 0.9,
);

const _pollenCodes = [
  ('alder_pollen', 'Ольха'),
  ('birch_pollen', 'Берёза'),
  ('grass_pollen', 'Злаки'),
  ('mugwort_pollen', 'Полынь'),
  ('olive_pollen', 'Олива'),
  ('ragweed_pollen', 'Амброзия'),
];

PollenSourceModel pollenSource({bool available = true}) => PollenSourceModel(
  available: available,
  provider: 'Open-Meteo',
  model: 'cams_europe',
  modelName: 'CAMS European Air Quality Forecast (CAMS ENSEMBLE)',
  kind: 'modeled_forecast_and_recent_archived_forecast',
  license: 'CC-BY-4.0',
  attribution: 'Pollen data by Open-Meteo.com; CAMS ENSEMBLE model',
  sourceUrl: 'https://open-meteo.com/en/docs/air-quality-api',
  retrievedAt: available ? fixtureInstant : null,
  validUntil: available ? fixtureInstant.add(const Duration(hours: 1)) : null,
  intervalStart: fixtureInstant.subtract(const Duration(hours: 1)),
  intervalEnd: fixtureInstant.add(const Duration(days: 4)),
  temporalResolutionSeconds: 3600,
  spatialResolutionMeters: 11000,
  gridStepDegrees: 0.1,
  cellLatitude: 59.9,
  cellLongitude: 30.3,
  cellBounds: const [59.85, 30.25, 59.95, 30.35],
  timeSemantics: 'instantaneous concentration valid for the indicated hour',
  reason: available ? null : 'pollen_not_configured',
);

/// The full modelled panel for one walk: five species with values (one of them
/// a confirmed zero) and one species whose hours all had values.
PollenAnalysisModel pollenConcentrationsFixture({double unitScale = 1}) {
  final species = [
    pollenSpecies('alder_pollen', 'Ольха', mean: 0.0 * unitScale),
    pollenSpecies('birch_pollen', 'Берёза', mean: 12.6 * unitScale),
    pollenSpecies('grass_pollen', 'Злаки', mean: 4.0 * unitScale),
    pollenSpecies('mugwort_pollen', 'Полынь', mean: 0.0 * unitScale),
    pollenSpecies('olive_pollen', 'Олива', mean: 1.5 * unitScale),
    pollenSpecies('ragweed_pollen', 'Амброзия', mean: 0.0 * unitScale),
  ];
  return PollenAnalysisModel(
    status: PollenStatus.available,
    method: 'experimental_pollen_exposure',
    methodVersion: 'c7_3.1',
    confidence: 'low',
    periodStart: fixtureInstant,
    periodEnd: fixtureInstant.add(const Duration(minutes: 54)),
    timezoneName: '+03:00',
    routeLengthMeters: 1000,
    knownMeters: 1000,
    unknownMeters: 0,
    coverageShare: 1,
    walkingDurationSeconds: 3240,
    elapsedDurationSeconds: 3240,
    concentrationUnit: 'grains/m³',
    species: species,
    legs: null,
    reasons: const ['modeled_pollen_concentration'],
    limitations: const [
      'Это концентрации пыльцы в воздухе, а не прогноз симптомов.',
    ],
    assumptions: const [
      'Концентрация считается постоянной внутри часа [t, t+1h).',
    ],
    source: pollenSource(),
  );
}

/// C7.3.1: the source HAS values for four species, but no hour of the walk
/// carried the whole six-species panel, so the answer publishes no numbers.
PollenAnalysisModel pollenWithheldFixture() => PollenAnalysisModel(
  status: PollenStatus.unavailable,
  method: 'experimental_pollen_exposure',
  methodVersion: 'c7_3.1',
  confidence: 'unavailable',
  periodStart: fixtureInstant,
  periodEnd: fixtureInstant.add(const Duration(hours: 2)),
  timezoneName: '+03:00',
  routeLengthMeters: 1000,
  knownMeters: 0,
  unknownMeters: 1000,
  coverageShare: 0,
  walkingDurationSeconds: 7200,
  elapsedDurationSeconds: 7200,
  concentrationUnit: 'grains/m³',
  species: [
    pollenSpecies('alder_pollen', 'Ольха', knownShare: 0.5),
    pollenSpecies('birch_pollen', 'Берёза', knownShare: 1),
    pollenSpecies('grass_pollen', 'Злаки', knownShare: 1),
    pollenSpecies('mugwort_pollen', 'Полынь', knownShare: 1),
    pollenSpecies('olive_pollen', 'Олива'),
    pollenSpecies('ragweed_pollen', 'Амброзия'),
  ],
  legs: null,
  reasons: const ['pollen_incomplete', 'pollen_no_complete_panel'],
  limitations: const [
    'Неполные значения не публикуются, чтобы часть не выглядела как целое.',
  ],
  assumptions: const [
    'Концентрация считается постоянной внутри часа [t, t+1h).',
  ],
  source: pollenSource(),
);

/// The source is simply off: no values, no attribution, and the honest reason.
PollenAnalysisModel pollenSourceOffFixture() => PollenAnalysisModel(
  status: PollenStatus.unavailable,
  method: 'experimental_pollen_exposure',
  methodVersion: 'c7_3.1',
  confidence: 'unavailable',
  periodStart: fixtureInstant,
  periodEnd: fixtureInstant.add(const Duration(minutes: 54)),
  timezoneName: '+03:00',
  routeLengthMeters: 1000,
  knownMeters: 0,
  unknownMeters: 1000,
  coverageShare: 0,
  walkingDurationSeconds: 3240,
  elapsedDurationSeconds: 3240,
  concentrationUnit: 'grains/m³',
  // With the source off, the backend publishes ZERO coverage for every
  // species (C7.3.1) — that is what distinguishes "the source had nothing"
  // from "the numbers were withheld".
  species: [
    for (final entry in _pollenCodes)
      pollenSpecies(entry.$1, entry.$2, knownShare: 0),
  ],
  legs: null,
  reasons: const ['pollen_not_configured'],
  limitations: const ['Источник пыльцы не подключён оператором.'],
  assumptions: const ['Источник пыльцы требует явного включения.'],
  source: pollenSource(available: false),
);
