import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/city_highlights/city_highlight_model.dart';
import 'package:smart_navigator_spb/data/city_highlights/city_highlights_catalog.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/providers/city_viewpoint_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/viewpoint_preview_card.dart';

const _hermitage = PlaceModel(
  id: 1,
  catalogKey: 'hermitage-winter-palace',
  title: 'Государственный Эрмитаж (Зимний дворец)',
  shortDescription: 'Главный музей города.',
  category: PlaceCategoryEnum.historyArchitecture,
  latitude: 59.9404659,
  longitude: 30.3137851,
  address: 'Дворцовая набережная, 38',
);

const _unknown = PlaceModel(
  id: 999,
  title: 'Место без карточки C14',
  shortDescription: 'Описание',
  category: PlaceCategoryEnum.nature,
  latitude: 59.94,
  longitude: 30.31,
  address: 'Адрес',
);

void main() {
  group('C14 content catalog', () {
    test('covers 8–12 existing places with unique valid keys', () {
      expect(CityHighlightsCatalog.entries.length, inInclusiveRange(8, 12));
      final keys = <String>{};
      for (final entry in CityHighlightsCatalog.entries) {
        expect(entry.catalogKey, matches(RegExp(r'^[a-z][a-z0-9-]{0,79}$')));
        expect(keys.add(entry.catalogKey), isTrue, reason: entry.catalogKey);
        expect(entry.verifiedOn, '2026-10-18');
      }
    });

    test('every card has 1–3 visual hints and a short story', () {
      for (final entry in CityHighlightsCatalog.entries) {
        expect(entry.hasAttentionHints, isTrue, reason: entry.catalogKey);
        expect(
          entry.attentionHints.length,
          inInclusiveRange(1, 3),
          reason: entry.catalogKey,
        );
        for (final hint in entry.attentionHints) {
          expect(hint.trim(), isNotEmpty);
          expect(hint.length, lessThanOrEqualTo(240));
        }
        expect(entry.hasShortStory, isTrue, reason: entry.catalogKey);
        final words = entry.shortStory!
            .trim()
            .split(RegExp(r'\s+'))
            .where((word) => word.isNotEmpty)
            .length;
        // 20–45 seconds at a calm Russian reading pace.
        expect(words, inInclusiveRange(45, 110), reason: entry.catalogKey);
      }
    });

    test('sources are https and include a non-map reference', () {
      for (final entry in CityHighlightsCatalog.entries) {
        expect(entry.sources.length, greaterThanOrEqualTo(2));
        for (final source in entry.sources) {
          expect(source.title.trim(), isNotEmpty);
          expect(source.url, startsWith('https://'));
          expect(source.sourceType, isNotEmpty);
        }
        expect(
          entry.sources.any((source) => source.sourceType != 'map'),
          isTrue,
          reason: entry.catalogKey,
        );
        expect(entry.primarySource?.sourceType, isNot('map'));
      }
    });

    test('all eight viewpoints use valid public OSM coordinates', () {
      final withViewpoints = CityHighlightsCatalog.entries
          .where((entry) => entry.hasViewpoint)
          .toList();
      expect(withViewpoints.length, 8);
      for (final entry in withViewpoints) {
        final viewpoint = entry.viewpoint!;
        expect(viewpoint.hasValidCoordinates, isTrue);
        expect(viewpoint.latitude, inInclusiveRange(-90, 90));
        expect(viewpoint.longitude, inInclusiveRange(-180, 180));
        expect(
          viewpoint.sourceUrl,
          startsWith('https://www.openstreetmap.org/'),
        );
        expect(viewpoint.verifiedOn, entry.verifiedOn);
        expect(viewpoint.description.trim(), isNotEmpty);
        expect(viewpoint.name.trim(), isNotEmpty);
        expect(
          entry.sources.any((source) => source.url == viewpoint.sourceUrl),
          isTrue,
          reason: entry.catalogKey,
        );
      }
    });

    test('lookup uses catalog identity and never guesses by title', () {
      expect(
        CityHighlightsCatalog.forPlace(_hermitage)?.catalogKey,
        'hermitage-winter-palace',
      );
      expect(CityHighlightsCatalog.forPlace(_unknown), isNull);
      expect(CityHighlightsCatalog.forCatalogKey(null), isNull);
      expect(CityHighlightsCatalog.forCatalogKey('missing-place'), isNull);
    });

    test('invalid coordinates hide the viewpoint instead of showing a pin', () {
      const invalid = CityViewpoint(
        name: 'Неверная точка',
        description: 'Описание',
        latitude: 200,
        longitude: 30,
        sourceUrl: 'https://www.openstreetmap.org/node/1',
        verifiedOn: '2026-10-18',
      );
      const card = CityHighlight(
        catalogKey: 'test',
        viewpoint: invalid,
        verifiedOn: '2026-10-18',
      );
      expect(card.hasViewpoint, isFalse);
    });
  });

  group('CityViewpointProvider', () {
    test('publishes and clears one explicit viewpoint session', () {
      final provider = CityViewpointProvider();
      var notifications = 0;
      provider.addListener(() => notifications++);
      final viewpoint = CityHighlightsCatalog.forPlace(_hermitage)!.viewpoint!;

      provider.show(_hermitage, viewpoint);
      expect(provider.session?.place.catalogKey, _hermitage.catalogKey);
      expect(provider.session?.viewpoint.name, 'Дворцовый мост');

      provider.clear();
      expect(provider.session, isNull);
      expect(notifications, 2);
      provider.dispose();
    });

    test('rejects a session without usable coordinates', () {
      final provider = CityViewpointProvider();
      provider.show(
        _hermitage,
        const CityViewpoint(
          name: 'Неверная точка',
          description: 'Описание',
          latitude: double.nan,
          longitude: 30,
          sourceUrl: 'https://www.openstreetmap.org/node/1',
          verifiedOn: '2026-10-18',
        ),
      );
      expect(provider.session, isNull);
      provider.dispose();
    });
  });

  group('ViewpointPreviewCard', () {
    const viewpoint = CityViewpoint(
      name: 'Дворцовый мост',
      description: 'С Дворцового моста дворец виден вдоль Невы: в кадр попадают фасад, набережная и отражение в воде.',
      latitude: 59.9410186,
      longitude: 30.3087045,
      sourceUrl: 'https://www.openstreetmap.org/node/4271175480',
      verifiedOn: '2026-10-18',
    );
    const session = CityViewpointSession(
      place: _hermitage,
      viewpoint: viewpoint,
    );

    testWidgets('offers both explicit actions on a compact screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var opened = 0;
      var routed = 0;
      var closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ViewpointPreviewCard(
                session: session,
                onClose: () => closed++,
                onOpenPlace: () => opened++,
                onBuildRoute: () => routed++,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Точка обзора'), findsOneWidget);
      expect(find.text('Дворцовый мост'), findsOneWidget);
      expect(find.text('Вернуться к карточке'), findsOneWidget);
      expect(find.text('Маршрут к точке'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Вернуться к карточке'));
      await tester.tap(find.text('Маршрут к точке'));
      await tester.tap(find.byTooltip('Закрыть точку обзора'));
      expect(opened, 1);
      expect(routed, 1);
      expect(closed, 1);
    });

    testWidgets('the route action disappears during navigation lock', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: ViewpointPreviewCard(
              session: session,
              onClose: () {},
              onOpenPlace: () {},
            ),
          ),
        ),
      );
      expect(find.text('Маршрут к точке'), findsNothing);
      expect(find.text('Вернуться к карточке'), findsOneWidget);
    });
  });
}
