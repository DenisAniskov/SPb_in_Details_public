import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/services/pedestrian_guidance_service.dart';
import 'package:smart_navigator_spb/services/voice/navigation_speech_formatter.dart';
import 'package:smart_navigator_spb/services/voice/navigation_voice_coordinator.dart';
import 'package:smart_navigator_spb/services/voice/tts_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_settings.dart';

class _FakeSpeaker implements VoiceSpeaker {
  final List<String> spoken = [];
  final List<double> rates = [];
  final List<String?> selectedVoices = [];
  int stops = 0;

  @override
  Future<void> speak(
    String text, {
    required double rate,
    String? voiceName,
    String? voiceLocale,
  }) async {
    spoken.add(text);
    rates.add(rate);
    selectedVoices.add(voiceName);
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

const _a = GeoCoord(60.0, 30.0);
const _b = GeoCoord(60.0005, 30.0);
const _c = GeoCoord(60.0010, 30.0);

PedestrianManeuverModel _turn(
  PedestrianManeuverKind kind,
  double offset, {
  int legIndex = 0,
  int segment = 0,
}) => PedestrianManeuverModel(
  kind: kind,
  segmentIndex: segment,
  segmentPosition: 0.5,
  offsetMeters: offset,
  legIndex: legIndex,
);

RouteLegModel _leg(
  List<PedestrianManeuverModel> maneuvers, {
  String to = 'Таврический дворец',
  double distance = 55.6,
  List<GeoCoord> geometry = const [_a, _b],
}) => RouteLegModel(
  fromTitle: 'Старт',
  toTitle: to,
  distanceMeters: distance,
  durationSeconds: 60,
  geometryPoints: geometry,
  maneuvers: maneuvers,
  visitMinutes: 20,
);

PedestrianRouteModel _route(List<RouteLegModel> legs) => PedestrianRouteModel(
  distanceMeters: legs.fold(0, (sum, leg) => sum + leg.distanceMeters),
  durationSeconds: 60 * legs.length,
  geometryPoints: const [_a, _b, _c],
  steps: const [],
  legs: legs,
  placesCount: legs.length,
);

UserLocationSnapshot _fix() =>
    UserLocationSnapshot(coordinate: _a, timestamp: DateTime.now());

LiveNavigationState _state({
  required PedestrianRouteModel route,
  NavigationStatus status = NavigationStatus.active,
  double progress = 0,
  int legIndex = 0,
  int maneuverIndex = 0,
  bool gpsLost = false,
  bool offRoute = false,
  bool waiting = false,
}) => LiveNavigationState(
  status: status,
  route: route,
  currentLegIndex: legIndex,
  currentManeuverIndex: maneuverIndex,
  currentLocation: _fix(),
  projectedPoint: _a,
  progressOnCurrentLegMeters: progress,
  remainingDistanceOnCurrentLegMeters: 55.6 - progress,
  totalProgressMeters: progress,
  totalRemainingMeters: 55.6 * route.legs.length - progress,
  isGpsLost: gpsLost,
  isOffRoute: offRoute,
  isWaitingForNextLegConfirmation: waiting,
);

void main() {
  const guidanceService = PedestrianGuidanceService();

  late _FakeSpeaker speaker;
  late NavigationVoiceCoordinator coordinator;

  setUp(() {
    speaker = _FakeSpeaker();
    coordinator = NavigationVoiceCoordinator(
      speaker: speaker,
      settings: const VoiceSettings(enabled: true),
    );
  });

  void say(LiveNavigationState state) {
    coordinator.onNavigation(
      state: state,
      guidance: guidanceService.guidanceFor(state),
    );
  }

  test('approaching maneuver is spoken once, not on every position update', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    final state = _state(route: route);

    say(state);
    say(state);
    say(state);

    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.single, 'Через 60 метров поверните направо');
  });

  test('approaching then imminent are the only two announcements', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);

    say(_state(route: route));
    expect(speaker.spoken.single, contains('Через'));

    say(_state(route: route, progress: 40));
    expect(speaker.spoken, hasLength(2));
    expect(speaker.spoken.last, 'Поверните направо');

