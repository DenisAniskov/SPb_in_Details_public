import 'package:dio/dio.dart';
import 'package:smart_navigator_spb/core/constants/api_constants.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/pollen_analysis_model.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';

enum PollenAnalysisFailureKind {
  serviceUnavailable,
  invalidResponse,
  requestRejected,
}

class PollenAnalysisFailure implements Exception {
  final PollenAnalysisFailureKind kind;
  final String message;
  const PollenAnalysisFailure(this.kind, this.message);

  @override
  String toString() => 'PollenAnalysisFailure(${kind.name}): $message';
}

abstract class BasePollenAnalysisService {
  Future<PollenAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  });
}

/// Builds the `/environment/pollen/analyze` body from the walk's REAL geometry.
///
/// The geometry, time and byte contract is the validated shade one (same
/// document limits, same offset-tagged departure, same refusal to shorten a
/// polyline); only the optional-detail flag differs — pollen asks for a
/// per-leg breakdown instead of an overlay. A walk that does not fit is
/// refused here, before anything is sent.
Map<String, dynamic> buildPollenAnalyzePayload({
  required DateTime departure,
  required List<RouteLegModel> legs,
  List<int> visitMinutesAfterLeg = const [],
  bool includeLegs = false,
}) {
  Map<String, dynamic> base;
  try {
    base = buildShadeAnalyzePayload(
      departure: departure,
      legs: legs,
      visitMinutesAfterLeg: visitMinutesAfterLeg,
      includeSegments: false,
    );
  } on ShadeAnalysisFailure {
    throw const PollenAnalysisFailure(
      PollenAnalysisFailureKind.requestRejected,
      'Маршрут не подходит для оценки пыльцы: проверьте ограничения '
      'геометрии и времени. Обычная навигация работает.',
    );
  }
  final payload = Map<String, dynamic>.from(base)..remove('include_segments');
  if (includeLegs) payload['include_legs'] = true;
  return payload;
}

class BackendPollenAnalysisService implements BasePollenAnalysisService {
  final ApiClient _apiClient;
  BackendPollenAnalysisService({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  @override
  Future<PollenAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    final payload = buildPollenAnalyzePayload(
      departure: departure,
      legs: legs,
      visitMinutesAfterLeg: visitMinutesAfterLeg,
    );
    Response<dynamic> response;
    try {
      response = await _apiClient.dio.post(
        ApiConstants.pollenAnalyzeEndpoint,
        data: payload,
        options: Options(
          receiveTimeout: const Duration(
            milliseconds: ApiConstants.shadeReceiveTimeoutMs,
          ),
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      // An older deployment without C7.3 returns 404. That is feature
      // availability, never evidence about the walk or about pollen.
      if (status == 413) {
        throw const PollenAnalysisFailure(
          PollenAnalysisFailureKind.requestRejected,
          'Маршрут слишком подробный для оценки пыльцы. '
          'Обычная навигация продолжает работать.',
        );
      }
      if (status != null && status >= 400 && status < 500 && status != 404) {
        throw const PollenAnalysisFailure(
          PollenAnalysisFailureKind.requestRejected,
          'Сервис не смог оценить этот маршрут. Обычная навигация работает.',
        );
      }
      throw const PollenAnalysisFailure(
        PollenAnalysisFailureKind.serviceUnavailable,
        'Оценка пыльцы сейчас недоступна. Обычная навигация работает.',
      );
    }
    final analysis = PollenAnalysisModel.tryFromJson(response.data);
    if (analysis == null) {
      throw const PollenAnalysisFailure(
        PollenAnalysisFailureKind.invalidResponse,
        'Сервис вернул неполную оценку пыльцы. Обычная навигация работает.',
      );
    }
    return analysis;
  }
}
