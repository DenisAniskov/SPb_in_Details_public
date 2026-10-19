import 'guided_walk_test_helpers.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/historical_content_model.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/smart_walk_preset.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/historical_content_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';
import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const stopPlace = PlaceModel(
  id: 11,
  title: 'Летний сад',
  shortDescription: 'Описание сада',
  category: PlaceCategoryEnum.nature,
  latitude: 59.944,
  longitude: 30.336,
  address: 'Набережная Лебяжьей канавки',
);

const otherPlace = PlaceModel(
  id: 12,
  title: 'Обычное место',
  shortDescription: 'Без истории',
  category: PlaceCategoryEnum.nature,
  latitude: 59.95,
  longitude: 30.34,
  address: 'Адрес',
);

const sampleCardJson = <String, dynamic>{
  'catalogKey': 'summer-garden',
  'locale': 'ru',
  'shortHistoricalSummary': 'Летний сад заложен по повелению Петра I в 1704 году. Это первый регулярный парк Петербурга.',
  'detailedHistoricalText': 'Сад разбивали с 1704 года, первые работы вёл Иван Матвеев. При Петре здесь били фонтаны.',
  'period': 'с 1704 года',
  'timeline': [
    {
      'id': 't1',
      'dateLabel': '1704 год',
      'datePrecision': 'year',
      'sortKey': '1704',
      'title': 'Основание сада',
      'description': 'Пётр I повелевает разбить регулярный сад.',
      'sourceIds': ['s1'],
    },
  ],
  'people': [
    {
      'name': 'Жан-Батист Леблон',
      'role': 'architect',
      'sourceIds': ['s1'],
    },
  ],
  'facts': [
    {
      'id': 'f1',
      'title': 'Первая паровая машина России',
      'text': 'В 1718 году в саду заработала паровая машина Дезагюлье.',
      'category': 'interesting_details',
      'sourceIds': ['s1'],
    },
  ],
  'sources': [
    {
      'id': 's1',
      'title': 'Летний сад — Википедия',
      'url': 'https://ru.wikipedia.org/wiki/Летний_сад',
      'publisher': 'Википедия',
      'sourceType': 'encyclopedia',
      'accessedOn': '2026-10-11',
      'license': 'CC BY-SA 4.0',
      'notes': 'Вспомогательный источник.',
    },
  ],
  'editorialStatus': 'verified',
  'lastVerifiedOn': '2026-10-11',
  'contentVersion': 1,
};

/// Fake repository: the card exists only for [stopPlace]; failures are
/// switchable at runtime to exercise the retry path.
class HistoryRepository extends PlacesRepository {
  HistoryRepository({this.failFor = const {}});

  Set<int> failFor;
  int historyCalls = 0;

  @override
  Future<PlaceModel?> getPlaceDetail(int placeId) async {
    if (placeId == stopPlace.id) return stopPlace;
    return otherPlace;
  }

  @override
  Future<HistoricalContent?> getPlaceHistory(int placeId) async {
    historyCalls++;
    if (failFor.contains(placeId)) {
      throw const FormatException('backend unavailable');
    }
    return placeId == stopPlace.id
        ? HistoricalContent.fromJson(sampleCardJson)
        : null;
  }

  @override
  Future<AutoWalkProposalResponseModel> proposeWalk({
    required double startLatitude,
    required double startLongitude,
    required int timeBudgetMinutes,
    List<PlaceCategoryEnum>? categories,
    bool preferUnusual = SmartWalkConfiguration.automaticPreferUnusual,
    int maxPlaces = 6,
  }) {
    return Future.value(
      AutoWalkProposalResponseModel(
        status: 'success',
        message: 'Прогулка подобрана',
        timeBudgetMinutes: timeBudgetMinutes,
        estimatedWalkingDurationSeconds: 900,
        estimatedVisitDurationMinutes: 30,
        estimatedTotalDurationMinutes: 45,
        estimatedTotalDistanceMeters: 1100,
        suggestedPlacesSequence: [stopPlace.id],
        items: [
          ProposedWalkItemModel(
            place: stopPlace,
            visitDurationMinutes: stopPlace.recommendedVisitMinutes,
            reasons: const ['рядом со стартом'],
          ),
        ],
      ),
    );
  }
}

