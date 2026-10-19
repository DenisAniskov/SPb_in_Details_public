import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:smart_navigator_spb/core/constants/api_constants.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/core/utils/route_projection_utils.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';

/// Typed failure kinds for shade requests (§13.2): the UI shows a clear
/// Russian message per kind and never a technical code.
enum ShadeAnalysisFailureKind {
  /// The backend could not be reached (offline, not deployed, timeout).
  serviceUnavailable,

  /// The backend answered, but not with a usable estimate payload.
  invalidResponse,

  /// The request was rejected (route too long, too many points, bad time).
  requestRejected,

  /// Normal navigation keeps working; shade analysis is simply unavailable.
  unsupportedEnvironment,
}

class ShadeAnalysisFailure implements Exception {
  final ShadeAnalysisFailureKind kind;
  final String message;
  final String? detail;

  const ShadeAnalysisFailure(this.kind, this.message, {this.detail});

  @override
  String toString() => 'ShadeAnalysisFailure(${kind.name}): $message';
}

/// ISO-8601 WITH the local UTC offset.
///
/// Dart's ``DateTime.toIso8601String()`` omits the offset for local times, and
/// the shade backend rejects naive datetimes on purpose (an assumed zone would
/// be an invented value).
String iso8601WithOffset(DateTime value) {
  final local = value.isUtc ? value.toLocal() : value;
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hours = offset.inHours.abs().toString().padLeft(2, '0');
  final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
  return '${local.toIso8601String()}$sign$hours:$minutes';
}

/// Contract for the shade backend, injectable so tests never touch the network.
abstract class BaseShadeAnalysisService {
  /// Analyses one walk (its real legs) as of [departure].
  ///
  /// [legs] must carry the REAL geometry and native walking durations of the
  /// route being evaluated; [visitMinutesAfterLeg] matches the walk's visit
  /// times so the moving sun is modelled correctly.
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  });
}

/// Document-level limits of the shade contract (§11.3), mirrored from the
/// staging backend: 24 legs, 2..2000 points per leg, at most 5000 points,
/// 25 km of walk, at most 6 h of walking per leg and 24 h of visiting.
///
/// Phase A6.3: a walk outside this contract is refused with a typed error.
/// Geometry is never shortened to fit — the backend would receive a different
/// polyline with the original duration and report shade for a walk nobody
/// takes.
class ShadeRequestLimits {
  static const int maxLegs = 24;
  static const int minPointsPerLeg = 2;
  static const int maxPointsPerLeg = 2000;
  static const int maxTotalPoints = 5000;
  static const double maxRouteLengthMeters = 25000;
  static const double maxWalkingDurationSeconds = 6 * 3600;
  static const double maxVisitDurationSeconds = 24 * 3600;

  /// Mirrors the backend's `REQUEST_MAX_BYTES` (see [ApiConstants]).
  static const int maxRequestBytes = ApiConstants.shadeMaxRequestBytes;
}

/// Shown when the walk is too detailed or too long for one whole analysis.
/// Normal navigation keeps working; nothing is estimated from partial geometry.
const String shadeRouteTooDetailedMessage =
    'Маршрут слишком подробный для оценки тени. Обычная навигация продолжает работать.';

