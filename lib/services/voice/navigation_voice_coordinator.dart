import 'dart:async';

import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_guidance_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/services/voice/navigation_speech_formatter.dart';
import 'package:smart_navigator_spb/services/voice/tts_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_settings.dart';

/// Derives speech exclusively from the same verified guidance model that the
/// navigation sheet renders. It never computes maneuvers, never reads raw GPS
/// and never repeats a maneuver on every position update.
///
/// A maneuver may be spoken at most once per phase (approaching, then
/// imminent) and phases only move forward for the same maneuver. Route
/// changes, rerouting, GPS loss, off-route, pause and completion cancel the
/// old utterance before any new one.
class NavigationVoiceCoordinator {
  NavigationVoiceCoordinator({
    required VoiceSpeaker speaker,
    VoiceSettings settings = VoiceSettings.defaults,
    // Public dependency names are part of the injection contract.
    // ignore: prefer_initializing_formals
  }) : _speaker = speaker,
       // ignore: prefer_initializing_formals
       _settings = settings;

  final VoiceSpeaker _speaker;
  VoiceSettings _settings;

  PedestrianRouteModel? _route;
  NavigationStatus? _lastStatus;
  PedestrianGuidanceAction? _lastAction;
  String? _maneuverKey;
  int _phaseRank = 0;
  int? _fallbackLegIndex;
  bool _completedSpoken = false;
  bool _pausedForRecognition = false;
  bool _silenced = false;
  bool _disposed = false;

  bool get enabled => _settings.enabled;

  void applySettings(VoiceSettings settings) {
    if (_disposed) return;
    final wasEnabled = _settings.enabled;
    _settings = settings;
    if (!settings.enabled) {
      _silence();
      _resetTracking();
    } else if (!wasEnabled) {
      // A deliberate enable starts a fresh announcement cycle on the next
      // navigation snapshot; nothing is spoken from a stale queue.
      _resetTracking();
      _silenced = false;
    }
  }

  void pauseForRecognition() {
    if (_disposed) return;
    _pausedForRecognition = true;
    _silence();
  }

  void resumeAfterRecognition() {
    if (_disposed) return;
    _pausedForRecognition = false;
    _silenced = false;
  }

  void onNavigation({
    required LiveNavigationState state,
    required PedestrianGuidanceModel guidance,
  }) {
    if (_disposed) return;
    if (!_settings.enabled || _pausedForRecognition) {
      _silence();
      return;
    }
    if (state.status == NavigationStatus.idle) {
      _silence();
      _resetTracking();
      _lastStatus = state.status;
      return;
    }
    if (state.status == NavigationStatus.error) {
      _silence();
      _resetTracking();
      _lastStatus = state.status;
      return;
    }

    final route = state.route;
    if (state.status == NavigationStatus.starting &&
        _lastStatus != NavigationStatus.starting) {
      _silence();
      _resetTracking();
    }
    _lastStatus = state.status;

    if (!identical(route, _route)) {
      _silence();
      _route = route;
      _maneuverKey = null;
      _phaseRank = 0;
      _fallbackLegIndex = null;
      _lastAction = null;
      _completedSpoken = false;
    }

    final action = guidance.action;
    switch (action) {
      case PedestrianGuidanceAction.unavailable:
        _silence();
        _resetManeuverProgress();
        break;
      case PedestrianGuidanceAction.starting:
        // The starting snapshot carries no verified progress; stay quiet.
        break;
      case PedestrianGuidanceAction.completed:
        if (!_completedSpoken) {
          _completedSpoken = true;
          _say(guidance.instruction);
        }
        break;
      case PedestrianGuidanceAction.rerouting:
        if (_lastAction != PedestrianGuidanceAction.rerouting) {
          _say('Маршрут перестраивается.');
        }
        _resetManeuverProgress();
        break;
      case PedestrianGuidanceAction.paused:
        if (_lastAction != PedestrianGuidanceAction.paused) {
          _say('Навигация приостановлена.');
        }
        _resetManeuverProgress();
        break;
      case PedestrianGuidanceAction.waitForGps:
        if (_lastAction != PedestrianGuidanceAction.waitForGps) {
          _say('Сигнал GPS временно потерян.');
        }
        _resetManeuverProgress();
        break;
      case PedestrianGuidanceAction.returnToRoute:
        if (_lastAction != PedestrianGuidanceAction.returnToRoute) {
          _say(guidance.instruction);
        }
        _resetManeuverProgress();
        break;
      case PedestrianGuidanceAction.continueToNextStop:
        if (_lastAction != PedestrianGuidanceAction.continueToNextStop) {
          _say('Вы достигли следующей точки прогулки.');
        }
        _resetManeuverProgress();
        break;
      case PedestrianGuidanceAction.followRoute:
        _speakFollowRoute(state, guidance);
        break;
    }
    _lastAction = action;
  }

  void _speakFollowRoute(
    LiveNavigationState state,
    PedestrianGuidanceModel guidance,
  ) {
    final maneuver = guidance.maneuver;
    if (maneuver == null) {
      // Honest fallback: one neutral reminder per leg, never invented turns.
      if (_fallbackLegIndex != state.currentLegIndex) {
        _fallbackLegIndex = state.currentLegIndex;
        _say(guidance.instruction);
      }
      return;
    }
    final rank = switch (guidance.maneuverState) {
      ManeuverPresentationState.approaching => 1,
      ManeuverPresentationState.imminent => 2,
      ManeuverPresentationState.passed => 3,
      ManeuverPresentationState.upcoming => 0,
      ManeuverPresentationState.unavailable ||
      ManeuverPresentationState.suspended => -1,
    };
    if (rank < 1) return;
    final key =
        '${state.currentLegIndex}:${state.currentManeuverIndex}:'
        '${maneuver.kind.name}:${maneuver.offsetMeters.toStringAsFixed(1)}';
    if (key != _maneuverKey) {
      _maneuverKey = key;
      _phaseRank = 0;
    }
    if (rank <= _phaseRank) return;
    _phaseRank = rank;
    _say(NavigationSpeechFormatter.forSpeech(guidance.instruction));
  }

  void _resetManeuverProgress() {
    _maneuverKey = null;
    _phaseRank = 0;
    _fallbackLegIndex = null;
  }

  void _resetTracking() {
    _route = null;
    _lastStatus = null;
    _lastAction = null;
    _maneuverKey = null;
    _phaseRank = 0;
    _fallbackLegIndex = null;
    _completedSpoken = false;
  }

  void _say(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty || _disposed) return;
    _silenced = false;
    unawaited(_speak(normalized));
  }

  Future<void> _speak(String text) async {
    try {
      await _speaker.speak(
        text,
        rate: _settings.rate,
        voiceName: _settings.voiceName,
        voiceLocale: _settings.voiceLocale,
      );
    } catch (_) {
      // A voice failure never blocks textual navigation.
    }
  }

  void _silence() {
    if (_silenced) return;
    _silenced = true;
    unawaited(_stopSpeaker());
  }

  Future<void> _stopSpeaker() async {
    try {
      await _speaker.stop();
    } catch (_) {
      // Stopping an idle speaker is harmless.
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _silenced = false;
    _silence();
  }
}
