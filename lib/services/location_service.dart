import 'package:smart_navigator_spb/core/constants/map_constants.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';

class LocationService {
  RoutePointModel _currentStartPoint = RoutePointModel.defaultStart;

  RoutePointModel get currentStartPoint => _currentStartPoint;

  List<RoutePointModel> get presetHubs {
    return MapConstants.presetStartingHubs.map((hub) {
      return RoutePointModel(
        id: hub['id'] as String,
        title: hub['title'] as String,
        subtitle: hub['subtitle'] as String,
        latitude: hub['lat'] as double,
        longitude: hub['lon'] as double,
        isPreset: true,
      );
    }).toList();
  }

  void setStartPoint(RoutePointModel point) {
    _currentStartPoint = point;
  }

  void setCustomStartPoint(
    double lat,
    double lon, {
    String title = 'Выбранная точка на карте',
  }) {
    _currentStartPoint = RoutePointModel(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      subtitle: '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}',
      latitude: lat,
      longitude: lon,
      isPreset: false,
    );
  }
}
