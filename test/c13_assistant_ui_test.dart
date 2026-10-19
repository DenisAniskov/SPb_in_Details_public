import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/local/guest_local_store.dart';
import 'package:smart_navigator_spb/data/models/assistant_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/suggest_item_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/data/repositories/search_repository.dart';
import 'package:smart_navigator_spb/providers/assistant_provider.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_consent_store.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_service.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';
import 'package:smart_navigator_spb/ui/widgets/assistant_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/place_preview_card.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';

import 'assistant_test_support.dart';

const _isaac = PlaceModel(
  id: 1,
  catalogKey: 'saint-isaacs-cathedral',
  title: 'Исаакиевский собор',
  shortDescription: 'Собор в центре Петербурга.',
  fullDescription: 'Один из главных соборов Санкт-Петербурга.',
  category: PlaceCategoryEnum.historyArchitecture,
  latitude: 59.934,
  longitude: 30.306,
  address: 'Исаакиевская площадь, 4',
  recommendedVisitMinutes: 45,
);

const _kazan = PlaceModel(
  id: 2,
  catalogKey: 'kazan-cathedral',
  title: 'Казанский собор',
  shortDescription: 'Собор на Невском проспекте.',
  fullDescription: 'Один из главных соборов Санкт-Петербурга.',
  category: PlaceCategoryEnum.historyArchitecture,
  latitude: 59.934,
  longitude: 30.324,
  address: 'Казанская площадь, 2',
  recommendedVisitMinutes: 40,
);

AssistantReply _defaultReply() => const AssistantReply(
  status: 'ok',
  answer: 'В каталоге есть Исаакиевский собор. Хотите открыть умную прогулку?',
  model: 'nvidia/nemotron-3-super-120b-a12b:free',
  places: [
    AssistantPlaceReference(
      id: 1,
      catalogKey: 'saint-isaacs-cathedral',
      title: 'Исаакиевский собор',
      category: PlaceCategoryEnum.historyArchitecture,
      isUnusual: false,
      shortDescription: 'Собор в центре Петербурга.',
    ),
  ],
  actions: [
    AssistantAction(type: 'open_smart_walk', label: 'Открыть умную прогулку'),
  ],
  warnings: ['Проверяйте важные факты.'],
  usage: AssistantUsage(costUsd: 0, costVerified: true),
);

class _MemoryStorage implements GuestKeyValueStore {
  String? value;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String value) async {
    this.value = value;
  }
}

class _Catalog extends PlacesRepository {
  _Catalog(this.catalog);

  final List<PlaceModel> catalog;

  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async => catalog;

  @override
  Future<List<CategoryModel>> getCategories() async => const [];

  @override
  Future<PlaceModel?> getPlaceDetail(int placeId) async {
    for (final place in catalog) {
      if (place.id == placeId) return place;
    }
    return null;
  }
}

class _SearchRepository extends SearchRepository {
  @override
  Future<List<SuggestItemModel>> getSuggestions(
    String query, {
    int limit = 7,
  }) async => const [];
}

class _Sent {
  _Sent(this.message, this.history, this.placeId);

  final String message;
  final List<AssistantHistoryTurn> history;
  final int? placeId;
}

class _FakeAssistant implements AssistantService {
  final List<_Sent> calls = [];
  Completer<AssistantReply>? pending;
  AssistantReply? reply;
  AssistantServiceException? error;

  @override
  Future<AssistantReply> send({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
    CancelToken? cancelToken,
  }) {
    calls.add(_Sent(message, history, placeId));
    if (pending != null) return pending!.future;
    if (error != null) return Future.error(error!);
    return Future.value(reply ?? _defaultReply());
  }
}

class _Host {
  _Host(this.assistant, this.service, this.places, this.routing);

  final AssistantProvider assistant;
  final _FakeAssistant service;
  final PlacesProvider places;
  final RoutingProvider routing;
}

class _PlaceHost {
  _PlaceHost(this.assistant, this.service);

  final AssistantProvider assistant;
  final _FakeAssistant service;
}

