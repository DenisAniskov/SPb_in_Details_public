import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/assistant_model.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_service.dart';

Map<String, dynamic> _payload() => {
  'status': 'ok',
  'answer': 'В каталоге есть Исаакиевский собор.',
  'model': 'nvidia/nemotron-3-super-120b-a12b:free',
  'places': [
    {
      'id': 1,
      'catalog_key': 'saint-isaacs-cathedral',
      'title': 'Исаакиевский собор',
      'category': 'history_architecture',
      'is_unusual': false,
      'short_description': 'Собор',
    },
  ],
  'actions': [
    {'type': 'open_smart_walk', 'label': 'Открыть умную прогулку'},
  ],
  'warnings': ['Проверяйте важные факты.'],
  'usage': {
    'prompt_tokens': 10,
    'completion_tokens': 5,
    'cost_usd': 0,
    'cost_verified': true,
  },
};

ApiClient _client(Interceptor interceptor) {
  final client = ApiClient(customBaseUrl: 'https://example.test/api/v1');
  client.dio.interceptors.add(interceptor);
  return client;
}

DioException _badResponse(
  RequestOptions options,
  int status, {
  Map<String, List<String>>? headers,
}) => DioException(
  requestOptions: options,
  response: Response(
    requestOptions: options,
    statusCode: status,
    headers: headers == null ? null : Headers.fromMap(headers),
  ),
  type: DioExceptionType.badResponse,
);

Future<AssistantServiceException> _expectFailure(
  Future<AssistantReply> future,
) async {
  try {
    await future;
    fail('expected AssistantServiceException');
  } on AssistantServiceException catch (error) {
    return error;
  }
}

void main() {
  test('sends only text, bounded history and an optional place id', () async {
    late RequestOptions captured;
    final client = _client(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: _payload(),
            ),
          );
        },
      ),
    );
    final service = BackendAssistantService(apiClient: client);
    final reply = await service.send(
      message: 'Расскажи об Исаакиевском соборе',
      history: const [AssistantHistoryTurn(role: 'user', content: 'Привет')],
      placeId: 7,
    );
    expect(reply.answer, contains('Исаакиевский собор'));
    expect(reply.places.single.catalogKey, 'saint-isaacs-cathedral');
    expect(reply.openSmartWalk, isTrue);
    expect(reply.usage.costUsd, 0);
    expect(captured.path, '/assistant/chat');
    expect(captured.headers.containsKey('X-Assistant-Access-Code'), isFalse);
    expect(captured.data['message'], 'Расскажи об Исаакиевском соборе');
    expect(captured.data['context']['place_id'], 7);
    expect(captured.data['context']['walk_context_enabled'], isFalse);
    expect(captured.data['history'], [
      {'role': 'user', 'content': 'Привет'},
    ]);
    expect(captured.data.toString().contains('latitude'), isFalse);
    expect(captured.receiveTimeout, const Duration(seconds: 30));
  });

  test('maps 401 and 403 to the generic unavailable message', () async {
    for (final status in [401, 403]) {
      final client = _client(
        InterceptorsWrapper(
          onRequest: (options, handler) =>
              handler.reject(_badResponse(options, status)),
        ),
      );
      final error = await _expectFailure(
        BackendAssistantService(
          apiClient: client,
        ).send(message: 'Вопрос', history: const []),
      );
      expect(error.code, 'unavailable');
      expect(error.userMessage, contains('Карта и навигация'));
      expect(error.userMessage, isNot(contains('код')));
    }
  });

  test('maps 429 to a clear wait from Retry-After', () async {
    final withHeader = _client(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(
          _badResponse(options, 429, headers: {
            'retry-after': ['120'],
          }),
        ),
      ),
    );
    final limited = await _expectFailure(
      BackendAssistantService(
        apiClient: withHeader,
      ).send(message: 'Вопрос', history: const []),
    );
    expect(limited.code, 'rate_limited');
    expect(limited.userMessage, contains('Повторите через 2 мин.'));

    final withoutHeader = _client(
      InterceptorsWrapper(
        onRequest: (options, handler) =>
            handler.reject(_badResponse(options, 429)),
      ),
    );
    final later = await _expectFailure(
      BackendAssistantService(
        apiClient: withoutHeader,
      ).send(message: 'Вопрос', history: const []),
    );
    expect(later.code, 'rate_limited');
    expect(later.userMessage, contains('Повторите позже'));
  });

  test('maps 422, 400 and 503 to stable friendly errors', () async {
    final cases = {
      400: 'invalid_request',
      422: 'invalid_request',
      503: 'unavailable',
    };
    for (final entry in cases.entries) {
      final client = _client(
        InterceptorsWrapper(
          onRequest: (options, handler) =>
              handler.reject(_badResponse(options, entry.key)),
        ),
      );
      final error = await _expectFailure(
        BackendAssistantService(
          apiClient: client,
        ).send(message: 'Вопрос', history: const []),
      );
      expect(error.code, entry.value);
      expect(error.userMessage, isNotEmpty);
      expect(error.userMessage, isNot(contains('OpenRouter')));
    }
  });

  test('503 uses the exact map-and-navigation fallback wording', () async {
    final client = _client(
      InterceptorsWrapper(
        onRequest: (options, handler) =>
            handler.reject(_badResponse(options, 503)),
      ),
    );
    final error = await _expectFailure(
      BackendAssistantService(
        apiClient: client,
      ).send(message: 'Вопрос', history: const []),
    );
    expect(
      error.userMessage,
      'ИИ-помощник временно недоступен. '
      'Карта и навигация продолжают работать.',
    );
  });

  test('cancel is never converted into a normal answer', () async {
    final client = _client(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            ),
          );
        },
      ),
    );
    final token = CancelToken()..cancel();
    final error = await _expectFailure(
      BackendAssistantService(
        apiClient: client,
      ).send(message: 'Вопрос', history: const [], cancelToken: token),
    );
    expect(error.code, 'cancelled');
  });

  test('network failures and malformed payloads stay unavailable', () async {
    final network = _client(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ),
        ),
      ),
    );
    final networkError = await _expectFailure(
      BackendAssistantService(
        apiClient: network,
      ).send(message: 'Вопрос', history: const []),
    );
    expect(networkError.code, 'unavailable');

    final malformed = _client(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {'status': 'ok'},
          ),
        ),
      ),
    );
    final malformedError = await _expectFailure(
      BackendAssistantService(
        apiClient: malformed,
      ).send(message: 'Вопрос', history: const []),
    );
    expect(malformedError.code, 'unavailable');
  });
}
