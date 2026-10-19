import 'guided_walk_test_helpers.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/walk_planner_sheet.dart';
import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';

PlaceModel poi(
  int id, {
  PlaceCategoryEnum category = PlaceCategoryEnum.historyArchitecture,
  bool unusual = false,
  int visit = 20,
}) => PlaceModel(
  id: id,
  title:
      'Очень длинное русское название редакторского места $id для проверки переноса строк',
  shortDescription: 'Описание',
  category: category,
  latitude: 59.94,
  longitude: 30.31,
  address: 'СПб',
  recommendedVisitMinutes: visit,
  isUnusual: unusual,
);

AutoWalkProposalResponseModel proposal({int budget = 120, bool empty = false}) {
  final places = empty
      ? <PlaceModel>[]
      : [poi(1), poi(2, category: PlaceCategoryEnum.art)];
  return AutoWalkProposalResponseModel(
    status: empty ? 'empty' : 'success',
    message: empty ? 'Ни одно место не помещается' : 'Предварительный подбор',
    timeBudgetMinutes: budget,
    estimatedWalkingDurationSeconds: 120,
    estimatedVisitDurationMinutes: empty ? 0 : 40,
    estimatedTotalDurationMinutes: empty ? 0 : 42,
    estimatedTotalDistanceMeters: empty ? 0 : 150,
    suggestedPlacesSequence: places.map((p) => p.id).toList(),
    items: places
        .map(
          (p) => ProposedWalkItemModel(
            place: p,
            visitDurationMinutes: 20,
            reasons: ['Предварительная геометрическая оценка'],
          ),
        )
        .toList(),
  );
}

class PendingRepository extends PlacesRepository {
  final pending = <Completer<AutoWalkProposalResponseModel>>[];
  final parameters = <(int, List<PlaceCategoryEnum>?, bool, double)>[];
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async => [];
  @override
  Future<List<CategoryModel>> getCategories() async => [];
  @override
  Future<AutoWalkProposalResponseModel> proposeWalk({
    required double startLatitude,
    required double startLongitude,
    required int timeBudgetMinutes,
    List<PlaceCategoryEnum>? categories,
    bool preferUnusual = false,
    int maxPlaces = 6,
  }) {
    parameters.add((
      timeBudgetMinutes,
      categories,
      preferUnusual,
      startLatitude,
    ));
    final c = Completer<AutoWalkProposalResponseModel>();
    pending.add(c);
    return c.future;
  }
}

class NativeRouteAdapter extends MapKitService {
  final calls = <(RoutePointModel, List<PlaceModel>)>[];
  final pending = <Completer<PedestrianRouteModel>>[];
  bool wait = false;
  bool fail = false;
  int Function(int count) seconds = (_) => 120;
  @override
  void cancel() {}
  @override
  Future<PedestrianRouteModel> calculateWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
  }) async {
    calls.add((startPoint, List.of(places)));
    if (fail) throw StateError('Native leg failure');
    if (wait) {
      final c = Completer<PedestrianRouteModel>();
      pending.add(c);
      return c.future;
    }
    return route(seconds(places.length), places.length);
  }
}

PedestrianRouteModel route(int seconds, int count) => PedestrianRouteModel(
  distanceMeters: count * 100,
  durationSeconds: seconds,
  geometryPoints: [GeoCoord(count.toDouble(), 0)],
  steps: [],
  placesCount: count,
  legs: [
    RouteLegModel(
      fromTitle: 'Старт',
      toTitle: 'Финиш',
      distanceMeters: count * 100,
      durationSeconds: seconds,
      geometryPoints: [GeoCoord(count.toDouble(), 0)],
    ),
  ],
);

