import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';

class FavoriteValues implements GuestKeyValueStore {
  String? value;
  Completer<void>? blockedWrite;
  @override
  Future<String?> read(String key) async => value;
  @override
  Future<void> write(String key, String value) async {
    await blockedWrite?.future;
    this.value = value;
  }
}

class FavoriteCatalog extends PlacesRepository {
  List<PlaceModel> places = [];
  Object? failure;
  int requests = 0;
  bool receivedFilters = false;
  final List<Completer<List<PlaceModel>>> pending = [];
  bool delayed = false;

  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async {
    ++requests;
    receivedFilters |=
        categories != null || isUnusual != null || searchQuery != null;
    if (failure != null) throw failure!;
    if (delayed) {
      final completion = Completer<List<PlaceModel>>();
      pending.add(completion);
      return completion.future;
    }
    return places;
  }
}

PlaceModel place({
  int id = 7,
  String? key = 'museum-one',
  String title = 'Музей',
  PlaceCategoryEnum category = PlaceCategoryEnum.art,
  double latitude = 59.93,
  double longitude = 30.31,
  String address = 'Текущий адрес',
}) => PlaceModel(
  id: id,
  catalogKey: key,
  title: title,
  shortDescription: 'Текущее описание',
  category: category,
  latitude: latitude,
  longitude: longitude,
  address: address,
);

