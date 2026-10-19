import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';

/// Voluntary UI preferences. None of these values authorizes an assessment.
class GuestPreferences {
  GuestPreferences({
    Set<PlaceCategoryEnum> categories = const {},
    this.preferUnusual = false,
    this.showRecommendations = true,
    this.recommendationPreference = RecommendationPreference.all,
  }) : categories = Set.unmodifiable(categories);

  final Set<PlaceCategoryEnum> categories;
  final bool preferUnusual;
  final bool showRecommendations;
  final RecommendationPreference recommendationPreference;

  GuestPreferences copyWith({
    Set<PlaceCategoryEnum>? categories,
    bool? preferUnusual,
    bool? showRecommendations,
    RecommendationPreference? recommendationPreference,
  }) => GuestPreferences(
    categories: categories ?? this.categories,
    preferUnusual: preferUnusual ?? this.preferUnusual,
    showRecommendations: showRecommendations ?? this.showRecommendations,
    recommendationPreference:
        recommendationPreference ?? this.recommendationPreference,
  );

  Map<String, Object> toJson() => {
    'categories': categories.map((category) => category.key).toList()..sort(),
    'preferUnusual': preferUnusual,
    'showRecommendations': showRecommendations,
    'recommendationPreference': recommendationPreference.name,
  };

  factory GuestPreferences.fromJson(Object? value) {
    final json = _object(value);
    _requireKeys(json, const {
      'categories',
      'preferUnusual',
      'showRecommendations',
      'recommendationPreference',
    });
    final rawCategories = json['categories'];
    if (rawCategories is! List ||
        rawCategories.length > PlaceCategoryEnum.values.length ||
        json['preferUnusual'] is! bool ||
        json['showRecommendations'] is! bool) {
      throw const FormatException('Invalid guest preferences');
    }
    final categories = <PlaceCategoryEnum>{};
    for (final raw in rawCategories) {
      final matches = PlaceCategoryEnum.values.where((item) => item.key == raw);
      if (matches.length != 1 || !categories.add(matches.single)) {
        throw const FormatException('Invalid guest category');
      }
    }
    final preference = RecommendationPreference.values.where(
      (item) => item.name == json['recommendationPreference'],
    );
    if (preference.length != 1) {
      throw const FormatException('Invalid recommendation preference');
    }
    return GuestPreferences(
      categories: categories,
      preferUnusual: json['preferUnusual'] as bool,
      showRecommendations: json['showRecommendations'] as bool,
      recommendationPreference: preference.single,
    );
  }
}

/// A reference, never a persisted place card. The title is a saved identifier
/// label; address, coordinates, history and hours always come from the catalog.
class FavoriteReference {
  const FavoriteReference({
    required this.catalogKey,
    required this.scope,
    required this.id,
    required this.fingerprint,
    required this.label,
  });

  final String? catalogKey;
  final String scope;
  final int id;
  final String fingerprint;
  final String label;

