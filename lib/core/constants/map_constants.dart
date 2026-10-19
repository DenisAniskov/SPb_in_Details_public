class MapConstants {
  // Координаты центра Санкт-Петербурга (Дворцовая площадь)
  static const double spbCenterLat = 59.939095;
  static const double spbCenterLon = 30.315868;

  static const double defaultZoom = 13.5;
  static const double placeDetailZoom = 15.5;
  static const double routeOverviewZoom = 12.5;

  // Ограничивающий прямоугольник Санкт-Петербурга
  static const double minLat = 59.70;
  static const double maxLat = 60.15;
  static const double minLon = 29.70;
  static const double maxLon = 30.85;

  // Популярные петербургские стартовые точки для ручного выбора
  static const List<Map<String, dynamic>> presetStartingHubs = [
    {
      'id': 'palace_square',
      'title': 'Дворцовая площадь',
      'subtitle': 'Главная площадь СПб, Зимний дворец',
      'lat': 59.939095,
      'lon': 30.315868,
    },
    {
      'id': 'gostiny_dvor',
      'title': 'Невский / Гостиный двор',
      'subtitle': 'Центр Невского проспекта',
      'lat': 59.934000,
      'lon': 30.334000,
    },
    {
      'id': 'vasileostrovskaya',
      'title': 'Стрелка Васильевского острова',
      'subtitle': 'Ростральные колонны, Биржа',
      'lat': 59.943889,
      'lon': 30.305556,
    },
    {
      'id': 'gorkovskaya',
      'title': 'Петроградская (м. Горьковская)',
      'subtitle': 'Александровский парк, Петропавловка',
      'lat': 59.956111,
      'lon': 30.318889,
    },
    {
      'id': 'vosstaniya',
      'title': 'Площадь Восстания',
      'subtitle': 'Московский вокзал, ТРЦ Галерея',
      'lat': 59.931667,
      'lon': 30.360556,
    },
    {
      'id': 'sennaya',
      'title': 'Сенная площадь',
      'subtitle': 'Пересадочный узел трех линий метро',
      'lat': 59.927222,
      'lon': 30.318611,
    },
  ];
}
