import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/core/network/ui_error.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/guest_experience_provider.dart';

enum PlacesStatus { initial, loading, success, error }

class PlacesProvider extends ChangeNotifier {
  final PlacesRepository _repository;

  PlacesProvider({PlacesRepository? repository, GuestExperienceProvider? guest})
    : _repository = repository ?? PlacesRepository(),
      _guest = guest {
    if (guest != null) {
      _selectedCategories.addAll(guest.categories);
      _isUnusualOnly = guest.preferUnusual;
      guest.addListener(_guestPreferencesChanged);
    }
    loadPlaces();
    loadCategories();
  }

  PlacesStatus _status = PlacesStatus.initial;
  List<PlaceModel> _places = const [];
  List<CategoryModel> _categories = const [];
  final Set<PlaceCategoryEnum> _selectedCategories = {};
  bool _isUnusualOnly = false;
  String _searchQuery = '';
  PlaceModel? _selectedPlace;
  String? _errorMessage;
  int _requestId = 0;
  bool _disposed = false;
  Timer? _searchTimer;
  final GuestExperienceProvider? _guest;

  void _guestPreferencesChanged() {
    final guest = _guest!;
    if (_disposed ||
        (setEquals(_selectedCategories, guest.categories) &&
            _isUnusualOnly == guest.preferUnusual)) {
      return;
    }
    _selectedCategories
      ..clear()
      ..addAll(guest.categories);
    _isUnusualOnly = guest.preferUnusual;
    // Same pagination, cancellation, stale-response guard and errors as filters.
    unawaited(loadPlaces());
  }

  PlacesStatus get status => _status;
  List<PlaceModel> get places => _places;
  List<CategoryModel> get categories => _categories;
  Set<PlaceCategoryEnum> get selectedCategories =>
      Set.unmodifiable(_selectedCategories);
  bool get isUnusualOnly => _isUnusualOnly;
  String get searchQuery => _searchQuery;
  PlaceModel? get selectedPlace => _selectedPlace;
  String? get errorMessage => _errorMessage;

  bool get isLoading => _status == PlacesStatus.loading;
  bool get hasError => _status == PlacesStatus.error;
  bool get isEmpty => _status == PlacesStatus.success && _places.isEmpty;

  Future<void> loadPlaces() async {
    _searchTimer?.cancel();
    final requestId = ++_requestId;
    _status = PlacesStatus.loading;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await _repository.getPlaces(
        categories: _selectedCategories.isEmpty
            ? null
            : _selectedCategories.toList(),
        isUnusual: _isUnusualOnly ? true : null,
        searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
      );
      if (_disposed || requestId != _requestId) return;
      // Preserve the old immutable snapshot for the map's update comparison,
      // even if the repository retains and later mutates its result list.
      _places = List.unmodifiable(result);
      if (!_places.any((p) => p.id == _selectedPlace?.id)) {
        _selectedPlace = null;
      }
      _status = PlacesStatus.success;
    } catch (e, stackTrace) {
      if (_disposed || requestId != _requestId) return;
      _places = const [];
      _selectedPlace = null;
      // Phase A6.6: a raw exception dump can carry the request URI with the
      // user's filter and query text into logcat, so only the failure type is
      // printed; the sanitized message is already produced by placesUiError.
      debugPrint('PlacesProvider error: ${e.runtimeType}\n$stackTrace');
      _errorMessage = placesUiError(e);
      _status = PlacesStatus.error;
    }
    notifyListeners();
  }

  Future<void> loadCategories() async {
    try {
      final result = await _repository.getCategories();
      if (_disposed) return;
      _categories = List.unmodifiable(result);
      notifyListeners();
    } catch (_) {}
  }

  void toggleCategory(PlaceCategoryEnum category) {
    if (_selectedCategories.contains(category)) {
      _selectedCategories.remove(category);
    } else {
      _selectedCategories.add(category);
    }
    loadPlaces();
    if (_guest != null) unawaited(_guest.setCategories(selectedCategories));
  }

  void clearCategories() {
    _selectedCategories.clear();
    loadPlaces();
    if (_guest != null) unawaited(_guest.setCategories(selectedCategories));
  }

  void toggleUnusualOnly() {
    _isUnusualOnly = !_isUnusualOnly;
    loadPlaces();
    if (_guest != null) unawaited(_guest.setPreferUnusual(_isUnusualOnly));
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    ++_requestId; // Invalidate responses for the previous text immediately.
    _searchTimer?.cancel();
    _places = const [];
    _selectedPlace = null;
    _status = PlacesStatus.loading;
    _errorMessage = null;
    notifyListeners();
    _searchTimer = Timer(const Duration(milliseconds: 300), loadPlaces);
  }

  void selectPlace(PlaceModel? place) {
    _selectedPlace = place;
    notifyListeners();
  }

  void clearFilters() {
    _selectedCategories.clear();
    _isUnusualOnly = false;
    _searchQuery = '';
    loadPlaces();
    if (_guest != null) {
      unawaited(
        _guest.setCatalogPreferences(
          categories: selectedCategories,
          preferUnusual: false,
        ),
      );
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _guest?.removeListener(_guestPreferencesChanged);
    _disposed = true;
    ++_requestId;
    super.dispose();
  }
}
