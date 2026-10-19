import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/smart_walk_preset.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/controllers/guided_walk_controller.dart';

import 'smart_walk_audit_test.dart' show poi;
import 'smart_walk_state_scoping_test.dart' show FixedRoutes;

class ProposalRepository extends PlacesRepository {
  int calls = 0;
  bool? unusual;
  int? budget;
  List<PlaceCategoryEnum>? interests;
  Completer<AutoWalkProposalResponseModel>? gate;
  bool invalid = false;
  AutoWalkProposalResponseModel? responseOverride;

  @override
  Future<AutoWalkProposalResponseModel> proposeWalk({
    required double startLatitude,
    required double startLongitude,
    required int timeBudgetMinutes,
    List<PlaceCategoryEnum>? categories,
    bool preferUnusual = true,
    int maxPlaces = 6,
  }) async {
    calls++;
    unusual = preferUnusual;
    budget = timeBudgetMinutes;
    interests = categories;
    return gate?.future ??
        responseOverride ??
        result(timeBudgetMinutes, invalid: invalid);
  }

  static AutoWalkProposalResponseModel result(
    int budget, {
    bool invalid = false,
  }) => AutoWalkProposalResponseModel(
    status: 'success',
    message: 'Прогулка',
    timeBudgetMinutes: budget,
    estimatedWalkingDurationSeconds: 100,
    estimatedVisitDurationMinutes: 20,
    estimatedTotalDurationMinutes: 22,
    estimatedTotalDistanceMeters: 100,
    suggestedPlacesSequence: [invalid ? 99 : 1],
    items: [
      ProposedWalkItemModel(
        place: poi(1),
        visitDurationMinutes: poi(1).recommendedVisitMinutes,
        reasons: const ['Интересное место'],
      ),
    ],
  );
}

