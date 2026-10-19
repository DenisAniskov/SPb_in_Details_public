import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/assistant_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/providers/assistant_provider.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_consent_store.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_service.dart';

import 'assistant_test_support.dart';

const _notice = AssistantConsentStore.currentVersion;

AssistantReply _reply({
  String answer = 'Исаакиевский собор есть в каталоге.',
  List<AssistantPlaceReference> places = const [],
  List<AssistantAction> actions = const [],
}) => AssistantReply(
  status: 'ok',
  answer: answer,
  model: 'nvidia/nemotron-3-super-120b-a12b:free',
  places: places,
  actions: actions,
  warnings: const ['Проверяйте важные факты.'],
  usage: const AssistantUsage(costUsd: 0, costVerified: true),
);

class _Call {
  _Call(this.message, this.history, this.placeId, this.cancelToken);

  final String message;
  final List<AssistantHistoryTurn> history;
  final int? placeId;
  final CancelToken? cancelToken;
}

class _FakeService implements AssistantService {
  final List<_Call> calls = [];
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
    calls.add(_Call(message, history, placeId, cancelToken));
    if (pending != null) return pending!.future;
    if (error != null) return Future.error(error!);
    return Future.value(reply ?? _reply());
  }
}

AssistantProvider _provider(
  AssistantService service, {
  MemoryAssistantConsentStore? store,
}) => AssistantProvider(
  assistantService: service,
  consentStore: store ?? MemoryAssistantConsentStore(),
);

