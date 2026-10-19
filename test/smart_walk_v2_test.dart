import 'guided_walk_test_helpers.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:smart_navigator_spb/core/network/ui_error.dart';
import 'package:smart_navigator_spb/core/network/route_calculation_failure.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/smart_walk_preset.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';

import 'smart_walk_audit_test.dart'
    show poi, proposal, route, PendingRepository, mountWizard, tapVisible;

AutoWalkAlternativeModel alternate(
  List<PlaceModel> places, {
  int budget = 60,
}) => AutoWalkAlternativeModel(
  timeBudgetMinutes: budget,
  suggestedPlacesSequence: places.map((p) => p.id).toList(),
  items: places
      .map(
        (p) => ProposedWalkItemModel(
          place: p,
          visitDurationMinutes: p.recommendedVisitMinutes,
          reasons: ['Причина варианта ${p.id}'],
        ),
      )
      .toList(),
);

/// No SDK initialization, device, key or external calls. The bounded wrapper
/// consumes simulated native requests to exercise the shared cap and report.
class ScenarioNativeRoutes extends MapKitService {
  final calls = <List<PlaceModel>>[];
  Future<PedestrianRouteModel> Function(List<PlaceModel>) answer = (
    places,
  ) async => route(120, places.length);
  int get legReservations => calls.fold(0, (sum, p) => sum + p.length);

  @override
  void cancel() {}

  @override
  Future<PedestrianRouteModel> calculateBoundedWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
    required NativeWalkRequestBudget requestBudget,
  }) {
    for (final _ in places) {
      requestBudget.consume();
    }
    return super.calculateBoundedWalkRoute(
      startPoint: startPoint,
      places: places,
      requestBudget: requestBudget,
    );
  }

  @override
  Future<PedestrianRouteModel> calculateWalkRoute({
    required RoutePointModel startPoint,
    required List<PlaceModel> places,
  }) {
    calls.add(List.of(places));
    return answer(places);
  }

  @override
  Future<PedestrianRouteModel> calculatePedestrianRoute({
    required RoutePointModel startPoint,
    required PlaceModel destination,
  }) async => route(120, 1);

  @override
  Future<PedestrianRouteModel> calculatePointToPointRoute({
    required RoutePointModel startPoint,
    required RoutePointModel destinationPoint,
  }) async => route(120, 1);
}

