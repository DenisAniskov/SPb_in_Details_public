import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/models/historical_content_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';

/// Phase C6 §8: lazy, cached access to verified historical cards.
///
/// - History is fetched per viewed place, never for the whole catalogue.
/// - A confirmed absence (history: null) is cached too, so the same place
///   does not trigger repeated requests.
/// - Every request carries a per-place token: a late response for a retried
///   or disposed place can never override newer data (stale-response guard).
/// - Failures are recorded as a soft per-place flag with an explicit retry,
///   never shown as fake «history not found» content.
class HistoricalContentProvider extends ChangeNotifier {
  final PlacesRepository _repository;

  HistoricalContentProvider({required this._repository});

  final Map<int, HistoricalContent?> _cache = {};
  final Map<int, int> _requestTokens = {};
  final Set<int> _loading = {};
  final Set<int> _failed = {};

  /// Places whose fetch is scheduled but has not started yet: deduplicates
  /// repeated `ensureLoaded` calls that happen inside one build pass.
  final Set<int> _scheduled = {};
  bool _disposed = false;

  /// Card for a place, or null when absent/unknown/not loaded yet.
  HistoricalContent? contentFor(int placeId) => _cache[placeId];

  bool isLoading(int placeId) => _loading.contains(placeId);

  bool hasFailed(int placeId) => _failed.contains(placeId);

  /// A response — including a confirmed `history: null` — has been cached.
  /// This distinguishes "the backend says there is no card" from "the request
  /// has not completed yet", which are different UI states.
  bool hasResolved(int placeId) => _cache.containsKey(placeId);

  /// Requests the card once; safe to call on every rebuild — the fetch is
  /// scheduled as a microtask so `notifyListeners` never fires during build.
  /// A place with a pending microtask is marked in [_scheduled], so several
  /// calls before the microtask runs still produce a single request.
  /// A failed place stays failed until the user asks for a retry: rebuilds
  /// must not turn one backend failure into an endless request loop.
  void ensureLoaded(PlaceModel place) {
    final id = place.id;
    if (_cache.containsKey(id) ||
        _loading.contains(id) ||
        _failed.contains(id) ||
        _scheduled.contains(id)) {
      return;
    }
    _scheduled.add(id);
    scheduleMicrotask(() => unawaited(_fetch(id)));
  }

  /// Explicit user retry after a failure: drops the failure flag and
  /// refetches with a fresh token. A retry is an explicit user action, so it
  /// deliberately supersedes a request that is still in flight (the token
  /// guard drops its late response); only a not-yet-started fetch is deduped.
  void retry(PlaceModel place) {
    final id = place.id;
    _failed.remove(id);
    _cache.remove(id);
    if (_scheduled.contains(id)) return;
    _scheduled.add(id);
    scheduleMicrotask(() => unawaited(_fetch(id)));
  }

  Future<void> _fetch(int placeId) async {
    _scheduled.remove(placeId);
    if (_disposed) return;
    final token = (_requestTokens[placeId] ?? 0) + 1;
    _requestTokens[placeId] = token;
    _loading.add(placeId);
    notifyListeners();
    try {
      final content = await _repository.getPlaceHistory(placeId);
      if (_disposed || _requestTokens[placeId] != token) return;
      _cache[placeId] = content;
      _failed.remove(placeId);
    } catch (error) {
      debugPrint('HistoricalContentProvider error for place $placeId: $error');
      if (_disposed || _requestTokens[placeId] != token) return;
      _failed.add(placeId);
    } finally {
      _loading.remove(placeId);
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
