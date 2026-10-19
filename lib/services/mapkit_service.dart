import 'dart:async';

import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';

import 'package:yandex_maps_mapkit/init.dart' as init;
import 'package:yandex_maps_mapkit/mapkit.dart' as ymk;
import 'package:yandex_maps_mapkit/mapkit_factory.dart' as mapkit_factory;
import 'package:yandex_maps_mapkit/transport.dart' as transport;
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/services/mapkit_pedestrian_guidance_adapter.dart';

/// Contract for real pedestrian route calculation through the Yandex MapKit
/// PedestrianRouter. Implemented by [MapKitService]; injectable so the live
/// navigation session can be tested without native MapKit.
abstract class BasePedestrianRouteService {
  /// Builds a real MapKit pedestrian route between two arbitrary points.
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  });

  /// Cancels the in-flight request, if any.
  void cancel();
}

class MapKitService implements BasePedestrianRouteService {
  /// Round up each native leg so fractional walking time is never discarded.
  static int nativeDurationSeconds(double seconds) {
    if (!seconds.isFinite || seconds < 0) {
      throw const RouteCalculationFailure(RouteFailureKind.invalidResponse);
    }
    return seconds.ceil();
  }

  // Initialization does not prove that Yandex has accepted the key.
  static bool isMapKitInitialized = false;
  static String? initializationError;
  static bool _started = false;

  static Future<void> initializeMapKit({String? apiKey}) async {
    if (apiKey == null || apiKey.trim().isEmpty) {
      initializationError = 'Для карты и маршрутов нужен ключ MapKit.';
      return;
    }
    try {
      await init.initMapkit(apiKey: apiKey);
      isMapKitInitialized = true;
    } catch (_) {
      initializationError = 'Не удалось инициализировать MapKit.';
    }
  }

  static void onStart() {
    if (isMapKitInitialized && !_started) {
      mapkit_factory.mapkit.onStart();
      _started = true;
    }
  }

  static void onStop() {
    if (isMapKitInitialized && _started) {
      mapkit_factory.mapkit.onStop();
      _started = false;
    }
  }

  transport.PedestrianRouter? _router;
  transport.MasstransitSession? _session;
  transport.RouteHandler? _handler;
  Completer<RouteLegModel>? _pendingLeg;
  /// In-flight variant request (Phase C7.1). Kept separate from [_pendingLeg]
  /// so both request kinds can be cancelled by [cancel] with their own types.
  Completer<List<RouteLegModel>>? _pendingVariants;
  int _operationId = 0;
  NativeWalkRequestBudget? _nextWalkRequestBudget;

