import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

class ApiConstants {
  static const int connectTimeoutMs = 8000;
  static const int receiveTimeoutMs = 8000;

  /// Phase A6.5: the shade engine may legitimately spend up to 10 s on the
  /// server (`SHADE_ANALYSIS_TIMEOUT_SECONDS`). The shade request therefore
  /// carries its own receive timeout instead of raising the global one, so a
  /// slow estimate never slows down catalog or search calls.
  static const int shadeReceiveTimeoutMs = 15000;

  /// Phase A6.3: body cap mirrored from the backend's `REQUEST_MAX_BYTES`
  /// (default 16384). A walk whose encoded request exceeds it cannot be
  /// analysed whole, and a shortened geometry would produce an invented
  /// estimate — so the client refuses before sending instead of truncating.
  static const int shadeMaxRequestBytes = 16384;

  /// Базовый URL для подключения к бэкенду.
  /// Для Android-эмулятора используется 10.0.2.2 вместо localhost.
  static String get defaultBaseUrl {
    if (kIsWeb) {
      return 'http://localhost:8000/api/v1';
    }
    try {
      if (Platform.isAndroid) {
        return 'http://10.0.2.2:8000/api/v1';
      }
    } catch (_) {}
    return 'http://localhost:8000/api/v1';
  }

  static const String placesEndpoint = '/places';
  static const String categoriesEndpoint = '/places/categories';

  /// Phase C6: verified historical card of one place (editorial dataset,
  /// served from the backend cache — no third-party network access).
  static String placeHistoryEndpoint(int placeId) =>
      '$placesEndpoint/$placeId/history';
  static const String routeEvaluateEndpoint = '/routes/evaluate';
  static const String routeProposeWalkEndpoint = '/routes/propose-walk';

  /// Phase C7.1: time-aware shade analysis of an existing walk (read-only
  /// OSM-derived pilot dataset; never a route generator).
  static const String shadeAnalyzeEndpoint = '/environment/shade/analyze';

  /// Phase C7.2: relative wet-surface assessment of an existing walk
  /// (read-only OSM pilot snapshot + modeled weather; never a route chooser).
  static const String puddleAnalyzeEndpoint = '/environment/puddle/analyze';

  /// Phase C7.3: modeled pollen concentrations along an existing walk (CAMS
  /// via Open-Meteo Air Quality; only species and coverage, no danger levels).
  static const String pollenAnalyzeEndpoint = '/environment/pollen/analyze';

  /// Phase C11: relative road-noise exposure proxy for an existing walk
  /// (pinned OSM road snapshot; never a route generator and never dB).
  static const String quietAnalyzeEndpoint = '/environment/quiet/analyze';
  static const int quietReceiveTimeoutMs = 15000;
  static const int quietMaxRequestBytes = shadeMaxRequestBytes;

  /// Phase C13.1: built-in guest AI assistant. No access code is sent; the
  /// OpenRouter key and model stay on the backend, and the client only sends
  /// text plus an optional catalog id.
  static const String assistantChatEndpoint = '/assistant/chat';
  static const String assistantStreamEndpoint = '/assistant/chat/stream';
  static const int assistantReceiveTimeoutMs = 30000;
  static const int assistantStreamIdleTimeoutMs = 60000;
  static const int assistantMaxMessageChars = 800;

  /// The ONLY concentration unit C7.3 accepts. The client verifies the unit
  /// the backend states instead of assuming it: a payload in another unit is
  /// refused rather than rendered with the wrong label.
  static const String pollenConcentrationUnit = 'grains/m³';
  static const String searchSuggestEndpoint = '/search/suggest';
  static const String searchGeocodeEndpoint = '/search/geocode';
  static const String searchReverseGeocodeEndpoint = '/search/reverse-geocode';
}
