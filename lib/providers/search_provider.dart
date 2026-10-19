import 'package:smart_navigator_spb/core/network/ui_error.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/suggest_item_model.dart';
import 'package:smart_navigator_spb/data/repositories/search_repository.dart';

class SearchProvider extends ChangeNotifier {
  final SearchRepository _repository;

  SearchProvider({SearchRepository? repository})
    : _repository = repository ?? SearchRepository();

  String _searchQuery = '';
  List<SuggestItemModel> _suggestResults = [];
  bool _isLoadingSuggest = false;
  bool _isGeocoding = false;
  ExternalMapPoint? _selectedExternalPoint;
  String? _errorMessage;

  Timer? _debounceTimer;
  int _searchRequestId = 0;
  int _resolveRequestId = 0;
  bool _disposed = false;

  String get searchQuery => _searchQuery;
  List<SuggestItemModel> get suggestResults =>
      List.unmodifiable(_suggestResults);
  bool get isLoadingSuggest => _isLoadingSuggest;
  bool get isGeocoding => _isGeocoding;
  ExternalMapPoint? get selectedExternalPoint => _selectedExternalPoint;
  String? get errorMessage => _errorMessage;

  bool get hasSuggestResults => _suggestResults.isNotEmpty;

  void setSearchQuery(String query) {
    if (query.trim() == _searchQuery.trim()) return;
    _searchQuery = query;
    _searchRequestId++;
    _resolveRequestId++;
    _debounceTimer?.cancel();
    _errorMessage = null;
    _isGeocoding = false;
    _selectedExternalPoint = null;
    _suggestResults = [];

    final trimmed = query.trim();
    if (trimmed.length > 150) {
      _suggestResults = [];
      _isLoadingSuggest = false;
      _errorMessage = 'Поисковый запрос не должен превышать 150 символов.';
      notifyListeners();
      return;
    }
    if (trimmed.length < 2) {
      _suggestResults = [];
      _isLoadingSuggest = false;
      notifyListeners();
      return;
    }

    _isLoadingSuggest = true;
    notifyListeners();

    _debounceTimer = Timer(const Duration(milliseconds: 350), () {
      _fetchSuggestions(trimmed, _searchRequestId);
    });
  }

  Future<void> _fetchSuggestions(String query, int requestId) async {
    try {
      final results = await _repository.getSuggestions(query);
      if (_disposed || requestId != _searchRequestId) return;

      _suggestResults = results;
      _isLoadingSuggest = false;
      _errorMessage = null;
    } catch (e) {
      if (_disposed || requestId != _searchRequestId) return;
      _suggestResults = [];
      _isLoadingSuggest = false;
      _errorMessage = searchUiError(e);
    }
    notifyListeners();
  }

  /// Геокодирование выбранной подсказки Яндекса в координаты
  Future<ExternalMapPoint?> resolveSuggestion(SuggestItemModel item) async {
    final requestId = ++_resolveRequestId;
    ++_searchRequestId;
    _debounceTimer?.cancel();
    _isLoadingSuggest = false;
    _suggestResults = [];
    _isGeocoding = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final point = await _repository.resolveGeocode(
        uri: item.uri,
        text: [
          item.title,
          if (item.subtitle != null) item.subtitle!,
        ].join(', '),
      );
      if (_disposed || requestId != _resolveRequestId) return null;

      _selectedExternalPoint = point;
      _suggestResults = [];
      _isGeocoding = false;
      notifyListeners();
      return point;
    } catch (e) {
      if (_disposed || requestId != _resolveRequestId) return null;
      _isGeocoding = false;
      _errorMessage = searchUiError(e);
      notifyListeners();
      return null;
    }
  }

  /// Обратное геокодирование точки по координатам (например, при клике на карте)
  Future<ExternalMapPoint?> reverseGeocodeCoordinates(
    double lat,
    double lon,
  ) async {
    try {
      return await _repository.reverseGeocode(latitude: lat, longitude: lon);
    } catch (_) {
      return null;
    }
  }

  void selectExternalPoint(ExternalMapPoint? point) {
    ++_resolveRequestId;
    ++_searchRequestId;
    _debounceTimer?.cancel();
    _isGeocoding = false;
    _isLoadingSuggest = false;
    _selectedExternalPoint = point;
    _suggestResults = [];
    _errorMessage = null;
    notifyListeners();
  }

  void clearSearch() {
    ++_resolveRequestId;
    _searchRequestId++;
    _debounceTimer?.cancel();
    _searchQuery = '';
    _suggestResults = [];
    _isLoadingSuggest = false;
    _isGeocoding = false;
    _selectedExternalPoint = null;
    _errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_searchRequestId;
    ++_resolveRequestId;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
