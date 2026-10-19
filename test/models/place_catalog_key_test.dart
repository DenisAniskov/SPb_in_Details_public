import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';

Map<String, dynamic> legacyPlace() => {
  'id': 42,
  'title': 'Место',
  'short_description': 'Описание',
  'category': 'nature',
  'latitude': 59.93,
  'longitude': 30.31,
  'address': 'Санкт-Петербург',
};

void main() {
  test('C8.1 old staging backend can omit catalog_key', () {
    final place = PlaceModel.fromJson(legacyPlace());
    expect(place.catalogKey, isNull);
    expect(place.id, 42);
    expect(place.toJson()['catalog_key'], isNull);
    expect(PlaceModel.fromJson(place.toJson()).catalogKey, isNull);
  });

  for (final key in ['a', 'hermitage', 'a' * 80]) {
    test('C8.1 valid catalog key round trips: ${key.length} characters', () {
      final place = PlaceModel.fromJson({...legacyPlace(), 'catalog_key': key});
      expect(place.catalogKey, key);
      expect(place.toJson()['catalog_key'], key);
      expect(PlaceModel.fromJson(place.toJson()).catalogKey, key);
      expect(place.routeLatitude, 59.93);
      expect(place.routeLongitude, 30.31);
    });
  }

  final invalidKeys = <Object?>[
    null,
    true,
    1,
    1.5,
    <String, dynamic>{},
    <dynamic>[],
    '',
    ' Upper',
    'with_underscore',
    'UPPER',
    'a' * 81,
    'hermitage\n',
    'hermitage/child',
  ];
  for (var index = 0; index < invalidKeys.length; index++) {
    test('C8.1 malformed catalog key $index is unavailable', () {
      final place = PlaceModel.fromJson({
        ...legacyPlace(),
        'catalog_key': invalidKeys[index],
      });
      expect(place.catalogKey, isNull);
      expect(place.toJson()['catalog_key'], isNull);
      expect(place.id, 42);
    });
  }

  test('C8.1 catalog identity is independent of database id and title', () {
    final first = PlaceModel.fromJson({
      ...legacyPlace(),
      'catalog_key': 'hermitage',
    });
    final migrated = PlaceModel.fromJson({
      ...legacyPlace(),
      'id': 9001,
      'title': 'Уточнённое название',
      'catalog_key': 'hermitage',
    });
    expect(migrated.catalogKey, first.catalogKey);
    expect(migrated.id, isNot(first.id));
  });

  test('C8.1 constructor does not serialize a malformed catalog identity', () {
    const place = PlaceModel(
      id: 1,
      catalogKey: 'INVALID-key',
      title: 'Место',
      shortDescription: 'Описание',
      category: PlaceCategoryEnum.nature,
      latitude: 59.93,
      longitude: 30.31,
      address: 'Санкт-Петербург',
    );
    expect(place.toJson()['catalog_key'], isNull);
  });
}
