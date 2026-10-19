class RoutePointModel {
  final String id;
  final String title;
  final String subtitle;
  final double latitude;
  final double longitude;
  final bool isPreset;

  const RoutePointModel({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.latitude,
    required this.longitude,
    this.isPreset = true,
  });

  static const RoutePointModel defaultStart = RoutePointModel(
    id: 'palace_square',
    title: 'Дворцовая площадь',
    subtitle: 'Главная площадь СПб, Зимний дворец',
    latitude: 59.939095,
    longitude: 30.315868,
    isPreset: true,
  );

  RoutePointModel copyWith({
    String? id,
    String? title,
    String? subtitle,
    double? latitude,
    double? longitude,
    bool? isPreset,
  }) {
    return RoutePointModel(
      id: id ?? this.id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      isPreset: isPreset ?? this.isPreset,
    );
  }
}
