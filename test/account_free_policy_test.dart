import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/context_recommendation_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/ui/screens/guest_onboarding_screen.dart';
import 'package:smart_navigator_spb/ui/screens/guest_settings_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/guest_launch_gate.dart';

const _place = PlaceModel(
  id: 1,
  catalogKey: 'test-garden',
  title: 'Сад',
  shortDescription: 'Актуальное описание сада',
  category: PlaceCategoryEnum.nature,
  latitude: 59.94,
  longitude: 30.31,
  address: 'Актуальный адрес',
);

const _scope = 'https://catalog.example/api/v1';

/// The C8.1/C10 schema must remain readable byte-for-byte: no C10.1 migration,
/// no new fields and no account identity in local storage.
const _previousReleaseEnvelope =
    '{"version":1,"onboardingCompleted":true,"preferences":'
    '{"categories":["art"],"preferUnusual":true,"showRecommendations":false,'
    '"recommendationPreference":"shade"},"favorites":[{"catalogKey":'
    '"test-garden","scope":'
    '"ed48162b1fab7cd8f5a923273a67e1c9fee4e9a8dc7c5700e608955d1e28d238",'
    '"id":1,"fingerprint":'
    '"3547a90118f561fa373ceb9ab3c584c91f2ca497fdfe2194af1714b9af3c0efa",'
    '"label":"Сад"}]}';

class _MemoryStorage implements GuestKeyValueStore {
  String? value;
  int writes = 0;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String value) async {
    writes++;
    this.value = value;
  }
}

class _NoRequestRepository extends PlacesRepository {
  int calls = 0;

  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async {
    calls++;
    return const [];
  }
}

GuestExperienceProvider _guest(
  _MemoryStorage storage,
  _NoRequestRepository repository,
) {
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: storage),
    repository: repository,
    catalogScope: _scope,
  );
  addTearDown(guest.dispose);
  return guest;
}

Future<void> _mount(
  WidgetTester tester,
  GuestExperienceProvider guest,
  Widget home,
) => tester.pumpWidget(
  ChangeNotifierProvider<GuestExperienceProvider>.value(
    value: guest,
    child: MaterialApp(theme: AppTheme.lightTheme, home: home),
  ),
);

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: scrollable,
      maxScrolls: 30,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('first launch explains account-free use without auth actions', (
    tester,
  ) async {
    final repository = _NoRequestRepository();
    final guest = _guest(_MemoryStorage(), repository);
    await guest.initialize();
    await _mount(
      tester,
      guest,
      GuestLaunchGate(homeBuilder: (_) => const Text('Карта без аккаунта')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(GuestOnboardingScreen), findsOneWidget);
    expect(find.text('Санкт-Петербург открыт каждому!'), findsOneWidget);
    expect(
      find.textContaining('без регистрации и создания аккаунта'),
      findsOneWidget,
    );
    expect(
      find.textContaining('сохраняются на вашем устройстве'),
      findsOneWidget,
    );
    await _reveal(tester, find.text('Подобрать прогулку'));
    expect(find.text('Подобрать прогулку'), findsOneWidget);
    expect(find.text('Перейти к карте'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    for (final authAction in [
      'Войти',
      'Вход',
      'Зарегистрироваться',
      'Создать аккаунт',
      'Профиль',
    ]) {
      expect(find.text(authAction), findsNothing, reason: authAction);
    }

    await _tapVisible(tester, 'Подобрать прогулку');
    expect(find.text('Карта без аккаунта'), findsOneWidget);
    expect(find.byType(GuestOnboardingScreen), findsNothing);
    expect(guest.onboardingCompleted, isTrue);
    expect(repository.calls, 0);
  });

  testWidgets('settings explain local storage and network boundaries', (
    tester,
  ) async {
    final repository = _NoRequestRepository();
    final guest = _guest(_MemoryStorage(), repository);
    await guest.initialize();
    await guest.completeOnboarding();
    await _mount(tester, guest, const GuestSettingsScreen());

    expect(find.text('Ваши настройки'), findsOneWidget);
    expect(find.text('Гостевой режим'), findsNothing);
    expect(find.textContaining('работает без аккаунтов'), findsOneWidget);
    expect(
      find.textContaining('не синхронизируются автоматически'),
      findsOneWidget,
    );
    expect(
      find.textContaining('могут быть потеряны при очистке данных'),
      findsOneWidget,
    );
    expect(
      find.textContaining('могут требовать сетевых обращений'),
      findsOneWidget,
    );
    for (final authAction in [
      'Войти',
      'Вход',
      'Зарегистрироваться',
      'Создать аккаунт',
      'Профиль',
    ]) {
      expect(find.text(authAction), findsNothing, reason: authAction);
    }
    expect(repository.calls, 0);
  });

  test('favorites and preferences persist without account data', () async {
    final storage = _MemoryStorage();
    final repository = _NoRequestRepository();
    final first = _guest(storage, repository);
    await first.initialize();
    await first.completeOnboarding();
    await first.addFavorite(_place);
    await first.setCategories({PlaceCategoryEnum.nature});
    await first.setPreferUnusual(true);
    await first.setShowRecommendations(false);
    await first.setRecommendationPreference(RecommendationPreference.shade);

    final raw = storage.value!;
    expect(raw, isNot(contains('account')));
    expect(raw, isNot(contains('token')));
    expect(raw, isNot(contains('email')));
    expect(raw, isNot(contains('password')));
    expect(raw, isNot(contains('@')));

    final restored = _guest(storage, repository);
    await restored.initialize();
    expect(restored.onboardingCompleted, isTrue);
    expect(restored.favorites, hasLength(1));
    expect(restored.isFavorite(_place), isTrue);
    expect(restored.categories, {PlaceCategoryEnum.nature});
    expect(restored.preferUnusual, isTrue);
    expect(restored.showRecommendations, isFalse);
    expect(restored.recommendationPreference, RecommendationPreference.shade);
    expect(repository.calls, 0);
  });

  test(
    'previous-release local data is read without migration or rewrite',
    () async {
      final storage = _MemoryStorage()..value = _previousReleaseEnvelope;
      final repository = _NoRequestRepository();
      final guest = _guest(storage, repository);
      await guest.initialize();

      expect(guest.storageError, isNull);
      expect(guest.onboardingCompleted, isTrue);
      expect(guest.categories, {PlaceCategoryEnum.art});
      expect(guest.preferUnusual, isTrue);
      expect(guest.showRecommendations, isFalse);
      expect(guest.recommendationPreference, RecommendationPreference.shade);
      expect(guest.favorites, hasLength(1));
      expect(guest.isFavorite(_place), isTrue);
      expect(storage.writes, 0);
      expect(storage.value, _previousReleaseEnvelope);
      expect(repository.calls, 0);
    },
  );
}
