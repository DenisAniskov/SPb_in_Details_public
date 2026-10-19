import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';

export 'package:smart_navigator_spb/data/local/guest_local_models.dart';

/// Guest state contains no credentials, navigation or assessment dependencies.
/// Restoring it can only read the local envelope. Catalog resolution is an
/// explicit Favorites-screen action through the existing paginated repository.
class GuestExperienceProvider extends ChangeNotifier {
  GuestExperienceProvider({
    required GuestLocalStore store,
    required PlacesRepository repository,
    required String catalogScope,
    // Public dependency names are part of the injection contract.
    // ignore: prefer_initializing_formals
  }) : _store = store,
       // ignore: prefer_initializing_formals
       _repository = repository,
       _catalogScope = FavoriteReference.scopeFor(catalogScope);

  final GuestLocalStore _store;
  final PlacesRepository _repository;
  final String _catalogScope;
  Future<void>? _initializing;
  bool _ready = false;
  bool _disposed = false;
  bool _onboardingCompleted = false;
  GuestPreferences _preferences = GuestPreferences();
  List<FavoriteReference> _favorites = const [];
  String? _storageError;
  int _resolutionRequest = 0;
  int _favoritesRevision = 0;

  bool get ready => _ready;
  bool get onboardingCompleted => _onboardingCompleted;
  Set<PlaceCategoryEnum> get categories => _preferences.categories;
  bool get preferUnusual => _preferences.preferUnusual;
  bool get showRecommendations => _preferences.showRecommendations;
  RecommendationPreference get recommendationPreference =>
      _preferences.recommendationPreference;
  List<FavoriteReference> get favorites => List.unmodifiable(_favorites);

