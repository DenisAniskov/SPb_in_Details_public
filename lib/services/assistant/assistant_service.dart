import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:smart_navigator_spb/core/constants/api_constants.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/assistant_model.dart';
import 'package:smart_navigator_spb/services/assistant/sse_parser.dart';

class AssistantServiceException implements Exception {
  const AssistantServiceException(this.code, this.userMessage);

  final String code;
  final String userMessage;
}

/// Typed events of the provisional assistant stream. Only
/// [AssistantStreamCompleted] carries a confirmed answer; callers must discard
/// [AssistantStreamDelta] text when an error or cancellation follows.
sealed class AssistantStreamEvent {
  const AssistantStreamEvent();
}

class AssistantStreamStarted extends AssistantStreamEvent {
  const AssistantStreamStarted({this.model});

  final String? model;
}

class AssistantStreamDelta extends AssistantStreamEvent {
  const AssistantStreamDelta(this.text);

  final String text;
}

class AssistantStreamCompleted extends AssistantStreamEvent {
  const AssistantStreamCompleted(this.reply);

  final AssistantReply reply;
}

class AssistantStreamError extends AssistantStreamEvent {
  const AssistantStreamError(
    this.code,
    this.userMessage, {
    this.retryAfterSeconds,
  });

  final String code;
  final String userMessage;
  final int? retryAfterSeconds;
}

abstract class AssistantService {
  Future<AssistantReply> send({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
    CancelToken? cancelToken,
  });
}

/// Optional SSE transport. The provider checks for this interface at runtime
/// so non-streaming test doubles and alternative transports stay compatible
/// with the single [AssistantService.send] contract.
abstract interface class StreamingAssistantService
    implements AssistantService {
  Stream<AssistantStreamEvent> stream({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
    CancelToken? cancelToken,
  });
}

class BackendAssistantService implements StreamingAssistantService {
  BackendAssistantService({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  static const String _unavailableMessage =
      'ИИ-помощник временно недоступен. '
      'Карта и навигация продолжают работать.';

  final ApiClient _apiClient;

  @override
  Future<AssistantReply> send({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _apiClient.dio.post<dynamic>(
        ApiConstants.assistantChatEndpoint,
        data: {
          'message': message,
          'history': history.map((turn) => turn.toJson()).toList(),
          'context': {
            if (placeId != null) 'place_id': placeId,
            'walk_context_enabled': walkContextEnabled,
          },
        },
        options: Options(
          receiveTimeout: const Duration(
            milliseconds: ApiConstants.assistantReceiveTimeoutMs,
          ),
          sendTimeout: const Duration(seconds: 10),
        ),
        cancelToken: cancelToken,
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw const FormatException('Invalid assistant response');
      }
      return AssistantReply.fromJson(data);
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw const AssistantServiceException('cancelled', 'Запрос отменён.');
      }
      final status = error.response?.statusCode;
      if (status == 429) {
        throw AssistantServiceException(
          'rate_limited',
          _rateLimitMessage(error),
        );
      }
      if (status == 422 || status == 400) {
        throw const AssistantServiceException(
          'invalid_request',
          'Не удалось отправить вопрос. Проверьте текст и выбранное место.',
        );
      }
      throw const AssistantServiceException(
        'unavailable',
        _unavailableMessage,
      );
    } on AssistantServiceException {
      rethrow;
    } on FormatException {
      throw const AssistantServiceException(
        'unavailable',
        _unavailableMessage,
      );
    } catch (_) {
      throw const AssistantServiceException(
        'unavailable',
        _unavailableMessage,
      );
    }
  }

  Map<String, dynamic> _payload({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
  }) => {
    'message': message,
    'history': history.map((turn) => turn.toJson()).toList(),
    'context': {
      if (placeId != null) 'place_id': placeId,
      'walk_context_enabled': walkContextEnabled,
    },
  };

  @override
  Stream<AssistantStreamEvent> stream({
    required String message,
    required List<AssistantHistoryTurn> history,
    int? placeId,
    bool walkContextEnabled = false,
    CancelToken? cancelToken,
  }) async* {
    final parser = SseParser();
    var completed = false;
    try {
      final response = await _apiClient.dio.post<ResponseBody>(
        ApiConstants.assistantStreamEndpoint,
        data: _payload(
          message: message,
          history: history,
          placeId: placeId,
          walkContextEnabled: walkContextEnabled,
        ),
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(
            milliseconds: ApiConstants.assistantStreamIdleTimeoutMs,
          ),
          sendTimeout: const Duration(seconds: 10),
          headers: {'Accept': 'text/event-stream'},
        ),
        cancelToken: cancelToken,
      );
      final body = response.data;
      if (body == null) {
        yield const AssistantStreamError('unavailable', _unavailableMessage);
        return;
      }
      // `utf8.decoder.bind` handles multi-byte characters split across
      // network chunks; a per-chunk `utf8.decode` would corrupt Cyrillic.
      await for (final text in utf8.decoder.bind(body.stream)) {
        for (final frame in parser.add(text)) {
          final event = _eventFromFrame(frame);
          if (event == null) continue;
          if (event is AssistantStreamError) {
            yield event;
            return;
          }
          if (event is AssistantStreamCompleted) completed = true;
          yield event;
        }
      }
      for (final frame in parser.close()) {
        final event = _eventFromFrame(frame);
        if (event == null) continue;
        if (event is AssistantStreamError) {
          yield event;
          return;
        }
        if (event is AssistantStreamCompleted) completed = true;
        yield event;
      }
      if (!completed) {
        // The stream ended without the server-confirmed final event. Any
        // earlier fragments were provisional and must not be treated as an
        // answer.
        yield const AssistantStreamError('incomplete', _unavailableMessage);
      }
    } on DioException catch (error) {
      yield _streamDioError(error);
    } on FormatException {
      yield const AssistantStreamError('unavailable', _unavailableMessage);
    } catch (_) {
      yield const AssistantStreamError('unavailable', _unavailableMessage);
    }
  }

