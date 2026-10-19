import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/services/device_location_service.dart';

/// On-demand, foreground location. Routing never subscribes to GPS changes.
class LocationProvider extends ChangeNotifier {
  final BaseDeviceLocationService _locationService;
  LocationProvider({BaseDeviceLocationService? locationService})
    : _locationService = locationService ?? DeviceLocationService();
  UserLocationState _state = const UserLocationState();
  UserLocationState get state => _state;
  LocationPermissionStatus get permissionStatus => _state.permissionStatus;
  bool get isLocating => _state.isLocating;
  UserLocationSnapshot? get lastKnownLocation => _state.lastKnownLocation;
  String? get errorMessage => _state.errorMessage;
  bool get isPermissionGranted =>
      permissionStatus == LocationPermissionStatus.grantedPrecise ||
      permissionStatus == LocationPermissionStatus.grantedCoarse;

  /// Classification of the last accepted fix. A coarse permission can never
  /// be reported as precise, even if the fused provider returns a small
  /// radius.
  LocationQuality get locationQuality {
    final point = _state.lastKnownLocation;
    if (_state.phase != LocationPhase.available || point == null) {
      return LocationQuality.unknown;
    }
    final accuracy = point.accuracy;
    if (permissionStatus == LocationPermissionStatus.grantedCoarse) {
      return accuracy != null && accuracy > 150
          ? LocationQuality.poor
          : LocationQuality.approximate;
    }
    if (accuracy == null || !accuracy.isFinite || accuracy < 0) {
      return LocationQuality.unknown;
    }
    if (accuracy <= 30) return LocationQuality.precise;
    if (accuracy <= 150) return LocationQuality.approximate;
    return LocationQuality.poor;
  }