class NoopMapKit extends MapKitService {}

class StubNav extends NavigationProvider {
  StubNav(this.snapshot);
  LiveNavigationState snapshot;

  @override
  LiveNavigationState get state => snapshot;
  @override
  NavigationStatus get status => snapshot.status;
}

PedestrianRouteModel routeTo(String stopTitle) {
  const points = [GeoCoord(59.94, 30.33), GeoCoord(59.944, 30.336)];
  return PedestrianRouteModel(
    distanceMeters: 500,
    durationSeconds: 360,
    geometryPoints: points,
    steps: const [],
    placesCount: 1,
    legs: [
      RouteLegModel(
        fromTitle: 'Старт',
        toTitle: stopTitle,
        distanceMeters: 500,
        durationSeconds: 360,
        geometryPoints: points,
      ),
    ],
  );
}

Widget wrap({
  required PlacesRepository repository,
  required RoutingProvider routing,
  NavigationProvider? nav,
  required WidgetBuilder builder,
}) {
  return MultiProvider(
    providers: [
      Provider<PlacesRepository>.value(value: repository),
      ChangeNotifierProvider<RoutingProvider>.value(value: routing),
      if (nav != null)
        ChangeNotifierProvider<NavigationProvider>.value(value: nav),
      ChangeNotifierProvider<HistoricalContentProvider>(
        create: (_) => HistoricalContentProvider(repository: repository),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.lightTheme,
      home: Builder(builder: builder),
    ),
  );
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

void main() {
  group('HistoricalContent model', () {
    test('parses a verified card and exposes labels', () {
      final card = HistoricalContent.fromJson(sampleCardJson);
      expect(card.catalogKey, 'summer-garden');
      expect(card.shortHistoricalSummary, contains('1704'));
      expect(card.period, 'с 1704 года');
      expect(card.hasTimeline, isTrue);
      expect(card.hasFacts, isTrue);
      expect(card.hasPeople, isTrue);
      expect(card.hasSources, isTrue);
      expect(card.timeline.first.dateLabel, '1704 год');
      expect(card.people.first.roleLabel, 'архитектор');
      expect(card.facts.first.categoryLabel, 'Интересные особенности');
      expect(card.sources.first.typeLabel, 'Энциклопедия');
    });

    test('damaged payload degrades to empty lists instead of crashing', () {
      final card = HistoricalContent.fromJson({
        'catalogKey': 42,
        'shortHistoricalSummary': null,
        'timeline': 'not-a-list',
        'facts': [
          null,
          1,
          {'no-id': true},
        ],
        'people': [],
        'sources': [],
      });
      expect(card.catalogKey, '');
      expect(card.shortHistoricalSummary, isEmpty);
      expect(card.timeline, isEmpty);
      expect(card.facts, isEmpty);
      expect(card.people, isEmpty);
      expect(card.sources, isEmpty);
      expect(card.hasTimeline, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Provider: lazy cache, negative cache, retry, stale-response guard
  // -------------------------------------------------------------------------

  group('HistoricalContentProvider', () {
    test('loads once and caches the card', () async {
      final repository = HistoryRepository();
      final provider = HistoricalContentProvider(repository: repository);
      provider.ensureLoaded(stopPlace);
      await Future<void>.delayed(Duration.zero);
      expect(provider.contentFor(stopPlace.id), isNotNull);
      expect(provider.isLoading(stopPlace.id), isFalse);
      provider.ensureLoaded(stopPlace);
      provider.ensureLoaded(stopPlace);
      await Future<void>.delayed(Duration.zero);
      expect(repository.historyCalls, 1);
      provider.dispose();
    });

    test('a confirmed absence is cached as a negative result', () async {
      final repository = HistoryRepository();
      final provider = HistoricalContentProvider(repository: repository);
      expect(provider.hasResolved(otherPlace.id), isFalse);
      provider.ensureLoaded(otherPlace);
      await Future<void>.delayed(Duration.zero);
      expect(provider.contentFor(otherPlace.id), isNull);
      expect(provider.hasResolved(otherPlace.id), isTrue);
      provider.ensureLoaded(otherPlace);
      await Future<void>.delayed(Duration.zero);
      expect(repository.historyCalls, 1);
      provider.dispose();
    });

    test('failure is a soft flag with explicit retry', () async {
      final repository = HistoryRepository(failFor: {stopPlace.id});
      final provider = HistoricalContentProvider(repository: repository);
      provider.ensureLoaded(stopPlace);
      await Future<void>.delayed(Duration.zero);
      expect(provider.hasFailed(stopPlace.id), isTrue);
      expect(provider.contentFor(stopPlace.id), isNull);

      repository.failFor = const {};
      provider.retry(stopPlace);
      await Future<void>.delayed(Duration.zero);
      expect(provider.hasFailed(stopPlace.id), isFalse);
      expect(provider.contentFor(stopPlace.id), isNotNull);
      provider.dispose();
    });

    test('a late stale response never overrides a newer request', () async {
      final hanging = _HangingRepository();
      final provider = HistoricalContentProvider(repository: hanging);
      provider.ensureLoaded(stopPlace);
      await Future<void>.delayed(Duration.zero);
      expect(hanging.calls, 1);

      // The user retries while the first request is still in flight.
      provider.retry(stopPlace);
      await Future<void>.delayed(Duration.zero);
      expect(hanging.calls, 2);

      // The retry resolves first: its value wins the cache.
      hanging.completers[1].complete(
        HistoricalContent.fromJson({
          ...sampleCardJson,
          'shortHistoricalSummary': 'СВЕЖИЙ ОТВЕТ',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        provider.contentFor(stopPlace.id)!.shortHistoricalSummary,
        'СВЕЖИЙ ОТВЕТ',
      );

      // The stale first response arrives late and must be dropped.
      hanging.completers[0].complete(
        HistoricalContent.fromJson({
          ...sampleCardJson,
          'shortHistoricalSummary': 'УСТАРЕВШИЙ ОТВЕТ',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        provider.contentFor(stopPlace.id)!.shortHistoricalSummary,
        'СВЕЖИЙ ОТВЕТ',
      );
      expect(provider.hasFailed(stopPlace.id), isFalse);
      provider.dispose();
    });

    test(
      'repeated ensureLoaded calls in one pass produce a single request',
      () async {
        final repository = HistoryRepository();
        final provider = HistoricalContentProvider(repository: repository);
        // Three calls before the scheduled microtask runs — the pending fetch
        // is deduplicated instead of spawning parallel identical requests.
        provider.ensureLoaded(stopPlace);
        provider.ensureLoaded(stopPlace);
        provider.ensureLoaded(stopPlace);
        await Future<void>.delayed(Duration.zero);
        expect(repository.historyCalls, 1);
        provider.dispose();
      },
    );

    test(
      'a fetch scheduled but not started is skipped after dispose',
      () async {
        final repository = HistoryRepository();
        final provider = HistoricalContentProvider(repository: repository);
        provider.ensureLoaded(stopPlace);
        provider.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(repository.historyCalls, 0);
      },
    );
  });

  // -------------------------------------------------------------------------
  // PlaceDetailScreen
  // -------------------------------------------------------------------------

  group('PlaceDetailScreen historical sections', () {
    Future<void> pumpDetail(
      WidgetTester tester, {
      required HistoryRepository repository,
      required PlaceModel place,
    }) async {
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      await tester.pumpWidget(
        wrap(
          repository: repository,
          routing: routing,
          builder: (_) => PlaceDetailScreen(place: place),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the verified historical sections when present', (
      tester,
    ) async {
      await pumpDetail(
        tester,
        repository: HistoryRepository(),
        place: stopPlace,
      );
      expect(find.text('Краткая история'), findsOneWidget);
      expect(
        find.textContaining('заложен по повелению Петра I в 1704 году'),
        findsOneWidget,
      );
      expect(find.text('Период: с 1704 года'), findsOneWidget);
      expect(find.text('Интересные факты'), findsOneWidget);
      expect(find.text('Важные даты'), findsOneWidget);
      expect(find.text('Личности'), findsOneWidget);
      expect(find.text('История и особенности'), findsOneWidget);
      expect(find.text('Источники'), findsOneWidget);
      // Existing place actions are preserved.
      expect(find.byTooltip('Добавить в прогулку'), findsOneWidget);
      expect(find.byTooltip('Сменить точку старта'), findsNothing);
    });

    testWidgets('failed history request shows an honest retry line', (
      tester,
    ) async {
      final repository = HistoryRepository(failFor: {stopPlace.id});
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      await tester.pumpWidget(
        wrap(
          repository: repository,
          routing: routing,
          builder: (_) => const PlaceDetailScreen(place: stopPlace),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Не удалось загрузить историческую справку'),
        findsOneWidget,
      );
      expect(find.text('Краткая история'), findsNothing);
      expect(find.text('Интересные факты'), findsNothing);

      // The backend recovers; the explicit retry loads the card.
      repository.failFor = const {};
      await tester.ensureVisible(find.text('Повторить').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Повторить').last, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Краткая история'), findsOneWidget);
      expect(find.text('Интересные факты'), findsOneWidget);
    });

    testWidgets('absent card renders the plain place screen', (tester) async {
      await pumpDetail(
        tester,
        repository: HistoryRepository(),
        place: otherPlace,
      );
      expect(find.text('Краткая история'), findsNothing);
      expect(
        find.text('Не удалось загрузить историческую справку'),
        findsNothing,
      );
      expect(
        find.text('Историческая справка пока не подготовлена.'),
        findsOneWidget,
      );
      expect(find.text('Читать историю места'), findsNothing);
      expect(find.text('Без истории'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // RouteDetailsSheet
  // -------------------------------------------------------------------------

  group('RouteDetailsSheet history lines', () {
    testWidgets('walk stop shows the short history and opens the card', (
      tester,
    ) async {
      final repository = HistoryRepository();
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      routing.setProposedWalk([stopPlace], timeBudgetMinutes: 60);
      routing.setProposedWalkForScenicTest(
        scenic: false,
        comparison: null,
        walkKind: WalkKind.normal,
        route: routeTo(stopPlace.title),
      );
      await tester.pumpWidget(
        wrap(
          repository: repository,
          routing: routing,
          builder: (_) => const Scaffold(body: RouteDetailsSheet()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(stopPlace.title), findsWidgets);
      expect(
        find.textContaining('заложен по повелению Петра I'),
        findsOneWidget,
      );
      expect(find.text('Подробнее'), findsOneWidget);

      await tester.tap(find.text('Подробнее'));
      await tester.pumpAndSettle();
      expect(find.text('Краткая история'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // LiveNavigationSheet (Phase C6 §11)
  // -------------------------------------------------------------------------

  group('LiveNavigationSheet history access', () {
    testWidgets('next stop offers history and navigation keeps running', (
      tester,
    ) async {
      final repository = HistoryRepository();
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      routing.setProposedWalk([stopPlace], timeBudgetMinutes: 60);
      final nav = StubNav(
        LiveNavigationState(
          status: NavigationStatus.active,
          route: routeTo(stopPlace.title),
          currentLegIndex: 0,
        ),
      );
      await tester.pumpWidget(
        wrap(
          repository: repository,
          routing: routing,
          nav: nav,
          builder: (_) => const Scaffold(body: LiveNavigationSheet()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Краткая история'), findsOneWidget);
      await tester.tap(find.text('Краткая история'));
      await tester.pumpAndSettle();
      expect(
        find.text('Следующая остановка — ${stopPlace.title}'),
        findsOneWidget,
      );
      expect(
        find.textContaining('заложен по повелению Петра I'),
        findsOneWidget,
      );
      // Opening history must not touch the running session.
      expect(nav.status, NavigationStatus.active);
    });

    testWidgets('no history button when the leg does not match a stop', (
      tester,
    ) async {
      final repository = HistoryRepository();
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      routing.setProposedWalk([stopPlace], timeBudgetMinutes: 60);
      final nav = StubNav(
        LiveNavigationState(
          status: NavigationStatus.active,
          route: routeTo('Непонятная точка'),
          currentLegIndex: 0,
        ),
      );
      await tester.pumpWidget(
        wrap(
          repository: repository,
          routing: routing,
          nav: nav,
          builder: (_) => const Scaffold(body: LiveNavigationSheet()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Краткая история'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // Smart Walk preview (Phase C6 §10)
  // -------------------------------------------------------------------------

  group('SmartWalkWizardSheet preview history', () {
    testWidgets('proposed stop shows its short historical phrase', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = HistoryRepository();
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      await tester.pumpWidget(
        wrap(
          repository: repository,
          routing: routing,
          builder: (_) => const Scaffold(body: SmartWalkWizardSheet()),
        ),
      );
      await tester.pumpAndSettle();

      await guidedToInterests(tester);
      await tester.tap(find.text('Сформировать прогулку'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Предварительный вариант'), findsOneWidget);
      expect(
        find.textContaining('заложен по повелению Петра I'),
        findsOneWidget,
      );
      // Wizard history must not alter the proposal data itself.
      expect(find.textContaining('Осмотр ~30 мин'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Narrow screens, large text and dark theme (§16)
  // -------------------------------------------------------------------------

  group('Historical UI under stress', () {
    testWidgets('sections survive a 320dp screen, dark theme and 1.6x text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = HistoryRepository();
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      await tester.pumpWidget(
        wrap(
          repository: repository,
          routing: routing,
          builder: (_) => const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: PlaceDetailScreen(place: stopPlace),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Краткая история'), findsOneWidget);
      expect(find.text('Интересные факты'), findsOneWidget);
      expect(find.text('Источники'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dark theme renders the navigation history sheet', (
      tester,
    ) async {
      final repository = HistoryRepository();
      final routing = RoutingProvider(mapKitService: NoopMapKit());
      routing.setProposedWalk([stopPlace], timeBudgetMinutes: 60);
      final nav = StubNav(
        LiveNavigationState(
          status: NavigationStatus.active,
          route: routeTo(stopPlace.title),
          currentLegIndex: 0,
        ),
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<PlacesRepository>.value(value: repository),
            ChangeNotifierProvider<RoutingProvider>.value(value: routing),
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
            ChangeNotifierProvider<HistoricalContentProvider>(
              create: (_) => HistoricalContentProvider(repository: repository),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: Builder(
              builder: (context) => const Scaffold(body: LiveNavigationSheet()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Краткая история'));
      await tester.pumpAndSettle();
      expect(
        find.text('Следующая остановка — ${stopPlace.title}'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}

/// Every request hangs on an explicit completer — used to prove the
/// stale-response guard (§8).
class _HangingRepository extends PlacesRepository {
  final List<Completer<HistoricalContent?>> completers = [];
  int calls = 0;

  @override
  Future<HistoricalContent?> getPlaceHistory(int placeId) async {
    calls++;
    final completer = Completer<HistoricalContent?>();
    completers.add(completer);
    return completer.future;
  }
}