  AssistantStreamEvent? _eventFromFrame(SseFrame frame) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(frame.data);
    } catch (_) {
      throw const FormatException('Invalid SSE payload');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid SSE payload');
    }
    switch (frame.event) {
      case 'started':
        final model = decoded['model'];
        return AssistantStreamStarted(model: model is String ? model : null);
      case 'delta':
        final text = decoded['text'];
        if (text is! String || text.isEmpty) {
          throw const FormatException('Invalid SSE delta');
        }
        return AssistantStreamDelta(text);
      case 'completed':
        return AssistantStreamCompleted(AssistantReply.fromJson(decoded));
      case 'error':
        final code = decoded['code'];
        final message = decoded['message'];
        final retry = decoded['retry_after_seconds'];
        return AssistantStreamError(
          code is String && code.isNotEmpty ? code : 'unavailable',
          message is String && message.isNotEmpty && message.length <= 300
              ? message
              : _unavailableMessage,
          retryAfterSeconds: retry is int && retry > 0 ? retry : null,
        );
      default:
        // Forward-compatible: unknown typed events are ignored.
        return null;
    }
  }

  AssistantStreamError _streamDioError(DioException error) {
    if (error.type == DioExceptionType.cancel) {
      return const AssistantStreamError('cancelled', 'Запрос отменён.');
    }
    final status = error.response?.statusCode;
    if (status == 429) {
      final raw = error.response?.headers.value('retry-after')?.trim();
      final seconds = int.tryParse(raw ?? '');
      return AssistantStreamError(
        'rate_limited',
        _rateLimitMessage(error),
        retryAfterSeconds: seconds != null && seconds > 0 ? seconds : null,
      );
    }
    if (status == 422 || status == 400) {
      return const AssistantStreamError(
        'invalid_request',
        'Не удалось отправить вопрос. Проверьте текст и выбранное место.',
      );
    }
    return const AssistantStreamError('unavailable', _unavailableMessage);
  }

  String _rateLimitMessage(DioException error) {
    final raw = error.response?.headers.value('retry-after')?.trim();
    final seconds = int.tryParse(raw ?? '');
    if (seconds == null || seconds <= 0) {
      return 'Лимит запросов к ИИ-помощнику исчерпан. Повторите позже.';
    }
    final wait = seconds < 60
        ? '$seconds сек.'
        : seconds < 3600
        ? '${(seconds / 60).ceil()} мин.'
        : '${(seconds / 3600).ceil()} ч.';
    return 'Лимит запросов к ИИ-помощнику исчерпан. '
        'Повторите через $wait';
  }
}