    // GPS jitter must not repeat the same phase or move it backwards.
    say(_state(route: route, progress: 42));
    say(_state(route: route, progress: 0));
    expect(speaker.spoken, hasLength(2));
  });

  test('the next maneuver has its own announcement cycle', () {
    final route = _route([
      _leg([
        _turn(PedestrianManeuverKind.right, 55.6),
        _turn(PedestrianManeuverKind.left, 90, segment: 1),
      ]),
    ]);
    say(_state(route: route, progress: 45, maneuverIndex: 1));

    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.single, contains('поверните налево'));

    say(_state(route: route, progress: 65, maneuverIndex: 1));
    expect(speaker.spoken, hasLength(2));
    expect(speaker.spoken.last, 'Поверните налево');
  });

  test('a new leg starts a new announcement cycle', () {
    final first = _leg([
      _turn(PedestrianManeuverKind.right, 55.6),
    ], to: 'Первая точка');
    final second = _leg([
      _turn(PedestrianManeuverKind.left, 55.6, legIndex: 1),
    ], to: 'Вторая точка');
    final route = _route([first, second]);

    say(_state(route: route));
    say(_state(route: route, legIndex: 1));

    expect(speaker.spoken, hasLength(2));
    expect(speaker.spoken.last, contains('налево'));
  });

  test('GPS loss suppresses turns, announces once and re-arms safely', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    say(_state(route: route));
    expect(speaker.spoken, hasLength(1));

    final lost = _state(route: route, gpsLost: true);
    say(lost);
    say(lost);
    expect(speaker.spoken, hasLength(2));
    expect(speaker.spoken.last, 'Сигнал GPS временно потерян.');

    // Fresh progress re-announces the current verified phase, never a stale
    // pre-loss position.
    say(_state(route: route));
    expect(speaker.spoken, hasLength(3));
    expect(speaker.spoken.last, contains('поверните направо'));
  });

  test('off-route suppresses specific turns and announces return once', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    final offRoute = _state(route: route, offRoute: true);

    say(offRoute);
    say(offRoute);

    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.single, contains('Вернитесь к линии на карте'));
  });

  test('rerouting cancels the old route and never speaks its turn later', () {
    final oldRoute = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    say(_state(route: oldRoute));
    expect(speaker.spoken, hasLength(1));
    final oldInstruction = speaker.spoken.single;

    say(_state(route: oldRoute, status: NavigationStatus.rerouting));
    expect(speaker.spoken.last, 'Маршрут перестраивается.');

    final newRoute = _route([
      _leg([
        _turn(PedestrianManeuverKind.left, 55.6),
        _turn(PedestrianManeuverKind.right, 80, segment: 1),
      ]),
    ]);
    say(_state(route: newRoute));
    expect(speaker.spoken.last, contains('налево'));
    expect(speaker.spoken.last, isNot(oldInstruction));
  });

  test('pause is announced once and no turn is spoken while paused', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    final paused = _state(route: route, status: NavigationStatus.paused);
    say(paused);
    say(paused);
    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.single, 'Навигация приостановлена.');
  });

  test('completion is announced exactly once', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    final completed = _state(route: route, status: NavigationStatus.completed);
    say(completed);
    say(completed);

    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.single, 'Вы достигли последней точки прогулки.');
  });

  test('idle stops an utterance and resets the session', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    say(_state(route: route));
    final before = speaker.stops;

    say(_state(route: route, status: NavigationStatus.idle));

    expect(speaker.stops, greaterThan(before));
  });

  test('disabled speech never calls the engine', () {
    coordinator.applySettings(const VoiceSettings(enabled: false));
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);

    say(_state(route: route));

    expect(speaker.spoken, isEmpty);
  });

  test('enabling speech announces the current verified phase once', () {
    coordinator.applySettings(const VoiceSettings(enabled: false));
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    final state = _state(route: route);
    say(state);
    expect(speaker.spoken, isEmpty);

    coordinator.applySettings(const VoiceSettings(enabled: true));
    say(state);
    say(state);

    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.single, contains('поверните направо'));
  });

  test('rapid enable and disable leaves no stale utterance active', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    say(_state(route: route));
    expect(speaker.spoken, hasLength(1));

    coordinator.applySettings(const VoiceSettings(enabled: false));
    final stopsAfterDisable = speaker.stops;
    expect(stopsAfterDisable, greaterThan(0));

    coordinator.applySettings(const VoiceSettings(enabled: true));
    say(_state(route: route, progress: 40));
    expect(speaker.spoken, hasLength(2));

    coordinator.applySettings(const VoiceSettings(enabled: false));
    expect(speaker.stops, greaterThan(stopsAfterDisable));
    say(_state(route: route, progress: 41));
    expect(speaker.spoken, hasLength(2));
  });

  test('rate and selected voice reach the speaker', () {
    coordinator.applySettings(
      const VoiceSettings(
        enabled: true,
        rate: 0.65,
        voiceName: 'ru-test',
        voiceLocale: 'ru-RU',
      ),
    );
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);

    say(_state(route: route));

    expect(speaker.rates.single, 0.65);
    expect(speaker.selectedVoices.single, 'ru-test');
  });

  test(
    'fallback without native maneuvers gives one neutral reminder per leg',
    () {
      final route = _route([_leg(const [])]);
      say(_state(route: route));
      say(_state(route: route, progress: 5));

      expect(speaker.spoken, hasLength(1));
      expect(speaker.spoken.single, contains('Продолжайте движение'));
    },
  );

  test('the starting snapshot stays silent', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    say(_state(route: route, status: NavigationStatus.starting));

    expect(speaker.spoken, isEmpty);
  });

  test('arrival at the next stop is announced once', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
      _leg(const [], to: 'Вторая точка'),
    ]);
    final waiting = _state(route: route, waiting: true);

    say(waiting);
    say(waiting);

    expect(speaker.spoken, hasLength(1));
    expect(speaker.spoken.single, 'Вы достигли следующей точки прогулки.');
  });

  test('a route replacement stops the old queue before the new phrase', () {
    final first = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    say(_state(route: first));
    final stopsBefore = speaker.stops;

    final second = _route([
      _leg([_turn(PedestrianManeuverKind.left, 55.6)]),
    ]);
    say(_state(route: second));

    expect(speaker.stops, greaterThan(stopsBefore));
    expect(speaker.spoken.last, contains('налево'));
  });

  test('speech is paused while the microphone is active', () {
    final route = _route([
      _leg([_turn(PedestrianManeuverKind.right, 55.6)]),
    ]);
    say(_state(route: route));
    expect(speaker.spoken, hasLength(1));

    final stops = speaker.stops;
    coordinator.pauseForRecognition();
    expect(speaker.stops, greaterThan(stops));
    say(_state(route: route, progress: 40));
    expect(speaker.spoken, hasLength(1));

    coordinator.resumeAfterRecognition();
    say(_state(route: route, progress: 41));
    expect(speaker.spoken, hasLength(2));
    expect(speaker.spoken.last, 'Поверните направо');
  });

  test('dispose stops the engine', () {
    coordinator.dispose();
    expect(speaker.stops, greaterThan(0));
  });

  test('guidance models in fallback never invent a turn', () {
    final route = _route([_leg(const [])]);
    final state = _state(route: route);
    final guidance = guidanceService.guidanceFor(state);

    expect(guidance.maneuver, isNull);
    expect(guidance.mode, PedestrianGuidanceMode.fallback);
  });

  group('NavigationSpeechFormatter', () {
    test('uses the correct Russian form of metres', () {
      expect(
        NavigationSpeechFormatter.forSpeech('Через 10 м поверните налево'),
        'Через 10 метров поверните налево',
      );
      expect(
        NavigationSpeechFormatter.forSpeech('Через 21 м поверните налево'),
        'Через 21 метр поверните налево',
      );
      expect(
        NavigationSpeechFormatter.forSpeech('Через 32 м поверните налево'),
        'Через 32 метра поверните налево',
      );
      expect(
        NavigationSpeechFormatter.forSpeech('Через 40 м поверните налево'),
        'Через 40 метров поверните налево',
      );
      expect(
        NavigationSpeechFormatter.forSpeech('Через 100 м поверните налево'),
        'Через 100 метров поверните налево',
      );
    });

    test('speaks kilometres without the abbreviation', () {
      expect(
        NavigationSpeechFormatter.forSpeech('Через 1,2 км поверните налево'),
        'Через 1,2 километра поверните налево',
      );
      expect(
        NavigationSpeechFormatter.forSpeech('Через 2,0 км поверните налево'),
        'Через 2 километра поверните налево',
      );
    });

    test('leaves bare and neutral instructions untouched', () {
      expect(
        NavigationSpeechFormatter.forSpeech('Поверните направо'),
        'Поверните направо',
      );
      expect(
        NavigationSpeechFormatter.forSpeech(
          'Продолжайте движение по отображённому пешеходному маршруту.',
        ),
        'Продолжайте движение по отображённому пешеходному маршруту.',
      );
    });
  });
}
