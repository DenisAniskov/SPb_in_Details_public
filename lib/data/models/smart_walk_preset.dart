/// Product defaults for automatic walks. The budget includes both the native
/// pedestrian walking time and the editorial time spent at each attraction.
enum SmartWalkPreset {
  quick(
    label: 'Быстрая прогулка',
    description: 'Ближайшие места и короткие переходы',
    approximateDuration: 'До 1 часа с осмотром',
    timeBudgetMinutes: 60,
  ),
  regular(
    label: 'Обычная прогулка',
    description: 'Несколько интересных мест в удобном темпе',
    approximateDuration: 'До 2 часов с осмотром',
    timeBudgetMinutes: 120,
  ),
  extended(
    label: 'Погулять подольше',
    description: 'Больше остановок и разнообразия, если позволяет маршрут',
    approximateDuration: 'До 4 часов с осмотром',
    timeBudgetMinutes: 240,
  );

  const SmartWalkPreset({
    required this.label,
    required this.description,
    required this.approximateDuration,
    required this.timeBudgetMinutes,
  });

  static const defaultPreset = regular;

  final String label;
  final String description;
  final String approximateDuration;
  final int timeBudgetMinutes;
}

abstract final class SmartWalkConfiguration {
  // Existing backend contract and existing soft preference, without changing
  // category eligibility or making an unusual attraction mandatory.
  static const minBudgetMinutes = 30;
  static const maxBudgetMinutes = 360;
  static const automaticPreferUnusual = true;

  static void validateBudget(int? minutes) {
    if (minutes != null &&
        (minutes < minBudgetMinutes || minutes > maxBudgetMinutes)) {
      throw ArgumentError.value(
        minutes,
        'timeBudgetMinutes',
        'Must be between $minBudgetMinutes and $maxBudgetMinutes',
      );
    }
  }
}