Future<void> mountWizard(
  WidgetTester tester,
  PendingRepository repo,
  RoutingProvider routing, {
  Size size = const Size(320, 640),
  double keyboard = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  final places = PlacesProvider(repository: repo);
  addTearDown(places.dispose);
  addTearDown(routing.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
        ChangeNotifierProvider<PlacesProvider>.value(value: places),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => SmartWalkWizardSheet(repository: repo),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть'));
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  test('correction terminates after at most six builds without publishing an impossible route', () async {
    final native = NativeRouteAdapter()..seconds = (_) => 10000;
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    routing.setProposedWalk(
      List.generate(6, (i) => poi(i + 1)),
      timeBudgetMinutes: 30,
    );
    await routing.buildWalkRoute();
    expect(
      native.calls.length,
      lessThanOrEqualTo(RoutingProvider.maxWalkRouteAttempts),
    );
    expect(
      native.calls.fold<int>(0, (sum, call) => sum + call.$2.length),
      lessThanOrEqualTo(RoutingProvider.maxNativeWalkLegRequests),
    );
    expect(routing.status, RoutingStatus.error);
    expect(routing.currentRoute, isNull);
    expect(
      routing.walkPlaces.length,
      6,
    ); // Transactional: original list survives failure.
  });

  test(
    'changing start while native request is pending discards old refinement',
    () async {
      final native = NativeRouteAdapter()..wait = true;
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk([poi(1), poi(2)], timeBudgetMinutes: 60);
      final old = routing.buildWalkRoute();
      routing.setCustomStartPoint(60, 31);
      expect(native.pending.length, 2);
      native.pending.last.complete(route(120, 2));
      await Future<void>.delayed(Duration.zero);
      native.pending.first.complete(route(10000, 2));
      await old;
      expect(native.calls.length, 2);
      expect(routing.hasRoute, isTrue);
      expect(routing.currentRoute!.durationSeconds, 120);
      expect(routing.startPoint.latitude, 60);
    },
  );

  test(
    'transfer deduplicates ordered IDs, caps six, and invalidates old route',
    () async {
      final native = NativeRouteAdapter();
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk([
        poi(1),
        poi(1),
        ...List.generate(7, (i) => poi(i + 2)),
      ]);
      expect(routing.walkPlaces.map((p) => p.id), [1, 2, 3, 4, 5, 6]);
      await routing.buildWalkRoute();
      expect(routing.hasRoute, isTrue);
      routing.setProposedWalk([poi(3)]);
      expect(routing.currentRoute, isNull);
      expect(routing.removePlaceFromWalk, isNotNull);
      expect(routing.addPlaceToWalk(poi(4)), isTrue);
      routing.removePlaceFromWalk(3);
      expect(routing.walkPlaces.single.id, 4);
    },
  );

  test('MapKit correction protects category coverage and unusual value, rebuilds totals/geometry', () async {
    final native = NativeRouteAdapter()
      ..seconds = (count) => count == 3 ? 90 * 60 : 70 * 60;
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    routing.setProposedWalk(
      [poi(1, unusual: true), poi(2), poi(3, category: PlaceCategoryEnum.art)],
      categories: {
        PlaceCategoryEnum.historyArchitecture,
        PlaceCategoryEnum.art,
      },
      preferUnusual: true,
      timeBudgetMinutes: 120,
      reasons: {
        1: ['old order'],
      },
    );
    await routing.buildWalkRoute();
    expect(routing.walkPlaces.map((p) => p.id), [1, 3]);
    expect(native.calls.length, 2);
    expect(native.calls.last.$2.map((p) => p.id), [1, 3]);
    expect(routing.currentRoute!.distanceMeters, 200);
    expect(routing.currentRoute!.geometryPoints.single.latitude, 2);
    expect(routing.totalWalkDurationSeconds, 110 * 60);
    expect(routing.placeReasons, isEmpty);
    expect(routing.budgetWarningMessage, isNotNull);
  });

  test(
    'no hidden +15 minutes; impossible single POI has no successful route',
    () async {
      final native = NativeRouteAdapter()..seconds = (_) => 10 * 60 + 1;
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk([poi(1)], timeBudgetMinutes: 30);
      await routing.buildWalkRoute();
      expect(routing.status, RoutingStatus.error);
      expect(routing.hasRoute, isFalse);
      expect(routing.totalWalkDurationSeconds, isNull);
      expect(native.calls.length, 1);
    },
  );

  test('stale native result cannot correct a newer accepted list', () async {
    final native = NativeRouteAdapter()..wait = true;
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    routing.setProposedWalk([poi(1), poi(2)], timeBudgetMinutes: 30);
    final old = routing.buildWalkRoute();
    routing.setProposedWalk([poi(3)]);
    native.pending.first.complete(route(10000, 2));
    await old;
    expect(native.calls.length, 1);
    expect(routing.walkPlaces.single.id, 3);
    expect(routing.currentRoute, isNull);
    expect(routing.budgetWarningMessage, isNull);
  });

  test('reorder rebuilds actual route and changing start retains Smart Walk budget', () async {
    final native = NativeRouteAdapter();
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    routing.setProposedWalk([poi(1), poi(2)], timeBudgetMinutes: 60);
    await routing.buildWalkRoute();
    routing.reorderWalkPlaces(0, 2);
    expect(routing.currentRoute, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(native.calls.last.$2.map((p) => p.id), [2, 1]);
    expect(routing.hasRoute, isTrue);
    native.seconds = (_) => 100 * 60;
    routing.setCustomStartPoint(60, 31);
    expect(routing.currentRoute, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(native.calls.last.$1.latitude, 60);
    expect(
      routing.status,
      RoutingStatus.error,
    ); // Budget was not silently dropped.
  });

  test('segment failure publishes no partial geometry or total', () async {
    final native = NativeRouteAdapter()..fail = true;
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    routing.setProposedWalk([poi(1), poi(2)]);
    await routing.buildWalkRoute();
    expect(routing.status, RoutingStatus.error);
    expect(routing.currentRoute, isNull);
    expect(routing.totalWalkDurationSeconds, isNull);
  });

  test(
    'visit model validates backend values and handles legacy missing field',
    () {
      final json = poi(1).toJson();
      json.remove('recommended_visit_minutes');
      expect(PlaceModel.fromJson(json).recommendedVisitMinutes, 30);
      for (final minutes in [0, 181, 12.5]) {
        json['recommended_visit_minutes'] = minutes;
        expect(() => PlaceModel.fromJson(json), throwsFormatException);
      }
    },
  );

  for (final edit in [
    'preset',
    'category',
    'start',
    'close',
    'navigation lock',
  ]) {
    testWidgets('wizard ignores pending proposal after $edit', (tester) async {
      final repo = PendingRepository();
      final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
      await mountWizard(tester, repo, routing);
      await guidedToInterests(tester);
      await tapVisible(tester, find.text('Сформировать прогулку'));
      expect(repo.pending.length, 1);
      if (edit == 'preset') {
        await tapVisible(tester, find.text('Назад'));
        await tapVisible(tester, find.text('Назад'));
        await tapVisible(tester, find.text('Быстрая прогулка'));
      }
      if (edit == 'category') {
        await tapVisible(tester, find.text('Назад'));
        await tapVisible(tester, find.text('Искусство'));
      }
      if (edit == 'navigation lock') {
        routing.setNavigationLocked(true);
        await tester.pump();
      }
      if (edit == 'start') {
        routing.setCustomStartPoint(60, 31);
        await tester.pump();
      }
      if (edit == 'close') {
        await tapVisible(tester, find.byIcon(Icons.close));
        await tester.pumpAndSettle();
      }
      repo.pending.first.complete(proposal());
      await tester.pumpAndSettle();
      expect(find.text('Предварительный подбор'), findsNothing);
      expect(tester.takeException(), isNull);
      if (edit == 'close') {
        await tester.tap(find.text('Открыть'));
        await tester.pumpAndSettle();
        expect(find.text('Предварительный подбор'), findsNothing);
      }
    });
  }

  testWidgets(
    'full wizard preference parameters, preview, transfer and real-route adapter on 320px',
    (tester) async {
      final repo = PendingRepository();
      final native = NativeRouteAdapter();
      final routing = RoutingProvider(mapKitService: native);
      await mountWizard(tester, repo, routing);
      await guidedTap(tester, 'Продолжить');
      await guidedTap(tester, 'Продолжить');
      expect(find.text('Быстрая прогулка'), findsOneWidget);
      expect(find.text('Обычная прогулка'), findsOneWidget);
      expect(find.text('Погулять подольше'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('Предпочитать необычные места'), findsNothing);
      await guidedTap(tester, 'Продолжить');
      await tapVisible(tester, find.text('История и архитектура'));
      await tapVisible(tester, find.text('Искусство'));
      await tapVisible(tester, find.text('Сформировать прогулку'));
      expect(repo.parameters.single.$1, 120);
      expect(repo.parameters.single.$2!.length, 2);
      expect(repo.parameters.single.$3, isTrue);
      repo.pending.first.complete(proposal());
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Построить прогулку'));
      await tester.pumpAndSettle();
      expect(routing.hasRoute, isFalse);
      await guidedPublish(tester);
      expect(routing.walkPlaces.map((p) => p.id), [1, 2]);
      expect(routing.hasRoute, isTrue);
      expect(routing.totalWalkDurationSeconds, 42 * 60);
      expect(native.calls.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wizard empty/error/scrolling with small height and keyboard', (
    tester,
  ) async {
    final repo = PendingRepository();
    final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
    await mountWizard(
      tester,
      repo,
      routing,
      size: const Size(320, 420),
      keyboard: 140,
    );
    await guidedToInterests(tester, preset: 'Быстрая прогулка');
    await tapVisible(tester, find.text('Сформировать прогулку'));
    repo.pending.first.complete(proposal(budget: 60, empty: true));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Ни одно место не помещается'));
    await tester.pumpAndSettle();
    expect(find.text('Построить прогулку'), findsNothing);
    await tapVisible(tester, find.text('Подобрать другой вариант'));
    repo.pending.last.completeError(StateError('Backend недоступен'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Не удалось подобрать маршрут'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'accepted sequence appears in existing WalkPlanner and native totals sheet',
    (tester) async {
      tester.view.physicalSize = const Size(320, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
      addTearDown(routing.dispose);
      routing.setProposedWalk([poi(1), poi(2)]);
      await routing.buildWalkRoute();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: routing,
          child: const MaterialApp(home: Scaffold(body: WalkPlannerSheet())),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: routing,
          child: const MaterialApp(home: Scaffold(body: RouteDetailsSheet())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('редакторская оценка'), findsOneWidget);
      expect(find.textContaining('ходьба MapKit + осмотр'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
