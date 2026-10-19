import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:smart_navigator_spb/core/constants/api_constants.dart';

/// Client-distributed settings. These values are recoverable from an APK.
class AppConfiguration {
  const AppConfiguration._({
    required this.mapKitApiKey,
    required this.apiBaseUrl,
    required this.appEnv,
  });

  final String mapKitApiKey;
  final String apiBaseUrl;
  final String appEnv;

  // Presence matters: an explicitly empty define must not use a local value.
  static const compileTimeValues = <String, String>{
    if (bool.hasEnvironment('MAPKIT_API_KEY'))
      'MAPKIT_API_KEY': String.fromEnvironment('MAPKIT_API_KEY'),
    if (bool.hasEnvironment('API_BASE_URL'))
      'API_BASE_URL': String.fromEnvironment('API_BASE_URL'),
    if (bool.hasEnvironment('APP_ENV'))
      'APP_ENV': String.fromEnvironment('APP_ENV'),
  };

  /// The Android debug source set supplies this asset, never pubspec.yaml.
  /// Profile/release do not even attempt to read local development settings.
  static Future<AppConfiguration> load({
    Map<String, String> defines = compileTimeValues,
    bool isDebug = kDebugMode,
    Future<Map<String, String>> Function()? readDevelopmentValues,
  }) async {
    var localValues = <String, String>{};
    if (isDebug) {
      try {
        localValues = await (readDevelopmentValues ?? _readDevelopmentValues)();
      } catch (_) {
        // Never expose parser/platform errors that could contain credentials.
        throw const AppConfigurationException(
          'Не удалось прочитать .env.dev. Проверьте формат файла настроек '
          'и полностью перезапустите flutter run.',
        );
      }
    }
    return AppConfiguration.resolve(
      defines: defines,
      localValues: localValues,
      isDebug: isDebug,
      developmentApiBaseUrl: ApiConstants.defaultBaseUrl,
    );
  }

  static Future<Map<String, String>> _readDevelopmentValues() async {
    final environment = DotEnv();
    await environment.load(fileName: 'development.env', isOptional: true);
    return environment.env;
  }

  /// Precedence per setting: explicit define > debug .env.dev > debug default.
  /// Nondebug builds require all settings explicitly, with HTTPS and a selected
  /// staging/production environment; localValues are ignored even if supplied.
  factory AppConfiguration.resolve({
    required Map<String, String> defines,
    Map<String, String> localValues = const {},
    required bool isDebug,
    String developmentApiBaseUrl = 'http://10.0.2.2:8000/api/v1',
  }) {
    String value(String name, [String defaultValue = '']) {
      if (defines.containsKey(name)) return defines[name]!.trim();
      if (!isDebug) return '';
      return (localValues[name] ?? defaultValue).trim();
    }

    final errors = <String>[];
    final appEnv = value('APP_ENV', 'development');
    if (!{'development', 'staging', 'production'}.contains(appEnv)) {
      errors.add('APP_ENV: укажите development, staging или production.');
    } else if (!isDebug && appEnv == 'development') {
      errors.add(
        'APP_ENV: для release/profile выберите staging или production.',
      );
    }
    if (!isDebug) {
      for (final name in ['MAPKIT_API_KEY', 'API_BASE_URL', 'APP_ENV']) {
        if (!defines.containsKey(name)) {
          errors.add(
            '$name: требуется явный --dart-define для release/profile.',
          );
        }
      }
    }

    final mapKitApiKey = value('MAPKIT_API_KEY');
    if (!isValidClientKey(mapKitApiKey)) {
      errors.add(
        'MAPKIT_API_KEY: нужен ключ мобильного MapKit вместо пустого значения '
        'или шаблона. Укажите его в .env.dev (debug) или --dart-define.',
      );
    }

    final rawUrl = value('API_BASE_URL', developmentApiBaseUrl);
    String? apiBaseUrl;
    try {
      apiBaseUrl = normalizeApiBaseUrl(rawUrl, requireHttps: !isDebug);
    } on AppConfigurationException catch (error) {
      errors.add(error.message);
    }
    if (errors.isNotEmpty) {
      throw AppConfigurationException(errors.join('\n\n'));
    }
    return AppConfiguration._(
      mapKitApiKey: mapKitApiKey,
      apiBaseUrl: apiBaseUrl!,
      appEnv: appEnv,
    );
  }

  static bool isValidClientKey(String key) {
    final normalized = key.toUpperCase();
    return key.isNotEmpty &&
        !RegExp(r'\s|[\x00-\x1f\x7f<>]').hasMatch(key) &&
        !normalized.startsWith('YOUR_') &&
        !normalized.startsWith('REPLACE_') &&
        !{'CHANGEME', 'PLACEHOLDER', 'TODO'}.contains(normalized);
  }

  static String normalizeApiBaseUrl(
    String value, {
    required bool requireHttps,
  }) {
    const invalid = AppConfigurationException(
      'API_BASE_URL: нужен абсолютный http(s) URL backend без логина, '
      'пароля, query или fragment; например http://10.0.2.2:8000.',
    );
    try {
      final uri = Uri.parse(value);
      if (!{'http', 'https'}.contains(uri.scheme) ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(value) ||
          RegExp(r'[^a-zA-Z0-9.\-:\[\]]').hasMatch(uri.host) ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.port < 1 ||
          uri.port > 65535) {
        throw invalid;
      }
      if (requireHttps && uri.scheme != 'https') {
        throw const AppConfigurationException(
          'API_BASE_URL: release/profile требует HTTPS backend.',
        );
      }
      var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
      if (!path.endsWith('/api/v1')) path = '$path/api/v1';
      return uri.replace(path: path).toString();
    } on FormatException {
      throw invalid;
    }
  }
}

/// Messages contain setting names/instructions only, never supplied values.
class AppConfigurationException implements Exception {
  const AppConfigurationException(this.message);
  final String message;

  @override
  String toString() => message;
}
