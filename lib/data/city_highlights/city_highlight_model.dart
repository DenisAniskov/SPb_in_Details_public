import 'package:smart_navigator_spb/data/models/place_model.dart';

/// C14 «Открой город»: one short, editorial card attached to a catalog place.
///
/// The content is optional and local to the client. A place without a card
/// keeps the ordinary place screen: no empty headers, no placeholder text and
/// no extra network request. Identity is the stable [PlaceModel.catalogKey],
/// never the mutable database id.
class CityHighlight {
  const CityHighlight({
    required this.catalogKey,
    this.attentionHints = const [],
    this.shortStory,
    this.viewpoint,
    this.sources = const [],
    required this.verifiedOn,
  });

  final String catalogKey;

  /// One to three short visual prompts. Each item is complete text, not a
  /// fragment assembled by the UI.
  final List<String> attentionHints;

  /// Optional 20–45 second story. The existing long historical card remains a
  /// separate, deeper layer.
  final String? shortStory;

  /// Optional verified public place from which the object reads differently.
  final CityViewpoint? viewpoint;

  final List<CityHighlightSource> sources;

  /// ISO date of the editorial verification pass.
  final String verifiedOn;

  bool get hasAttentionHints =>
      attentionHints.any((hint) => hint.trim().isNotEmpty);

  bool get hasShortStory => shortStory != null && shortStory!.trim().isNotEmpty;

  bool get hasViewpoint => viewpoint?.hasValidCoordinates ?? false;

  bool get hasSources => sources.isNotEmpty;

  CityHighlightSource? get primarySource {
    for (final source in sources) {
      if (source.sourceType != 'map') return source;
    }
    return sources.isEmpty ? null : sources.first;
  }
}

/// A confirmed public point associated with an attraction.
///
/// Coordinates are copied from the cited OpenStreetMap object (a designated
/// viewpoint, a public square or a public garden). They are never estimated
/// from the attraction itself.
class CityViewpoint {
  const CityViewpoint({
    required this.name,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.sourceUrl,
    required this.verifiedOn,
  });

  /// Neutral short label, e.g. «Дворцовый мост». The UI never calls the
  /// point «the best»: it is simply one confirmed angle.
  final String name;

  /// What becomes visible from here and why the angle is different.
  final String description;

  final double latitude;
  final double longitude;

  /// Public OSM object used to verify the point and its access.
  final String sourceUrl;

  final String verifiedOn;

  bool get hasValidCoordinates =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;
}

/// A source kept next to the content so every factual claim can be audited.
class CityHighlightSource {
  const CityHighlightSource({
    required this.title,
    required this.url,
    required this.sourceType,
  });

  final String title;
  final String url;

  /// `official`, `encyclopedia`, `publication` or `map`.
  final String sourceType;
}
