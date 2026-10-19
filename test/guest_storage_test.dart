import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';

class MemoryGuestValues implements GuestKeyValueStore {
  String? value;
  int reads = 0;
  int writes = 0;
  bool failRead = false;
  bool failWrite = false;
  Completer<void>? firstWrite;

  @override
  Future<String?> read(String key) async {
    ++reads;
    if (failRead) throw StateError('synthetic disk read');
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    ++writes;
    if (writes == 1) await firstWrite?.future;
    if (failWrite) throw StateError('synthetic disk write');
    this.value = value;
  }
}

class NoRequestRepository extends PlacesRepository {
  int catalogRequests = 0;
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async {
    ++catalogRequests;
    throw StateError('Unexpected automatic catalog request');
  }
}

const savedPlace = PlaceModel(
  id: 16,
  catalogKey: 'test-museum',
  title: 'Сохранённый музей',
  shortDescription: 'Не сохранять эту карточку',
  category: PlaceCategoryEnum.art,
  latitude: 59.93901,
  longitude: 30.31523,
  address: 'Не сохранять этот адрес',
  workingHours: 'Не сохранять часы',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  GuestExperienceProvider provider(
    MemoryGuestValues values, {
    NoRequestRepository? repository,
  }) {
    final instance = GuestExperienceProvider(
      store: JsonGuestLocalStore(storage: values),
      repository: repository ?? NoRequestRepository(),
      catalogScope: 'https://synthetic.test/api/v1',
    );
    addTearDown(instance.dispose);
    return instance;
  }

  test(
    'construction is lazy and first local load uses safe defaults',
    () async {
      final values = MemoryGuestValues();
      final store = JsonGuestLocalStore(storage: values);
      final repository = NoRequestRepository();
      final guest = GuestExperienceProvider(
        store: store,
        repository: repository,
        catalogScope: 'https://synthetic.test/api/v1',
      );
      addTearDown(guest.dispose);
      expect(values.reads, 0);
      expect(guest.ready, false);
      await Future.wait([guest.initialize(), guest.initialize()]);
      expect(values.reads, 1);
      expect(values.writes, 0);
      expect(guest.ready, true);
      expect(guest.onboardingCompleted, false);
      expect(guest.categories, isEmpty);
      expect(guest.preferUnusual, false);
      expect(guest.showRecommendations, true);
      expect(guest.recommendationPreference, RecommendationPreference.all);
      expect(repository.catalogRequests, 0);
    },
  );

  for (final action in ['completion', 'skip']) {
    test('onboarding $action persists across provider recreation', () async {
      final values = MemoryGuestValues();
      final first = provider(values);
      await first.completeOnboarding();
      final recreated = provider(values);
      await recreated.initialize();
      expect(recreated.onboardingCompleted, true);
      expect(recreated.storageError, null);
    });
  }

  test(
    'all voluntary preferences persist without automatic catalog work',
    () async {
      final values = MemoryGuestValues();
      final repository = NoRequestRepository();
      final first = provider(values, repository: repository);
      await first.setCategories({
        PlaceCategoryEnum.art,
        PlaceCategoryEnum.nature,
      });
      await first.setPreferUnusual(true);
      await first.setShowRecommendations(false);
      await first.setRecommendationPreference(RecommendationPreference.scenic);
      final recreated = provider(values, repository: repository);
      await recreated.initialize();
      expect(recreated.categories, {
        PlaceCategoryEnum.art,
        PlaceCategoryEnum.nature,
      });
      expect(recreated.preferUnusual, true);
      expect(recreated.showRecommendations, false);
      expect(
        recreated.recommendationPreference,
        RecommendationPreference.scenic,
      );
      expect(repository.catalogRequests, 0);
    },
  );

  test('re-enabling recommendations survives another restart', () async {
    final values = MemoryGuestValues();
    await provider(values).setShowRecommendations(false);
    final second = provider(values);
    await second.initialize();
    expect(second.showRecommendations, false);
    await second.setShowRecommendations(true);
    final third = provider(values);
    await third.initialize();
    expect(third.showRecommendations, true);
  });

  test(
    'reset preferences preserves onboarding and favorite identifiers',
    () async {
      final values = MemoryGuestValues();
      final first = provider(values);
      await first.completeOnboarding();
      await first.addFavorite(savedPlace);
      await first.setCatalogPreferences(
        categories: {PlaceCategoryEnum.art},
        preferUnusual: true,
      );
      await first.setShowRecommendations(false);
      await first.setRecommendationPreference(RecommendationPreference.shade);
      await first.resetPreferences();
      final recreated = provider(values);
      await recreated.initialize();
      expect(recreated.onboardingCompleted, true);
      expect(recreated.favorites, hasLength(1));
      expect(recreated.isFavorite(savedPlace), true);
      expect(recreated.categories, isEmpty);
      expect(recreated.preferUnusual, false);
      expect(recreated.showRecommendations, true);
      expect(recreated.recommendationPreference, RecommendationPreference.all);
    },
  );

  test('single envelope serializes independent concurrent writes', () async {
    final values = MemoryGuestValues()..firstWrite = Completer<void>();
    final store = JsonGuestLocalStore(storage: values);
    final reference = FavoriteReference.fromPlace(
      savedPlace,
      FavoriteReference.scopeFor('https://synthetic.test/api/v1'),
    );
    final writes = [
      store.savePreferences(GuestPreferences(preferUnusual: true)),
      store.saveOnboardingCompleted(true),
      store.saveFavorites([reference]),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(values.writes, 1);
    values.firstWrite!.complete();
    await Future.wait(writes);
    final reloaded = await JsonGuestLocalStore(storage: values).load();
    expect(values.writes, 3);
    expect(reloaded.onboardingCompleted, true);
    expect(reloaded.preferences.preferUnusual, true);
    expect(reloaded.favorites.single.catalogKey, 'test-museum');
  });

  test(
    'queued writes snapshot mutable input and deduplicate identifiers',
    () async {
      final values = MemoryGuestValues()..firstWrite = Completer<void>();
      final store = JsonGuestLocalStore(storage: values);
      final reference = FavoriteReference.fromPlace(
        savedPlace,
        FavoriteReference.scopeFor('scope'),
      );
      final first = store.saveOnboardingCompleted(true);
      final references = [reference, reference];
      final second = store.saveFavorites(references);
      references.clear();
      values.firstWrite!.complete();
      await Future.wait([first, second]);
      expect((await store.loadFavorites()), hasLength(1));
    },
  );

  test(
    'failed writes do not poison queue and next write recovers session data',
    () async {
      final values = MemoryGuestValues()..failWrite = true;
      final store = JsonGuestLocalStore(storage: values);
      await expectLater(
        store.savePreferences(GuestPreferences(preferUnusual: true)),
        throwsA(isA<GuestStorageException>()),
      );
      expect(values.value, null);
      expect(store.error, isNotNull);
      values.failWrite = false;
      await store.saveOnboardingCompleted(true);
      final reloaded = await JsonGuestLocalStore(storage: values).load();
      expect(reloaded.preferences.preferUnusual, true);
      expect(reloaded.onboardingCompleted, true);
      expect(store.error, null);
    },
  );

  test('provider stays usable and exposes a local write failure', () async {
    final values = MemoryGuestValues()..failWrite = true;
    final guest = provider(values);
    await guest.completeOnboarding();
    await guest.setCategories({PlaceCategoryEnum.nature});
    expect(guest.ready, true);
    expect(guest.onboardingCompleted, true);
    expect(guest.categories, {PlaceCategoryEnum.nature});
    expect(guest.storageError, contains('Не удалось сохранить'));
    values.failWrite = false;
    await guest.setShowRecommendations(false);
    expect(guest.storageError, null);
    final recreated = provider(values);
    await recreated.initialize();
    expect(recreated.categories, {PlaceCategoryEnum.nature});
    expect(recreated.onboardingCompleted, true);
  });

  test(
    'read failure provides usable defaults and cannot overwrite unseen data',
    () async {
      final original = GuestLocalSnapshot(onboardingCompleted: true).encode();
      final values = MemoryGuestValues()
        ..value = original
        ..failRead = true;
      final guest = provider(values);
      await guest.initialize();
      await guest.setShowRecommendations(false);
      expect(guest.ready, true);
      expect(guest.showRecommendations, false);
      expect(guest.storageError, isNotNull);
      expect(values.value, original);
      expect(values.writes, 0);
    },
  );

  final malformed = <String, Object?>{
    'non-object': [],
    'future-version': {'version': 2},
    'floating-version': {'version': 1.0},
    'onboarding-number': {'onboardingCompleted': 1},
    'extra-envelope-field': {'unexpected': true},
    'categories-not-list': {'preferences.categories': 'art'},
    'unknown-category': {
      'preferences.categories': ['private_category'],
    },
    'duplicate-category': {
      'preferences.categories': ['art', 'art'],
    },
    'unusual-string': {'preferences.preferUnusual': 'true'},
    'recommendations-number': {'preferences.showRecommendations': 0},
    'unknown-preference': {'preferences.recommendationPreference': 'safety'},
    'favorites-not-list': {'favorites': {}},
    'invalid-favorite': {
      'favorites': [
        {'id': 1},
      ],
    },
  };
  for (final entry in malformed.entries) {
    test(
      '${entry.key}: defaults are safe and original raw data is retained',
      () async {
        dynamic json = jsonDecode(GuestLocalSnapshot().encode());
        final patch = entry.value;
        if (patch is Map) {
          for (final item in patch.entries) {
            final key = item.key as String;
            if (key.startsWith('preferences.')) {
              json['preferences'][key.substring('preferences.'.length)] =
                  item.value;
            } else {
              json[key] = item.value;
            }
          }
        } else {
          json = patch;
        }
        final raw = jsonEncode(json);
        final values = MemoryGuestValues()..value = raw;
        final guest = provider(values);
        await guest.initialize();
        expect(guest.ready, true);
        expect(guest.onboardingCompleted, false);
        expect(guest.favorites, isEmpty);
        expect(guest.categories, isEmpty);
        expect(guest.storageError, isNotNull);
        await guest.completeOnboarding();
        expect(values.value, raw);
        expect(values.writes, 0);
      },
    );
  }

  for (final field in ['catalogKey', 'scope', 'fingerprint']) {
    test(
      'favorite $field rejects trailing newline and protects raw envelope',
      () async {
        final reference = FavoriteReference.fromPlace(
          savedPlace,
          FavoriteReference.scopeFor('https://synthetic.test/api/v1'),
        );
        final json = jsonDecode(
          GuestLocalSnapshot(favorites: [reference]).encode(),
        ) as Map<String, dynamic>;
        final favorite = json['favorites'].single as Map<String, dynamic>;
        favorite[field] = '${favorite[field]}\n';
        final raw = jsonEncode(json);
        final values = MemoryGuestValues()..value = raw;
        final guest = provider(values);
        await guest.initialize();
        expect(guest.favorites, isEmpty);
        expect(guest.storageError, isNotNull);
        await guest.completeOnboarding();
        expect(values.value, raw);
        expect(values.writes, 0);
      },
    );
  }

  test('invalid place identity cannot crash favorite action', () async {
    final values = MemoryGuestValues();
    final guest = provider(values);
    const invalid = PlaceModel(
      id: 0,
      title: 'Повреждённое место',
      shortDescription: '',
      category: PlaceCategoryEnum.art,
      latitude: double.nan,
      longitude: 30,
      address: '',
    );
    await guest.addFavorite(invalid);
    expect(guest.favorites, isEmpty);
    expect(guest.storageError, isNotNull);
    expect(values.writes, 0);
  });

  test('truncated JSON and oversized envelopes never crash startup', () async {
    for (final raw in ['{"version":', 'x' * (512 * 1024 + 1)]) {
      final values = MemoryGuestValues()..value = raw;
      final guest = provider(values);
      await guest.initialize();
      expect(guest.ready, true);
      expect(guest.storageError, isNotNull);
      expect(values.value, raw);
    }
  });

  test(
    'storage contains digests and identifier label rather than place facts',
    () async {
      final values = MemoryGuestValues();
      await provider(values).addFavorite(savedPlace);
      final raw = values.value!;
      expect(raw, contains(savedPlace.title));
      for (final sensitive in [
        savedPlace.address,
        savedPlace.shortDescription,
        savedPlace.workingHours!,
        savedPlace.latitude.toString(),
        savedPlace.longitude.toString(),
        'https://synthetic.test',
      ]) {
        expect(raw, isNot(contains(sensitive)));
      }
      expect(jsonDecode(raw)['favorites'].single['fingerprint'], hasLength(64));
    },
  );

  test('scope digest excludes URL credentials and query secrets', () {
    expect(
      FavoriteReference.scopeFor(
        'https://user:secret@synthetic.test/api/v1/?key=secret#x',
      ),
      FavoriteReference.scopeFor('https://synthetic.test/api/v1'),
    );
    expect(
      FavoriteReference.scopeFor('https://synthetic.test/api/v1'),
      isNot(FavoriteReference.scopeFor('https://other.test/api/v1')),
    );
  });

  test(
    'production shared preferences implementation roundtrips one envelope',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = SharedPreferencesGuestLocalStore();
      await store.saveOnboardingCompleted(true);
      await store.savePreferences(GuestPreferences(preferUnusual: true));
      final snapshot = await SharedPreferencesGuestLocalStore().load();
      expect(snapshot.onboardingCompleted, true);
      expect(snapshot.preferences.preferUnusual, true);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys(), {JsonGuestLocalStore.storageKey});
    },
  );
}
