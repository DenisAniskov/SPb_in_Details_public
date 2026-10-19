import 'package:flutter/foundation.dart';

import 'package:smart_navigator_spb/core/config/app_configuration.dart';
import 'package:smart_navigator_spb/services/guidance_diagnostics.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/scenic_diagnostics.dart';

/// Resolves/validates client settings before touching the native SDK.
Future<AppConfiguration> initializeApplication({
  Future<AppConfiguration> Function()? loadConfiguration,
  Future<void> Function(String)? initializeMapKit,
}) async {
  // Development-only guidance diagnostics (Phase C4 A3): strictly opt-in via
  // a build-time define; recording is a no-op in release builds regardless.
  GuidanceDiagnostics.enabled =
      const bool.fromEnvironment('GUIDANCE_DIAGNOSTICS');
  // Development-only scenic diagnostics (Phase C4/C5 runtime fixes §3):
  // debug only, even when the define is supplied in profile or release.
  ScenicDiagnostics.enabled =
      kDebugMode && const bool.fromEnvironment('SCENIC_DIAGNOSTICS');
  final configuration = await (loadConfiguration ?? AppConfiguration.load)();
  await (initializeMapKit ??
      (key) => MapKitService.initializeMapKit(apiKey: key))(
    configuration.mapKitApiKey,
  );
  return configuration;
}