Future<void> _settleConsent(AssistantProvider provider) async {
  for (var attempt = 0; attempt < 10 && provider.consentLoading; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(provider.consentLoading, isFalse);
}

Future<void> _accept(
  AssistantProvider provider, {
  MemoryAssistantConsentStore? store,
}) async {
  await _settleConsent(provider);
  if (!provider.consented) {
    await provider.acceptConsent();
  }
  expect(provider.consented, isTrue);
  if (store != null) expect(store.version, _notice);
}

void main() {
  test('nothing is sent before consent', () async {
    final service = _FakeService();
    final provider = _provider(service);
    addTearDown(provider.dispose);
    await _settleConsent(provider);
    expect(provider.needsConsent, isTrue);
    await provider.send('Привет');
    expect(service.calls, isEmpty);
    expect(provider.messages, isEmpty);
  });

  test('accepted notice version persists for a new provider', () async {
    final store = MemoryAssistantConsentStore();
    final first = _provider(_FakeService(), store: store);
    addTearDown(first.dispose);
    await _accept(first, store: store);
    expect(store.version, _notice);
    expect(store.accepts, 1);

    final second = _provider(_FakeService(), store: store);
    addTearDown(second.dispose);
    await _settleConsent(second);
    expect(second.consented, isTrue);
    expect(second.needsConsent, isFalse);
  });

  test('send adds user and grounded assistant messages', () async {
    final service = _FakeService()
      ..reply = _reply(
        places: [
          const AssistantPlaceReference(
            id: 1,
            catalogKey: 'saint-isaacs-cathedral',
            title: 'Исаакиевский собор',
            category: PlaceCategoryEnum.historyArchitecture,
            isUnusual: false,
            shortDescription: 'Собор',
          ),
        ],
        actions: const [
          AssistantAction(
            type: 'open_smart_walk',
            label: 'Открыть умную прогулку',
          ),
        ],
      );
    final provider = _provider(service);
    addTearDown(provider.dispose);
    await _accept(provider);
    await provider.send('Расскажи об Исаакиевском соборе');
    expect(provider.messages.length, 2);
    expect(provider.messages.first.isUser, isTrue);
    expect(provider.messages.last.isAssistant, isTrue);
    expect(
      provider.messages.last.reply!.places.single.title,
      'Исаакиевский собор',
    );
    expect(provider.messages.last.reply!.openSmartWalk, isTrue);
    expect(service.calls.single.message, 'Расскажи об Исаакиевском соборе');
    expect(service.calls.single.history, isEmpty);
    expect(provider.isSending, isFalse);
  });

  test('history is bounded and long assistant answers are clipped', () async {
    final service = _FakeService()
      ..reply = _reply(answer: 'Очень длинный ответ ${'а' * 1200}');
    final provider = _provider(service);
    addTearDown(provider.dispose);
    await _accept(provider);
    await provider.send('Первый вопрос');
    await provider.send('Второй вопрос');
    expect(service.calls.length, 2);
    final history = service.calls[1].history;
    expect(history.length, 2);
    expect(history.first.role, 'user');
    expect(history.last.role, 'assistant');
    expect(history.last.content.length, lessThanOrEqualTo(800));
  });

  test('rapid sends produce exactly one request', () async {
    final service = _FakeService()..pending = Completer<AssistantReply>();
    final provider = _provider(service);
    addTearDown(provider.dispose);
    await _accept(provider);
    final first = provider.send('Первый');
    final second = provider.send('Второй');
    await Future<void>.delayed(Duration.zero);
    expect(service.calls.length, 1);
    expect(provider.messages.where((m) => m.isUser).length, 1);
    service.pending!.complete(_reply());
    await Future.wait([first, second]);
  });

  test(
    'cancel discards a late answer and keeps an explicit cancelled state',
    () async {
      final service = _FakeService()..pending = Completer<AssistantReply>();
      final provider = _provider(service);
      addTearDown(provider.dispose);
      await _accept(provider);
      final future = provider.send('Вопрос');
      await Future<void>.delayed(Duration.zero);
      provider.cancel();
      service.pending!.complete(_reply(answer: 'Поздний ответ'));
      await future;
      await Future<void>.delayed(Duration.zero);
      expect(provider.messages.last.isCancelled, isTrue);
      expect(provider.messages.any((m) => m.text == 'Поздний ответ'), isFalse);
      expect(provider.isSending, isFalse);
    },
  );

  test('a network error is friendly and retry replaces the error', () async {
    final service = _FakeService()
      ..error = const AssistantServiceException(
        'unavailable',
        'ИИ-помощник временно недоступен. '
        'Карта и навигация продолжают работать.',
      );
    final provider = _provider(service);
    addTearDown(provider.dispose);
    await _accept(provider);
    await provider.send('Вопрос');
    expect(provider.messages.last.isError, isTrue);
    expect(provider.messages.last.text, contains('Карта и навигация'));
    service.error = null;
    service.reply = _reply();
    await provider.retryLast();
    expect(provider.messages.length, 2);
    expect(provider.messages.first.isUser, isTrue);
    expect(provider.messages.last.isAssistant, isTrue);
    expect(service.calls.length, 2);
  });

  test('revoking consent clears the conversation and blocks new sends', () async {
    final service = _FakeService();
    final store = MemoryAssistantConsentStore();
    final provider = _provider(service, store: store);
    addTearDown(provider.dispose);
    await _accept(provider, store: store);
    await provider.send('Вопрос');
    expect(provider.messages, isNotEmpty);

    await provider.revokeConsent();
    expect(provider.needsConsent, isTrue);
    expect(provider.consented, isFalse);
    expect(provider.messages, isEmpty);
    expect(store.version, isNull);
    expect(store.revokes, 1);

    await provider.send('Новый вопрос');
    expect(service.calls.length, 1);
    expect(provider.messages, isEmpty);
  });

  test('revocation discards an in-flight answer', () async {
    final service = _FakeService()..pending = Completer<AssistantReply>();
    final provider = _provider(service);
    addTearDown(provider.dispose);
    await _accept(provider);
    final future = provider.send('Вопрос');
    await Future<void>.delayed(Duration.zero);
    await provider.revokeConsent();
    service.pending!.complete(_reply(answer: 'Поздний'));
    await future;
    await Future<void>.delayed(Duration.zero);
    expect(provider.messages, isEmpty);
    expect(provider.isSending, isFalse);
  });

  test(
    'prepare clears a different place conversation but keeps the same one',
    () async {
      final service = _FakeService();
      final provider = _provider(service);
      addTearDown(provider.dispose);
      await _accept(provider);
      provider.prepare(placeId: 1, placeTitle: 'Первое');
      await provider.send('Вопрос');
      expect(provider.messages, isNotEmpty);
      provider.prepare(placeId: 1, placeTitle: 'Первое');
      expect(provider.messages, isNotEmpty);
      provider.prepare(placeId: 2, placeTitle: 'Второе');
      expect(provider.messages, isEmpty);
      expect(provider.placeId, 2);
      expect(provider.placeTitle, 'Второе');
    },
  );

  test('clear cancels and discards a late result', () async {
    final service = _FakeService()..pending = Completer<AssistantReply>();
    final provider = _provider(service);
    addTearDown(provider.dispose);
    await _accept(provider);
    final future = provider.send('Вопрос');
    await Future<void>.delayed(Duration.zero);
    provider.clear();
    service.pending!.complete(_reply(answer: 'Поздний'));
    await future;
    await Future<void>.delayed(Duration.zero);
    expect(provider.messages, isEmpty);
    expect(provider.isSending, isFalse);
  });

  test('an unexpected service failure also clears the sending state', () async {
    final service = _ThrowingService();
    final provider = _provider(service);
    addTearDown(provider.dispose);
    await _accept(provider);
    await provider.send('Вопрос');
    expect(provider.messages.last.isError, isTrue);
    expect(provider.isSending, isFalse);
  });

  test('an unreadable consent record fails closed', () async {
    final store = MemoryAssistantConsentStore(version: _notice)
      ..failRead = true;
    final provider = _provider(_FakeService(), store: store);
    addTearDown(provider.dispose);
    await _settleConsent(provider);
    expect(provider.consented, isFalse);
    expect(provider.needsConsent, isTrue);
  });

  test('a failed local write keeps the current choice and warns', () async {
    final store = MemoryAssistantConsentStore()..failAccept = true;
    final provider = _provider(_FakeService(), store: store);
    addTearDown(provider.dispose);
    await _settleConsent(provider);
    await provider.acceptConsent();
    expect(provider.consented, isTrue);
    expect(provider.consentPersistenceFailed, isTrue);
    expect(provider.canSend('Вопрос'), isTrue);
  });
}

class _ThrowingService implements AssistantService {
  @override
  Future<AssistantReply> send({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
    CancelToken? cancelToken,
  }) async {
    throw StateError('boom');
  }
}
