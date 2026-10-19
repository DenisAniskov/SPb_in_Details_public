// Regression: a successful point selection must clear a stale search failure
// banner. Without this, the user picks a valid place and still sees an error
// from the previous failed suggest request.
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/suggest_item_model.dart';
import 'package:smart_navigator_spb/data/repositories/search_repository.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';

class _FailingSuggestRepository extends SearchRepository {
  _FailingSuggestRepository() : super();

  @override
  Future<List<SuggestItemModel>> getSuggestions(String query, {int limit = 7}) async {
    throw Exception('Время ожидания ответа от сервиса поиска истекло.');
  }
}

void main() {
  test('selecting a point after a failed search clears the stale error', () async {
    final provider = SearchProvider(repository: _FailingSuggestRepository());

    provider.setSearchQuery('Невский');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    await Future<void>.delayed(Duration.zero);
    expect(provider.errorMessage, isNotNull, reason: 'setup: search must have failed');

    provider.selectExternalPoint(const ExternalMapPoint(
      title: 'Точка',
      latitude: 59.94,
      longitude: 30.31,
    ));
    expect(provider.errorMessage, isNull,
        reason: 'a successful selection must not keep a stale failure banner');
    expect(provider.selectedExternalPoint, isNotNull);
  });
}
