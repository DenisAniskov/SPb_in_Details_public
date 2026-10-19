import 'package:flutter/material.dart';

class AppColors {
  // Санкт-Петербургская цветовая палитра: благородный гранит, глубина Невы, янтарные акценты
  static const Color primary = Color(0xFF1E3A8A); // Royal Navy Blue
  static const Color primaryLight = Color(0xFF3B82F6);
  static const Color primaryDark = Color(0xFF172554);

  static const Color secondary = Color(0xFF0F766E); // Neva Teal
  static const Color accent = Color(
    0xFFD97706,
  ); // Amber Gold (Янтарь/Эрмитажное золото)

  static const Color background = Color(0xFFF8FAFC);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceVariant = Color(0xFFF1F5F9);

  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF475569);
  static const Color textMuted = Color(0xFF64748B);

  static const Color border = Color(0xFFE2E8F0);
  static const Color divider = Color(0xFFCBD5E1);

  // Цвета категорий
  static const Color historyArchitecture = Color(
    0xFF854D0E,
  ); // Бронза / Классика
  static const Color art = Color(0xFF7C3AED); // Фиолетовый / Искусство
  static const Color scienceTechnology = Color(0xFF0369A1); // Синий инжиниринг
  static const Color nature = Color(0xFF15803D); // Зелёный парк
  static const Color modernSpaces = Color(0xFFC2410C); // Оранжевый лофт
  static const Color familyLeisure = Color(0xFFBE185D); // Розовый семейный
  static const Color unusualBadge = Color(0xFF9333EA); // Необычные места

  static const Color routeColor = Color(
    0xFF2563EB,
  ); // Пешеходная линия маршрута
  static const Color routeStartMarker = Color(0xFF10B981); // Зеленый старт
  static const Color routeEndMarker = Color(0xFFEF4444); // Красный финиш

  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFB91C1C);

  // Dark Theme Palette
  static const Color darkBackground = Color(0xFF0F172A);
  static const Color darkSurface = Color(0xFF1E293B);
  static const Color darkSurfaceVariant = Color(0xFF334155);
  static const Color darkBorder = Color(0xFF475569);
  static const Color darkDivider = Color(0xFF334155);
  static const Color darkTextPrimary = Color(0xFFF8FAFC);
  static const Color darkTextSecondary = Color(0xFFCBD5E1);
  static const Color darkTextMuted = Color(0xFF94A3B8);

  // Map Overlay Surfaces
  static const Color mapOverlayLight = Color(0xF2FFFFFF); // 95% opacity white
  static const Color mapOverlayDark = Color(0xF21E293B);
}

/// Semantic application chrome. MapKit styling remains the SDK default.
class AppPalette {
  final bool dark;
  AppPalette.of(BuildContext context)
    : dark = Theme.of(context).brightness == Brightness.dark;
  Color get surface => dark ? AppColors.darkSurface : AppColors.surface;
  Color get surfaceVariant =>
      dark ? AppColors.darkSurfaceVariant : AppColors.surfaceVariant;
  Color get background =>
      dark ? AppColors.darkBackground : AppColors.background;
  Color get textPrimary =>
      dark ? AppColors.darkTextPrimary : AppColors.textPrimary;
  Color get textSecondary =>
      dark ? AppColors.darkTextSecondary : AppColors.textSecondary;
  Color get textMuted =>
      dark ? AppColors.darkTextSecondary : AppColors.textMuted;
  Color get border => dark ? AppColors.darkBorder : AppColors.border;
  Color get divider => dark ? AppColors.darkDivider : AppColors.divider;
  Color get primary => dark ? const Color(0xFF93C5FD) : AppColors.primary;
  Color get secondary => dark ? const Color(0xFF5EEAD4) : AppColors.secondary;
  Color get accent => dark ? const Color(0xFFFCD34D) : const Color(0xFF92400E);
  Color get error => dark ? const Color(0xFFFCA5A5) : AppColors.error;
  Color get success => dark ? const Color(0xFF6EE7B7) : const Color(0xFF047857);
  Color get unusualBadge =>
      dark ? const Color(0xFFD8B4FE) : AppColors.unusualBadge;
  Color category(Color color) => dark
      ? HSLColor.fromColor(color).withLightness(0.76).toColor()
      : HSLColor.fromColor(color)
            .withLightness(HSLColor.fromColor(color).lightness.clamp(0, 0.36))
            .toColor();

  /// Text/icon color on solid fills of [primary] and [category] colors:
  /// white on the saturated light-theme fills, dark granite ink on the pastel
  /// dark-theme fills (white on pastel is unreadable).
  Color get onSolid => dark ? AppColors.primaryDark : Colors.white;
}
