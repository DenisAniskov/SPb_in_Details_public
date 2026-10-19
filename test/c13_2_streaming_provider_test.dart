import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/assistant_model.dart';
import 'package:smart_navigator_spb/providers/assistant_provider.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_service.dart';

import 'assistant_test_support.dart';

AssistantReply _reply() => AssistantReply.fromJson({
  'status': 'ok',
  'answer': 'Подтверждённый **ответ**.',
  'model': 'nvidia/nemotron-3-super-120b-a12b:free',
  'places': <dynamic>[],
  'actions': <dynamic>[],
  'warnings': <String>[],
  'usage': {
    'prompt_tokens': 1,
    'completion_tokens': 2,
    'cost_usd': 0,
    'cost_verified': true,
  },
});

class _StreamingService implements StreamingAssistantService {
  final List<StreamController<AssistantStreamEvent>> controllers = [];
  final List<List<AssistantHistoryTurn>> histories = [];

  StreamController<AssistantStreamEvent> get current =>
      controllers.last;

  @override
  Future<AssistantReply> send({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
    CancelToken? cancelToken,
  }) {
    throw StateError('streaming must be used');
  }

  @override
  Stream<AssistantStreamEvent> stream({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
    CancelToken? cancelToken,
  }) {
    histories.add(history);
    final controller = StreamController<AssistantStreamEvent>();
    controllers.add(controller);
    return controller.stream;
  }
}

Future<AssistantProvider> _provider(_StreamingService service) async {
  final provider = AssistantProvider(
    assistantService: service,
    consentStore: MemoryAssistantConsentStore(),
  );
  await pumpEventQueue();
  await provider.acceptConsent();
  return provider;
}

void main() {
  test('provisional fragments never enter messages or the next history',
      () async {
    final service = _StreamingService();
    final provider = await _provider(service);
    addTearDown(provider.dispose);

    final sending = provider.send('Вопрос');
    await pumpEventQueue();
    expect(provider.messages, hasLength(1));
    expect(provider.messages.single.isUser, isTrue);

    service.current.add(
      const AssistantStreamStarted(model: 'nvidia/nemotron:free'),
    );
    service.current.add(const AssistantStreamDelta('**Частичный** '));
    service.current.add(const AssistantStreamDelta('ответ'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(provider.provisionalText, '**Частичный** ответ');
    expect(provider.messages, hasLength(1));
    expect(provider.isSending, isTrue);

    service.current.add(AssistantStreamCompleted(_reply()));
    await service.current.close();
    await sending;

    expect(provider.provisionalText, isEmpty);
    expect(provider.isSending, isFalse);
    expect(provider.messages, hasLength(2));
    expect(provider.messages.last.isAssistant, isTrue);
    expect(provider.messages.last.text, contains('Подтверждённый'));

    final second = provider.send('Ещё вопрос');
    await pumpEventQueue();
    expect(service.histories.last.map((turn) => turn.role), [
      'user',
      'assistant',
    ]);
    // The provisional fragment is not in the confirmed assistant turn.
    expect(service.histories.last[1].content, contains('Подтверждённый'));
    expect(service.histories.last[1].content, isNot(contains('Частичный')));
    service.current.add(AssistantStreamCompleted(_reply()));
    await service.current.close();
    await second;
  });

  test('deltas are throttled instead of rebuilding on every fragment',
      () async {
    final service = _StreamingService();
    final provider = await _provider(service);
    addTearDown(provider.dispose);
    var notifications = 0;
    provider.addListener(() => notifications++);

    final sending = provider.send('Вопрос');
    await pumpEventQueue();
    for (var index = 0; index < 100; index++) {
      service.current.add(const AssistantStreamDelta('x'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(provider.provisionalText, hasLength(100));
    expect(notifications, lessThan(20));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(notifications, lessThan(20));
    service.current.add(AssistantStreamCompleted(_reply()));
    await service.current.close();
    await sending;
  });

  test('an error after fragments discards the provisional answer', () async {
    final service = _StreamingService();
    final provider = await _provider(service);
    addTearDown(provider.dispose);

    final sending = provider.send('Вопрос');
    await pumpEventQueue();
    service.current.add(const AssistantStreamDelta('Предварительно'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    service.current.add(
      const AssistantStreamError(
        'model_mismatch',
        'ИИ-помощник временно недоступен. '
        'Карта и навигация продолжают работать.',
      ),
    );
    await service.current.close();
    await sending;

    expect(provider.provisionalText, isEmpty);
    expect(provider.messages.where((m) => m.isAssistant), isEmpty);
    expect(provider.messages.last.isError, isTrue);
    expect(provider.messages.last.text, isNot(contains('Предварительно')));
  });

  test('cancel drops late fragments and completed data', () async {
    final service = _StreamingService();
    final provider = await _provider(service);
    addTearDown(provider.dispose);

    final sending = provider.send('Вопрос');
    await pumpEventQueue();
    service.current.add(const AssistantStreamDelta('Начало'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    provider.cancel();
    expect(provider.isSending, isFalse);
    expect(provider.provisionalText, isEmpty);
    expect(provider.messages.last.isCancelled, isTrue);

    service.current.add(const AssistantStreamDelta('поздно'));
    service.current.add(AssistantStreamCompleted(_reply()));
    await service.current.close();
    await sending;

    expect(provider.messages.where((m) => m.isAssistant), isEmpty);
    expect(provider.messages.last.isCancelled, isTrue);
  });

  test('a stream without a completed event becomes a safe error', () async {
    final service = _StreamingService();
    final provider = await _provider(service);
    addTearDown(provider.dispose);

    final sending = provider.send('Вопрос');
    await pumpEventQueue();
    service.current.add(const AssistantStreamDelta('Обрыв'));
    await service.current.close();
    await sending;

    expect(provider.provisionalText, isEmpty);
    expect(provider.messages.where((m) => m.isAssistant), isEmpty);
    expect(provider.messages.last.isError, isTrue);
  });
}
