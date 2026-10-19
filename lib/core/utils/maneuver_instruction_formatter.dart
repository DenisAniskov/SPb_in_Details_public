/// Application-side Russian phrasing for verified native maneuvers.
///
/// Base imperative strings live on [PedestrianManeuverModel] as the typed
/// localization of the actual SDK enum. This composer adds the distance
/// prefix and the «Затем …» follower line. The wording is composed by this
/// application from the typed event and a distance measured on the accepted
/// route geometry; it is never a verbatim sentence supplied by Yandex and is
/// never parsed back into logic.
class ManeuverInstructionFormatter {
  ManeuverInstructionFormatter._();

  /// Distance under which the maneuver is imminent: the «Через …» prefix is
  /// dropped and the bare imperative is shown. Configurable and unit-tested.
  static const double imminentThresholdMeters = 30.0;

  /// Round displayed approach distances to 10 m: GPS projection jitter is a
  /// few meters, and a counter flickering 73→77→71 m reads as noise.
  static String formatApproachDistance(double meters) {
    if (!meters.isFinite || meters < 0) return '';
    if (meters >= 1000) {
      final km = (meters / 1000).toStringAsFixed(1).replaceAll('.', ',');
      return '$km км';
    }
    final rounded = (meters / 10).round() * 10;
    return '${rounded < 10 ? 10 : rounded} м';
  }

  static String _lowercaseFirst(String text) =>
      text.isEmpty ? text : '${text[0].toLowerCase()}${text.substring(1)}';

  /// «Через 80 м поверните направо» while there is a meaningful distance;
  /// the untouched base imperative once the maneuver is imminent.
  static String composeInstruction(
    String baseInstruction, {
    double? distanceMeters,
    double imminentThresholdMeters = imminentThresholdMeters,
  }) {
    final distance = distanceMeters;
    if (distance == null ||
        !distance.isFinite ||
        distance <= imminentThresholdMeters) {
      return baseInstruction;
    }
    final formatted = formatApproachDistance(distance);
    if (formatted.isEmpty) return baseInstruction;
    return 'Через $formatted ${_lowercaseFirst(baseInstruction)}';
  }

  /// «Затем продолжайте прямо» — the verified maneuver after the active one.
  static String composeFollowingInstruction(String baseInstruction) =>
      'Затем ${_lowercaseFirst(baseInstruction)}';
}
