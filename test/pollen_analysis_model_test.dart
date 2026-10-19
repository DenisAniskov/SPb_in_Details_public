import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';

// --------------------------------------------------------------------------
// Phase C7.3: the client model must REFUSE inconsistent payloads instead of
// silently repairing them. Every rejection below is a case where a naive
// parser would either render an unknown as clean air, hide a gap, or show a
// concentration under the wrong unit.
// --------------------------------------------------------------------------

const _codes = <String, String>{
  'alder_pollen': 'Ольха',
  'birch_pollen': 'Берёза',
  'grass_pollen': 'Злаки',
  'mugwort_pollen': 'Полынь',
  'ragweed_pollen': 'Амброзия',
  'olive_pollen': 'Маслина',
};

Map<String, dynamic> _species({String code = 'birch_pollen'}) => {
  'code': code,
  'name': _codes[code],
  'unit': 'grains/m³',
  'status': 'available',
  'known_seconds': 3600,
  'total_seconds': 3600,
  'known_share': 1.0,
  'mean_concentration': 12.6,
  'peak_concentration': 12.6,
  'peak_at': '2026-07-17T08:00:00+00:00',
  'exposure_grains_hours_per_m3': 12.6,
};

Map<String, dynamic> _unknownSpecies({String code = 'olive_pollen'}) => {
  'code': code,
  'name': _codes[code],
  'unit': 'grains/m³',
  'status': 'unknown',
  'known_seconds': 0,
  'total_seconds': 3600,
  'known_share': 0.0,
  'mean_concentration': null,
  'peak_concentration': null,
  'peak_at': null,
  'exposure_grains_hours_per_m3': null,
};

List<Map<String, dynamic>> _allSpecies() =>
    _codes.keys.map((code) => _species(code: code)).toList();

Map<String, dynamic> _source({bool available = true}) => {
  'available': available,
  'provider': 'Open-Meteo',
  'model': 'cams_europe',
  'model_name': 'CAMS European Air Quality Forecast (CAMS ENSEMBLE)',
  'kind': 'modeled_forecast_and_recent_archived_forecast',
  'license': 'CC-BY-4.0',
  'attribution': 'Pollen data by Open-Meteo.com; CAMS ENSEMBLE (Copernicus Atmosphere Monitoring Service) model',
  'source_url': 'https://open-meteo.com/en/docs/air-quality-api',
  'retrieved_at': '2026-07-17T08:00:00+00:00',
  'valid_until': '2026-07-17T09:00:00+00:00',
  'interval_start': '2026-07-17T07:00:00+00:00',
  'interval_end': '2026-07-18T00:00:00+00:00',
  'temporal_resolution_seconds': 3600,
  'spatial_resolution_meters': 11000,
  'grid_step_degrees': 0.1,
  'cell_latitude': 59.9,
  'cell_longitude': 30.3,
  'cell_bounds': [59.85, 30.25, 59.95, 30.35],
  'time_semantics': 'instantaneous concentration valid for the indicated hour [t, t+1h); null is a gap, not zero',
  if (!available) 'reason': 'pollen_not_configured',
};

/// Distinguishes "omitted on purpose" from a derived default.
const _auto = Object();

Map<String, dynamic> _payload({
  String status = 'available',
  Object? total = 1000,
  double known = 1000,
  double unknown = 0,
  double coverage = 1.0,
  double walking = 3600,
  double elapsed = 3600,
  String unit = 'grains/m³',
  String confidence = 'low',
  Object? species,
  Object? legs = _auto,
  Object? source,
  Object? reasons = const ['modeled_pollen_concentration'],
  Object? limitations = const ['Ограничение модели.'],
  Object? assumptions = const [
    'Концентрация считается постоянной внутри часа.',
  ],
  Object? period,
  Object? estimate = true,
}) => {
  'status': status,
  'method': 'experimental_pollen_exposure',
  'method_version': 'c7_3.1',
  'estimate': estimate,
  'confidence': confidence,
  'evaluated_period':
      period ??
      {
        'start': '2026-07-17T11:00:00+03:00',
        'end': '2026-07-17T12:00:00+03:00',
        'timezone': '+03:00',
      },
  'route_length_meters': total,
  'known_meters': known,
  'unknown_meters': unknown,
  'coverage_share': coverage,
  'walking_duration_seconds': walking,
  'elapsed_duration_seconds': elapsed,
  'concentration_unit': unit,
  'species': species ?? _allSpecies(),
  'legs': identical(legs, _auto) ? null : legs,
  'reasons': reasons,
  'limitations': limitations,
  'assumptions': assumptions,
  'source_provenance': source ?? _source(),
  'diagnostics': const {'legs': 1},
};

