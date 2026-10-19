import 'package:flutter/material.dart';
import 'package:smart_navigator_spb/core/config/app_version.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';

typedef AppVersionLoader = Future<String?> Function();

/// Single authorship/version block. The version comes from the installed
/// package metadata; when it is unavailable the line is omitted rather than
/// hard-coded or invented.
class AboutAppSection extends StatefulWidget {
  const AboutAppSection({
    super.key,
    this.loadVersion = readInstalledAppVersion,
  });

  final AppVersionLoader loadVersion;

  @override
  State<AboutAppSection> createState() => _AboutAppSectionState();
}

class _AboutAppSectionState extends State<AboutAppSection> {
  late final Future<String?> _version = widget.loadVersion();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('О приложении', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.appTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(AppStrings.appCreator),
                const SizedBox(height: 4),
                const Text(AppStrings.appTagline),
                FutureBuilder<String?>(
                  future: _version,
                  builder: (context, snapshot) {
                    final version = snapshot.data;
                    if (version == null || version.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Версия $version',
                        style: theme.textTheme.bodySmall,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
