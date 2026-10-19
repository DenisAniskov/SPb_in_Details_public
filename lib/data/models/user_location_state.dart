import 'package:flutter/foundation.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';

/// Permission status enumeration for device location.
enum LocationPermissionStatus {
  notRequested,
  grantedPrecise,
  grantedCoarse,
  denied,
  permanentlyDenied,
  serviceDisabled,
}

enum LocationPhase {
  idle,
  requestingPermission,
  locating,
  available,
  unavailable,
}

/// User-facing precision classes. They describe the REPORTED Android
/// accuracy, not a map-matched or guessed position.
enum LocationQuality { precise, approximate, poor, unknown }

/// Snapshot of the user's device location.
class UserLocationSnapshot {
  final GeoCoord coordinate;
  final double? accuracy;
  final double? altitude;
  final double? heading;
  final double? speed;
  final DateTime timestamp;
  final bool isCached;

  const UserLocationSnapshot({
    required this.coordinate,
    this.accuracy,
    this.altitude,
    this.heading,
    this.speed,
    required this.timestamp,
    this.isCached = false,
  });

  /// Wall clock behind [isFresh]. Only tests override it so freshness can be
  /// simulated without real sleeps; production always reads the real time.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Check whether the snapshot is considered fresh (e.g., within 60 seconds).
  bool isFresh({Duration maxAge = const Duration(minutes: 1)}) {
    final age = clock().difference(timestamp);
    return !age.isNegative && age <= maxAge;
  }
}

/// State representation of the user's location lifecycle.
class UserLocationState {
  final LocationPermissionStatus permissionStatus;
  final LocationPhase phase;
  bool get isLocating =>
      phase == LocationPhase.requestingPermission ||
      phase == LocationPhase.locating;
  final UserLocationSnapshot? lastKnownLocation;
  final String? errorMessage;

  const UserLocationState({
    this.permissionStatus = LocationPermissionStatus.notRequested,
    this.phase = LocationPhase.idle,
    this.lastKnownLocation,
    this.errorMessage,
  });

  bool get hasLocation => lastKnownLocation != null;

  UserLocationState copyWith({
    LocationPermissionStatus? permissionStatus,
    LocationPhase? phase,
    UserLocationSnapshot? lastKnownLocation,
    String? errorMessage,
    bool clearError = false,
    bool clearLocation = false,
  }) {
    return UserLocationState(
      permissionStatus: permissionStatus ?? this.permissionStatus,
      phase: phase ?? this.phase,
      lastKnownLocation: clearLocation
          ? null
          : (lastKnownLocation ?? this.lastKnownLocation),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