  static String scopeFor(String catalogScope) {
    final uri = Uri.tryParse(catalogScope);
    // Never persist URL credentials, query parameters or backend configuration.
    final normalized = uri != null && uri.hasScheme && uri.host.isNotEmpty
        ? Uri(
            scheme: uri.scheme.toLowerCase(),
            host: uri.host.toLowerCase(),
            port: uri.hasPort ? uri.port : null,
            path: uri.path.replaceAll(RegExp(r'/+$'), ''),
          ).toString()
        : catalogScope;
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  static String fingerprintFor(PlaceModel place) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            place.title,
            place.category.key,
            place.latitude,
            place.longitude,
          ]),
        ),
      )
      .toString();

  factory FavoriteReference.fromPlace(PlaceModel place, String scope) {
    if (place.id <= 0 ||
        !place.latitude.isFinite ||
        !place.longitude.isFinite ||
        place.latitude.abs() > 90 ||
        place.longitude.abs() > 180 ||
        !_isDigest(scope)) {
      throw ArgumentError('Invalid favorite identity');
    }
    final label = place.title.replaceAll(RegExp(r'\s+'), ' ').trim();
    return FavoriteReference(
      catalogKey: validCatalogKey(place.catalogKey),
      scope: scope,
      id: place.id,
      fingerprint: fingerprintFor(place),
      label: label.isEmpty
          ? 'Сохранённое место'
          : label.substring(0, label.length > 200 ? 200 : label.length),
    );
  }

  static String? validCatalogKey(String? value) {
    if (value == null) return null;
    final match = RegExp(r'[a-z][a-z0-9-]{0,79}').matchAsPrefix(value);
    return match?.end == value.length ? value : null;
  }

  String get identity => catalogKey != null
      ? 'catalog:$catalogKey'
      : 'legacy:$scope:$id:$fingerprint';

  bool matches(PlaceModel place, String currentScope) {
    final currentKey = validCatalogKey(place.catalogKey);
    if (catalogKey != null && currentKey != null) {
      return catalogKey == currentKey;
    }
    return scope == currentScope &&
        id == place.id &&
        fingerprint == fingerprintFor(place);
  }

  Map<String, Object?> toJson() => {
    'catalogKey': catalogKey,
    'scope': scope,
    'id': id,
    'fingerprint': fingerprint,
    'label': label,
  };

  factory FavoriteReference.fromJson(Object? value) {
    final json = _object(value);
    _requireKeys(json, const {
      'catalogKey',
      'scope',
      'id',
      'fingerprint',
      'label',
    });
    final key = json['catalogKey'];
    final scope = json['scope'];
    final id = json['id'];
    final fingerprint = json['fingerprint'];
    final label = json['label'];
    if ((key != null && (key is! String || validCatalogKey(key) == null)) ||
        scope is! String ||
        !_isDigest(scope) ||
        id is! int ||
        id <= 0 ||
        fingerprint is! String ||
        !_isDigest(fingerprint) ||
        label is! String ||
        label.trim().isEmpty ||
        label.length > 200) {
      throw const FormatException('Invalid favorite reference');
    }
    return FavoriteReference(
      catalogKey: key as String?,
      scope: scope,
      id: id,
      fingerprint: fingerprint,
      label: label,
    );
  }

  static bool _isDigest(String value) =>
      RegExp(r'[a-f0-9]{64}').matchAsPrefix(value)?.end == value.length;
}

enum FavoriteUnavailableReason { catalogUnavailable, notFound, superseded }

class FavoriteResolution {
  const FavoriteResolution({
    required this.reference,
    this.place,
    this.unavailableReason,
  });

  final FavoriteReference reference;
  final PlaceModel? place;
  final FavoriteUnavailableReason? unavailableReason;
}

class GuestLocalSnapshot {
  GuestLocalSnapshot({
    this.onboardingCompleted = false,
    GuestPreferences? preferences,
    List<FavoriteReference> favorites = const [],
  }) : preferences = preferences ?? GuestPreferences(),
       favorites = List.unmodifiable(favorites);

  static const int version = 1;
  static const int maxFavorites = 1000;
  final bool onboardingCompleted;
  final GuestPreferences preferences;
  final List<FavoriteReference> favorites;

  GuestLocalSnapshot copyWith({
    bool? onboardingCompleted,
    GuestPreferences? preferences,
    List<FavoriteReference>? favorites,
  }) => GuestLocalSnapshot(
    onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    preferences: preferences ?? this.preferences,
    favorites: favorites ?? this.favorites,
  );

  String encode() => jsonEncode({
    'version': version,
    'onboardingCompleted': onboardingCompleted,
    'preferences': preferences.toJson(),
    'favorites': favorites.map((item) => item.toJson()).toList(),
  });

  factory GuestLocalSnapshot.decode(String raw) {
    if (raw.length > 512 * 1024) {
      throw const FormatException('Guest data exceeds storage limit');
    }
    final json = _object(jsonDecode(raw));
    if (json['version'] != version || json['version'] is! int) {
      throw const FormatException('Unsupported guest data version');
    }
    // Version dispatch is intentionally centralized here. C8.1 is the first
    // released format; future versions must explicitly migrate this envelope.
    _requireKeys(json, const {
      'version',
      'onboardingCompleted',
      'preferences',
      'favorites',
    });
    final rawFavorites = json['favorites'];
    if (json['onboardingCompleted'] is! bool ||
        rawFavorites is! List ||
        rawFavorites.length > maxFavorites) {
      throw const FormatException('Invalid guest envelope');
    }
    final favorites = <String, FavoriteReference>{};
    for (final raw in rawFavorites) {
      final reference = FavoriteReference.fromJson(raw);
      favorites.putIfAbsent(reference.identity, () => reference);
    }
    return GuestLocalSnapshot(
      onboardingCompleted: json['onboardingCompleted'] as bool,
      preferences: GuestPreferences.fromJson(json['preferences']),
      favorites: favorites.values.toList(),
    );
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected guest data object');
  }
  return value;
}

void _requireKeys(Map<String, dynamic> json, Set<String> keys) {
  if (json.length != keys.length || !keys.every(json.containsKey)) {
    throw const FormatException('Unexpected guest data fields');
  }
}
