import 'package:dio/dio.dart';
import 'package:smart_navigator_spb/core/constants/api_constants.dart';

class ApiClient {
  late final Dio dio;
  String _baseUrl;

  ApiClient({String? customBaseUrl})
    : _baseUrl = customBaseUrl ?? ApiConstants.defaultBaseUrl {
    dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        listFormat: ListFormat.multi,
        connectTimeout: const Duration(
          milliseconds: ApiConstants.connectTimeoutMs,
        ),
        receiveTimeout: const Duration(
          milliseconds: ApiConstants.receiveTimeoutMs,
        ),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      ),
    );
  }

  void updateBaseUrl(String newBaseUrl) {
    _baseUrl = newBaseUrl;
    dio.options.baseUrl = newBaseUrl;
  }

  String get currentBaseUrl => _baseUrl;
}