Map<String, dynamic> _leg({
  int index = 0,
  double length = 1000,
  double known = 1000,
  double unknown = 0,
  bool inside = true,
  Object? species,
}) => {
  'leg_index': index,
  'length_meters': length,
  'known_meters': known,
  'unknown_meters': unknown,
  'starts_at_seconds': 0,
  'ends_at_seconds': 3600,
  'inside_source_cell': inside,
  'species': species ?? (inside ? _allSpecies() : const <Object>[]),
};

void main() {
  test('a consistent available payload parses with all six species', () {
    final model = PollenAnalysisModel.tryFromJson(_payload());
    expect(model, isNotNull);
    expect(model!.status, PollenStatus.available);
    expect(model.methodVersion, 'c7_3.1');
    expect(model.concentrationUnit, 'grains/m³');
    expect(model.species, hasLength(6));
    expect(model.speciesWithValues, hasLength(6));
    expect(model.hasEstimate, isTrue);
    expect(model.coverageShare, 1.0);
    expect(model.legs, isNull);
    expect(model.source.available, isTrue);
    expect(model.source.license, 'CC-BY-4.0');
    expect(model.source.spatialResolutionMeters, 11000);
    expect(model.source.cellBounds, [59.85, 30.25, 59.95, 30.35]);
    expect(model.reasons, contains('modeled_pollen_concentration'));
  });

  test('a partial payload keeps the gap as a gap and never as a zero', () {
    final species = [
      _species(code: 'birch_pollen'),
      _species(code: 'grass_pollen'),
      _unknownSpecies(code: 'olive_pollen'),
    ];
    final model = PollenAnalysisModel.tryFromJson(
      _payload(
        status: 'partial',
        known: 500,
        unknown: 500,
        coverage: 0.5,
        species: species,
      ),
    );
    expect(model, isNotNull);
    expect(model!.status, PollenStatus.partial);
    expect(model.hasEstimate, isTrue);
    expect(model.speciesWithValues, hasLength(2));
    final olive = model.species.firstWhere(
      (item) => item.code == 'olive_pollen',
    );
    expect(olive.state, PollenSpeciesState.unknown);
    expect(olive.meanConcentration, isNull);
    expect(olive.concentrationLabel, 'нет данных');
    expect(model.knownMeters, 500);
  });

  test('an unavailable payload keeps unknown and shows no numbers', () {
    final species = _codes.keys
        .map((code) => _unknownSpecies(code: code))
        .toList();
    final model = PollenAnalysisModel.tryFromJson(
      _payload(
        status: 'unavailable',
        known: 0,
        unknown: 1000,
        coverage: 0.0,
        confidence: 'unavailable',
        species: species,
        source: _source(available: false),
        reasons: const ['pollen_not_configured'],
      ),
    );
    expect(model, isNotNull);
    expect(model!.hasEstimate, isFalse);
    expect(model.knownMeters, 0);
    expect(model.speciesWithValues, isEmpty);
    expect(model.source.available, isFalse);
    expect(model.source.reason, 'pollen_not_configured');
    // No read source → nothing was withheld; this is genuinely "no data".
    expect(model.hasWithheldNumbers, isFalse);
    expect(model.speciesWithSourceValues, isEmpty);
  });

  test('the withheld-panel answer the backend really sends is accepted', () {
    // The VERBATIM HTTP 200 body of the mandatory C7.3.1 scenario: a two-hour
    // walk whose first hour has alder but not birch and whose second hour has
    // birch but not alder, so no hour carries the complete six-species panel.
    // Four species are covered for the whole walk and not one number is
    // published. Regenerate with:
    //
    //   cd backend
    //   PYTHONPATH=. python \
    //     D:/SmartNavigator_C7_3_Validation/capture_c731_payload.py
    //
    // then copy c731_payload.json over this fixture.
    final decoded = jsonDecode(
      File('test/fixtures/c7_3_1_withheld_panel_response.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    // Guard the fixture itself: it must be the real answer, not a lookalike.
    expect(decoded['status'], 'unavailable');
    expect(decoded['confidence'], 'unavailable');
    expect(decoded['diagnostics']['species_withheld'], 6);
    expect(decoded['reasons'], contains('pollen_no_complete_panel'));

    final model = PollenAnalysisModel.tryFromJson(decoded);

    expect(
      model,
      isNotNull,
      reason: 'the backend answer must be accepted, not read as a defect',
    );
    expect(model!.status, PollenStatus.unavailable);
    expect(model.hasEstimate, isFalse);
    expect(model.knownMeters, 0);
    expect(model.coverageShare, 0);
    expect(model.speciesWithValues, isEmpty);
    expect(model.legs, isNull, reason: 'legs are withheld with the numbers');
    // Withholding is not erasure: what the source DID have stays visible, so
    // the card can name the species instead of claiming nothing was known.
    expect(model.hasWithheldNumbers, isTrue);
    expect(model.speciesWithSourceValues.map((item) => item.name).toList(), [
      'Ольха',
      'Берёза',
      'Злаки',
      'Полынь',
      'Амброзия',
      'Маслина',
    ]);
    double shareOf(String code) =>
        model.species.firstWhere((item) => item.code == code).knownShare;
    expect(shareOf('alder_pollen'), 0.5);
    expect(shareOf('birch_pollen'), 0.5);
    expect(shareOf('grass_pollen'), 1.0);
    for (final item in model.species) {
      expect(item.state, PollenSpeciesState.unknown);
      expect(item.meanConcentration, isNull);
      expect(item.peakConcentration, isNull);
      expect(item.peakAt, isNull);
      expect(item.exposureGrainsHoursPerM3, isNull);
      expect(item.concentrationLabel, 'нет данных');
    }
    // The new reason has human wording instead of leaking the raw code.
    expect(
      pollenReasonText('pollen_no_complete_panel'),
      isNot('pollen_no_complete_panel'),
    );
  });

  test('a confirmed zero is a value, not a gap', () {
    final species = _codes.keys
        .map(
          (code) => {
            ..._species(code: code),
            'mean_concentration': 0.0,
            'peak_concentration': 0.0,
            'exposure_grains_hours_per_m3': 0.0,
          },
        )
        .toList();
    final model = PollenAnalysisModel.tryFromJson(_payload(species: species));
    expect(model, isNotNull);
    expect(model!.speciesWithValues, hasLength(6));
    expect(model.hasEstimate, isTrue);
    expect(model.species.first.concentrationLabel, '0 зёрен пыльцы/м³');
  });

  test('per-leg detail is parsed and cross-checked when present', () {
    final model = PollenAnalysisModel.tryFromJson(
      _payload(
        status: 'partial',
        known: 500,
        unknown: 500,
        coverage: 0.5,
        legs: [
          _leg(index: 0, length: 1000, known: 1000, unknown: 0),
          _leg(index: 1, length: 1000, known: 0, unknown: 1000, inside: false),
        ],
      ),
    );
    expect(model, isNotNull);
    expect(model!.legs, hasLength(2));
    expect(model.legs![0].insideSourceCell, isTrue);
    expect(model.legs![1].insideSourceCell, isFalse);
    expect(model.legs![1].species, isEmpty);
    expect(model.legs![1].knownMeters, 0);
  });

  test('the timezone, instants and attribution survive parsing', () {
    final model = PollenAnalysisModel.tryFromJson(_payload())!;
    expect(model.timezoneName, '+03:00');
    expect(model.periodStart.toUtc().hour, 8);
    expect(model.source.intervalEnd, isNotNull);
    expect(model.source.sourceUrl, contains('open-meteo.com'));
    expect(model.source.attribution, contains('CAMS'));
    expect(model.source.timeSemantics, contains('instantaneous'));
    expect(model.limitations, isNotEmpty);
    expect(model.assumptions, isNotEmpty);
  });

  // ------------------------------------------------------------------
  // Rejections: every case where a naive parser would show something false.
  // ------------------------------------------------------------------
  final bogusValues = <Object?>[
    double.nan,
    double.infinity,
    -5.0,
    '12.6',
    null,
  ];

  for (final value in bogusValues) {
    test('a bogus mean concentration ($value) is refused', () {
      final species = _allSpecies();
      species[0]['mean_concentration'] = value;
      expect(
        PollenAnalysisModel.tryFromJson(_payload(species: species)),
        isNull,
      );
    });
  }

  for (final value in bogusValues) {
    test('a bogus route length ($value) is refused', () {
      expect(PollenAnalysisModel.tryFromJson(_payload(total: value)), isNull);
    });
  }

  test('the rejection table refuses every inconsistent payload', () {
    final sources = <String, Map<String, dynamic>>{
      'unknown status': _payload(status: 'low'),
      'unavailable with known metres': _payload(
        status: 'unavailable',
        known: 500,
        unknown: 500,
        coverage: 0.5,
        confidence: 'unavailable',
        species: _codes.keys.map((c) => _unknownSpecies(code: c)).toList(),
        source: _source(available: false),
      ),
      'an unavailable answer that still carries a species number': _payload(
        status: 'unavailable',
        known: 0,
        unknown: 1000,
        coverage: 0.0,
        confidence: 'unavailable',
        // C7.3.1: the backend withholds this number, and the client must
        // refuse the payload if it ever stops doing so — "no complete panel,
        // here is the partial number anyway" is exactly the half-true picture
        // this model exists to prevent.
        species: [
          {
            ..._species(code: 'birch_pollen'),
            'status': 'partial',
            'known_seconds': 1800,
            'known_share': 0.5,
          },
        ],
        reasons: const ['pollen_no_complete_panel'],
      ),
      'available with unknown metres': _payload(
        unknown: 500,
        known: 500,
        coverage: 0.5,
      ),
      'partial with a full coverage': _payload(status: 'partial'),
      'sums that do not add up': _payload(known: 900, unknown: 0),
      'coverage that disagrees with the lengths': _payload(coverage: 0.4),
      'a different concentration unit': _payload(unit: 'µg/m³'),
      'a missing unit': _payload(unit: ''),
      'estimate false': _payload(estimate: false),
      'an unknown confidence code': _payload(confidence: 'high'),
      'numbers with confidence unavailable': _payload(
        confidence: 'unavailable',
      ),
      'no species at all': _payload(species: const []),
      'duplicated species': _payload(
        species: [
          _species(code: 'birch_pollen'),
          _species(code: 'birch_pollen'),
        ],
      ),
      'a species in another unit': _payload(
        species: [
          {..._species(code: 'birch_pollen'), 'unit': 'mg/m³'},
        ],
      ),
      'a species without a name': _payload(
        species: [
          {..._species(code: 'birch_pollen'), 'name': ''},
        ],
      ),
      'an available species without a mean': _payload(
        species: [
          {..._species(code: 'birch_pollen'), 'mean_concentration': null},
        ],
      ),
      'an unknown species that carries a number': _payload(
        species: [
          {..._unknownSpecies(code: 'birch_pollen'), 'mean_concentration': 3.0},
        ],
      ),
      'a peak below the mean': _payload(
        species: [
          {..._species(code: 'birch_pollen'), 'peak_concentration': 1.0},
        ],
      ),
      'an available species without a peak instant': _payload(
        species: [
          {..._species(code: 'birch_pollen'), 'peak_at': null},
        ],
      ),
      'a naive peak instant': _payload(
        species: [
          {..._species(code: 'birch_pollen'), 'peak_at': '2026-07-17T08:00:00'},
        ],
      ),
      'a known share above one': _payload(
        species: [
          {..._species(code: 'birch_pollen'), 'known_share': 1.4},
        ],
      ),
      'a known time longer than the total': _payload(
        species: [
          {..._species(code: 'birch_pollen'), 'known_seconds': 9000},
        ],
      ),
      'numbers without attribution': _payload(
        source: {..._source(), 'attribution': ''},
      ),
      'numbers without a licence': _payload(
        source: {..._source(), 'license': ''},
      ),
      'numbers with an unavailable source': _payload(
        source: _source(available: false),
      ),
      'numbers without assumptions': _payload(assumptions: const []),
      'numbers without limitations': _payload(limitations: const []),
      'a naive period start': _payload(
        period: {
          'start': '2026-07-17T11:00:00',
          'end': '2026-07-17T12:00:00+03:00',
          'timezone': '+03:00',
        },
      ),
      'a period that ends before it starts': _payload(
        period: {
          'start': '2026-07-17T12:00:00+03:00',
          'end': '2026-07-17T11:00:00+03:00',
          'timezone': '+03:00',
        },
      ),
      'an empty timezone': _payload(
        period: {
          'start': '2026-07-17T11:00:00+03:00',
          'end': '2026-07-17T12:00:00+03:00',
          'timezone': '',
        },
      ),
      'legs that do not sum up': _payload(
        status: 'partial',
        known: 500,
        unknown: 500,
        coverage: 0.5,
        legs: [_leg(length: 1000, known: 100, unknown: 100)],
      ),
      'a leg outside the cell with known metres': _payload(
        status: 'partial',
        known: 500,
        unknown: 500,
        coverage: 0.5,
        legs: [_leg(inside: false, length: 1000, known: 1000, unknown: 0)],
      ),
      'a leg outside the cell carrying species': _payload(
        status: 'partial',
        known: 500,
        unknown: 500,
        coverage: 0.5,
        legs: [
          _leg(
            inside: false,
            length: 1000,
            known: 0,
            unknown: 1000,
            species: [_species(code: 'birch_pollen')],
          ),
        ],
      ),
      'a leg inside the cell without species': _payload(
        legs: [_leg(species: const [])],
      ),
      'a malformed reason list': _payload(reasons: const ['', 'ok']),
      'walking longer than elapsed': _payload(walking: 7200, elapsed: 3600),
    };

    sources.forEach((label, payload) {
      expect(
        PollenAnalysisModel.tryFromJson(payload),
        isNull,
        reason: 'payload must be refused: $label',
      );
    });
    expect(sources, hasLength(37));
  });

  test('non-maps and short payloads are refused without throwing', () {
    for (final value in <Object?>[
      null,
      'not a payload',
      <String>[],
      <String, dynamic>{},
      const {'status': 'available'},
      const {'status': 'available', 'method': 'x', 'method_version': 'y'},
    ]) {
      expect(PollenAnalysisModel.tryFromJson(value), isNull, reason: '$value');
    }
  });

  test('every reason code has a human-readable Russian explanation', () {
    const codes = [
      'pollen_not_configured',
      'pollen_unavailable',
      'pollen_source_invalid',
      'pollen_stale',
      'pollen_outside_window',
      'pollen_no_data',
      'outside_source_cell',
      'pollen_incomplete',
      'modeled_pollen_concentration',
      'experimental_uncalibrated',
    ];
    for (final code in codes) {
      final text = pollenReasonText(code);
      expect(text, isNotEmpty);
      expect(text, isNot(code), reason: '$code must be translated');
    }
    // An unknown code is shown verbatim rather than swallowed.
    expect(pollenReasonText('some_future_code'), 'some_future_code');
  });

  test('no danger or medical wording appears in the model vocabulary', () {
    for (final state in PollenSpeciesState.values) {
      final label = pollenSpeciesStateLabel(state).toLowerCase();
      for (final forbidden in [
        'опасн',
        'риск',
        'безопасн',
        'доза',
        'симптом',
      ]) {
        expect(label, isNot(contains(forbidden)));
      }
    }
  });
}