/// Builds the `/environment/shade/analyze` body from the walk's REAL geometry.
///
/// Throws [ShadeAnalysisFailure] of kind `requestRejected` when the walk does
/// not fit the analysable contract. Every check happens before the request
/// leaves the device, and the returned payload is byte-identical to what will
/// be sent (the encoded size is measured on it).
Map<String, dynamic> buildShadeAnalyzePayload({
  required DateTime departure,
  required List<RouteLegModel> legs,
  List<int> visitMinutesAfterLeg = const [],
  bool includeSegments = true,
  int maxRequestBytes = ShadeRequestLimits.maxRequestBytes,
}) {
  ShadeAnalysisFailure reject(String message) =>
      ShadeAnalysisFailure(ShadeAnalysisFailureKind.requestRejected, message);

  if (legs.isEmpty) {
    throw reject('У маршрута нет этапов для оценки тени.');
  }
  if (legs.length > ShadeRequestLimits.maxLegs) {
    throw reject('Слишком много этапов для одного расчёта тени.');
  }

  var totalPoints = 0;
  var totalLengthMeters = 0.0;
  final payloadLegs = <Map<String, dynamic>>[];
  for (var i = 0; i < legs.length; ++i) {
    final leg = legs[i];
    final points = leg.geometryPoints;
    if (points.length < ShadeRequestLimits.minPointsPerLeg) {
      throw reject('Этап ${i + 1}: для оценки тени нужны минимум две точки.');
    }
    if (points.length > ShadeRequestLimits.maxPointsPerLeg) {
      throw reject(shadeRouteTooDetailedMessage);
    }
    for (final point in points) {
      if (!point.latitude.isFinite ||
          !point.longitude.isFinite ||
          point.latitude.abs() > 90 ||
          point.longitude.abs() > 180) {
        throw reject('Этап ${i + 1}: геометрия содержит некорректные координаты.');
      }
    }
    final durationSeconds = leg.durationSeconds;
    if (durationSeconds <= 0 ||
        durationSeconds > ShadeRequestLimits.maxWalkingDurationSeconds) {
      throw reject('Этап ${i + 1}: некорректная длительность ходьбы.');
    }
    final visitMinutes =
        i < visitMinutesAfterLeg.length ? visitMinutesAfterLeg[i] : 0;
    if (visitMinutes < 0 ||
        visitMinutes * 60 > ShadeRequestLimits.maxVisitDurationSeconds) {
      throw reject('Этап ${i + 1}: некорректное время осмотра.');
    }
    totalPoints += points.length;
    totalLengthMeters += RouteProjectionUtils.polylineLengthMeters(points);
    payloadLegs.add({
      'geometry': [
        for (final point in points)
          {'latitude': point.latitude, 'longitude': point.longitude},
      ],
      'walking_duration_seconds': durationSeconds,
      'visit_duration_seconds_after_leg': visitMinutes * 60,
    });
  }

  if (totalPoints > ShadeRequestLimits.maxTotalPoints) {
    throw reject(shadeRouteTooDetailedMessage);
  }
  if (totalLengthMeters > ShadeRequestLimits.maxRouteLengthMeters) {
    throw reject(
      'Маршрут длиннее лимита анализа тени '
      '(${ShadeRequestLimits.maxRouteLengthMeters ~/ 1000} км).',
    );
  }

  final payload = <String, dynamic>{
    'departure_at': iso8601WithOffset(departure),
    'include_segments': includeSegments,
    'legs': payloadLegs,
  };
  if (utf8.encode(jsonEncode(payload)).length > maxRequestBytes) {
    throw reject(shadeRouteTooDetailedMessage);
  }
  return payload;
}

/// Backend implementation of the shade analysis contract.
class BackendShadeAnalysisService implements BaseShadeAnalysisService {
  /// §11.3: the backend refuses longer walks with a typed rejection.
  static const int maxLegs = ShadeRequestLimits.maxLegs;
  static const int maxPointsPerLeg = ShadeRequestLimits.maxPointsPerLeg;

  final ApiClient _apiClient;

  BackendShadeAnalysisService({ApiClient? apiClient})
    : _apiClient = apiClient ?? ApiClient();

  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async {
    final payload = buildShadeAnalyzePayload(
      departure: departure,
      legs: legs,
      visitMinutesAfterLeg: visitMinutesAfterLeg,
      includeSegments: includeSegments,
    );

    Response<dynamic> response;
    try {
      response = await _apiClient.dio.post(
        ApiConstants.shadeAnalyzeEndpoint,
        data: payload,
        // Phase A6.5: a dedicated receive budget — the engine may legally take
        // up to 10 s on the server. A timeout is a service problem, never a
        // route problem: the walk itself keeps working.
        options: Options(
          receiveTimeout: const Duration(
            milliseconds: ApiConstants.shadeReceiveTimeoutMs,
          ),
        ),
      );
    } on DioException catch (error) {
      throw _mapDioError(error);
    }

    final parsed = ShadeAnalysisModel.tryFromJson(response.data);
    if (parsed == null) {
      throw const ShadeAnalysisFailure(
        ShadeAnalysisFailureKind.invalidResponse,
        'Сервис оценки тени вернул неожиданный ответ.',
      );
    }
    return parsed;
  }

  ShadeAnalysisFailure _mapDioError(DioException error) {
    final status = error.response?.statusCode;
    if (status == 413) {
      // The server's body cap is the authority; the local check mirrors it.
      return const ShadeAnalysisFailure(
        ShadeAnalysisFailureKind.requestRejected,
        shadeRouteTooDetailedMessage,
        detail: 'HTTP 413',
      );
    }
    if (status != null && status >= 400 && status < 500) {
      return ShadeAnalysisFailure(
        ShadeAnalysisFailureKind.requestRejected,
        'Запрос оценки тени отклонён сервисом.',
        detail: 'HTTP $status',
      );
    }
    if (error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.connectionTimeout) {
      return const ShadeAnalysisFailure(
        ShadeAnalysisFailureKind.serviceUnavailable,
        'Сервис оценки тени не ответил вовремя. '
        'Обычный маршрут продолжает работать.',
      );
    }
    return const ShadeAnalysisFailure(
      ShadeAnalysisFailureKind.serviceUnavailable,
      'Сервис оценки тени недоступен. Обычный маршрут продолжает работать.',
    );
  }
}
