import 'package:smart_navigator_spb/data/models/route_point_model.dart';

class ExternalMapPoint {
  final String title;
  final String? subtitle;
  final String? address;
  final double latitude;
  final double longitude;
  final String source; // 'yandex_suggest', 'yandex_geocode', 'map_tap'
  final String? uri;
  final String? kind;

  const ExternalMapPoint({
    required this.title,
    this.subtitle,
    this.address,
    required this.latitude,
    required this.longitude,
    this.source = 'yandex_geocode',
    this.uri,
    this.kind,
  });

  factory ExternalMapPoint.fromJson(
    Map<String, dynamic> json, {
    String source = 'yandex_geocode',
  }) {
    final lat = (json['latitude'] as num).toDouble();
    final lon = (json['longitude'] as num).toDouble();
    if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
      throw const FormatException('Некорректные координаты');
    }
    return ExternalMapPoint(
      title: json['title'] as String? ?? 'Точка на карте',
      subtitle: json['subtitle'] as String?,
      address: json['address'] as String?,
      latitude: lat,
      longitude: lon,
      source: source,
      uri: json['uri'] as String?,
      kind: json['kind'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'subtitle': subtitle,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'source': source,
      'uri': uri,
      'kind': kind,
    };
  }

  /// Преобразование внешней точки в RoutePointModel для использования
  /// в качестве старта маршрута или точки назначения
  RoutePointModel toRoutePoint({String? customId}) {
    return RoutePointModel(
      id:
          customId ??
          'external_${latitude.toStringAsFixed(5)}_${longitude.toStringAsFixed(5)}',
      title: title,
      subtitle:
          address ??
          subtitle ??
          '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}',
      latitude: latitude,
      longitude: longitude,
      isPreset: false,
    );
  }
}
