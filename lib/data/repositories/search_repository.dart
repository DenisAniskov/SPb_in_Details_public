import 'package:dio/dio.dart';
import 'package:smart_navigator_spb/core/constants/api_constants.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/suggest_item_model.dart';

class SearchRepository {
  final ApiClient _apiClient;

  SearchRepository({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  /// Получение подсказок (Geosuggest) по тексту запроса
  Future<List<SuggestItemModel>> getSuggestions(
    String query, {
    int limit = 7,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    try {
      final response = await _apiClient.dio.get(
        ApiConstants.searchSuggestEndpoint,
        queryParameters: {'text': trimmed, 'results': limit},
      );

      final data = response.data;
      if (data is Map<String, dynamic> && data['results'] is List) {
        return (data['results'] as List)
            .map(
              (item) => SuggestItemModel.fromJson(item as Map<String, dynamic>),
            )
            .toList();
      }
      return [];
    } on DioException catch (e) {
      throw _handleDioError(e, 'Не удалось получить поисковые подсказки');
    } catch (e) {
      throw Exception('Ошибка поиска. Попробуйте ещё раз.');
    }
  }

  /// Получение точных координат по URI или текстовому названию (Geocoder)
  Future<ExternalMapPoint> resolveGeocode({String? text, String? uri}) async {
    if ((text == null || text.trim().isEmpty) &&
        (uri == null || uri.trim().isEmpty)) {
      throw ArgumentError(
        'Необходимо указать текст или URI для геокодирования',
      );
    }

    try {
      final queryParams = <String, dynamic>{};
      if (uri != null && uri.trim().isNotEmpty) {
        queryParams['uri'] = uri.trim();
      } else if (text != null && text.trim().isNotEmpty) {
        queryParams['text'] = text.trim();
      }

      final response = await _apiClient.dio.get(
        ApiConstants.searchGeocodeEndpoint,
        queryParameters: queryParams,
      );

      if (response.data is Map<String, dynamic>) {
        return ExternalMapPoint.fromJson(
          response.data as Map<String, dynamic>,
          source: 'yandex_geocode',
        );
      }
      throw Exception('Некорректный формат ответа геокодера');
    } on DioException catch (e) {
      throw _handleDioError(
        e,
        'Не удалось определить координаты выбранного объекта',
      );
    } catch (e) {
      throw Exception('Ошибка геокодирования. Попробуйте ещё раз.');
    }
  }

  /// Обратное геокодирование точки на карте (Reverse Geocoding)
  Future<ExternalMapPoint> reverseGeocode({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final response = await _apiClient.dio.get(
        ApiConstants.searchReverseGeocodeEndpoint,
        queryParameters: {'lat': latitude, 'lon': longitude},
      );

      if (response.data is Map<String, dynamic>) {
        return ExternalMapPoint.fromJson(
          response.data as Map<String, dynamic>,
          source: 'map_tap',
        );
      }
      throw Exception('Не удалось распознать адрес точки');
    } on DioException catch (e) {
      throw _handleDioError(e, 'Не удалось определить адрес по координатам');
    } catch (e) {
      throw Exception('Ошибка обратного геокодирования. Попробуйте ещё раз.');
    }
  }

  Exception _handleDioError(DioException error, String fallbackMessage) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return Exception('Время ожидания ответа от сервиса поиска истекло.');
    } else if (error.type == DioExceptionType.connectionError) {
      return Exception('Нет связи с сервером поиска. Проверьте сеть.');
    }

    final statusCode = error.response?.statusCode;
    if (statusCode == 429) {
      return Exception(
        'Превышен лимит запросов поиска. Повторите попытку через минуту.',
      );
    } else if (statusCode == 404) {
      return Exception('Объект не найден на карте.');
    } else if (statusCode != null && statusCode >= 500) {
      return Exception('Сервис поиска временно недоступен.');
    }

    return Exception(fallbackMessage);
  }
}
