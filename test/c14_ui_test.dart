import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/city_highlights/city_highlight_model.dart';
import 'package:smart_navigator_spb/data/models/historical_content_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/city_viewpoint_provider.dart';
import 'package:smart_navigator_spb/providers/historical_content_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/tts_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/services/voice/tts_service.dart';
import 'package:smart_navigator_spb/services/voice/voice_settings.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';

const _hermitage = PlaceModel(
  id: 1,
  catalogKey: 'hermitage-winter-palace',
  title: 'Государственный Эрмитаж (Зимний дворец)',
  shortDescription: 'Главный музей города.',
  fullDescription: 'Зимний дворец на Дворцовой площади.',
  category: PlaceCategoryEnum.historyArchitecture,
  latitude: 59.9404659,
  longitude: 30.3137851,
  address: 'Дворцовая набережная, 38',
  recommendedVisitMinutes: 50,
);

const _singer = PlaceModel(
  id: 2,
  catalogKey: 'singer-house',
  title: 'Дом компании «Зингер»',
  shortDescription: 'Дом книги на Невском.',
  fullDescription: 'Угловое здание с башней и глобусом.',
  category: PlaceCategoryEnum.historyArchitecture,
  latitude: 59.9358632,
  longitude: 30.3258905,
  address: 'Невский проспект, 28',
  recommendedVisitMinutes: 20,
);

const _plain = PlaceModel(
  id: 3,
  title: 'Место без карточки C14',
  shortDescription: 'Обычная карточка места.',
  fullDescription: 'Описание обычного места.',
  category: PlaceCategoryEnum.nature,
  latitude: 59.94,
  longitude: 30.31,
  address: 'Адрес',
  recommendedVisitMinutes: 20,
);

class _C14Repository extends PlacesRepository {
  _C14Repository(this.places);

  final Map<int, PlaceModel> places;

  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async => places.values.toList(growable: false);

  @override
  Future<List<CategoryModel>> getCategories() async => const [];

  @override
  Future<PlaceModel?> getPlaceDetail(int placeId) async => places[placeId];

  @override
  Future<HistoricalContent?> getPlaceHistory(int placeId) async => null;
}

class _NoopMapKit extends MapKitService {}

class _FakeTts implements TtsService {
  final List<String> spoken = [];
  Completer<void>? pending;
  int stops = 0;
  TtsAvailability availability = const TtsAvailability(
    available: true,
    voices: [TtsVoice(name: 'ru-alpha', locale: 'ru-RU')],
  );

  @override
  Future<TtsAvailability> initialize() async => availability;

  @override
  Future<void> speak(
    String text, {
    required double rate,
    String? voiceName,
    String? voiceLocale,
  }) async {
    spoken.add(text);
    final gate = pending;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    final gate = pending;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> dispose() async {}
}

class _MemoryVoiceStore implements VoiceSettingsStore {
  @override
  Future<VoiceSettings> load() async => VoiceSettings.defaults;

