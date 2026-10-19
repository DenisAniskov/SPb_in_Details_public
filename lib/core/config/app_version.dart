import 'package:package_info_plus/package_info_plus.dart';

/// The installed package version, or null when the platform metadata is
/// unavailable. The about section treats the version as optional: a missing
/// value must not break settings or show an invented number.
Future<String?> readInstalledAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    final version = info.version.trim();
    if (version.isEmpty) return null;
    final build = info.buildNumber.trim();
    return build.isEmpty ? version : '$version (сборка $build)';
  } catch (_) {
    return null;
  }
}
