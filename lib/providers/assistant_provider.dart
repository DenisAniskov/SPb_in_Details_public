import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/models/assistant_model.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_consent_store.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_service.dart';

enum AssistantMessageKind { user, assistant, error, cancelled }

class AssistantMessage {
  const AssistantMessage._({
    required this.kind,
    required this.text,
    this.reply,
  });

  factory AssistantMessage.user(String text) =>
      AssistantMessage._(kind: AssistantMessageKind.user, text: text);

  factory AssistantMessage.assistant(AssistantReply reply) =>
      AssistantMessage._(
        kind: AssistantMessageKind.assistant,
        text: reply.answer,
        reply: reply,
      );

  factory AssistantMessage.error(String text) =>
      AssistantMessage._(kind: AssistantMessageKind.error, text: text);

  factory AssistantMessage.cancelled() => const AssistantMessage._(
    kind: AssistantMessageKind.cancelled,
    text: 'Запрос отменён.',
  );

  final AssistantMessageKind kind;
  final String text;
  final AssistantReply? reply;

  bool get isUser => kind == AssistantMessageKind.user;
  bool get isAssistant => kind == AssistantMessageKind.assistant;
  bool get isError => kind == AssistantMessageKind.error;
  bool get isCancelled => kind == AssistantMessageKind.cancelled;
}

/// Built-in assistant conversation and versioned consent.
///
/// Messages stay in memory for this session. Only the accepted notice version
/// is persisted locally; the backend key and model never reach the client.
class AssistantProvider extends ChangeNotifier {
  AssistantProvider({
    required AssistantService assistantService,
    AssistantConsentStore? consentStore,
  }) : _service = assistantService,
       _consentStore = consentStore ?? SharedPreferencesAssistantConsentStore() {
    _loadConsent();
  }

  final AssistantService _service;
  final AssistantConsentStore _consentStore;
  final List<AssistantMessage> _messages = [];
  String? _acceptedConsentVersion;
  bool _consentLoading = true;
  bool _consentPersistenceFailed = false;
  bool _disposed = false;
  int? _placeId;
  String? _placeTitle;
  bool _sending = false;
  int _generation = 0;
  CancelToken? _cancelToken;
  String _provisionalText = '';
  String? _provisionalModel;
  Timer? _notifyTimer;
  bool _completedEventSeen = false;

  List<AssistantMessage> get messages => List.unmodifiable(_messages);
  bool get consentLoading => _consentLoading;
  bool get consented =>
      _acceptedConsentVersion == AssistantConsentStore.currentVersion;
  bool get needsConsent => !_consentLoading && !consented;
  bool get consentPersistenceFailed => _consentPersistenceFailed;
  bool get isSending => _sending;

  /// Provisional assistant text while the SSE answer is still unconfirmed.
  /// It is shown in the conversation but never enters [messages] or history.
  String get provisionalText => _provisionalText;
  String? get provisionalModel => _provisionalModel;
  bool get hasProvisionalText => _sending && _provisionalText.isNotEmpty;
  int? get placeId => _placeId;
  String? get placeTitle => _placeTitle;
  bool get hasMessages => _messages.isNotEmpty;

  bool canSend(String text) =>
      !_sending && !_consentLoading && consented && text.trim().isNotEmpty;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadConsent() async {
    String? version;
    try {
      version = await _consentStore.readAcceptedVersion();
    } catch (_) {
      // Fail closed: if the local record cannot be read, ask for consent.
      version = null;
    }
    if (_disposed) return;
    _acceptedConsentVersion = version;
    _consentLoading = false;
    _notify();
  }

  /// Accepting is session-scoped even if the local write fails; the user's
  /// current choice is never discarded because of a storage error.
  Future<void> acceptConsent() async {
    if (_consentLoading) return;
    _acceptedConsentVersion = AssistantConsentStore.currentVersion;
    _consentPersistenceFailed = false;
    _notify();
    try {
      await _consentStore.accept(AssistantConsentStore.currentVersion);
    } catch (_) {
      if (_disposed) return;
      _consentPersistenceFailed = true;
      _notify();
    }
  }

  /// Revocation stops new requests immediately and clears this conversation.
  Future<void> revokeConsent() async {
    _acceptedConsentVersion = null;
    _consentPersistenceFailed = false;
    _generation++;
    _cancelToken?.cancel('consent_revoked');
    _cancelToken = null;
    _cancelScheduledNotify();
    _sending = false;
    _provisionalText = '';
    _provisionalModel = null;
    _messages.clear();
    _notify();
    try {
      await _consentStore.revoke();
    } catch (_) {
      if (_disposed) return;
      _consentPersistenceFailed = true;
      _notify();
    }
  }

  /// The optional place context starts a fresh conversation; reopening the
  /// same place keeps it. Consent survives context changes.
  void prepare({int? placeId, String? placeTitle}) {
    if (placeId != _placeId) {
      _generation++;
      _cancelToken?.cancel('context_changed');
      _cancelToken = null;
      _cancelScheduledNotify();
      _sending = false;
      _provisionalText = '';
      _provisionalModel = null;
      _messages.clear();
    }
    _placeId = placeId;
    _placeTitle = placeId == null ? null : placeTitle;
    _notify();
  }