  /// Changes whenever the saved set changes, including legacy-key migration.
  /// Unlike its identities, this also changes across a remove/re-add cycle.
  /// It is session state only; the persisted guest schema remains unchanged.
  int get favoritesRevision => _favoritesRevision;
  String? get storageError => _storageError;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      final saved = await _store.load();
      if (_disposed) return;
      _onboardingCompleted = saved.onboardingCompleted;
      _preferences = saved.preferences;
      _favorites = saved.favorites;
      if (_favorites.isNotEmpty) ++_favoritesRevision;
      _storageError = _store.error;
    } catch (_) {
      _storageError =
          'Не удалось прочитать настройки устройства. '
          'Приложение доступно с обычными настройками.';
    }
    if (_disposed) return;
    _ready = true;
    notifyListeners();
  }

  Future<void> _persist(Future<void> Function() write) async {
    try {
      await write();
      if (_disposed) return;
      _storageError = _store.error;
    } catch (_) {
      if (_disposed) return;
      _storageError =
          _store.error ??
          'Не удалось сохранить изменения на устройстве. '
              'Они доступны до закрытия приложения.';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> completeOnboarding() async {
    await initialize();
    if (_disposed) return;
    _onboardingCompleted = true;
    notifyListeners();
    await _persist(() => _store.saveOnboardingCompleted(true));
  }

  Future<void> _setPreferences(GuestPreferences preferences) async {
    if (_disposed) return;
    _preferences = preferences;
    notifyListeners();
    await _persist(() => _store.savePreferences(preferences));
  }

  Future<void> setCategories(Set<PlaceCategoryEnum> value) async {
    await initialize();
    await _setPreferences(_preferences.copyWith(categories: value));
  }

  Future<void> setPreferUnusual(bool value) async {
    await initialize();
    await _setPreferences(_preferences.copyWith(preferUnusual: value));
  }

  Future<void> setCatalogPreferences({
    required Set<PlaceCategoryEnum> categories,
    required bool preferUnusual,
  }) async {
    await initialize();
    await _setPreferences(
      _preferences.copyWith(
        categories: categories,
        preferUnusual: preferUnusual,
      ),
    );
  }

  Future<void> setShowRecommendations(bool value) async {
    await initialize();
    await _setPreferences(_preferences.copyWith(showRecommendations: value));
  }

  Future<void> setRecommendationPreference(
    RecommendationPreference value,
  ) async {
    await initialize();
    await _setPreferences(
      _preferences.copyWith(recommendationPreference: value),
    );
  }

  /// Intentionally preserves onboarding and favorites. Erasing favorites is
  /// a separate explicit action in the Favorites storage contract.
  Future<void> resetPreferences() async {
    await initialize();
    await _setPreferences(GuestPreferences());
  }

  bool isFavorite(PlaceModel place) =>
      _favorites.any((reference) => reference.matches(place, _catalogScope));

  Future<void> addFavorite(PlaceModel place) async {
    await initialize();
    if (_disposed || isFavorite(place)) return;
    if (_favorites.length >= GuestLocalSnapshot.maxFavorites) {
      _storageError =
          'Сохранено слишком много мест. '
          'Удалите ненужное место перед добавлением нового.';
      notifyListeners();
      return;
    }
    late final FavoriteReference reference;
    try {
      reference = FavoriteReference.fromPlace(place, _catalogScope);
    } on ArgumentError {
      _storageError =
          'Не удалось сохранить место: сведения каталога '
          'некорректны. Попробуйте обновить каталог.';
      notifyListeners();
      return;
    }
    _favorites = [..._favorites, reference];
    ++_favoritesRevision;
    ++_resolutionRequest;
    notifyListeners();
    final snapshot = favorites;
    await _persist(() => _store.saveFavorites(snapshot));
  }

  Future<void> toggleFavorite(PlaceModel place) async {
    await initialize();
    if (_disposed) return;
    final matches = _favorites.where(
      (reference) => reference.matches(place, _catalogScope),
    );
    if (matches.isEmpty) {
      await addFavorite(place);
    } else {
      final identities = matches.map((item) => item.identity).toSet();
      _favorites = _favorites
          .where((reference) => !identities.contains(reference.identity))
          .toList(growable: false);
      ++_favoritesRevision;
      ++_resolutionRequest;
      notifyListeners();
      final snapshot = favorites;
      await _persist(() => _store.saveFavorites(snapshot));
    }
  }

  Future<void> removeFavorite(FavoriteReference reference) async {
    await initialize();
    if (_disposed) return;
    final next = _favorites
        .where((item) => item.identity != reference.identity)
        .toList(growable: false);
    if (next.length == _favorites.length) return;
    _favorites = next;
    ++_favoritesRevision;
    ++_resolutionRequest;
    notifyListeners();
    final snapshot = favorites;
    await _persist(() => _store.saveFavorites(snapshot));
  }

  Future<void> clearFavorites() async {
    await initialize();
    if (_disposed || _favorites.isEmpty) return;
    _favorites = const [];
    ++_favoritesRevision;
    ++_resolutionRequest;
    notifyListeners();
    await _persist(() => _store.saveFavorites(const []));
  }

  List<FavoriteResolution> _unavailable(FavoriteUnavailableReason reason) =>
      List.unmodifiable(
        _favorites.map(
          (reference) => FavoriteResolution(
            reference: reference,
            unavailableReason: reason,
          ),
        ),
      );

  /// Resolves a complete, unfiltered catalog using its existing pagination.
  /// Network errors and missing identities never remove saved references.
  /// Concurrent changes invalidate all place facts from the older request.
  Future<List<FavoriteResolution>> resolveFavorites() async {
    await initialize();
    if (_disposed) return const [];
    final request = ++_resolutionRequest;
    if (_favorites.isEmpty) return const [];
    final references = favorites;
    late final List<PlaceModel> places;
    try {
      places = await _repository.getPlaces();
    } catch (_) {
      return _disposed
          ? const []
          : _unavailable(
              request == _resolutionRequest
                  ? FavoriteUnavailableReason.catalogUnavailable
                  : FavoriteUnavailableReason.superseded,
            );
    }
    if (_disposed) return const [];
    if (request != _resolutionRequest) {
      return _unavailable(FavoriteUnavailableReason.superseded);
    }

    final resolved = <FavoriteResolution>[];
    final unique = <String, FavoriteReference>{};
    var migrated = false;
    for (final reference in references) {
      final matches = places
          .where((place) => reference.matches(place, _catalogScope))
          .toList(growable: false);
      var place = matches.length == 1 ? matches.single : null;
      FavoriteReference? knownLegacyIdentity;
      if (place != null &&
          FavoriteReference.validCatalogKey(place.catalogKey) == null) {
        final currentPlace = place;
        final known = <String, FavoriteReference>{};
        for (final other in references) {
          if (other.catalogKey != null &&
              other.matches(currentPlace, _catalogScope)) {
            known[other.catalogKey!] = other;
          }
        }
        if (known.length > 1) {
          // An older server cannot adjudicate conflicting known stable keys.
          // Exact legacy facts alone must not select either saved identity.
          place = null;
        } else if (known.length == 1) {
          knownLegacyIdentity = known.values.single;
        }
      }
      // Upgrade only a uniquely resolved fallback. A reused ID with a changed
      // title/category/coordinate cannot acquire a new stable key silently.
      final updated =
          reference.catalogKey == null &&
              place != null &&
              FavoriteReference.validCatalogKey(place.catalogKey) != null
          ? FavoriteReference.fromPlace(place, _catalogScope)
          : reference.catalogKey == null && knownLegacyIdentity != null
          ? knownLegacyIdentity
          : reference;
      migrated |= updated.identity != reference.identity;
      if (unique.containsKey(updated.identity)) {
        migrated = true;
        continue;
      }
      unique[updated.identity] = updated;
      resolved.add(
        FavoriteResolution(
          reference: updated,
          place: place,
          unavailableReason: place == null
              ? FavoriteUnavailableReason.notFound
              : null,
        ),
      );
    }
    if (migrated) {
      _favorites = unique.values.toList(growable: false);
      ++_favoritesRevision;
      notifyListeners();
      final snapshot = favorites;
      await _persist(() => _store.saveFavorites(snapshot));
      if (_disposed) return const [];
      if (request != _resolutionRequest) {
        return _unavailable(FavoriteUnavailableReason.superseded);
      }
    }
    return List.unmodifiable(resolved);
  }

  @override
  void dispose() {
    _disposed = true;
    ++_resolutionRequest;
    super.dispose();
  }
}
