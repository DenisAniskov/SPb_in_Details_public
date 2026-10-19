import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_navigator_spb/data/local/guest_local_models.dart';

export 'guest_local_models.dart';

/// The app is permanently account-free: local persistence is the
/// product design, not a temporary guest mode. Separate contracts keep the
/// implementation replaceable (for tests or future local backends) without
/// introducing authentication into guest UI state.
abstract interface class PreferencesStore {
  Future<GuestPreferences> loadPreferences();
  Future<void> savePreferences(GuestPreferences preferences);
  Future<bool> loadOnboardingCompleted();
  Future<void> saveOnboardingCompleted(bool completed);
}

abstract interface class FavoritesStore {
  Future<List<FavoriteReference>> loadFavorites();
  Future<void> saveFavorites(List<FavoriteReference> favorites);
}

abstract interface class GuestLocalStore
    implements PreferencesStore, FavoritesStore {
  Future<GuestLocalSnapshot> load();
  String? get error;
}

/// Minimal async boundary for deterministic tests and platform replacement.
abstract interface class GuestKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class GuestStorageException implements Exception {
  const GuestStorageException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One versioned JSON value avoids independently updated preference keys.
/// Mutations are serialized. A failed write retains desired session state, so
/// the next successful write also recovers earlier changes. Preferences are
/// best-effort disk persistence, not a database transaction or a secret store.
class JsonGuestLocalStore implements GuestLocalStore {
  JsonGuestLocalStore({required GuestKeyValueStore storage})
    // Public injection name; the implementation field remains private.
    // ignore: prefer_initializing_formals
    : _storage = storage;

  static const String storageKey = 'smartnavigator.guest';
  final GuestKeyValueStore _storage;
  Future<void> _tail = Future<void>.value();
  GuestLocalSnapshot? _snapshot;
  bool _readProtected = false;
  String? _error;

  @override
  String? get error => _error;

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    // A failed write must not poison the following operations in the queue.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _ensureLoaded() async {
    if (_snapshot != null) return;
    try {
      final raw = await _storage.read(storageKey);
      _snapshot = raw == null
          ? GuestLocalSnapshot()
          : GuestLocalSnapshot.decode(raw);
    } catch (_) {
      _snapshot = GuestLocalSnapshot();
      _readProtected = true;
      // Preserve unknown/corrupt data for recovery, including future schemas.
      // Do not silently overwrite it with defaults on the next UI mutation.
      _error =
          'Не удалось прочитать настройки. Изменения доступны '
          'до закрытия приложения; сохранённые данные оставлены без изменений.';
    }
  }

  @override
  Future<GuestLocalSnapshot> load() => _serialized(() async {
    await _ensureLoaded();
    return _snapshot!;
  });

  Future<void> _update(
    GuestLocalSnapshot Function(GuestLocalSnapshot) update,
  ) => _serialized(() async {
    await _ensureLoaded();
    if (_readProtected) throw GuestStorageException(_error!);
    final next = update(_snapshot!);
    // Validate before the one envelope write, including callers of interfaces.
    final encoded = next.encode();
    GuestLocalSnapshot.decode(encoded);
    _snapshot = next;
    try {
      await _storage.write(storageKey, encoded);
      _error = null;
    } catch (_) {
      _error =
          'Не удалось сохранить изменения на устройстве. '
          'Они доступны до закрытия приложения.';
      throw GuestStorageException(_error!);
    }
  });

  @override
  Future<GuestPreferences> loadPreferences() async =>
      (await load()).preferences;

  @override
  Future<void> savePreferences(GuestPreferences preferences) =>
      _update((state) => state.copyWith(preferences: preferences));

  @override
  Future<bool> loadOnboardingCompleted() async =>
      (await load()).onboardingCompleted;

  @override
  Future<void> saveOnboardingCompleted(bool completed) =>
      _update((state) => state.copyWith(onboardingCompleted: completed));

  @override
  Future<List<FavoriteReference>> loadFavorites() async =>
      (await load()).favorites;

  @override
  Future<void> saveFavorites(List<FavoriteReference> favorites) {
    final unique = <String, FavoriteReference>{};
    for (final reference in favorites) {
      unique.putIfAbsent(reference.identity, () => reference);
    }
    // Snapshot synchronously so a caller cannot mutate a queued operation.
    final copied = unique.values.toList(growable: false);
    return _update((state) => state.copyWith(favorites: copied));
  }
}

/// Platform initialization is lazy: constructing the app starts no reads.
class SharedPreferencesGuestLocalStore extends JsonGuestLocalStore {
  SharedPreferencesGuestLocalStore()
    : super(storage: _SharedPreferencesKeyValueStore());
}

class _SharedPreferencesKeyValueStore implements GuestKeyValueStore {
  Future<SharedPreferences>? _preferences;

  Future<SharedPreferences> get _instance =>
      _preferences ??= SharedPreferences.getInstance();

  @override
  Future<String?> read(String key) async => (await _instance).getString(key);

  @override
  Future<void> write(String key, String value) async {
    if (!await (await _instance).setString(key, value)) {
      throw const GuestStorageException('Preferences write was rejected');
    }
  }
}