Future<_Host> _mountMap(
  WidgetTester tester, {
  Size size = const Size(360, 640),
  bool dark = false,
  double textScale = 1,
  _FakeAssistant? service,
  MemoryAssistantConsentStore? consentStore,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  MapKitService.isMapKitInitialized = false;

  final repository = _Catalog(const [_isaac]);
  final guest = GuestExperienceProvider(
    store: JsonGuestLocalStore(storage: _MemoryStorage()),
    repository: repository,
    catalogScope: 'https://catalog.example/api/v1',
  );
  addTearDown(guest.dispose);
  await guest.initialize();
  await guest.completeOnboarding();
  final places = PlacesProvider(repository: repository, guest: guest);
  final search = SearchProvider(repository: _SearchRepository());
  final routing = RoutingProvider();
  final fake = service ?? _FakeAssistant();
  final assistant = AssistantProvider(
    assistantService: fake,
    consentStore: consentStore ?? MemoryAssistantConsentStore(),
  );
  addTearDown(places.dispose);
  addTearDown(search.dispose);
  addTearDown(routing.dispose);
  addTearDown(assistant.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<PlacesRepository>.value(value: repository),
        ChangeNotifierProvider<GuestExperienceProvider>.value(value: guest),
        ChangeNotifierProvider<PlacesProvider>.value(value: places),
        ChangeNotifierProvider<SearchProvider>.value(value: search),
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
        ChangeNotifierProvider<AssistantProvider>.value(value: assistant),
      ],
      child: MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const MainMapScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Host(assistant, fake, places, routing);
}

Future<_PlaceHost> _mountPlaceDetail(
  WidgetTester tester, {
  List<PlaceModel> catalog = const [_isaac],
  MemoryAssistantConsentStore? consentStore,
  _FakeAssistant? service,
}) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = _Catalog(catalog);
  final routing = RoutingProvider();
  final fake = service ?? _FakeAssistant();
  final assistant = AssistantProvider(
    assistantService: fake,
    consentStore: consentStore ?? MemoryAssistantConsentStore(),
  );
  addTearDown(routing.dispose);
  addTearDown(assistant.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<PlacesRepository>.value(value: repository),
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
        ChangeNotifierProvider<AssistantProvider>.value(value: assistant),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: PlaceDetailScreen(place: catalog.first),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _PlaceHost(assistant, fake);
}

Future<void> _tapPlaceAssistant(WidgetTester tester) async {
  final button = find.text('Спросить ИИ об этом месте');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
  expect(_sheet, findsOneWidget);
}

Future<void> _openAssistant(WidgetTester tester) async {
  final entry = find.byKey(const Key('ai_assistant_entry'));
  expect(entry, findsOneWidget);
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
  expect(_sheet, findsOneWidget);
}

Finder get _sheet => find.byType(AssistantSheet);

Finder get _sheetTextFields =>
    find.descendant(of: _sheet, matching: find.byType(TextField));

Finder get _sheetCheckbox =>
    find.descendant(of: _sheet, matching: find.byType(CheckboxListTile));

Future<void> _passGate(
  WidgetTester tester, {
  String buttonText = 'Согласиться и продолжить',
}) async {
  await tester.pumpAndSettle();
  if (find.text('Перед началом').evaluate().isEmpty) return;
  final checkbox = _sheetCheckbox;
  expect(checkbox, findsOneWidget);
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox);
  await tester.pump();
  final proceed = find.descendant(
    of: _sheet,
    matching: find.widgetWithText(FilledButton, buttonText),
  );
  expect(proceed, findsOneWidget);
  await tester.ensureVisible(proceed);
  await tester.pumpAndSettle();
  await tester.tap(proceed);
  await tester.pumpAndSettle();
  expect(find.text('Перед началом'), findsNothing);
}

Future<void> _ask(WidgetTester tester, String text) async {
  final input = _sheetTextFields;
  expect(input, findsOneWidget);
  await tester.enterText(input, text);
  await tester.pump();
  final send = find.byTooltip('Отправить вопрос');
  expect(send, findsOneWidget);
  await tester.ensureVisible(send);
  await tester.pumpAndSettle();
  await tester.tap(send);
  await tester.pumpAndSettle();
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Дополнительные действия'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Настройки'));
  await tester.pumpAndSettle();
  expect(find.text('Ваши настройки'), findsOneWidget);
}