  @override
  Future<void> save(VoiceSettings settings) async {}
}

Widget _detailApp({
  required PlaceModel place,
  required _C14Repository repository,
  required TtsProvider tts,
  required CityViewpointProvider viewpoints,
  required RoutingProvider routing,
  double textScale = 1,
  ThemeData? theme,
}) {
  return MultiProvider(
    providers: [
      Provider<PlacesRepository>.value(value: repository),
      ChangeNotifierProvider<RoutingProvider>.value(value: routing),
      ChangeNotifierProvider<HistoricalContentProvider>(
        create: (_) => HistoricalContentProvider(repository: repository),
      ),
      ChangeNotifierProvider<TtsProvider>.value(value: tts),
      ChangeNotifierProvider<CityViewpointProvider>.value(value: viewpoints),
    ],
    child: MaterialApp(
      theme: theme ?? AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: PlaceDetailScreen(place: place),
    ),
  );
}

void main() {
  group('C14 place card', () {
    testWidgets('shows attention, viewpoint and story when prepared', (
      tester,
    ) async {
      final repository = _C14Repository({_hermitage.id: _hermitage});
      final ttsService = _FakeTts();
      final navigation = NavigationProvider();
      final tts = TtsProvider(
        service: ttsService,
        store: _MemoryVoiceStore(),
        navigation: navigation,
      );
      await tts.initialize();
      final viewpoints = CityViewpointProvider();
      final routing = RoutingProvider(mapKitService: _NoopMapKit());
      addTearDown(() {
        tts.dispose();
        navigation.dispose();
        viewpoints.dispose();
        routing.dispose();
      });

      await tester.pumpWidget(
        _detailApp(
          place: _hermitage,
          repository: repository,
          tts: tts,
          viewpoints: viewpoints,
          routing: routing,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Обрати внимание'), findsOneWidget);
      expect(find.text('Посмотреть с другого ракурса'), findsOneWidget);
      expect(find.text('Показать на карте'), findsOneWidget);
      expect(find.text('Короткая история'), findsOneWidget);
      expect(find.text('Слушать'), findsOneWidget);
      expect(
        find.textContaining('балюстраду завершают статуи'),
        findsOneWidget,
      );
      expect(find.textContaining('Елизаветы Петровны'), findsOneWidget);
      // Opening the card must never start sound on its own.
      expect(ttsService.spoken, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('partial content omits the absent viewpoint section', (
      tester,
    ) async {
      final repository = _C14Repository({_singer.id: _singer});
      final ttsService = _FakeTts();
      final navigation = NavigationProvider();
      final tts = TtsProvider(
        service: ttsService,
        store: _MemoryVoiceStore(),
        navigation: navigation,
      );
      await tts.initialize();
      final viewpoints = CityViewpointProvider();
      final routing = RoutingProvider(mapKitService: _NoopMapKit());
      addTearDown(() {
        tts.dispose();
        navigation.dispose();
        viewpoints.dispose();
        routing.dispose();
      });

      await tester.pumpWidget(
        _detailApp(
          place: _singer,
          repository: repository,
          tts: tts,
          viewpoints: viewpoints,
          routing: routing,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Обрати внимание'), findsOneWidget);
      expect(find.text('Короткая история'), findsOneWidget);
      expect(find.text('Посмотреть с другого ракурса'), findsNothing);
      expect(find.text('Показать на карте'), findsNothing);
    });

    testWidgets('a place without a card keeps the ordinary card intact', (
      tester,
    ) async {
      final repository = _C14Repository({_plain.id: _plain});
      final ttsService = _FakeTts();
      final navigation = NavigationProvider();
      final tts = TtsProvider(
        service: ttsService,
        store: _MemoryVoiceStore(),
        navigation: navigation,
      );
      await tts.initialize();
      final viewpoints = CityViewpointProvider();
      final routing = RoutingProvider(mapKitService: _NoopMapKit());
      addTearDown(() {
        tts.dispose();
        navigation.dispose();
        viewpoints.dispose();
        routing.dispose();
      });

      await tester.pumpWidget(
        _detailApp(
          place: _plain,
          repository: repository,
          tts: tts,
          viewpoints: viewpoints,
          routing: routing,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(_plain.title), findsOneWidget);
      expect(find.text('Обрати внимание'), findsNothing);
      expect(find.text('Посмотреть с другого ракурса'), findsNothing);
      expect(find.text('Короткая история'), findsNothing);
      expect(find.text('Слушать'), findsNothing);
      expect(find.text('Спросить ИИ об этом месте'), findsOneWidget);
    });

    testWidgets('show-on-map publishes the verified viewpoint only', (
      tester,
    ) async {
      final repository = _C14Repository({_hermitage.id: _hermitage});
      final ttsService = _FakeTts();
      final navigation = NavigationProvider();
      final tts = TtsProvider(
        service: ttsService,
        store: _MemoryVoiceStore(),
        navigation: navigation,
      );
      await tts.initialize();
      final viewpoints = CityViewpointProvider();
      final routing = RoutingProvider(mapKitService: _NoopMapKit());
      addTearDown(() {
        tts.dispose();
        navigation.dispose();
        viewpoints.dispose();
        routing.dispose();
      });

      await tester.pumpWidget(
        _detailApp(
          place: _hermitage,
          repository: repository,
          tts: tts,
          viewpoints: viewpoints,
          routing: routing,
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Показать на карте'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Показать на карте'));
      await tester.pumpAndSettle();

      expect(viewpoints.session?.viewpoint.name, 'Дворцовый мост');
      expect(viewpoints.session?.place.catalogKey, _hermitage.catalogKey);
      expect(routing.hasRoute, isFalse);
    });

    testWidgets('story playback is explicit, stoppable and stops on dispose', (
      tester,
    ) async {
      final repository = _C14Repository({_hermitage.id: _hermitage});
      final ttsService = _FakeTts();
      final navigation = NavigationProvider();
      final tts = TtsProvider(
        service: ttsService,
        store: _MemoryVoiceStore(),
        navigation: navigation,
      );
      await tts.initialize();
      ttsService.pending = Completer<void>();
      final stopsBefore = ttsService.stops;
      final viewpoints = CityViewpointProvider();
      final routing = RoutingProvider(mapKitService: _NoopMapKit());
      addTearDown(() {
        tts.dispose();
        navigation.dispose();
        viewpoints.dispose();
        routing.dispose();
        final gate = ttsService.pending;
        if (gate != null && !gate.isCompleted) gate.complete();
      });

      await tester.pumpWidget(
        _detailApp(
          place: _hermitage,
          repository: repository,
          tts: tts,
          viewpoints: viewpoints,
          routing: routing,
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Слушать'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Слушать'));
      await tester.pump();

      expect(ttsService.spoken, hasLength(1));
      expect(ttsService.spoken.single, contains('Зимний дворец'));
      expect(find.text('Остановить'), findsOneWidget);
      expect(tts.isNarrating, isTrue);

      await tester.tap(find.text('Остановить'));
      await tester.pumpAndSettle();

      expect(ttsService.stops, stopsBefore + 1);
      expect(tts.isNarrating, isFalse);
      expect(find.text('Слушать'), findsOneWidget);

      // Starting again and destroying the card must not leave a voice behind.
      ttsService.pending = Completer<void>();
      await tester.tap(find.text('Слушать'));
      await tester.pump();
      expect(tts.isNarrating, isTrue);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Готово'))),
      );
      await tester.pump();

      expect(ttsService.stops, stopsBefore + 2);
      expect(tts.isNarrating, isFalse);
    });

    testWidgets('no Russian engine disables the button with an honest note', (
      tester,
    ) async {
      final repository = _C14Repository({_hermitage.id: _hermitage});
      final ttsService = _FakeTts()
        ..availability = const TtsAvailability(
          available: false,
          message: 'Русский голос не установлен.',
        );
      final navigation = NavigationProvider();
      final tts = TtsProvider(
        service: ttsService,
        store: _MemoryVoiceStore(),
        navigation: navigation,
      );
      await tts.initialize();
      final viewpoints = CityViewpointProvider();
      final routing = RoutingProvider(mapKitService: _NoopMapKit());
      addTearDown(() {
        tts.dispose();
        navigation.dispose();
        viewpoints.dispose();
        routing.dispose();
      });

      await tester.pumpWidget(
        _detailApp(
          place: _hermitage,
          repository: repository,
          tts: tts,
          viewpoints: viewpoints,
          routing: routing,
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Слушать'));
      await tester.pumpAndSettle();
      expect(
        find.text('Озвучивание недоступно на этом устройстве.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Слушать'), warnIfMissed: false);
      await tester.pump();
      expect(ttsService.spoken, isEmpty);
      expect(tts.isNarrating, isFalse);
    });

    testWidgets('a viewpoint cannot take over during active navigation', (
      tester,
    ) async {
      final repository = _C14Repository({_hermitage.id: _hermitage});
      final ttsService = _FakeTts();
      final navigation = NavigationProvider();
      final tts = TtsProvider(
        service: ttsService,
        store: _MemoryVoiceStore(),
        navigation: navigation,
      );
      await tts.initialize();
      final viewpoints = CityViewpointProvider();
      final routing = RoutingProvider(mapKitService: _NoopMapKit());
      addTearDown(() {
        tts.dispose();
        navigation.dispose();
        viewpoints.dispose();
        routing.dispose();
      });
      routing.setNavigationLocked(true);

      await tester.pumpWidget(
        _detailApp(
          place: _hermitage,
          repository: repository,
          tts: tts,
          viewpoints: viewpoints,
          routing: routing,
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Показать на карте'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Показать на карте'));
      await tester.pump();

      expect(viewpoints.session, isNull);
      expect(find.text('Сначала завершите текущую навигацию.'), findsOneWidget);
    });

    testWidgets('opening another place stops the previous story', (
      tester,
    ) async {
      final repository = _C14Repository({
        _hermitage.id: _hermitage,
        _singer.id: _singer,
      });
      final ttsService = _FakeTts();
      final navigation = NavigationProvider();
      final tts = TtsProvider(
        service: ttsService,
        store: _MemoryVoiceStore(),
        navigation: navigation,
      );
      await tts.initialize();
      ttsService.pending = Completer<void>();
      final stopsBefore = ttsService.stops;
      final viewpoints = CityViewpointProvider();
      final routing = RoutingProvider(mapKitService: _NoopMapKit());
      addTearDown(() {
        tts.dispose();
        navigation.dispose();
        viewpoints.dispose();
        routing.dispose();
        final gate = ttsService.pending;
        if (gate != null && !gate.isCompleted) gate.complete();
      });

      await tester.pumpWidget(
        _detailApp(
          place: _hermitage,
          repository: repository,
          tts: tts,
          viewpoints: viewpoints,
          routing: routing,
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Слушать'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Слушать'));
      await tester.pump();
      expect(tts.isNarrating, isTrue);

      Navigator.of(tester.element(find.byType(PlaceDetailScreen))).push(
        MaterialPageRoute<void>(
          builder: (_) => const PlaceDetailScreen(place: _singer),
        ),
      );
      await tester.pumpAndSettle();

      expect(tts.isNarrating, isFalse);
      expect(ttsService.stops, stopsBefore + 1);
      expect(find.text(_singer.title), findsOneWidget);
      expect(find.text('Короткая история'), findsOneWidget);
      expect(find.text('Посмотреть с другого ракурса'), findsNothing);
    });

    for (final entry in {
      'light': AppTheme.lightTheme,
      'dark': AppTheme.darkTheme,
    }.entries) {
      testWidgets(
        'compact 320x480 at text scale 1.6 stays usable (${entry.key})',
        (tester) async {
          tester.view.physicalSize = const Size(320, 480);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final repository = _C14Repository({_hermitage.id: _hermitage});
          final ttsService = _FakeTts();
          final navigation = NavigationProvider();
          final tts = TtsProvider(
            service: ttsService,
            store: _MemoryVoiceStore(),
            navigation: navigation,
          );
          await tts.initialize();
          final viewpoints = CityViewpointProvider();
          final routing = RoutingProvider(mapKitService: _NoopMapKit());
          addTearDown(() {
            tts.dispose();
            navigation.dispose();
            viewpoints.dispose();
            routing.dispose();
          });

          await tester.pumpWidget(
            _detailApp(
              place: _hermitage,
              repository: repository,
              tts: tts,
              viewpoints: viewpoints,
              routing: routing,
              textScale: 1.6,
              theme: entry.value,
            ),
          );
          await tester.pumpAndSettle();

          await tester.scrollUntilVisible(
            find.text('Короткая история'),
            260,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(find.text('Короткая история'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  group('C14 map viewpoint overlay', () {
    testWidgets('map card returns to the place and can be closed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      MapKitService.isMapKitInitialized = false;
      addTearDown(() => MapKitService.isMapKitInitialized = false);

      final repository = _C14Repository({_hermitage.id: _hermitage});
      final places = PlacesProvider(repository: repository);
      final routing = RoutingProvider(mapKitService: _NoopMapKit());
      final viewpoints = CityViewpointProvider();
      final history = HistoricalContentProvider(repository: repository);
      addTearDown(() {
        places.dispose();
        routing.dispose();
        viewpoints.dispose();
        history.dispose();
      });
      // The known card is loaded directly from the catalog in the card widget;
      // this test only needs a valid session.
      const viewpoint = CityViewpoint(
        name: 'Дворцовый мост',
        description: 'Вид вдоль Невы.',
        latitude: 59.9410186,
        longitude: 30.3087045,
        sourceUrl: 'https://www.openstreetmap.org/node/4271175480',
        verifiedOn: '2026-10-18',
      );
      viewpoints.show(_hermitage, viewpoint);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<PlacesRepository>.value(value: repository),
            ChangeNotifierProvider<PlacesProvider>.value(value: places),
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
            ChangeNotifierProvider<HistoricalContentProvider>.value(
              value: history,
            ),
            ChangeNotifierProvider<CityViewpointProvider>.value(
              value: viewpoints,
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const MainMapScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Точка обзора'), findsOneWidget);
      expect(find.text('Дворцовый мост'), findsOneWidget);
      expect(find.text('Вернуться к карточке'), findsOneWidget);

      await tester.tap(find.text('Вернуться к карточке'));
      await tester.pumpAndSettle();
      expect(find.byType(PlaceDetailScreen), findsOneWidget);
      expect(find.text(_hermitage.title), findsOneWidget);

      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.text('Точка обзора'), findsOneWidget);

      await tester.tap(find.byTooltip('Закрыть точку обзора'));
      await tester.pumpAndSettle();
      expect(find.text('Точка обзора'), findsNothing);
      expect(viewpoints.session, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
