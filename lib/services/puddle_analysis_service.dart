import 'package:dio/dio.dart';
import 'package:smart_navigator_spb/core/constants/api_constants.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/puddle_analysis_model.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';

enum PuddleAnalysisFailureKind {
  serviceUnavailable,
  invalidResponse,
  requestRejected,
}

class PuddleAnalysisFailure implements Exception {
  final PuddleAnalysisFailureKind kind;
  final String message;
  const PuddleAnalysisFailure(this.kind, this.message);
}

abstract class BasePuddleAnalysisService {
  Future<PuddleAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  });
}

/// Shares the validated geometry/time/byte contract with Shade, without
/// truncating the native polyline or estimating native walking duration.
Map<String, dynamic> buildPuddleAnalyzePayload({
  required DateTime departure,
  required List<RouteLegModel> legs,
  List<int> visitMinutesAfterLeg = const [],
}) {
  try {
    return buildShadeAnalyzePayload(
      departure: departure,
      legs: legs,
      visitMinutesAfterLeg: visitMinutesAfterLeg,
      includeSegments:
          false, // v1 displays an assessment, no unverified overlay.
    );
  } on ShadeAnalysisFailure {
    throw const PuddleAnalysisFailure(
      PuddleAnalysisFailureKind.requestRejected,
      'Маршрут не подходит для оценки мокрых участков: '
      'проверьте ограничения геометрии и времени. Обычная навигация работает.',
    );
  }
}

class BackendPuddleAnalysisService implements BasePuddleAnalysisService {
  final ApiClient _apiClient;
  BackendPuddleAnalysisService({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  @override
  Future<PuddleAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
  }) async {
    final payload = buildPuddleAnalyzePayload(
      departure: departure,
      legs: legs,
      visitMinutesAfterLeg: visitMinutesAfterLeg,
    );
    Response<dynamic> response;
    try {
      response = await _apiClient.dio.post(
        ApiConstants.puddleAnalyzeEndpoint,
        data: payload,
        options: Options(
          receiveTimeout: const Duration(
            milliseconds: ApiConstants.shadeReceiveTimeoutMs,
          ),
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      // An old staging deployment without C7.2 returns 404. That is feature
      // availability, never evidence that the walk itself is invalid.
      if (status == 413) {
        throw const PuddleAnalysisFailure(
          PuddleAnalysisFailureKind.requestRejected,
          'Маршрут слишком подробный для оценки мокрых участков. '
          'Обычная навигация продолжает работать.',
        );
      }
      if (status != null && status >= 400 && status < 500 && status != 404) {
        throw const PuddleAnalysisFailure(
          PuddleAnalysisFailureKind.requestRejected,
          'Сервис не смог оценить этот маршрут. Обычная навигация работает.',
        );
      }
      throw const PuddleAnalysisFailure(
        PuddleAnalysisFailureKind.serviceUnavailable,
        'Оценка мокрых участков сейчас недоступна. Обычная навигация работает.',
      );
    }
    final analysis = PuddleAnalysisModel.tryFromJson(response.data);
    if (analysis == null) {
      throw const PuddleAnalysisFailure(
        PuddleAnalysisFailureKind.invalidResponse,
        'Сервис вернул неполную оценку мокрых участков. Обычная навигация работает.',
      );
    }
    return analysis;
  }
}