void main() {
  late RoutingProvider source;
  late ProposalRepository repository;
  late GuidedWalkController controller;

  setUp(() {
    source = RoutingProvider(mapKitService: FixedRoutes());
    repository = ProposalRepository();
    controller = GuidedWalkController(source: source, repository: repository);
  });
  tearDown(() {
    controller.dispose();
    source.dispose();
  });

  test('steps advance in order and back preserves preset/interests', () async {
    expect(controller.step, GuidedWalkStep.start);
    controller.next();
    expect(controller.step, GuidedWalkStep.mode);
    controller.next();
    expect(controller.step, GuidedWalkStep.duration);
    controller.setPreset(SmartWalkPreset.quick);
    controller.next();
    controller.toggleCategory(PlaceCategoryEnum.historyArchitecture);
    controller.setPreferUnusual(false);
    controller.back();
    expect(controller.step, GuidedWalkStep.duration);
    expect(controller.preset, SmartWalkPreset.quick);
    controller.next();
    expect(controller.categories, {PlaceCategoryEnum.historyArchitecture});
    expect(controller.preferUnusual, false);
    await controller.generateProposal();
    expect(controller.step, GuidedWalkStep.proposal);
    expect(repository.budget, 60);
    expect(repository.unusual, false);
    expect(repository.interests, [PlaceCategoryEnum.historyArchitecture]);
  });

  for (final preset in SmartWalkPreset.values) {
    test('${preset.name} forwards full walking + visits budget', () async {
      controller.setPreset(preset);
      await controller.generateProposal();
      expect(repository.budget, preset.timeBudgetMinutes);
      expect(controller.proposal!.timeBudgetMinutes, preset.timeBudgetMinutes);
    });
  }

  test('empty interests preserve absent-filter contract', () async {
    await controller.generateProposal();
    expect(repository.interests, isNull);
  });

  test(
    'start change invalidates delayed proposal without mutating source',
    () async {
      repository.gate = Completer();
      final pending = controller.generateProposal();
      controller.routing.setStartPoint(
        RoutePointModel.defaultStart.copyWith(id: 'other', latitude: 59.95),
      );
      repository.gate!.complete(ProposalRepository.result(120));
      await pending;
      expect(controller.proposal, isNull);
      expect(controller.busy, false);
      expect(source.startPoint.id, 'palace_square');
    },
  );

  test(
    'interest change rejects stale proposal and leaves no loading',
    () async {
      repository.gate = Completer();
      final pending = controller.generateProposal();
      controller.toggleCategory(PlaceCategoryEnum.art);
      repository.gate!.complete(ProposalRepository.result(120));
      await pending;
      expect(controller.proposal, isNull);
      expect(controller.busy, false);
    },
  );

  test('switching to manual rejects delayed smart response', () async {
    repository.gate = Completer();
    final pending = controller.generateProposal();
    controller.setMode(GuidedWalkMode.manual);
    repository.gate!.complete(ProposalRepository.result(120));
    await pending;
    expect(controller.proposal, isNull);
    expect(controller.mode, GuidedWalkMode.manual);
  });

  test('double proposal tap deduplicates and back reuses response', () async {
    repository.gate = Completer();
    final pending = controller.generateProposal();
    await controller.generateProposal();
    expect(repository.calls, 1);
    repository.gate!.complete(ProposalRepository.result(120));
    await pending;
    controller.back();
    await controller.generateProposal();
    expect(repository.calls, 1);
  });

  test('invalid proposal never becomes a buildable route', () async {
    repository.invalid = true;
    await controller.generateProposal();
    await controller.buildPreview();
    expect(controller.proposal, isNull);
    expect(controller.error, isNotNull);
    expect(source.hasRoute, false);
  });

  test(
    'manual points/order survive mode changes and no inherited budget',
    () async {
      controller.setMode(GuidedWalkMode.manual);
      controller.routing.addPlaceToWalk(poi(3));
      controller.routing.addPlaceToWalk(poi(2));
      controller.routing.reorderWalkPlaces(1, 0);
      controller.setMode(GuidedWalkMode.smart);
      await controller.generateProposal();
      controller.setMode(GuidedWalkMode.manual);
      expect(controller.routing.walkPlaces.map((p) => p.id), [2, 3]);
      await controller.buildPreview();
      expect(controller.routing.walkBudgetMinutes, isNull);
      expect(controller.routing.walkPlaces.map((p) => p.id), [2, 3]);
      expect(source.walkPlaces, isEmpty);
    },
  );

  test('native preview remains separate; explicit map action publishes exact snapshot', () async {
    await controller.generateProposal();
    expect(controller.routing.currentRoute, isNull);
    await controller.buildPreview();
    expect(controller.routing.currentRoute!.distanceMeters, 750);
    expect(controller.proposal!.estimatedTotalDistanceMeters, 100);
    expect(source.hasRoute, false);
    controller.next();
    controller.skipEnvironment();
    expect(controller.step, GuidedWalkStep.report);
    final route = controller.routing.currentRoute;
    expect(controller.showMap(), true);
    expect(identical(source.currentRoute, route), true);
    expect(source.navigationLocked, false);
    expect(source.navigationRoute, isNull);
  });

  test('cancel preserves existing confirmed walk', () async {
    controller.dispose();
    source.setProposedWalk([poi(9)]);
    await source.buildWalkRoute();
    final old = source.currentRoute;
    controller = GuidedWalkController(source: source, repository: repository);
    await controller.generateProposal();
    await controller.buildPreview();
    controller.cancel();
    expect(identical(source.currentRoute, old), true);
    expect(source.walkPlaces.single.id, 9);
  });

  test('navigation lock cancels draft and blocks publication', () async {
    await controller.generateProposal();
    source.setNavigationLocked(true);
    await controller.buildPreview();
    expect(controller.locked, true);
    expect(controller.busy, false);
    expect(controller.showMap(), false);
    expect(source.hasRoute, false);
  });

  test('network failure keeps map available and answers editable', () async {
    repository.gate = Completer();
    final pending = controller.generateProposal();
    repository.gate!.completeError(StateError('network'));
    await pending;
    expect(controller.error, isNotNull);
    expect(controller.busy, false);
    controller.back();
    controller.setPreset(SmartWalkPreset.extended);
    expect(controller.preset, SmartWalkPreset.extended);
    expect(source.navigationLocked, false);
  });
}
