import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/providers/theme_provider.dart';

/// Compact entry point for the existing appearance preference. It reads and
/// writes the SAME ThemeProvider as the settings screen, so both stay in sync
/// and the choice is persisted by the provider's own store.
class ThemeModeButton extends StatelessWidget {
  const ThemeModeButton({super.key});

  static IconData iconFor(AppThemePreference preference) =>
      switch (preference) {
        AppThemePreference.system => Icons.brightness_auto_outlined,
        AppThemePreference.light => Icons.light_mode_outlined,
        AppThemePreference.dark => Icons.dark_mode_outlined,
      };

  Future<void> _showThemeMenu(
    BuildContext context,
    ThemeProvider provider,
  ) async {
    final button = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) return;
    final selected = await showMenu<AppThemePreference>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          button.localToGlobal(Offset.zero),
          button.localToGlobal(button.size.bottomRight(Offset.zero)),
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final preference in AppThemePreference.values)
          CheckedPopupMenuItem<AppThemePreference>(
            value: preference,
            checked: provider.preference == preference,
            child: Text(preference.label),
          ),
      ],
    );
    if (selected != null && selected != provider.preference) {
      await provider.setPreference(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ThemeProvider?>();
    if (provider == null) return const SizedBox.shrink();
    final enabled = !provider.loading;
    void openMenu() {
      if (enabled) _showThemeMenu(context, provider);
    }

    return Semantics(
      button: true,
      excludeSemantics: true,
      label: 'Тема оформления. Сейчас: ${provider.preference.label}',
      hint: 'Открывает выбор системной, светлой или тёмной темы',
      onTap: enabled ? openMenu : null,
      child: Tooltip(
        message: 'Тема оформления',
        child: IconButton(
          key: const Key('theme_mode_button'),
          onPressed: enabled ? openMenu : null,
          icon: Icon(iconFor(provider.preference)),
        ),
      ),
    );
  }
}