  /// Additive entry point: existing injected adapters still override
  /// calculateWalkRoute. The production implementation also checks the actual
  /// request count immediately before every native leg request.
  Future<PedestrianRouteModel> calculateBoundedWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
    required NativeWalkRequestBudget requestBudget,
  }) async {
    _nextWalkRequestBudget = requestBudget;
    try {
      return await calculateWalkRoute(startPoint: startPoint, places: places);
    } finally {
      if (identical(_nextWalkRequestBudget, requestBudget)) {
        _nextWalkRequestBudget = null;
      }
    }
  }

  @override
  void cancel() {
    ++_operationId;
    _session?.cancel();
    _session = null;
    _handler = null;
    final pending = _pendingLeg;
    _pendingLeg = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('Запрос маршрута отменён'));
    }
    final pendingVariants = _pendingVariants;
    _pendingVariants = null;
    if (pendingVariants != null && !pendingVariants.isCompleted) {
      pendingVariants.completeError(StateError('Запрос маршрута отменён'));
    }
  }

  Future<RouteLegModel> _requestSingleLeg({
    required double fromLat,
    required double fromLon,
    required String fromTitle,
    required double toLat,
    required double toLon,
    required String toTitle,
    NativeWalkRequestBudget? requestBudget,
    int legIndex = 0,
    int? visitMinutes,
  }) async {
    _router ??= transport.TransportFactory.instance.createPedestrianRouter();
    final completer = Completer<RouteLegModel>();
    _pendingLeg = completer;

    final handler = transport.RouteHandler(
      onMasstransitRoutes: (routes) {
        if (completer.isCompleted) return;
        if (routes.isEmpty) {
          completer.completeError(
            const RouteCalculationFailure(
              RouteFailureKind.pedestrianUnavailable,
            ),
          );
          return;
        }
        try {
          final route = routes.first;
          final geometry = route.geometry.points
              .map((p) => GeoCoord(p.latitude, p.longitude))
              .toList();
          completer.complete(
            RouteLegModel(
              fromTitle: fromTitle,
              toTitle: toTitle,
              distanceMeters: route.metadata.weight.walkingDistance.value,
              durationSeconds: nativeDurationSeconds(
                route.metadata.weight.time.value,
              ),
              geometryPoints: geometry,
              maneuvers: const MapKitPedestrianGuidanceAdapter()
                  .fromNativeRoute(route, geometry, legIndex: legIndex),
              visitMinutes: visitMinutes,
            ),
          );
        } catch (_) {
          // Complete malformed metadata failures immediately; otherwise an
          // uncaught callback exception would become a misleading timeout.
          if (!completer.isCompleted) {
            completer.completeError(
              const RouteCalculationFailure(RouteFailureKind.invalidResponse),
            );
          }
        }
      },
      onMasstransitRoutesError: (_) {
        if (!completer.isCompleted) {
          completer.completeError(
            const RouteCalculationFailure(RouteFailureKind.serviceUnavailable),
          );
        }
      },
    );
    _handler = handler; // Native SDK requires strong references.

    try {
      requestBudget?.consume();
      _session = _router!.requestRoutes(
        const transport.TimeOptions(),
        const transport.RouteOptions(transport.FitnessOptions()),
        _handler!,
        points: [
          ymk.RequestPoint(
            ymk.Point(latitude: fromLat, longitude: fromLon),
            ymk.RequestPointType.Waypoint,
            null,
            null,
            null,
          ),
          ymk.RequestPoint(
            ymk.Point(latitude: toLat, longitude: toLon),
            ymk.RequestPointType.Waypoint,
            null,
            null,
            null,
          ),
        ],
      );
      return await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      if (identical(_pendingLeg, completer)) {
        _session?.cancel();
        _session = null;
        _handler = null;
        _pendingLeg = null;
      }
    }
  }

  /// Real MapKit pedestrian VARIANTS for one leg (Phase C7.1 §12).
  ///
  /// The PedestrianRouter answers one request with a list of routes; the app
  /// historically used only the first. This method returns up to
  /// [maxVariants] real alternatives from the SAME single request, so
  /// discovering them costs one unit of the native request budget — never one
  /// per variant. Variants are never synthesised, never straightened and
  /// never re-ordered; the first entry is always the primary route the normal
  /// build would have used.
  Future<List<RouteLegModel>> requestLegVariants({
    required double fromLat,
    required double fromLon,
    required String fromTitle,
    required double toLat,
    required double toLon,
    required String toTitle,
    NativeWalkRequestBudget? requestBudget,
    int legIndex = 0,
    int? visitMinutes,
    int maxVariants = 2,
  }) async {
    _router ??= transport.TransportFactory.instance.createPedestrianRouter();
    final completer = Completer<List<RouteLegModel>>();
    _pendingVariants = completer;

    RouteLegModel legFrom(transport.MasstransitRoute route, int variantIndex) {
      final geometry = route.geometry.points
          .map((p) => GeoCoord(p.latitude, p.longitude))
          .toList();
      return RouteLegModel(
        fromTitle: fromTitle,
        toTitle: toTitle,
        distanceMeters: route.metadata.weight.walkingDistance.value,
        durationSeconds: nativeDurationSeconds(route.metadata.weight.time.value),
        geometryPoints: geometry,
        maneuvers: const MapKitPedestrianGuidanceAdapter()
            .fromNativeRoute(route, geometry, legIndex: legIndex),
        visitMinutes: visitMinutes,
      );
    }

    final handler = transport.RouteHandler(
      onMasstransitRoutes: (routes) {
        if (completer.isCompleted) return;
        if (routes.isEmpty) {
          completer.completeError(
            const RouteCalculationFailure(RouteFailureKind.pedestrianUnavailable),
          );
          return;
        }
        try {
          // Keep the primary first, then real distinct alternatives, bounded.
          final variants = <RouteLegModel>[];
          for (final route in routes.take(maxVariants)) {
            variants.add(legFrom(route, variants.length));
          }
          completer.complete(variants);
        } catch (_) {
          if (!completer.isCompleted) {
            completer.completeError(
              const RouteCalculationFailure(RouteFailureKind.invalidResponse),
            );
          }
        }
      },
      onMasstransitRoutesError: (_) {
        if (!completer.isCompleted) {
          completer.completeError(
            const RouteCalculationFailure(RouteFailureKind.serviceUnavailable),
          );
        }
      },
    );
    _handler = handler;

    try {
      requestBudget?.consume();
      _session = _router!.requestRoutes(
        const transport.TimeOptions(),
        const transport.RouteOptions(transport.FitnessOptions()),
        _handler!,
        points: [
          ymk.RequestPoint(
            ymk.Point(latitude: fromLat, longitude: fromLon),
            ymk.RequestPointType.Waypoint,
            null,
            null,
            null,
          ),
          ymk.RequestPoint(
            ymk.Point(latitude: toLat, longitude: toLon),
            ymk.RequestPointType.Waypoint,
            null,
            null,
            null,
          ),
        ],
      );
      return await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      if (identical(_pendingVariants, completer)) {
        _session?.cancel();
        _session = null;
        _handler = null;
        _pendingVariants = null;
      }
    }
  }

  /// Построение пешеходного маршрута для туристической прогулки по нескольким местам.
  /// MapKit PedestrianRouter поддерживает запросы точка-точка, поэтому для многоточечной прогулки
  /// последовательно рассчитываются участки маршрута (legs) и агрегируются реальные данные MapKit.
  Future<PedestrianRouteModel> calculateWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
  }) async {    final requestBudget = _nextWalkRequestBudget;
    _nextWalkRequestBudget = null;
    if (!isMapKitInitialized) {
      throw const RouteCalculationFailure(RouteFailureKind.serviceUnavailable);
    }
    if (places.isEmpty) {
      throw ArgumentError('Не выбраны места для построения прогулки');
    }

    cancel();
    final operationId = _operationId;

    final legs = <RouteLegModel>[];
    double totalDistance = 0;
    int totalDuration = 0;
    final allPoints = <GeoCoord>[];

    for (int i = 0; i < places.length; i++) {
      if (operationId != _operationId) {
        throw StateError('Запрос маршрута отменён');
      }

      // Pedestrian legs connect the verified routing points when a place
      // carries one; markers and arrival narrative still use display points.
      final fromLat =
          (i == 0) ? startPoint.latitude : places[i - 1].routeLatitude;
      final fromLon =
          (i == 0) ? startPoint.longitude : places[i - 1].routeLongitude;
      final fromTitle = (i == 0) ? startPoint.title : places[i - 1].title;

      final toLat = places[i].routeLatitude;
      final toLon = places[i].routeLongitude;
      final toTitle = places[i].title;

      final leg = await _requestSingleLeg(
        fromLat: fromLat,
        fromLon: fromLon,
        fromTitle: fromTitle,
        toLat: toLat,
        toLon: toLon,
        toTitle: toTitle,
        requestBudget: requestBudget,
        legIndex: i,
        visitMinutes: places[i].recommendedVisitMinutes,
      );

      if (operationId != _operationId) {
        throw StateError('Запрос маршрута отменён');
      }

      legs.add(leg);
      totalDistance += leg.distanceMeters;
      totalDuration += leg.durationSeconds;
      allPoints.addAll(leg.geometryPoints);
    }

    return PedestrianRouteModel(
      distanceMeters: totalDistance,
      durationSeconds: totalDuration,
      geometryPoints: allPoints,
      steps: const [],
      legs: legs,
      placesCount: places.length,
    );
  }

  /// Построение пешеходного маршрута между двумя произвольными точками (A -> B)
  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async {
    if (!isMapKitInitialized) {
      throw StateError(initializationError ?? 'MapKit не инициализирован');
    }
    cancel();

    final leg = await _requestSingleLeg(
      fromLat: startPoint.latitude,
      fromLon: startPoint.longitude,
      fromTitle: startPoint.title,
      toLat: destinationPoint.latitude,
      toLon: destinationPoint.longitude,
      toTitle: destinationPoint.title,
    );

    return PedestrianRouteModel(
      distanceMeters: leg.distanceMeters,
      durationSeconds: leg.durationSeconds,
      geometryPoints: leg.geometryPoints,
      steps: const [],
      legs: [leg],
      placesCount: 1,
    );
  }

  /// Построение одиночного пешеходного маршрута A -> B до места каталога.
  /// Запрос ведётся к проверенной точке подхода, когда она есть в каталоге;
  /// маркер остаётся на отображаемой точке.
  Future<PedestrianRouteModel> calculatePedestrianRoute({
    required RoutePointModel startPoint,
    required PlaceModel destination,
  }) => calculatePointToPointRoute(
    startPoint: startPoint,
    destinationPoint: RoutePointModel(
      id: 'place_${destination.id}',
      title: destination.title,
      subtitle: destination.address,
      latitude: destination.routeLatitude,
      longitude: destination.routeLongitude,
      isPreset: false,
    ),
  );
}
