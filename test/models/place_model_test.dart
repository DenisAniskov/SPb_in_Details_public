import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';

void main() {
  group('PlaceModel Tests', () {
    test('PlaceModel JSON serialization and deserialization', () {
      final json = {
        'id': 1,
        'title': 'Государственный Эрмитаж',
        'short_description': 'Музей мирового уровня',
        'full_description': 'Зимний дворец и залы шедевров',
        'category': 'history_architecture',
        'is_unusual': false,
        'latitude': 59.939832,
        'longitude': 30.314560,
        'address': 'Дворцовая наб., 32',
        'photo_url': 'https://example.com/hermitage.jpg',
        'working_hours': '11:00-18:00',
        'tags': 'музей, барокко, эрмитаж',
        'rating': 4.9,
        'architectural_style': 'Елизаветинское барокко',
        'year_built': '1754-1762',
      };

      final place = PlaceModel.fromJson(json);
      expect(place.id, 1);
      expect(place.title, 'Государственный Эрмитаж');
      expect(place.category, PlaceCategoryEnum.historyArchitecture);
      expect(place.category.displayName, 'История и архитектура');
      expect(place.isUnusual, false);
      expect(place.tagList, ['музей', 'барокко', 'эрмитаж']);

      final serialized = place.toJson();
      expect(serialized['id'], 1);
      expect(serialized['category'], 'history_architecture');
    });

    test('PlaceCategoryEnum matches all 6 required categories', () {
      expect(PlaceCategoryEnum.values.length, 6);
      final categories = PlaceCategoryEnum.values.map((c) => c.key).toList();
      expect(
        categories,
        containsAll([
          'history_architecture',
          'art',
          'science_technology',
          'nature',
          'modern_spaces',
          'family_leisure',
        ]),
      );
    });

    test('routing schema defaults when the backend omits Phase C3 fields', () {
      final json = {
        'id': 2,
        'title': 'Воронцовский сквер',
        'short_description': 'Зелёная остановка',
        'category': 'nature',
        'latitude': 59.8467567,
        'longitude': 30.237876,
        'address': 'Санкт-Петербург',
      };
      final place = PlaceModel.fromJson(json);
      expect(place.routingLatitude, isNull);
      expect(place.routingLongitude, isNull);
      expect(place.routingPointSource, isNull);
      expect(place.routingPointVerifiedOn, isNull);
      expect(place.routingAccessStatus, 'representative_point_only');
      // Without a verified entrance the pedestrian destination is the
      // display point itself.
      expect(place.routeLatitude, place.latitude);
      expect(place.routeLongitude, place.longitude);
    });

    test('verified routing point overrides the pedestrian destination only',
        () {
      final json = {
        'id': 3,
        'title': 'Парк с проверенным входом',
        'short_description': 'Зелёная остановка',
        'category': 'nature',
        'latitude': 59.8400,
        'longitude': 30.1300,
        'address': 'Санкт-Петербург',
        'routing_latitude': 59.8415,
        'routing_longitude': 30.1312,
        'routing_point_source': 'https://www.openstreetmap.org/node/123',
        'routing_point_verified_on': '2026-10-10',
        'routing_access_status': 'verified_public_entrance',
      };
      final place = PlaceModel.fromJson(json);
      expect(place.routeLatitude, 59.8415);
      expect(place.routeLongitude, 30.1312);
      // Display coordinates remain the representative point.
      expect(place.latitude, 59.8400);
      expect(place.longitude, 30.1300);

      final serialized = place.toJson();
      expect(serialized['routing_latitude'], 59.8415);
      expect(serialized['routing_access_status'], 'verified_public_entrance');
      final restored = PlaceModel.fromJson(serialized);
      expect(restored.routeLatitude, 59.8415);
      expect(restored.routeLongitude, 30.1312);
      expect(restored.routingAccessStatus, 'verified_public_entrance');
    });

    test('RoutePointModel default start is Palace Square', () {
      const defaultStart = RoutePointModel.defaultStart;
      expect(defaultStart.id, 'palace_square');
      expect(defaultStart.title, 'Дворцовая площадь');
      expect(defaultStart.latitude, 59.939095);
      expect(defaultStart.longitude, 30.315868);
    });

    test('PedestrianRouteModel formatting', () {
      const shortRoute = PedestrianRouteModel(
        distanceMeters: 450,
        durationSeconds: 360,
        geometryPoints: [GeoCoord(59.93, 30.31), GeoCoord(59.94, 30.32)],
        steps: [],
      );
      expect(shortRoute.formattedDistance, '450 м');
      expect(shortRoute.formattedDuration, '6 мин');

      const longRoute = PedestrianRouteModel(
        distanceMeters: 2400,
        durationSeconds: 1920,
        geometryPoints: [],
        steps: [],
      );
      expect(longRoute.formattedDistance, '2.4 км');
      expect(longRoute.formattedDuration, '32 мин');
    });

    test('PedestrianRouteModel walk legs formatting and calculation', () {
      const leg1 = RouteLegModel(
        fromTitle: 'Старт: Дворцовая площадь',
        toTitle: 'Эрмитаж',
        distanceMeters: 300,
        durationSeconds: 240,
        geometryPoints: [GeoCoord(59.939, 30.315), GeoCoord(59.940, 30.314)],
      );
      const leg2 = RouteLegModel(
        fromTitle: 'Эрмитаж',
        toTitle: 'Спас на Крови',
        distanceMeters: 900,
        durationSeconds: 720,
        geometryPoints: [GeoCoord(59.940, 30.314), GeoCoord(59.940, 30.328)],
      );

      const walkRoute = PedestrianRouteModel(
        distanceMeters: 1200,
        durationSeconds: 960,
        geometryPoints: [
          GeoCoord(59.939, 30.315),
          GeoCoord(59.940, 30.314),
          GeoCoord(59.940, 30.328),
        ],
        steps: [],
        legs: [leg1, leg2],
        placesCount: 2,
      );

      expect(walkRoute.isWalkRoute, isTrue);
      expect(walkRoute.legs.length, 2);
      expect(walkRoute.placesCount, 2);
      expect(walkRoute.formattedDistance, '1.2 км');
      expect(walkRoute.formattedDuration, '16 мин');
      expect(walkRoute.formattedWalkingDurationNote, contains('Время ходьбы: ~16 мин'));
      expect(walkRoute.formattedWalkingDurationNote, contains('без учёта времени посещения объектов'));
    });
  });
}
