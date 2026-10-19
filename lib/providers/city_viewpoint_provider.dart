import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/city_highlights/city_highlight_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';

/// One active viewpoint shown on the main map.
///
/// The session keeps the parent place so the map can offer a direct way back
/// to the card. It is a UI selection only: it never owns, changes or starts a
/// route.
class CityViewpointSession {
  const CityViewpointSession({required this.place, required this.viewpoint});

  final PlaceModel place;
  final CityViewpoint viewpoint;
}

/// App-wide, transient selection of a C14 viewpoint.
class CityViewpointProvider extends ChangeNotifier {
  CityViewpointSession? _session;

  CityViewpointSession? get session => _session;

  void show(PlaceModel place, CityViewpoint viewpoint) {
    if (!viewpoint.hasValidCoordinates) return;
    _session = CityViewpointSession(place: place, viewpoint: viewpoint);
    notifyListeners();
  }

  void clear() {
    if (_session == null) return;
    _session = null;
    notifyListeners();
  }
}