void main() {
  testWidgets('map exposes the built-in assistant with consent, no code', (
    tester,
  ) async {
    final host = await _mountMap(tester);
    expect(find.byKey(const Key('ai_assistant_entry')), findsOneWidget);
    expect(find.text('ИИ-помощник'), findsOneWidget);
    expect(
      find.byTooltip('ИИ-помощник: спросите о городе и приложении'),
      findsOneWidget,
    );
    await _openAssistant(tester);
    expect(find.text('Перед началом'), findsOneWidget);
    expect(find.textContaining('OpenRouter'), findsWidgets);
    expect(find.textContaining('Не указывайте личные данные'), findsOneWidget);
    expect(find.text('Код доступа'), findsNothing);
    expect(_sheetTextFields, findsNothing);
    expect(host.service.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('consent is required before any request', (tester) async {
    final host = await _mountMap(tester);
    await _openAssistant(tester);
    var proceed = tester.widget<FilledButton>(
      find.descendant(
        of: _sheet,
        matching: find.widgetWithText(FilledButton, 'Согласиться и продолжить'),
      ),
    );
    expect(proceed.onPressed, isNull);
    await tester.ensureVisible(_sheetCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(_sheetCheckbox);
    await tester.pump();
    proceed = tester.widget<FilledButton>(
      find.descendant(
        of: _sheet,
        matching: find.widgetWithText(FilledButton, 'Согласиться и продолжить'),
      ),
    );
    expect(proceed.onPressed, isNotNull);
    await tester.ensureVisible(find.text('Согласиться и продолжить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Согласиться и продолжить'));
    await tester.pumpAndSettle();
    expect(find.text('Спросите о Петербурге'), findsOneWidget);
    expect(host.service.calls, isEmpty);
  });

  testWidgets('consent survives closing and reopening the sheet', (
    tester,
  ) async {
    final store = MemoryAssistantConsentStore();
    final host = await _mountMap(tester, consentStore: store);
    await _openAssistant(tester);
    await _passGate(tester);
    expect(store.version, AssistantConsentStore.currentVersion);
    await tester.tap(find.byTooltip('Закрыть ИИ-помощника'));
    await tester.pumpAndSettle();
    await _openAssistant(tester);
    expect(find.text('Перед началом'), findsNothing);
    expect(find.text('Спросите о Петербурге'), findsOneWidget);
    expect(host.service.calls, isEmpty);
  });

  testWidgets('reply shows grounded place and explicit Smart Walk action', (
    tester,
  ) async {
    final host = await _mountMap(tester);
    await _openAssistant(tester);
    await _passGate(tester);
    await _ask(tester, 'Расскажи об Исаакиевском соборе');
    expect(
      find.textContaining('В каталоге есть Исаакиевский собор'),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _sheet, matching: find.text('Исаакиевский собор')),
      findsOneWidget,
    );
    expect(find.text('Открыть место'), findsOneWidget);
    expect(find.text('Открыть умную прогулку'), findsOneWidget);
    expect(host.routing.currentRoute, isNull);
    expect(
      host.service.calls.single.message,
      'Расскажи об Исаакиевском соборе',
    );
    expect(host.service.calls.single.placeId, isNull);
    await tester.ensureVisible(find.text('Открыть умную прогулку'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Открыть умную прогулку'));
    await tester.pumpAndSettle();
    expect(find.byType(SmartWalkWizardSheet), findsOneWidget);
    expect(host.routing.currentRoute, isNull);
  });

  testWidgets('place card opens the existing catalog preview, not a route', (
    tester,
  ) async {
    final host = await _mountMap(tester);
    await _openAssistant(tester);
    await _passGate(tester);
    await _ask(tester, 'Расскажи об Исаакиевском соборе');
    await tester.ensureVisible(find.text('Открыть место'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Открыть место'));
    await tester.pumpAndSettle();
    expect(host.places.selectedPlace?.id, _isaac.id);
    expect(find.byType(PlacePreviewCard), findsOneWidget);
    expect(host.routing.currentRoute, isNull);
  });

  testWidgets('cancel discards a late answer', (tester) async {
    final service = _FakeAssistant()..pending = Completer<AssistantReply>();
    await _mountMap(tester, service: service);
    await _openAssistant(tester);
    await _passGate(tester);
    await tester.enterText(_sheetTextFields, 'Вопрос');
    await tester.pump();
    await tester.tap(find.byTooltip('Отправить вопрос'));
    await tester.pump();
    expect(find.byTooltip('Отменить ответ'), findsOneWidget);
    await tester.tap(find.byTooltip('Отменить ответ'));
    await tester.pump();
    expect(find.text('Запрос отменён.'), findsOneWidget);
    service.pending!.complete(_defaultReply());
    await tester.pumpAndSettle();
    expect(find.textContaining('В каталоге есть'), findsNothing);
  });

  testWidgets('clear conversation requires confirmation and keeps the map', (
    tester,
  ) async {
    await _mountMap(tester);
    await _openAssistant(tester);
    await _passGate(tester);
    await _ask(tester, 'Расскажи об Исаакиевском соборе');
    await tester.tap(find.byTooltip('Очистить беседу'));
    await tester.pumpAndSettle();
    expect(find.text('Очистить беседу?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Очистить'));
    await tester.pumpAndSettle();
    expect(find.text('Спросите о Петербурге'), findsOneWidget);
    expect(find.textContaining('В каталоге есть'), findsNothing);
  });

  testWidgets('network error is friendly and does not break the map', (
    tester,
  ) async {
    final service = _FakeAssistant()
      ..error = const AssistantServiceException(
        'unavailable',
        'ИИ-помощник временно недоступен. Карта и навигация продолжают работать.',
      );
    await _mountMap(tester, service: service);
    await _openAssistant(tester);
    await _passGate(tester);
    await _ask(tester, 'Вопрос');
    expect(
      find.textContaining('Карта и навигация продолжают работать'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Закрыть ИИ-помощника'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai_assistant_entry')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quota message reports the Retry-After wait', (tester) async {
    final service = _FakeAssistant()
      ..error = const AssistantServiceException(
        'rate_limited',
        'Лимит запросов к ИИ-помощнику исчерпан. Повторите через 2 мин.',
      );
    await _mountMap(tester, service: service);
    await _openAssistant(tester);
    await _passGate(tester);
    await _ask(tester, 'Вопрос');
    expect(find.textContaining('Повторите через 2 мин.'), findsOneWidget);
    expect(find.textContaining('Карта, поиск'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('revoking consent in settings clears the chat and blocks sends', (
    tester,
  ) async {
    final store = MemoryAssistantConsentStore();
    final host = await _mountMap(tester, consentStore: store);
    await _openAssistant(tester);
    await _passGate(tester);
    await _ask(tester, 'Расскажи об Исаакиевском соборе');
    expect(host.service.calls.length, 1);
    await tester.tap(find.byTooltip('Закрыть ИИ-помощника'));
    await tester.pumpAndSettle();

    await _openSettings(tester);
    await tester.scrollUntilVisible(
      find.text('Отозвать согласие'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Отозвать согласие'), findsOneWidget);
    await tester.tap(find.text('Отозвать согласие'));
    await tester.pumpAndSettle();
    expect(find.text('Отозвать согласие?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Отозвать'));
    await tester.pumpAndSettle();
    expect(store.version, isNull);
    expect(store.revokes, 1);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await _openAssistant(tester);
    expect(find.text('Перед началом'), findsOneWidget);
    expect(host.assistant.messages, isEmpty);
    expect(host.service.calls.length, 1);
    expect(tester.takeException(), isNull);
  });

  for (final config in [
    (const Size(320, 480), false),
    (const Size(320, 480), true),
    (const Size(360, 640), false),
    (const Size(360, 640), true),
  ]) {
    testWidgets(
      'AI sheet fits ${config.$1.width.toInt()}x${config.$1.height.toInt()} '
      '${config.$2 ? 'dark' : 'light'} with large text',
      (tester) async {
        await _mountMap(
          tester,
          size: config.$1,
          dark: config.$2,
          textScale: 1.6,
        );
        await _openAssistant(tester);
        expect(tester.takeException(), isNull);
        await _passGate(tester);
        expect(find.text('Спросите о Петербурге'), findsOneWidget);
        await _ask(tester, 'Расскажи об Исаакиевском соборе');
        expect(find.text('Открыть место'), findsOneWidget);
        expect(find.text('Открыть умную прогулку'), findsOneWidget);
        expect(find.byTooltip('Отправить вопрос'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('assistant exposes accessible actions and place semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _mountMap(tester);
    await _openAssistant(tester);
    expect(tester.getSemantics(_sheetCheckbox).label, contains('Я понимаю'));
    await _passGate(tester);
    final send = find.descendant(
      of: _sheet,
      matching: find.byTooltip('Отправить вопрос'),
    );
    final sendSemantics = tester.getSemantics(send);
    expect(
      '${sendSemantics.label} ${sendSemantics.tooltip}',
      contains('Отправить вопрос'),
    );
    await _ask(tester, 'Расскажи об Исаакиевском соборе');
    expect(
      find.bySemanticsLabel(RegExp('Открыть место: Исаакиевский собор')),
      findsWidgets,
    );
    semantics.dispose();
  });

  testWidgets(
    'place detail sends the prepared question once when consent exists',
    (tester) async {
      final host = await _mountPlaceDetail(
        tester,
        consentStore: MemoryAssistantConsentStore(
          version: AssistantConsentStore.currentVersion,
        ),
      );
      await _tapPlaceAssistant(tester);
      expect(find.text('Перед началом'), findsNothing);
      expect(find.text('Контекст: Исаакиевский собор'), findsOneWidget);
      expect(host.service.calls.length, 1);
      final call = host.service.calls.single;
      expect(call.message, 'Расскажи об этом месте');
      expect(call.placeId, _isaac.id);
      expect(host.assistant.messages.first.isUser, isTrue);
      expect(host.assistant.messages.first.text, 'Расскажи об этом месте');
      expect(find.textContaining('В каталоге есть'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(host.service.calls.length, 1);
    },
  );

  testWidgets('without consent no request is sent before the explicit action', (
    tester,
  ) async {
    final host = await _mountPlaceDetail(tester);
    await _tapPlaceAssistant(tester);
    expect(find.text('Перед началом'), findsOneWidget);
    expect(find.text('Согласиться и спросить ИИ'), findsOneWidget);
    expect(host.service.calls, isEmpty);
    expect(host.assistant.messages, isEmpty);
  });

  testWidgets('accepting consent sends exactly one prepared question', (
    tester,
  ) async {
    final host = await _mountPlaceDetail(tester);
    await _tapPlaceAssistant(tester);
    await _passGate(tester, buttonText: 'Согласиться и спросить ИИ');
    expect(host.service.calls.length, 1);
    expect(host.service.calls.single.message, 'Расскажи об этом месте');
    expect(host.service.calls.single.placeId, _isaac.id);
    expect(
      host.assistant.messages.where((message) => message.isUser).length,
      1,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(host.service.calls.length, 1);
  });

  testWidgets('closing the consent gate sends nothing', (tester) async {
    final host = await _mountPlaceDetail(tester);
    await _tapPlaceAssistant(tester);
    await tester.tap(find.byTooltip('Закрыть ИИ-помощника'));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(host.service.calls, isEmpty);
    expect(host.assistant.messages, isEmpty);
  });

  testWidgets('reopening the same place does not duplicate the question', (
    tester,
  ) async {
    final host = await _mountPlaceDetail(
      tester,
      consentStore: MemoryAssistantConsentStore(
        version: AssistantConsentStore.currentVersion,
      ),
    );
    await _tapPlaceAssistant(tester);
    expect(host.service.calls.length, 1);
    await tester.tap(find.byTooltip('Закрыть ИИ-помощника'));
    await tester.pumpAndSettle();
    await _tapPlaceAssistant(tester);
    expect(host.service.calls.length, 1);
    expect(host.assistant.messages.length, 2);
    expect(find.textContaining('В каталоге есть'), findsOneWidget);
  });

  testWidgets(
    'changing place drops the pending question and asks the new one',
    (tester) async {
      final host = await _mountPlaceDetail(
        tester,
        catalog: const [_isaac, _kazan],
      );
      await _tapPlaceAssistant(tester);
      expect(find.text('Перед началом'), findsOneWidget);
      expect(host.service.calls, isEmpty);

      // Simulate the context changing before the prepared question is sent.
      host.assistant.prepare(placeId: _kazan.id, placeTitle: _kazan.title);
      await tester.pumpAndSettle();
      expect(find.text('Согласиться и спросить ИИ'), findsNothing);
      await _passGate(tester);
      expect(host.service.calls, isEmpty);

      await tester.tap(find.byTooltip('Закрыть ИИ-помощника'));
      await tester.pumpAndSettle();
      final navigator = Navigator.of(
        tester.element(find.byType(PlaceDetailScreen)),
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const PlaceDetailScreen(place: _kazan),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tapPlaceAssistant(tester);
      expect(host.service.calls.length, 1);
      expect(host.service.calls.single.placeId, _kazan.id);
      expect(host.service.calls.single.message, 'Расскажи об этом месте');
    },
  );

  testWidgets('revoking consent before dispatch sends nothing', (tester) async {
    final host = await _mountPlaceDetail(tester);
    await _tapPlaceAssistant(tester);
    await tester.ensureVisible(_sheetCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(_sheetCheckbox);
    await tester.pump();
    final proceed = find.text('Согласиться и спросить ИИ');
    await tester.ensureVisible(proceed);
    await tester.pumpAndSettle();
    await tester.tap(proceed);
    await host.assistant.revokeConsent();
    await tester.pumpAndSettle();
    expect(host.service.calls, isEmpty);
    expect(host.assistant.messages, isEmpty);
    expect(find.text('Перед началом'), findsOneWidget);
  });

  testWidgets('map assistant keeps manual-question behaviour', (tester) async {
    final host = await _mountMap(tester);
    await _openAssistant(tester);
    await _passGate(tester);
    expect(host.service.calls, isEmpty);
    expect(find.text('Расскажи об этом месте'), findsNothing);
    await _ask(tester, 'Что посмотреть?');
    expect(host.service.calls.length, 1);
    expect(host.service.calls.single.message, 'Что посмотреть?');
    expect(host.service.calls.single.placeId, isNull);
  });

  testWidgets('keyboard insets lift the input above themselves at 1.6x', (
    tester,
  ) async {
    await _mountMap(tester, textScale: 1.6);
    await _openAssistant(tester);
    await _passGate(tester);

    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    final input = _sheetTextFields;
    expect(input, findsOneWidget);
    expect(tester.getRect(input).bottom, lessThanOrEqualTo(640 - 280));
    final send = find.descendant(
      of: _sheet,
      matching: find.byTooltip('Отправить вопрос'),
    );
    expect(tester.getRect(send).bottom, lessThanOrEqualTo(640 - 280));
    // Messages scroll inside the remaining area; the composer never scrolls
    // away with them.
    expect(
      find.descendant(of: _sheet, matching: find.byType(SingleChildScrollView)),
      findsOneWidget,
    );
    await tester.enterText(input, 'Что посмотреть рядом?');
    await tester.pump();
    expect(find.text('Что посмотреть рядом?'), findsOneWidget);

    // Back closes the keyboard first: the sheet and its draft stay put.
    EditableText editor() => tester.widget<EditableText>(
      find.descendant(of: input, matching: find.byType(EditableText)),
    );
    await tester.tap(input);
    await tester.pump();
    expect(editor().focusNode.hasFocus, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_sheet, findsOneWidget);
    expect(find.text('Что посмотреть рядом?'), findsOneWidget);
    expect(editor().focusNode.hasFocus, isFalse);

    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
