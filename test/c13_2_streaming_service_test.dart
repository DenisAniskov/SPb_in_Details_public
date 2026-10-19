import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_service.dart';
import 'package:smart_navigator_spb/services/assistant/sse_parser.dart';

class _StreamAdapter implements HttpClientAdapter {
  _StreamAdapter(this.stream, {this.statusCode = 200});

  final Stream<Uint8List> stream;
  final int statusCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      stream,
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

BackendAssistantService _service(Stream<Uint8List> stream, {int status = 200}) {
  final client = ApiClient(customBaseUrl: 'https://example.test/api/v1');
  client.dio.httpClientAdapter = _StreamAdapter(stream, statusCode: status);
  return BackendAssistantService(apiClient: client);
}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('stream event did not arrive in time');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String _frame(String event, Map<String, dynamic> data) =>
    'event: $event\ndata: ${jsonEncode(data)}\n\n';

Map<String, dynamic> _replyJson() => {
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
};

void main() {
  group('SSE parser', () {
    test('handles CRLF, comments and multi-line data', () {
      final parser = SseParser();
      final frames = parser.add(
        ': keepalive\r\n'
        'event: delta\r\n'
        'data: {"text":"A"}\r\n'
        '\r\n',
      );
      expect(frames, hasLength(1));
      expect(frames.single.event, 'delta');
      expect(frames.single.data, '{"text":"A"}');

      final multi = parser.add(
        'event: delta\n'
        'data: line1\n'
        'data: line2\n'
        '\n',
      );
      expect(multi.single.data, 'line1\nline2');
    });

    test('returns nothing before a complete event', () {
      final parser = SseParser();
      expect(parser.add('event: delta\n'), isEmpty);
      expect(parser.add('data: {"text":"x"}\n'), isEmpty);
      expect(parser.add('\n'), hasLength(1));
    });
  });

  test('streams fragments before the final completed event', () async {
    final body = StreamController<Uint8List>();
    final service = _service(body.stream);
    final events = <AssistantStreamEvent>[];
    final done = Completer<void>();
    final subscription = service
        .stream(message: 'Вопрос', history: const [])
        .listen(
          events.add,
          onError: done.completeError,
          onDone: done.complete,
        );

    body.add(_bytes(_frame('started', {'model': 'free/model:free'})));
    await _until(() => events.whereType<AssistantStreamStarted>().isNotEmpty);
    expect(events.whereType<AssistantStreamStarted>(), hasLength(1));

    body.add(_bytes(_frame('delta', {'text': 'Первая '})));
    await _until(() => events.whereType<AssistantStreamDelta>().isNotEmpty);
    expect(events.whereType<AssistantStreamDelta>().map((e) => e.text), [
      'Первая ',
    ]);
    expect(events.whereType<AssistantStreamCompleted>(), isEmpty);

    body.add(_bytes(_frame('delta', {'text': 'часть'})));
    await _until(
      () => events.whereType<AssistantStreamDelta>().length == 2,
    );
    expect(events.whereType<AssistantStreamDelta>().map((e) => e.text), [
      'Первая ',
      'часть',
    ]);

    body.add(_bytes(_frame('completed', _replyJson())));
    await body.close();
    await done.future.timeout(const Duration(seconds: 2));
    await subscription.cancel();

    expect(events.whereType<AssistantStreamCompleted>(), hasLength(1));
    expect(
      events.whereType<AssistantStreamCompleted>().single.reply.answer,
      'Подтверждённый **ответ**.',
    );
  });

  test('a server error event ends the stream without a completed answer',
      () async {
    final service = _service(Stream.value(_bytes(
      _frame('started', {'model': 'free/model:free'}) +
          _frame('delta', {'text': 'Частично'}) +
          _frame('error', {
            'code': 'model_mismatch',
            'message': 'ИИ-помощник временно недоступен.',
          }),
    )));
    final events = await service
        .stream(message: 'Q', history: const [])
        .toList();
    expect(events.whereType<AssistantStreamDelta>(), hasLength(1));
    expect(events.whereType<AssistantStreamCompleted>(), isEmpty);
    final error = events.whereType<AssistantStreamError>().single;
    expect(error.code, 'model_mismatch');
    expect(error.userMessage, isNot(contains('sk-or-v1')));
  });

  test('a stream that ends without completed is discarded as incomplete',
      () async {
    final service = _service(Stream.value(_bytes(
      _frame('delta', {'text': 'Обрыв'}),
    )));
    final events = await service
        .stream(message: 'Q', history: const [])
        .toList();
    expect(events.whereType<AssistantStreamCompleted>(), isEmpty);
    final error = events.whereType<AssistantStreamError>().single;
    expect(error.code, 'incomplete');
    expect(error.userMessage, contains('Карта и навигация'));
  });

  test('429 before the stream keeps the Retry-After message', () async {
    final service = _service(const Stream.empty(), status: 429);
    final events = await service
        .stream(message: 'Q', history: const [])
        .toList();
    expect(events.whereType<AssistantStreamCompleted>(), isEmpty);
    final error = events.whereType<AssistantStreamError>().single;
    expect(error.code, 'rate_limited');
    expect(error.userMessage, contains('Лимит запросов'));
  });

  test('cancellation ends the stream and never yields a completed answer',
      () async {
    final body = StreamController<Uint8List>();
    final service = _service(body.stream);
    final token = CancelToken();
    final events = <AssistantStreamEvent>[];
    final done = Completer<void>();
    service
        .stream(
          message: 'Q',
          history: const [],
          cancelToken: token,
        )
        .listen(
          events.add,
          onError: done.completeError,
          onDone: done.complete,
        );
    body.add(_bytes(_frame('started', {'model': 'free/model:free'})));
    await _until(() => events.isNotEmpty);
    token.cancel('test');
    await body.close();
    await done.future.timeout(const Duration(seconds: 2));
    expect(events.whereType<AssistantStreamCompleted>(), isEmpty);
  });
}