void main() {
  for (final malformed in <(String, num)>[
    ('id', 0),
    ('latitude', double.nan),
    ('latitude', 91),
    ('longitude', double.infinity),
    ('longitude', -181),
  ]) {
    testWidgets(
      'wizard rejects malformed primary ${malformed.$1}=${malformed.$2} before acceptance',
      (tester) async {
        final repo = PendingRepository();
        final native = ScenarioNativeRoutes();
        final routing = RoutingProvider(mapKitService: native);
        await mountWizard(tester, repo, routing);
        await guidedToInterests(tester);
        await tapVisible(tester, find.text('Сформировать прогулку'));
        final corrupt = PlaceModel.fromJson({
          ...poi(1).toJson(),
          malformed.$1: malformed.$2,
        });
        repo.pending.single.complete(
          AutoWalkProposalResponseModel(
            status: 'success',
            message: 'Malformed fixture',
            timeBudgetMinutes: 120,
            estimatedWalkingDurationSeconds: 120,
            estimatedVisitDurationMinutes: 20,
            estimatedTotalDurationMinutes: 22,
            estimatedTotalDistanceMeters: 150,
            suggestedPlacesSequence: [corrupt.id],
            items: [
              ProposedWalkItemModel(
                place: corrupt,
                visitDurationMinutes: 20,
                reasons: const [],
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Ответ сервера не соответствует'),
          findsOneWidget,
        );
        expect(find.text('Построить прогулку'), findsNothing);
        expect(native.calls, isEmpty);
        expect(routing.walkPlaces, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('backend timeout, HTTP failure, malformed response and unknown error remain distinct', () {
    final options = RequestOptions(path: '/synthetic');
    DioException http(int status) => DioException(
      requestOptions: options,
      type: DioExceptionType.badResponse,
      response: Response(requestOptions: options, statusCode: status),
    );
    expect(
      walkProposalUiError(TimeoutException('fixture')),
      contains('не ответил вовремя'),
    );
    expect(walkProposalUiError(http(503)), contains('временно недоступен'));
    expect(walkProposalUiError(http(422)), contains('не принял параметры'));
    expect(
      walkProposalUiError(const FormatException('fixture')),
      contains('некорректный ответ'),
    );
    final unknown = walkProposalUiError(StateError('fixture'));
    expect(unknown, isNot(contains('сеть')));
    expect(unknown, isNot(contains('мест')));
  });

  testWidgets(
    'wizard backend disconnection never claims attractions or time are insufficient',
    (tester) async {
      final repo = PendingRepository();
      final routing = RoutingProvider(mapKitService: ScenarioNativeRoutes());
      await mountWizard(tester, repo, routing);
      await guidedToInterests(tester);
      await tapVisible(tester, find.text('Сформировать прогулку'));
      repo.pending.single.completeError(const SocketException('synthetic'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Нет связи с сервером подбора прогулок'),
        findsOneWidget,
      );
      expect(find.textContaining('не помещаются'), findsNothing);
      expect(find.textContaining('нет мест'), findsNothing);
    },
  );

  for (final reason in [
    'category_filter_empty',
    'preliminary_budget_infeasible',
  ]) {
    testWidgets('wizard $reason stays distinct from backend connectivity', (
      tester,
    ) async {
      final repo = PendingRepository();
      final routing = RoutingProvider(mapKitService: ScenarioNativeRoutes());
      await mountWizard(tester, repo, routing);
      await guidedToInterests(tester);
      await tapVisible(tester, find.text('Сформировать прогулку'));
      repo.pending.single.complete(
        AutoWalkProposalResponseModel(
          status: 'empty',
          message: 'legacy empty',
          reasonCode: reason,
          timeBudgetMinutes: 120,
          estimatedWalkingDurationSeconds: 0,
          estimatedVisitDurationMinutes: 0,
          estimatedTotalDurationMinutes: 0,
          estimatedTotalDistanceMeters: 0,
          suggestedPlacesSequence: const [],
          items: const [],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          reason == 'category_filter_empty'
              ? 'Измените категории'
              : 'не помещаются',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Нет связи'), findsNothing);
    });
  }

  test('fractional native seconds round up and cannot cross the preset boundary unnoticed', () {
    expect(MapKitService.nativeDurationSeconds(2400), 2400);
    expect(MapKitService.nativeDurationSeconds(2400.01), 2401);
    expect(MapKitService.nativeDurationSeconds(0.01), 1);
    for (final invalid in [double.nan, double.infinity, -1.0]) {
      expect(
        () => MapKitService.nativeDurationSeconds(invalid),
        throwsA(isA<RouteCalculationFailure>()),
      );
    }
  });

  test(
    'available over-budget and unavailable paths retain both failure reasons',
    () async {
      final native = ScenarioNativeRoutes()
        ..answer = (p) async {
          if (p.first.id == 1) return route(10000, p.length);
          throw const RouteCalculationFailure(
            RouteFailureKind.pedestrianUnavailable,
          );
        };
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk(
        [poi(1)],
        preset: SmartWalkPreset.quick,
        alternatives: [
          alternate([poi(2)]),
        ],
      );
      await routing.buildWalkRoute();
      expect(routing.errorMessage, contains('Часть'));
      expect(routing.errorMessage, contains('не помещаются'));
    },
  );

  test(
    'native zero-distance walk is not manufactured into a successful outcome',
    () async {
      final native = ScenarioNativeRoutes()
        ..answer = (p) async => PedestrianRouteModel(
          distanceMeters: 0,
          durationSeconds: 0,
          geometryPoints: const [],
          steps: const [],
          legs: const [],
          placesCount: p.length,
        );
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk([poi(1)], preset: SmartWalkPreset.quick);
      await routing.buildWalkRoute();
      expect(routing.hasRoute, isFalse);
      expect(routing.errorMessage, contains('нулевую длину'));
    },
  );

  test(
    'explicit synthetic diagnostics include removals and final POI sequence',
    () async {
      final native = ScenarioNativeRoutes()
        ..answer = (p) async => route(p.length > 1 ? 10000 : 600, p.length);
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk([poi(1), poi(2)], preset: SmartWalkPreset.quick);
      await routing.buildWalkRoute(
        syntheticDiagnosticTestPointId: 'synthetic-start',
      );
      expect(routing.walkDiagnostic!.refinementRemovedCount, 1);
      expect(
        routing.walkDiagnostic!.finalSequence,
        routing.walkPlaces.map((p) => p.id),
      );
      expect(routing.walkDiagnostic!.attempts.length, 2);
      routing.addPlaceToWalk(poi(3));
      expect(routing.walkDiagnostic, isNull);
    },
  );

  testWidgets('wizard transfers additive alternatives into native validation', (
    tester,
  ) async {
    final repo = PendingRepository();
    final native = ScenarioNativeRoutes()
      ..answer = (p) async => route(p.first.id == 1 ? 10000 : 600, p.length);
    final routing = RoutingProvider(mapKitService: native);
    await mountWizard(tester, repo, routing);
    await guidedToInterests(tester, preset: 'Быстрая прогулка');
    await tapVisible(tester, find.text('Сформировать прогулку'));
    final primary = proposal(budget: 60);
    repo.pending.single.complete(
      AutoWalkProposalResponseModel(
        status: primary.status,
        message: primary.message,
        timeBudgetMinutes: primary.timeBudgetMinutes,
        estimatedWalkingDurationSeconds:
            primary.estimatedWalkingDurationSeconds,
        estimatedVisitDurationMinutes: primary.estimatedVisitDurationMinutes,
        estimatedTotalDurationMinutes: primary.estimatedTotalDurationMinutes,
        estimatedTotalDistanceMeters: primary.estimatedTotalDistanceMeters,
        suggestedPlacesSequence: primary.suggestedPlacesSequence,
        items: primary.items,
        alternatives: [
          alternate([poi(3)]),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('Построить прогулку'));
    await tester.pumpAndSettle();
    await guidedPublish(tester);
    expect(routing.walkPlaces.single.id, 3);
    expect(routing.totalWalkDurationSeconds, 30 * 60);
    expect(tester.takeException(), isNull);
  });
  test(
    'legacy contract omits v2 fields; additive candidates retain ordered items',
    () {
      final item = {
        'place': poi(4).toJson(),
        'visit_duration_minutes': 20,
        'reasons': ['Рядом'],
      };
      final legacy = AutoWalkProposalResponseModel.fromJson({
        'time_budget_minutes': 60,
        'items': [],
        'suggested_places_sequence': [],
      });
      expect(legacy.alternatives, isEmpty);
      expect(legacy.reasonCode, isNull);
      final v2 = AutoWalkProposalResponseModel.fromJson({
        'status': 'empty',
        'reason_code': 'category_filter_empty',
        'time_budget_minutes': 60,
        'items': [],
        'suggested_places_sequence': [],
        'alternatives': [
          {
            'time_budget_minutes': 60,
            'suggested_places_sequence': [4],
            'items': [item],
          },
        ],
      });
      expect(v2.alternatives.single.items.single.place.id, 4);
      expect(v2.resultMessage, contains('Измените категории'));
    },
  );

  test('only two different valid POI sets are retained and category leakage is rejected', () {
    final routing = RoutingProvider(mapKitService: ScenarioNativeRoutes());
    addTearDown(routing.dispose);
    routing.setProposedWalk(
      [poi(1), poi(2)],
      preset: SmartWalkPreset.quick,
      categories: {PlaceCategoryEnum.historyArchitecture},
      alternatives: [
        alternate([poi(2), poi(1)]),
        alternate([poi(3, category: PlaceCategoryEnum.art)]),
        alternate([poi(4)], budget: 120),
        alternate([poi(5), poi(5)]),
        alternate([poi(6)]),
        alternate([poi(7)]),
        alternate([poi(8)]),
      ],
    );
    expect(routing.walkAlternativeCount, 2);
    expect(
      () => routing.setProposedWalk(
        [poi(9, category: PlaceCategoryEnum.art)],
        categories: {PlaceCategoryEnum.nature},
      ),
      throwsArgumentError,
    );
    expect(routing.walkPlaces.map((p) => p.id), [1, 2]);
  });

  test('native budget failure tries a distinct nearby alternative before deleting primary', () async {
    final native = ScenarioNativeRoutes()
      ..answer = (p) async => route(p.first.id == 1 ? 6000 : 1800, p.length);
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    routing.setProposedWalk(
      [poi(1), poi(2)],
      preset: SmartWalkPreset.quick,
      alternatives: [
        alternate([poi(3)]),
      ],
    );
    await routing.buildWalkRoute();
    expect(native.calls.map((p) => p.map((i) => i.id).toList()), [
      [1, 2],
      [3],
    ]);
    expect(routing.walkPlaces.single.id, 3);
    expect(routing.totalWalkDurationSeconds, 50 * 60);
    expect(routing.placeReasons[3], ['Причина варианта 3']);
    expect(routing.budgetWarningMessage, contains('другой вариант'));
  });

  test(
    'unavailable pedestrian route can recover using another proposal',
    () async {
      final native = ScenarioNativeRoutes()
        ..answer = (p) async {
          if (p.first.id == 1) {
            throw const RouteCalculationFailure(
              RouteFailureKind.pedestrianUnavailable,
            );
          }
          return route(120, p.length);
        };
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk(
        [poi(1)],
        preset: SmartWalkPreset.quick,
        alternatives: [
          alternate([poi(2)]),
        ],
      );
      await routing.buildWalkRoute();
      expect(routing.hasRoute, isTrue);
      expect(native.calls.length, 2);
    },
  );

  for (final failure in <Object>[
    const RouteCalculationFailure(RouteFailureKind.serviceUnavailable),
    const SocketException('synthetic disconnected'),
    TimeoutException('synthetic timeout'),
    StateError('unknown SDK failure'),
  ]) {
    test(
      '${failure.runtimeType} stops retries and never becomes a time error',
      () async {
        final native = ScenarioNativeRoutes()
          ..answer = (_) async => throw failure;
        final routing = RoutingProvider(mapKitService: native);
        addTearDown(routing.dispose);
        routing.setProposedWalk(
          [poi(1), poi(2)],
          preset: SmartWalkPreset.quick,
          alternatives: [
            alternate([poi(3)]),
          ],
        );
        await routing.buildWalkRoute();
        expect(native.calls.length, 1);
        expect(routing.hasRoute, isFalse);
        expect(routing.errorMessage, contains('сеть'));
        expect(routing.errorMessage, isNot(contains('не помещаются')));
        expect(routing.walkPlaces.map((p) => p.id), [1, 2]);
      },
    );
  }

  test(
    'network failure following an over-budget proposal remains a service error',
    () async {
      final native = ScenarioNativeRoutes()
        ..answer = (p) async {
          if (p.first.id == 1) return route(6000, p.length);
          throw const RouteCalculationFailure(
            RouteFailureKind.serviceUnavailable,
          );
        };
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk(
        [poi(1)],
        preset: SmartWalkPreset.quick,
        alternatives: [
          alternate([poi(2)]),
        ],
      );
      await routing.buildWalkRoute();
      expect(native.calls.length, 2);
      expect(routing.errorMessage, contains('временно недоступен'));
      expect(routing.errorMessage, isNot(contains('не помещаются')));
    },
  );

  test('small alternative precedes primary deletion when multi-stop proposals fail', () async {
    final native = ScenarioNativeRoutes()
      ..answer = (p) async => route(p.length > 1 ? 6000 : 600, p.length);
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    routing.setProposedWalk(
      [poi(1), poi(2)],
      preset: SmartWalkPreset.quick,
      alternatives: [
        alternate([poi(3), poi(4)]),
        alternate([poi(5), poi(6)]),
      ],
    );
    await routing.buildWalkRoute();
    expect(native.calls.length, 4);
    expect(native.calls.last.single.id, 3);
    expect(routing.totalWalkDurationSeconds, 30 * 60);
    expect(routing.placeReasons, isEmpty);
    expect(routing.budgetWarningMessage, contains('другому варианту'));
    expect(routing.budgetWarningMessage, isNot(contains('Исключены')));
  });

  test('six-stop alternatives cannot turn one action into dozens of native requests', () async {
    final native = ScenarioNativeRoutes()
      ..answer = (p) async => route(10000, p.length);
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    routing.setProposedWalk(
      List.generate(6, (i) => poi(i + 1)),
      preset: SmartWalkPreset.quick,
      alternatives: [
        alternate(List.generate(6, (i) => poi(i + 7))),
        alternate(List.generate(6, (i) => poi(i + 13))),
      ],
    );
    await routing.buildWalkRoute(
      syntheticDiagnosticTestPointId: 'synthetic-nevsky-01',
    );
    expect(native.calls.length, lessThanOrEqualTo(6));
    expect(native.legReservations, lessThanOrEqualTo(12));
    expect(routing.walkDiagnostic!.nativeLegRequests, native.legReservations);
    expect(
      routing.walkDiagnostic!.reservedNativeLegRequests,
      native.legReservations,
    );
    expect(routing.walkDiagnostic!.testPointId, 'synthetic-nevsky-01');
    expect(routing.hasRoute, isFalse);
    expect(routing.walkPlaces.length, 6);
  });

  test(
    'actual native request budget rejects the thirteenth leg before dispatch',
    () {
      final budget = NativeWalkRequestBudget(12);
      for (var i = 0; i < 12; ++i) {
        budget.consume();
      }
      expect(budget.requests, 12);
      expect(
        () => budget.consume(),
        throwsA(
          isA<RouteCalculationFailure>().having(
            (e) => e.kind,
            'kind',
            RouteFailureKind.requestLimitReached,
          ),
        ),
      );
      expect(budget.requests, 12);
    },
  );

  for (final preset in SmartWalkPreset.values) {
    test(
      '${preset.name} accepts exact native plus visits budget and rejects one extra second',
      () async {
        final native = ScenarioNativeRoutes()
          ..answer = (p) async =>
              route((preset.timeBudgetMinutes - 20) * 60, p.length);
        final routing = RoutingProvider(mapKitService: native);
        addTearDown(routing.dispose);
        routing.setProposedWalk([poi(1)], preset: preset);
        await routing.buildWalkRoute();
        expect(routing.totalWalkDurationSeconds, preset.timeBudgetMinutes * 60);
        expect(routing.walkDiagnostic, isNull);
        native.answer = (p) async =>
            route((preset.timeBudgetMinutes - 20) * 60 + 1, p.length);
        await routing.buildWalkRoute();
        expect(routing.hasRoute, isFalse);
        expect(routing.errorMessage, contains('не помещаются'));
        expect(routing.walkPreset, preset);
      },
    );
  }

  for (final edit in [
    'add',
    'remove',
    'reorder',
    'start',
    'route',
    'external',
    'clear',
    'navigation',
  ]) {
    test(
      '$edit clears alternatives that belong to the previous proposal',
      () async {
        final routing = RoutingProvider(mapKitService: ScenarioNativeRoutes());
        addTearDown(routing.dispose);
        routing.setProposedWalk(
          [poi(1), poi(2)],
          preset: SmartWalkPreset.quick,
          alternatives: [
            alternate([poi(3)]),
          ],
        );
        expect(routing.walkAlternativeCount, 1);
        switch (edit) {
          case 'add':
            routing.addPlaceToWalk(poi(4));
          case 'remove':
            routing.removePlaceFromWalk(1);
          case 'reorder':
            routing.reorderWalkPlaces(0, 2);
          case 'start':
            routing.setCustomStartPoint(59.877, 30.447);
          case 'route':
            await routing.buildRouteTo(poi(4));
          case 'external':
            await routing.buildRouteToExternalPoint(
              const ExternalMapPoint(
                title: 'Synthetic',
                latitude: 59.877,
                longitude: 30.447,
              ),
            );
          case 'clear':
            routing.clearRoute();
          case 'navigation':
            routing.setNavigationLocked(true);
        }
        expect(routing.walkAlternativeCount, 0);
        expect(routing.walkDiagnostic, isNull);
      },
    );
  }

  test('stale result cannot start fallback or attach diagnostics to a newer proposal', () async {
    final pending = Completer<PedestrianRouteModel>();
    final native = ScenarioNativeRoutes()..answer = (_) => pending.future;
    final routing = RoutingProvider(mapKitService: native);
    addTearDown(routing.dispose);
    routing.setProposedWalk(
      [poi(1)],
      preset: SmartWalkPreset.quick,
      alternatives: [
        alternate([poi(2)]),
      ],
    );
    final old = routing.buildWalkRoute(
      syntheticDiagnosticTestPointId: 'synthetic-old',
    );
    routing.setProposedWalk(
      [poi(3)],
      preset: SmartWalkPreset.regular,
      alternatives: [
        alternate([poi(4)], budget: 120),
      ],
    );
    pending.complete(route(10000, 1));
    await old;
    expect(native.calls.length, 1);
    expect(routing.walkPlaces.single.id, 3);
    expect(routing.walkAlternativeCount, 1);
    expect(routing.walkDiagnostic, isNull);
    expect(routing.status, RoutingStatus.idle);
  });

  test(
    'unavailable path is distinct from native travel time infeasibility',
    () async {
      final native = ScenarioNativeRoutes()
        ..answer = (_) async => throw const RouteCalculationFailure(
          RouteFailureKind.pedestrianUnavailable,
        );
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk([poi(1)], preset: SmartWalkPreset.quick);
      await routing.buildWalkRoute();
      expect(routing.errorMessage, contains('не найден'));
      expect(routing.errorMessage, isNot(contains('не помещаются')));
    },
  );

  test(
    'proposal object construction keeps older callers source-compatible',
    () {
      expect(proposal().alternatives, isEmpty);
    },
  );
}