  Future<void> send(String text) async {
    final message = text.trim();
    if (message.isEmpty || !canSend(message)) return;
    final bounded = message.length > 800 ? message.substring(0, 800) : message;
    final history = _history();
    _messages.add(AssistantMessage.user(bounded));
    _sending = true;
    _provisionalText = '';
    _provisionalModel = null;
    _completedEventSeen = false;
    var sawFailure = false;
    final generation = ++_generation;
    final token = CancelToken();
    _cancelToken = token;
    _notify();
    try {
      await for (final event in _events(
        service: _service,
        message: bounded,
        history: history,
        placeId: _placeId,
        cancelToken: token,
      )) {
        if (generation != _generation) return;
        switch (event) {
          case AssistantStreamStarted():
            _provisionalModel = event.model;
            _notify();
          case AssistantStreamDelta():
            _provisionalText += event.text;
            // Rebuild at most ~30 times per second; an answer can contain
            // hundreds of small fragments and must not rebuild per character.
            _scheduleNotify();
          case AssistantStreamCompleted():
            _cancelScheduledNotify();
            _provisionalText = '';
            _provisionalModel = null;
            _completedEventSeen = true;
            _messages.add(AssistantMessage.assistant(event.reply));
            _notify();
          case AssistantStreamError():
            _cancelScheduledNotify();
            _provisionalText = '';
            _provisionalModel = null;
            sawFailure = true;
            if (event.code == 'cancelled') {
              _messages.add(AssistantMessage.cancelled());
            } else {
              _messages.add(AssistantMessage.error(event.userMessage));
            }
            _notify();
        }
      }
      if (generation != _generation) return;
      if (!_completedEventSeen && !sawFailure) {
        _messages.add(
          AssistantMessage.error(
            'ИИ-помощник временно недоступен. '
            'Карта и навигация продолжают работать.',
          ),
        );
      }
    } on AssistantServiceException catch (error) {
      if (generation != _generation) return;
      _cancelScheduledNotify();
      _provisionalText = '';
      _provisionalModel = null;
      _messages.add(
        error.code == 'cancelled'
            ? AssistantMessage.cancelled()
            : AssistantMessage.error(error.userMessage),
      );
    } catch (_) {
      if (generation != _generation) return;
      _cancelScheduledNotify();
      _provisionalText = '';
      _provisionalModel = null;
      _messages.add(
        AssistantMessage.error(
          'ИИ-помощник временно недоступен. '
          'Карта и навигация продолжают работать.',
        ),
      );
    } finally {
      if (generation == _generation) {
        _cancelScheduledNotify();
        _sending = false;
        _cancelToken = null;
        _provisionalText = '';
        _provisionalModel = null;
        _notify();
      }
    }
  }

  /// Uses a real SSE transport when available; otherwise emits one completed
  /// event from the existing non-streaming [AssistantService.send].
  Stream<AssistantStreamEvent> _events({
    required AssistantService service,
    required String message,
    required List<AssistantHistoryTurn> history,
    required int? placeId,
    required CancelToken? cancelToken,
  }) {
    if (service is StreamingAssistantService) {
      return service.stream(
        message: message,
        history: history,
        placeId: placeId,
        cancelToken: cancelToken,
      );
    }
    return _sendFallback(
      service: service,
      message: message,
      history: history,
      placeId: placeId,
      cancelToken: cancelToken,
    );
  }

  Stream<AssistantStreamEvent> _sendFallback({
    required AssistantService service,
    required String message,
    required List<AssistantHistoryTurn> history,
    required int? placeId,
    required CancelToken? cancelToken,
  }) async* {
    final reply = await service.send(
      message: message,
      history: history,
      placeId: placeId,
      cancelToken: cancelToken,
    );
    yield AssistantStreamStarted(model: reply.model);
    yield AssistantStreamCompleted(reply);
  }

  void _scheduleNotify() {
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 33), () {
      _notifyTimer = null;
      _notify();
    });
  }

  void _cancelScheduledNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
  }

  void cancel() {
    if (!_sending) return;
    _generation++;
    _cancelToken?.cancel('user_cancelled');
    _cancelToken = null;
    _cancelScheduledNotify();
    _sending = false;
    _provisionalText = '';
    _provisionalModel = null;
    _messages.add(AssistantMessage.cancelled());
    _notify();
  }

  Future<void> retryLast() async {
    if (_sending || !consented || _messages.isEmpty) return;
    if (_messages.last.kind != AssistantMessageKind.error) return;
    _messages.removeLast();
    if (_messages.isEmpty || !_messages.last.isUser) {
      _notify();
      return;
    }
    final previous = _messages.removeLast();
    await send(previous.text);
  }

  void clear() {
    _generation++;
    _cancelToken?.cancel('cleared');
    _cancelToken = null;
    _cancelScheduledNotify();
    _sending = false;
    _provisionalText = '';
    _provisionalModel = null;
    _messages.clear();
    _notify();
  }

  List<AssistantHistoryTurn> _history() {
    final turns = <AssistantHistoryTurn>[];
    for (final message in _messages) {
      if (message.isUser) {
        turns.add(AssistantHistoryTurn(role: 'user', content: message.text));
      } else if (message.isAssistant) {
        turns.add(
          AssistantHistoryTurn(role: 'assistant', content: _clip(message.text)),
        );
      }
    }
    if (turns.length > 8) {
      return turns.sublist(turns.length - 8);
    }
    return turns;
  }

  static String _clip(String value) {
    final trimmed = value.trim();
    if (trimmed.length <= 800) return trimmed;
    return '${trimmed.substring(0, 799)}…';
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelToken?.cancel('disposed');
    _cancelScheduledNotify();
    super.dispose();
  }
}
