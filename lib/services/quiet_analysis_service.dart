import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:smart_navigator_spb/core/constants/api_constants.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';

enum QuietAnalysisFailureKind {
  serviceUnavailable,
  invalidResponse,
  requestRejected,
}

class QuietAnalysisFailure implements Exception {
  final QuietAnalysisFailureKind kind;
  final String message;
  const QuietAnalysisFailure(this.kind, this.message);

  @override
  String toString() => 'QuietAnalysisFailure(${kind.name}): $message';
}

abstract class BaseQuietAnalysisService {
  Future<QuietAnalysisModel> analyzeWalk({
    required DateTime assessedAt,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeLegs = false,
  });
}

const String quietRouteTooDetailedMessage =
    'Маршрут слишком подробный для оценки тишины. '
    'Обычная навигация продолжает работать.';

/// Builds `/environment/quiet/analyze` from the walk's REAL geometry.
///
/// The document limits are the already validated shade ones (24 legs, 2000
/// points per leg, 5000 in total, 25 km, 16 KiB body). Geometry is never
/// shortened: a walk that does not fit is refused before anything is sent.
Map<String, dynamic> buildQuietAnalyzePayload({
  required DateTime assessedAt,
  required List<RouteLegModel> legs,
  List<int> visitMinutesAfterLeg = const [],
  bool includeLegs = false,
  int maxRequestBytes = ApiConstants.quietMaxRequestBytes,
}) {
  Map<String, dynamic> shadePayload;
  try {
    shadePayload = buildShadeAnalyzePayload(
      departure: assessedAt,
      legs: legs,
      visitMinutesAfterLeg: visitMinutesAfterLeg,
      includeSegments: false,
    );
  } on ShadeAnalysisFailure {
    throw const QuietAnalysisFailure(
      QuietAnalysisFailureKind.requestRejected,
      quietRouteTooDetailedMessage,
    );
  }
  final payload = <String, dynamic>{
    'assessed_at': shadePayload['departure_at'],
    'include_legs': includeLegs,
    'legs': [
      for (final leg in (shadePayload['legs'] as List))
        {'geometry': (leg as Map<String, dynamic>)['geometry']},
    ],
  };
  if (utf8.encode(jsonEncode(payload)).length > maxRequestBytes) {
    throw const QuietAnalysisFailure(
      QuietAnalysisFailureKind.requestRejected,
      quietRouteTooDetailedMessage,
    );
  }
  return payload;
}

class BackendQuietAnalysisService implements BaseQuietAnalysisService {
  final ApiClient _apiClient;
  BackendQuietAnalysisService({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  @override
  Future<QuietAnalysisModel> analyzeWalk({
    required DateTime assessedAt,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeLegs = false,
  }) async {
    final payload = buildQuietAnalyzePayload(
      assessedAt: assessedAt,
      legs: legs,
      visitMinutesAfterLeg: visitMinutesAfterLeg,
      includeLegs: includeLegs,
    );
    Response<dynamic> response;
    try {
      response = await _apiClient.dio.post(
        ApiConstants.quietAnalyzeEndpoint,
        data: payload,
        options: Options(
          receiveTimeout: const Duration(
            milliseconds: ApiConstants.quietReceiveTimeoutMs,
          ),
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 413 ||
          (status != null && status >= 400 && status < 500 && status != 404)) {
        throw const QuietAnalysisFailure(
          QuietAnalysisFailureKind.requestRejected,
          'Сервис не смог оценить этот маршрут. '
          'Обычная навигация продолжает работать.',
        );
      }
      // 404 is an older deployment without C11: availability, not evidence.
      throw const QuietAnalysisFailure(
        QuietAnalysisFailureKind.serviceUnavailable,
        'Оценка тишины сейчас недоступна. Обычная навигация работает.',
      );
    }
    final analysis = QuietAnalysisModel.tryFromJson(response.data);
    if (analysis == null) {
      throw const QuietAnalysisFailure(
        QuietAnalysisFailureKind.invalidResponse,
        'Сервис вернул неполную оценку тишины. '
        'Обычная навигация продолжает работать.',
      );
    }
    return analysis;
  }
}