void main() {
  GuestExperienceProvider provider(
    FavoriteValues values,
    FavoriteCatalog catalog, {
    String scope = 'https://synthetic.test/api/v1',
  }) {
    final guest = GuestExperienceProvider(
      store: JsonGuestLocalStore(storage: values),
      repository: catalog,
      catalogScope: scope,
    );
    addTearDown(guest.dispose);
    return guest;
  }

  test(
    'adding twice is idempotent and toggle removes the identifier',
    () async {
      final guest = provider(FavoriteValues(), FavoriteCatalog());
      final saved = place();
      await Future.wait([guest.addFavorite(saved), guest.addFavorite(saved)]);
      expect(guest.favorites, hasLength(1));
      expect(guest.isFavorite(saved), true);
      await guest.toggleFavorite(saved);
      expect(guest.favorites, isEmpty);
      expect(guest.isFavorite(saved), false);
      await guest.toggleFavorite(saved);
      expect(guest.favorites, hasLength(1));
    },
  );

  test(
    'favorites survive provider recreation and individual removal',
    () async {
      final values = FavoriteValues();
      final catalog = FavoriteCatalog();
      final first = provider(values, catalog);
      await first.addFavorite(place());
      await first.addFavorite(place(id: 8, key: 'museum-two'));
      final second = provider(values, catalog);
      await second.initialize();
      expect(second.favorites, hasLength(2));
      await second.removeFavorite(second.favorites.first);
      final third = provider(values, catalog);
      await third.initialize();
      expect(third.favorites.single.catalogKey, 'museum-two');
      expect(catalog.requests, 0);
    },
  );

  test(
    'composition revision ignores preferences and no-op mutations',
    () async {
      final catalog = FavoriteCatalog()..places = [place()];
      final guest = provider(FavoriteValues(), catalog);
      await guest.initialize();
      final initial = guest.favoritesRevision;
      await guest.clearFavorites();
      await guest.removeFavorite(
        FavoriteReference.fromPlace(
          place(),
          FavoriteReference.scopeFor('https://synthetic.test/api/v1'),
        ),
      );
      await guest.setPreferUnusual(true);
      expect(guest.favoritesRevision, initial);

      await guest.addFavorite(place());
      final added = guest.favoritesRevision;
      expect(added, greaterThan(initial));
      await guest.addFavorite(place(id: 99, title: 'Новое название'));
      await guest.resolveFavorites();
      await guest.setCategories({PlaceCategoryEnum.art});
      expect(guest.favoritesRevision, added);

      await guest.toggleFavorite(place());
      final removed = guest.favoritesRevision;
      expect(removed, greaterThan(added));
      await guest.toggleFavorite(place());
      final readded = guest.favoritesRevision;
      expect(readded, greaterThan(removed));
      await guest.clearFavorites();
      expect(guest.favoritesRevision, greaterThan(readded));
    },
  );

  test(
    'remove and re-add same identity invalidates pending old card facts',
    () async {
      final values = FavoriteValues();
      final catalog = FavoriteCatalog()..delayed = true;
      final guest = provider(values, catalog);
      await guest.addFavorite(place());
      final savedReference = guest.favorites.single;
      final originalRevision = guest.favoritesRevision;
      final oldResolution = guest.resolveFavorites();
      await Future<void>.delayed(Duration.zero);

      await guest.removeFavorite(savedReference);
      await guest.addFavorite(place(address: 'Новые сведения'));
      final currentReference = guest.favorites.single;
      expect(identical(currentReference, savedReference), false);
      expect(currentReference.identity, savedReference.identity);
      expect(guest.favoritesRevision, greaterThan(originalRevision));
      catalog.pending.single.complete([place(address: 'Устаревшие сведения')]);
      final stale = await oldResolution;
      expect(stale.single.reference.identity, currentReference.identity);
      expect(stale.single.place, null);
      expect(
        stale.single.unavailableReason,
        FavoriteUnavailableReason.superseded,
      );

      catalog.delayed = false;
      final current = place(address: 'Новые сведения');
      catalog.places = [current];
      expect((await guest.resolveFavorites()).single.place, same(current));
      final restored = provider(values, catalog);
      await restored.initialize();
      expect(restored.favorites.single.identity, currentReference.identity);
      expect((await restored.resolveFavorites()).single.place, same(current));
    },
  );

  test(
    'pending card cannot be substituted after key changes with reused ID',
    () async {
      final catalog = FavoriteCatalog()..delayed = true;
      final guest = provider(FavoriteValues(), catalog);
      await guest.addFavorite(place());
      final oldReference = guest.favorites.single;
      final oldResolution = guest.resolveFavorites();
      await Future<void>.delayed(Duration.zero);
      await guest.removeFavorite(oldReference);
      final replacement = place(
        key: 'replacement-museum',
        title: 'Другой музей',
      );
      await guest.addFavorite(replacement);
      catalog.pending.single.complete([place()]);
      final stale = await oldResolution;
      expect(stale.single.reference.catalogKey, 'replacement-museum');
      expect(stale.single.place, null);
      expect(
        stale.single.unavailableReason,
        FavoriteUnavailableReason.superseded,
      );

      catalog.delayed = false;
      catalog.places = [place()];
      expect((await guest.resolveFavorites()).single.place, null);
      catalog.places = [replacement];
      expect((await guest.resolveFavorites()).single.place, same(replacement));
    },
  );

  test(
    'legacy migration changes observable revision before persistence completes',
    () async {
      final scope = FavoriteReference.scopeFor('https://synthetic.test/api/v1');
      final legacy = FavoriteReference.fromPlace(place(key: null), scope);
      final gate = Completer<void>();
      final values = FavoriteValues()
        ..value = GuestLocalSnapshot(favorites: [legacy]).encode()
        ..blockedWrite = gate;
      final catalog = FavoriteCatalog()..places = [place()];
      final guest = provider(values, catalog);
      await guest.initialize();
      final initialRevision = guest.favoritesRevision;
      final observedIdentities = <String>[];
      guest.addListener(() {
        if (guest.favoritesRevision != initialRevision) {
          observedIdentities.add(guest.favorites.single.identity);
        }
      });
      final resolving = guest.resolveFavorites();
      await Future<void>.delayed(Duration.zero);
      expect(guest.favorites.single.identity, 'catalog:museum-one');
      expect(guest.favoritesRevision, greaterThan(initialRevision));
      expect(observedIdentities, contains('catalog:museum-one'));
      expect(
        GuestLocalSnapshot.decode(values.value!).favorites.single.identity,
        legacy.identity,
      );

      gate.complete();
      final result = await resolving;
      expect(result.single.reference.identity, guest.favorites.single.identity);
      expect(result.single.place, isNotNull);
      final migratedRevision = guest.favoritesRevision;
      await guest.resolveFavorites();
      expect(guest.favoritesRevision, migratedRevision);
      final restored = provider(values, catalog);
      await restored.initialize();
      expect(restored.favorites.single.identity, 'catalog:museum-one');
      expect((await restored.resolveFavorites()).single.place, isNotNull);
    },
  );

  test(
    'older-backend consolidation changes revision only for identity migration',
    () async {
      final scope = FavoriteReference.scopeFor('https://synthetic.test/api/v1');
      final values = FavoriteValues()
        ..value = GuestLocalSnapshot(
          favorites: [
            FavoriteReference.fromPlace(place(key: null), scope),
            FavoriteReference.fromPlace(place(), scope),
          ],
        ).encode();
      final catalog = FavoriteCatalog()..places = [place(key: null)];
      final guest = provider(values, catalog);
      await guest.initialize();
      final before = guest.favoritesRevision;
      final result = await guest.resolveFavorites();
      expect(guest.favoritesRevision, greaterThan(before));
      expect(result.single.reference.identity, 'catalog:museum-one');
      expect(result.single.place, isNotNull);
      final settled = guest.favoritesRevision;
      await guest.resolveFavorites();
      expect(guest.favoritesRevision, settled);
      expect(GuestLocalSnapshot.decode(values.value!).favorites, hasLength(1));
    },
  );

  test('empty favorites resolve without requesting a catalog', () async {
    final catalog = FavoriteCatalog();
    expect(
      await provider(FavoriteValues(), catalog).resolveFavorites(),
      isEmpty,
    );
    expect(catalog.requests, 0);
  });

  test('resolution is explicit, unfiltered and returns current card', () async {
    final catalog = FavoriteCatalog();
    final guest = provider(FavoriteValues(), catalog);
    await guest.addFavorite(place(address: 'Старый адрес'));
    await guest.setCategories({PlaceCategoryEnum.nature});
    await guest.setPreferUnusual(true);
    expect(catalog.requests, 0);
    final current = place(
      id: 90,
      title: 'Новое название',
      address: 'Новый адрес',
    );
    catalog.places = [current];
    final result = await guest.resolveFavorites();
    expect(result.single.place, same(current));
    expect(result.single.reference.label, 'Музей');
    expect(catalog.requests, 1);
    expect(catalog.receivedFilters, false);
  });

  test(
    'network failure exposes unavailable rows and retains durable identifiers',
    () async {
      final values = FavoriteValues();
      final catalog = FavoriteCatalog()..failure = StateError('offline');
      final guest = provider(values, catalog);
      await guest.addFavorite(place());
      final saved = values.value;
      final result = await guest.resolveFavorites();
      expect(result.single.place, null);
      expect(
        result.single.unavailableReason,
        FavoriteUnavailableReason.catalogUnavailable,
      );
      expect(guest.favorites, hasLength(1));
      expect(values.value, saved);
      catalog.failure = null;
      catalog.places = [place()];
      expect((await guest.resolveFavorites()).single.place, isNotNull);
    },
  );

  test(
    'deleted stable key cannot resolve against a reused numerical ID',
    () async {
      final catalog = FavoriteCatalog()
        ..places = [place(key: 'different-place')];
      final guest = provider(FavoriteValues(), catalog);
      await guest.addFavorite(place());
      expect((await guest.resolveFavorites()).single.place, null);
      expect(guest.favorites, hasLength(1));
      expect(guest.isFavorite(catalog.places.single), false);
    },
  );

  test('ambiguous duplicate stable keys are unavailable', () async {
    final catalog = FavoriteCatalog()..places = [place(), place(id: 8)];
    final guest = provider(FavoriteValues(), catalog);
    await guest.addFavorite(place());
    expect((await guest.resolveFavorites()).single.place, null);
    expect(guest.favorites, hasLength(1));
  });

  test(
    'legacy backend resolves exact fallback without a catalog key',
    () async {
      final legacy = place(key: null);
      final catalog = FavoriteCatalog()..places = [legacy];
      final guest = provider(FavoriteValues(), catalog);
      await guest.addFavorite(legacy);
      expect(guest.favorites.single.catalogKey, null);
      expect((await guest.resolveFavorites()).single.place, same(legacy));
    },
  );

  final identityChanges = <String, PlaceModel>{
    'title': place(key: null, title: 'Другое место'),
    'category': place(key: null, category: PlaceCategoryEnum.nature),
    'latitude': place(key: null, latitude: 59.94),
    'longitude': place(key: null, longitude: 30.32),
    'id': place(key: null, id: 8),
  };
  for (final entry in identityChanges.entries) {
    test(
      'legacy ${entry.key} change never substitutes another place',
      () async {
        final catalog = FavoriteCatalog()..places = [entry.value];
        final guest = provider(FavoriteValues(), catalog);
        await guest.addFavorite(place(key: null));
        expect((await guest.resolveFavorites()).single.place, null);
        expect(guest.isFavorite(entry.value), false);
        expect(guest.favorites, hasLength(1));
      },
    );
  }

  test(
    'legacy backend scope prevents matching identical IDs on another server',
    () async {
      final values = FavoriteValues();
      final catalog = FavoriteCatalog()..places = [place(key: null)];
      await provider(values, catalog).addFavorite(place(key: null));
      final other = provider(
        values,
        catalog,
        scope: 'https://other.test/api/v1',
      );
      expect((await other.resolveFavorites()).single.place, null);
    },
  );

  test(
    'legacy address changes use fresh facts without expanding identity hash',
    () async {
      final current = place(key: null, address: 'Новый адрес');
      final catalog = FavoriteCatalog()..places = [current];
      final guest = provider(FavoriteValues(), catalog);
      await guest.addFavorite(place(key: null, address: 'Старый адрес'));
      expect((await guest.resolveFavorites()).single.place, same(current));
    },
  );

  test('fallback upgrades to stable key only after unique exact identity resolution', () async {
    final values = FavoriteValues();
    final catalog = FavoriteCatalog()..places = [place()];
    final guest = provider(values, catalog);
    await guest.addFavorite(place(key: null));
    final result = await guest.resolveFavorites();
    expect(result.single.place, isNotNull);
    expect(guest.favorites.single.catalogKey, 'museum-one');
    final recreated = provider(values, catalog);
    await recreated.initialize();
    expect(recreated.favorites.single.catalogKey, 'museum-one');
  });

  test(
    'changed fallback cannot silently upgrade to a new stable identity',
    () async {
      final catalog = FavoriteCatalog()
        ..places = [place(title: 'Другое место')];
      final guest = provider(FavoriteValues(), catalog);
      await guest.addFavorite(place(key: null));
      expect((await guest.resolveFavorites()).single.place, null);
      expect(guest.favorites.single.catalogKey, null);
    },
  );

  test(
    'new key becoming unavailable on older backend requires protected fallback',
    () async {
      final catalog = FavoriteCatalog()..places = [place(key: null)];
      final guest = provider(FavoriteValues(), catalog);
      await guest.addFavorite(place());
      expect((await guest.resolveFavorites()).single.place, isNotNull);
      catalog.places = [place(key: null, title: 'Другое место')];
      expect((await guest.resolveFavorites()).single.place, null);
      expect(guest.favorites.single.catalogKey, 'museum-one');
    },
  );

  test(
    'keyed and fallback duplicate migration is conservative and durable',
    () async {
      final scope = FavoriteReference.scopeFor('https://synthetic.test/api/v1');
      final keyed = FavoriteReference.fromPlace(place(), scope);
      final fallback = FavoriteReference.fromPlace(place(key: null), scope);
      final values = FavoriteValues()
        ..value = GuestLocalSnapshot(favorites: [fallback, keyed]).encode();
      final catalog = FavoriteCatalog()..places = [place()];
      final guest = provider(values, catalog);
      final result = await guest.resolveFavorites();
      expect(result, hasLength(1));
      expect(guest.favorites, hasLength(1));
      expect(jsonDecode(values.value!)['favorites'], hasLength(1));
    },
  );

  test(
    'late catalog cannot resurrect a favorite removed while loading',
    () async {
      final catalog = FavoriteCatalog()..delayed = true;
      final guest = provider(FavoriteValues(), catalog);
      await guest.addFavorite(place());
      final loading = guest.resolveFavorites();
      await Future<void>.delayed(Duration.zero);
      await guest.removeFavorite(guest.favorites.single);
      catalog.pending.single.complete([place()]);
      expect(await loading, isEmpty);
      expect(guest.favorites, isEmpty);
    },
  );

  test(
    'older concurrent catalog completion exposes no stale place facts',
    () async {
      final catalog = FavoriteCatalog()..delayed = true;
      final guest = provider(FavoriteValues(), catalog);
      await guest.addFavorite(place());
      final old = guest.resolveFavorites();
      await Future<void>.delayed(Duration.zero);
      final current = guest.resolveFavorites();
      await Future<void>.delayed(Duration.zero);
      catalog.pending[1].complete([]);
      expect((await current).single.place, null);
      catalog.pending[0].complete([place()]);
      final stale = await old;
      expect(stale.single.place, null);
      expect(
        stale.single.unavailableReason,
        FavoriteUnavailableReason.superseded,
      );
    },
  );

  test(
    'mixed keyed and fallback duplicates consolidate on an older backend',
    () async {
      final scope = FavoriteReference.scopeFor('https://synthetic.test/api/v1');
      final values = FavoriteValues()
        ..value = GuestLocalSnapshot(
          favorites: [
            FavoriteReference.fromPlace(place(key: null), scope),
            FavoriteReference.fromPlace(place(), scope),
          ],
        ).encode();
      final catalog = FavoriteCatalog()..places = [place(key: null)];
      final guest = provider(values, catalog);
      final result = await guest.resolveFavorites();
      expect(result, hasLength(1));
      expect(result.single.place, isNotNull);
      expect(guest.favorites.single.catalogKey, 'museum-one');
      expect(jsonDecode(values.value!)['favorites'], hasLength(1));
    },
  );

  test(
    'conflicting stable references never share an unkeyed current card',
    () async {
      final scope = FavoriteReference.scopeFor('https://synthetic.test/api/v1');
      final values = FavoriteValues()
        ..value = GuestLocalSnapshot(
          favorites: [
            FavoriteReference.fromPlace(place(), scope),
            FavoriteReference.fromPlace(place(key: 'different-museum'), scope),
          ],
        ).encode();
      final raw = values.value;
      final catalog = FavoriteCatalog()..places = [place(key: null)];
      final guest = provider(values, catalog);
      final result = await guest.resolveFavorites();
      expect(result, hasLength(2));
      expect(result.every((entry) => entry.place == null), true);
      expect(guest.favorites, hasLength(2));
      expect(values.value, raw);
    },
  );

  test('clear favorites preserves onboarding and all preferences', () async {
    final values = FavoriteValues();
    final catalog = FavoriteCatalog();
    final guest = provider(values, catalog);
    await guest.completeOnboarding();
    await guest.setPreferUnusual(true);
    await guest.addFavorite(place());
    await guest.clearFavorites();
    final recreated = provider(values, catalog);
    await recreated.initialize();
    expect(recreated.favorites, isEmpty);
    expect(recreated.onboardingCompleted, true);
    expect(recreated.preferUnusual, true);
  });
}