  /// Honest wording for the map snackbar and the compact quality chip.
  /// Returns null when the fix is precise enough for the old message.
  String? get locationQualityMessage {
    final accuracy = _state.lastKnownLocation?.accuracy;
    final rounded = accuracy?.round();
    return switch (locationQuality) {
      LocationQuality.precise => null,
      LocationQuality.approximate =>
        permissionStatus == LocationPermissionStatus.grantedCoarse
            ? 'Разрешено только приблизительное местоположение. '
                  'Точность около ${rounded ?? '?'} м.'
            : 'Местоположение приблизительное. '
                  'Точность около ${rounded ?? '?'} м.',
      LocationQuality.poor =>
        'Местоположение неточное. Точность около ${rounded ?? '?'} м. '
            'Проверьте видимость неба и настройки геолокации.',
      LocationQuality.unknown => 'Точность местоположения неизвестна.',
    };
  }
  bool _disposed = false;
  bool _foreground = true;
  bool get isForeground => _foreground;
  int _revision = 0;
  Future<UserLocationSnapshot?>? _pending;
  bool _active(int revision) =>
      !_disposed && _foreground && revision == _revision;
  bool _valid(UserLocationSnapshot point) =>
      point.coordinate.latitude.isFinite &&
      point.coordinate.longitude.isFinite &&
      point.coordinate.latitude.abs() <= 90 &&
      point.coordinate.longitude.abs() <= 180 &&
      (point.accuracy == null ||
          (point.accuracy!.isFinite && point.accuracy! >= 0)) &&
      point.isFresh(maxAge: const Duration(seconds: 30));
  void _publish(UserLocationState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  Future<void> checkPermissionStatus() async {
    if (_disposed || !_foreground || isLocating) return;
    final revision = ++_revision;
    try {
      final status = await _locationService.checkPermission();
      if (!_active(revision)) return;
      final granted =
          status == LocationPermissionStatus.grantedPrecise ||
          status == LocationPermissionStatus.grantedCoarse;
      final last = granted
          ? await _locationService.getLastKnownPosition()
          : null;
      if (!_active(revision)) return;
      _publish(
        UserLocationState(permissionStatus: status, lastKnownLocation: last),
      );
    } catch (error) {
      if (!_active(revision)) return;
      debugPrint('Location status failure: ${error.runtimeType}');
      _publish(
        const UserLocationState(
          phase: LocationPhase.unavailable,
          errorMessage: 'Не удалось проверить доступ к местоположению.',
        ),
      );
    }
  }

  /// Concurrent taps share one request. Cached fixes are never routed as current.
  Future<UserLocationSnapshot?> requestLocationAndLocate() {
    if (_disposed || !_foreground) return Future.value(null);
    if (_pending != null) return _pending!;
    final revision = ++_revision;
    final future = _locate(revision);
    _pending = future;
    return future.whenComplete(() {
      if (identical(_pending, future)) _pending = null;
    });
  }

  Future<UserLocationSnapshot?> _locate(int revision) async {
    _publish(
      _state.copyWith(
        phase: LocationPhase.requestingPermission,
        clearError: true,
        clearLocation: true,
      ),
    );
    try {
      final enabled = await _locationService.isLocationServiceEnabled();
      if (!_active(revision)) return null;
      if (!enabled) {
        return _fail(
          LocationPermissionStatus.serviceDisabled,
          'Службы геолокации отключены. Включите геолокацию на устройстве.',
        );
      }
      final permission = await _locationService.requestPermission();
      if (!_active(revision)) return null;
      if (permission == LocationPermissionStatus.serviceDisabled) {
        return _fail(
          permission,
          'Службы геолокации отключены. Включите геолокацию на устройстве.',
        );
      }
      if (permission == LocationPermissionStatus.permanentlyDenied) {
        return _fail(
          permission,
          'Доступ к геопозиции заблокирован. Разрешите доступ в настройках приложения.',
        );
      }
      if (permission != LocationPermissionStatus.grantedPrecise &&
          permission != LocationPermissionStatus.grantedCoarse) {
        return _fail(
          permission,
          'Доступ к геопозиции отклонён. Разрешите доступ или выберите старт вручную.',
        );
      }
      _publish(
        UserLocationState(
          permissionStatus: permission,
          phase: LocationPhase.locating,
        ),
      );
      final point = await _locationService.getCurrentPosition(
        timeLimit: const Duration(seconds: 10),
      );
      if (!_active(revision)) return null;
      final enabledAfterFix = await _locationService.isLocationServiceEnabled();
      if (!_active(revision)) return null;
      if (!enabledAfterFix) {
        return _fail(
          LocationPermissionStatus.serviceDisabled,
          'Службы геолокации отключены. Включите геолокацию на устройстве.',
        );
      }
      // Access can change while the native one-shot is still pending.
      // Recheck silently before publishing coordinates or creating a start.
      final currentPermission = await _locationService.checkPermission();
      if (!_active(revision)) return null;
      if (currentPermission == LocationPermissionStatus.serviceDisabled) {
        return _fail(
          currentPermission,
          'Службы геолокации отключены. Включите геолокацию на устройстве.',
        );
      }
      if (currentPermission == LocationPermissionStatus.permanentlyDenied) {
        return _fail(
          currentPermission,
          'Доступ к геопозиции заблокирован. Разрешите доступ в настройках приложения.',
        );
      }
      if (currentPermission != LocationPermissionStatus.grantedPrecise &&
          currentPermission != LocationPermissionStatus.grantedCoarse) {
        return _fail(
          currentPermission,
          'Доступ к геопозиции отклонён. Разрешите доступ или выберите старт вручную.',
        );
      }
      if (point.isCached || !_valid(point)) {
        return _fail(
          currentPermission,
          'Не удалось получить актуальное местоположение. Повторите попытку.',
        );
      }
      _publish(
        UserLocationState(
          permissionStatus: currentPermission,
          phase: LocationPhase.available,
          lastKnownLocation: point,
        ),
      );
      return point;
    } on TimeoutException {
      if (!_active(revision)) return null;
      return _fail(
        permissionStatus,
        'Не удалось определить местоположение. Нет актуального сигнала; повторите попытку.',
      );
    } on LocationServiceDisabledException {
      if (!_active(revision)) return null;
      return _fail(
        LocationPermissionStatus.serviceDisabled,
        'Службы геолокации отключены. Включите геолокацию на устройстве.',
      );
    } catch (error) {
      if (!_active(revision)) return null;
      debugPrint('Location fix failure: ${error.runtimeType}');
      return _fail(
        permissionStatus,
        'Не удалось определить местоположение. Повторите попытку или выберите старт вручную.',
      );
    }
  }

  UserLocationSnapshot? _fail(
    LocationPermissionStatus permission,
    String message,
  ) {
    _publish(
      UserLocationState(
        permissionStatus: permission,
        phase: LocationPhase.unavailable,
        errorMessage: message,
      ),
    );
    return null;
  }

  /// Copies coordinates; subsequent device updates cannot mutate this input.
  RoutePointModel? createUserLocationRoutePoint([
    UserLocationSnapshot? snapshot,
  ]) {
    final point = snapshot ?? lastKnownLocation;
    if (!isPermissionGranted ||
        _state.phase != LocationPhase.available ||
        point == null ||
        point.isCached ||
        !_valid(point)) {
      return null;
    }
    return RoutePointModel(
      id: 'user_location',
      title: 'Моё местоположение',
      subtitle: permissionStatus == LocationPermissionStatus.grantedCoarse
          ? 'Приблизительная позиция · снимок старта'
          : 'Снимок позиции устройства',
      latitude: point.coordinate.latitude,
      longitude: point.coordinate.longitude,
      isPreset: false,
    );
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    ++_revision;
    if (!foreground) {
      _pending = null;
      _publish(UserLocationState(permissionStatus: permissionStatus));
    } else {
      unawaited(checkPermissionStatus());
    }
  }

  Future<bool> openAppSettings() => Geolocator.openAppSettings();
  void clearError() => _publish(_state.copyWith(clearError: true));
  @override
  void dispose() {
    _disposed = true;
    ++_revision;
    super.dispose();
  }
}
