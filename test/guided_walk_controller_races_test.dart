import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/controllers/guided_walk_controller.dart';

import 'guided_walk_controller_test.dart' show ProposalRepository;
import 'guided_walk_routing_test.dart' show GuidedNativeRoutes;
import 'smart_walk_audit_test.dart' show poi;

void main() {
  for (final malformed in ['status', 'negative_total', 'visits']) {
    test('invalid proposal $malformed summary cannot be published', () async {
      final valid = ProposalRepository.result(120);
      final repository = ProposalRepository()
        ..responseOverride = AutoWalkProposalResponseModel(
          status: malformed == 'status' ? 'error' : valid.status,
          message: valid.message,
          timeBudgetMinutes: valid.timeBudgetMinutes,
          estimatedWalkingDurationSeconds:
              valid.estimatedWalkingDurationSeconds,
          estimatedVisitDurationMinutes: malformed == 'visits'
              ? 0
              : valid.estimatedVisitDurationMinutes,
          estimatedTotalDurationMinutes: malformed == 'negative_total'
              ? -1
              : valid.estimatedTotalDurationMinutes,
          estimatedTotalDistanceMeters: valid.estimatedTotalDistanceMeters,
          suggestedPlacesSequence: valid.suggestedPlacesSequence,
          items: valid.items,
        );
      final source = RoutingProvider(mapKitService: GuidedNativeRoutes());
      final controller = GuidedWalkController(
        source: source,
        repository: repository,
      );
      addTearDown(source.dispose);
      addTearDown(controller.dispose);
      await controller.generateProposal();
      expect(controller.proposal, isNull);
      expect(controller.error, isNotEmpty);
      await controller.buildPreview();
      expect(controller.routing.currentRoute, isNull);
      expect(source.currentRoute, isNull);
    });
  }

  test(
    'backend empty proposal remains available with its explanation',
    () async {
      final repository = ProposalRepository()
        ..responseOverride = const AutoWalkProposalResponseModel(
          status: 'empty',
          message: 'Измените интересы или старт',
          timeBudgetMinutes: 120,
          estimatedWalkingDurationSeconds: 0,
          estimatedVisitDurationMinutes: 0,
          estimatedTotalDurationMinutes: 0,
          estimatedTotalDistanceMeters: 0,
          suggestedPlacesSequence: [],
          items: [],
        );
      final source = RoutingProvider(mapKitService: GuidedNativeRoutes());
      final controller = GuidedWalkController(
        source: source,
        repository: repository,
      );
      addTearDown(source.dispose);
      addTearDown(controller.dispose);
      await controller.generateProposal();
      expect(controller.proposal!.status, 'empty');
      expect(controller.proposal!.message, 'Измените интересы или старт');
      expect(controller.error, isNull);
      await controller.buildPreview();
      expect(controller.routing.currentRoute, isNull);
    },
  );

  test(
    'a confirmed scenic option requires an explicit normal or scenic choice',
    () async {
      final native = GuidedNativeRoutes();
      final source = RoutingProvider(mapKitService: native);
      final controller = GuidedWalkController(
        source: source,
        repository: ProposalRepository(),
      );
      addTearDown(source.dispose);
      addTearDown(controller.dispose);
      await controller.generateProposal();
      await controller.buildPreview();
      expect(controller.routing.verifiedScenicRoute, isNotNull);
      expect(controller.routeChoiceConfirmed, isFalse);
      expect(controller.canContinueScenic, isFalse);
      controller.next();
      expect(controller.step, GuidedWalkStep.scenic);
      controller.skipEnvironment();
      expect(controller.step, GuidedWalkStep.scenic);
      controller.selectRoute(WalkKind.normal);
      expect(controller.routeChoiceConfirmed, isTrue);
      expect(controller.canContinueScenic, isTrue);
      controller.next();
      expect(controller.step, GuidedWalkStep.environment);
      expect(native.walkCalls, 1);
      expect(native.pointCalls, 0);
      controller.back();
      controller.back();
      await controller.buildPreview();
      expect(controller.routeChoiceConfirmed, isTrue);
      expect(native.walkCalls, 1);
    },
  );

  test(
    'no confirmed scenic alternative permits continuing with normal',
    () async {
      final source = RoutingProvider(
        mapKitService: GuidedNativeRoutes()..onPath = false,
      );
      final controller = GuidedWalkController(
        source: source,
        repository: ProposalRepository(),
      );
      addTearDown(source.dispose);
      addTearDown(controller.dispose);
      await controller.generateProposal();
      await controller.buildPreview();
      expect(controller.routing.verifiedScenicRoute, isNull);
      expect(controller.canContinueScenic, isTrue);
      controller.next();
      expect(controller.step, GuidedWalkStep.environment);
    },
  );

  test(
    'manual selection survives building a smart route and switching back',
    () async {
      final source = RoutingProvider(mapKitService: GuidedNativeRoutes());
      final controller = GuidedWalkController(
        source: source,
        repository: ProposalRepository(),
      );
      addTearDown(source.dispose);
      addTearDown(controller.dispose);
      controller.setMode(GuidedWalkMode.manual);
      controller.routing.addPlaceToWalk(poi(3));
      controller.routing.addPlaceToWalk(poi(2));
      controller.setMode(GuidedWalkMode.smart);
      await controller.generateProposal();
      await controller.buildPreview();
      expect(controller.routing.walkPlaces.single.id, 1);
      controller.setMode(GuidedWalkMode.manual);
      expect(controller.routing.walkPlaces.map((place) => place.id), [3, 2]);
      expect(controller.routing.currentRoute, isNull);
      expect(controller.routeChoiceConfirmed, isFalse);
    },
  );

  test('main-only place mutation invalidates the wizard transaction', () async {
    final source = RoutingProvider(mapKitService: GuidedNativeRoutes());
    final controller = GuidedWalkController(
      source: source,
      repository: ProposalRepository(),
    );
    addTearDown(source.dispose);
    addTearDown(controller.dispose);
    await controller.generateProposal();
    await controller.buildPreview();
    source.addPlaceToWalk(poi(7));
    expect(controller.locked, isTrue);
    expect(controller.busy, isFalse);
    expect(controller.error, contains('Маршрут изменился'));
    expect(controller.showMap(), isFalse);
    expect(source.walkPlaces.single.id, 7);
  });

  testWidgets('obsolete native timeout cannot cancel a newer build', (
    tester,
  ) async {
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final native = GuidedNativeRoutes()
      ..onPath = false
      ..gate = firstGate;
    final source = RoutingProvider(mapKitService: native);
    final controller = GuidedWalkController(
      source: source,
      repository: ProposalRepository(),
      requestTimeout: const Duration(seconds: 45),
    );
    addTearDown(source.dispose);
    addTearDown(controller.dispose);
    await controller.generateProposal();
    final first = controller.buildPreview();
    await tester.pump(const Duration(seconds: 10));
    controller.back();
    native.gate = secondGate;
    final second = controller.buildPreview();
    final cancellations = native.cancellations;
    await tester.pump(const Duration(seconds: 35));
    await first;
    expect(native.cancellations, cancellations);
    expect(controller.routing.isCalculating, isTrue);
    expect(controller.busy, isTrue);
    secondGate.complete();
    await second;
    final route = controller.routing.currentRoute;
    firstGate.complete();
    await tester.pump();
    expect(controller.routing.currentRoute, same(route));
    expect(controller.busy, isFalse);
    expect(native.walkCalls, 2);
  });

  testWidgets(
    'obsolete scenic timeout cannot cancel a retry of the same walk',
    (tester) async {
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      final native = GuidedNativeRoutes()
        ..detour = true
        ..scenicGate = firstGate;
      final source = RoutingProvider(mapKitService: native);
      final controller = GuidedWalkController(
        source: source,
        repository: ProposalRepository(),
        requestTimeout: const Duration(seconds: 45),
      );
      addTearDown(source.dispose);
      addTearDown(controller.dispose);
      await controller.generateProposal();
      final first = controller.buildPreview();
      await tester.pump();
      expect(controller.routing.isCheckingScenic, isTrue);
      await tester.pump(const Duration(seconds: 10));
      controller.back();
      native.scenicGate = secondGate;
      final second = controller.buildPreview();
      final cancellations = native.cancellations;
      await tester.pump(const Duration(seconds: 35));
      await first;
      expect(native.cancellations, cancellations);
      expect(controller.routing.isCheckingScenic, isTrue);
      expect(controller.busy, isTrue);
      secondGate.complete();
      await second;
      final reservations = native.budgets.single.requests;
      final scenic = controller.routing.verifiedScenicRoute;
      firstGate.complete();
      await tester.pump();
      expect(controller.routing.verifiedScenicRoute, same(scenic));
      expect(native.budgets.single.requests, reservations);
      expect(controller.busy, isFalse);
      expect(native.walkCalls, 1);
      expect(native.budgets.single.requests, lessThanOrEqualTo(12));
    },
  );

  testWidgets('manual edit after backing out of pending native build is kept', (
    tester,
  ) async {
    final gate = Completer<void>();
    final native = GuidedNativeRoutes()
      ..onPath = false
      ..gate = gate;
    final source = RoutingProvider(mapKitService: native);
    final controller = GuidedWalkController(
      source: source,
      repository: ProposalRepository(),
    );
    addTearDown(source.dispose);
    addTearDown(controller.dispose);
    controller.setMode(GuidedWalkMode.manual);
    controller.routing.addPlaceToWalk(poi(2));
    controller.next();
    controller.next();
    final pending = controller.buildPreview();
    controller.back();
    controller.routing.addPlaceToWalk(poi(3));
    controller.setMode(GuidedWalkMode.smart);
    controller.setMode(GuidedWalkMode.manual);
    expect(controller.routing.walkPlaces.map((place) => place.id), [2, 3]);
    gate.complete();
    await pending;
    expect(controller.routing.currentRoute, isNull);
    expect(controller.busy, isFalse);
    expect(source.currentRoute, isNull);
  });
}
