import 'guided_walk_test_helpers.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/smart_walk_preset.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/walk_planner_sheet.dart';

import 'smart_walk_audit_test.dart'
    show
        PendingRepository,
        NativeRouteAdapter,
        mountWizard,
        tapVisible,
        proposal,
        poi;

void main() {
  test(
    'exactly three centralized presets retain the backend budget contract',
    () {
      expect(SmartWalkPreset.values.map((preset) => preset.label), [
        'Быстрая прогулка',
        'Обычная прогулка',
        'Погулять подольше',
      ]);
      expect(SmartWalkPreset.values.map((preset) => preset.timeBudgetMinutes), [
        60,
        120,
        240,
      ]);
      expect(SmartWalkPreset.defaultPreset, SmartWalkPreset.regular);
      for (final preset in SmartWalkPreset.values) {
        expect(
          () => SmartWalkConfiguration.validateBudget(preset.timeBudgetMinutes),
          returnsNormally,
        );
      }
    },
  );

  for (final preset in SmartWalkPreset.values) {
    testWidgets(
      '${preset.label} transfers its budget and automatic unusual preference',
      (tester) async {
        final repo = PendingRepository();
        final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
        await mountWizard(tester, repo, routing);
        await guidedToInterests(tester, preset: preset.label);
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.byType(Switch), findsNothing);
        expect(find.byType(FilterChip), findsNWidgets(6));
        await tapVisible(tester, find.text('Сформировать прогулку'));
        expect(repo.parameters.single.$1, preset.timeBudgetMinutes);
        expect(repo.parameters.single.$2, isNull);
        expect(repo.parameters.single.$3, isTrue);
        repo.pending.single.complete(
          proposal(budget: preset.timeBudgetMinutes),
        );
        await tester.pumpAndSettle();
        await tapVisible(tester, find.text('Построить прогулку'));
        await tester.pumpAndSettle();
        await guidedPublish(tester);
        expect(routing.walkPreset, preset);
        expect(routing.walkBudgetMinutes, preset.timeBudgetMinutes);
        expect(routing.walkPreferUnusual, isTrue);
        expect(
          routing.totalWalkDurationSeconds,
          lessThanOrEqualTo(preset.timeBudgetMinutes * 60),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a later preset proposal cannot be overwritten by an earlier completion',
    (tester) async {
      final repo = PendingRepository();
      final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
      await mountWizard(tester, repo, routing);
      await guidedToInterests(tester);
      await tapVisible(tester, find.text('Сформировать прогулку'));
      await tapVisible(tester, find.text('Назад'));
      await tapVisible(tester, find.text('Назад'));
      await tapVisible(tester, find.text(SmartWalkPreset.quick.label));
      await guidedTap(tester, 'Продолжить');
      await tapVisible(tester, find.text('Сформировать прогулку'));
      expect(repo.parameters.map((parameters) => parameters.$1), [120, 60]);
      repo.pending.last.complete(proposal(budget: 60));
      await tester.pumpAndSettle();
      repo.pending.first.complete(proposal(budget: 120, empty: true));
      await tester.pumpAndSettle();
      expect(find.text('Ни одно место не помещается'), findsNothing);
      await tapVisible(tester, find.text('Построить прогулку'));
      await tester.pumpAndSettle();
      await guidedPublish(tester);
      expect(routing.walkPreset, SmartWalkPreset.quick);
      expect(routing.walkBudgetMinutes, 60);
      expect(routing.hasRoute, isTrue);
    },
  );

  testWidgets(
    'server response cannot silently replace the selected preset budget',
    (tester) async {
      final repo = PendingRepository();
      final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
      await mountWizard(tester, repo, routing);
      await guidedToInterests(tester, preset: SmartWalkPreset.quick.label);
      await tapVisible(tester, find.text('Сформировать прогулку'));
      repo.pending.single.complete(proposal(budget: 240));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('не соответствует выбранной прогулке'),
        findsOneWidget,
      );
      expect(find.text('Построить прогулку'), findsNothing);
      expect(routing.walkPlaces, isEmpty);
      await tapVisible(tester, find.text('Подобрать прогулку'));
      expect(repo.parameters.last.$1, 60);
      repo.pending.last.complete(proposal(budget: 60));
      await tester.pumpAndSettle();
      expect(find.text('Построить прогулку'), findsOneWidget);
    },
  );

  testWidgets(
    'changing the start invalidates proposals even at unchanged coordinates',
    (tester) async {
      final repo = PendingRepository();
      final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
      await mountWizard(tester, repo, routing);
      await guidedToInterests(tester);
      await tapVisible(tester, find.text('Сформировать прогулку'));
      routing.setStartPoint(routing.startPoint.copyWith(title: 'Другой старт'));
      await tester.pump();
      repo.pending.single.complete(proposal());
      await tester.pumpAndSettle();
      expect(find.text('Предварительный подбор'), findsNothing);
      expect(find.textContaining('Маршрут изменился'), findsOneWidget);
    },
  );

  testWidgets(
    'strict category request and ordinary/unusual proposal items survive transfer',
    (tester) async {
      final repo = PendingRepository();
      final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
      await mountWizard(tester, repo, routing);
      await guidedToInterests(tester);
      await tapVisible(tester, find.text(PlaceCategoryEnum.nature.displayName));
      await tapVisible(tester, find.text('Сформировать прогулку'));
      expect(repo.parameters.single.$2, [PlaceCategoryEnum.nature]);
      expect(repo.parameters.single.$3, isTrue);
      final items = [
        poi(1, category: PlaceCategoryEnum.nature, unusual: true),
        poi(2, category: PlaceCategoryEnum.nature),
      ];
      repo.pending.single.complete(
        AutoWalkProposalResponseModel(
          status: 'success',
          message: 'Подбор природы',
          timeBudgetMinutes: SmartWalkPreset.defaultPreset.timeBudgetMinutes,
          estimatedWalkingDurationSeconds: 120,
          estimatedVisitDurationMinutes: 40,
          estimatedTotalDurationMinutes: 42,
          estimatedTotalDistanceMeters: 150,
          suggestedPlacesSequence: [1, 2],
          items: items
              .map(
                (place) => ProposedWalkItemModel(
                  place: place,
                  visitDurationMinutes: 20,
                  reasons: [place.isUnusual ? 'Необычное место' : 'Рядом'],
                ),
              )
              .toList(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Необычное место'), findsOneWidget);
      await tapVisible(tester, find.text('Построить прогулку'));
      await tester.pumpAndSettle();
      await guidedPublish(tester);
      expect(routing.walkPlaces.map((place) => place.isUnusual), [true, false]);
      expect(routing.walkCategories, {PlaceCategoryEnum.nature});
      expect(
        routing.walkPlaces.every(
          (place) => place.category == PlaceCategoryEnum.nature,
        ),
        isTrue,
      );
      expect(routing.placeReasons[1], ['Необычное место']);
    },
  );

  test(
    'typed preset survives walk edits, native refinement and start changes',
    () async {
      final native = NativeRouteAdapter()..seconds = (count) => 600 * count;
      final routing = RoutingProvider(mapKitService: native);
      addTearDown(routing.dispose);
      routing.setProposedWalk([
        poi(1),
        poi(2),
        poi(3),
      ], preset: SmartWalkPreset.quick);
      await routing.buildWalkRoute();
      expect(routing.walkPlaces.length, 2);
      expect(routing.walkPreset, SmartWalkPreset.quick);
      expect(routing.totalWalkDurationSeconds, 60 * 60);
      routing.addPlaceToWalk(poi(4));
      routing.reorderWalkPlaces(0, 2);
      routing.setCustomStartPoint(59.96, 30.33);
      await routing.buildWalkRoute();
      expect(routing.walkPreset, SmartWalkPreset.quick);
      expect(routing.walkBudgetMinutes, 60);
      expect(routing.totalWalkDurationSeconds, lessThanOrEqualTo(60 * 60));
      routing.clearRoute();
      expect(routing.walkPreset, isNull);
      expect(routing.walkBudgetMinutes, isNull);
    },
  );

  test('legacy explicit budget overrides clear a mismatched preset', () async {
    final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
    addTearDown(routing.dispose);
    routing.setProposedWalk([poi(1)], preset: SmartWalkPreset.regular);
    await routing.buildWalkRoute(timeBudgetMinutes: 120);
    expect(routing.walkPreset, SmartWalkPreset.regular);
    await routing.buildWalkRoute(timeBudgetMinutes: 90);
    expect(routing.walkBudgetMinutes, 90);
    expect(routing.walkPreset, isNull);
  });

  test(
    'invalid or mismatched budgets never mutate the accepted walk',
    () async {
      final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
      addTearDown(routing.dispose);
      routing.setProposedWalk([poi(1)], preset: SmartWalkPreset.quick);
      await routing.buildWalkRoute();
      for (final budget in [29, 361]) {
        expect(
          () => routing.setProposedWalk([poi(2)], timeBudgetMinutes: budget),
          throwsArgumentError,
        );
        await expectLater(
          routing.buildWalkRoute(timeBudgetMinutes: budget),
          throwsArgumentError,
        );
      }
      expect(
        () => routing.setProposedWalk(
          [poi(2)],
          preset: SmartWalkPreset.extended,
          timeBudgetMinutes: 60,
        ),
        throwsArgumentError,
      );
      expect(routing.walkPlaces.single.id, 1);
      expect(routing.walkPreset, SmartWalkPreset.quick);
      expect(routing.walkBudgetMinutes, 60);
      expect(routing.hasRoute, isTrue);
    },
  );

  testWidgets(
    'preset identity is consistent in wizard, planner and route details at large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = PendingRepository();
      final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
      addTearDown(routing.dispose);
      routing.setProposedWalk([
        poi(1),
        poi(2),
      ], preset: SmartWalkPreset.extended);
      await routing.buildWalkRoute();
      for (final sheet in [
        SmartWalkWizardSheet(repository: repo),
        const WalkPlannerSheet(),
        const RouteDetailsSheet(),
      ]) {
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: routing,
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.8)),
                child: child!,
              ),
              home: Scaffold(body: sheet),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (sheet is SmartWalkWizardSheet) {
          await guidedTap(tester, 'Продолжить');
          await guidedTap(tester, 'Продолжить');
        }
        expect(
          find.textContaining(SmartWalkPreset.extended.label),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull, reason: '${sheet.runtimeType}');
        if (sheet is SmartWalkWizardSheet) {
          final selected = tester.widgetList<Semantics>(
            find.ancestor(
              of: find.text(SmartWalkPreset.extended.label),
              matching: find.byType(Semantics),
            ),
          );
          expect(
            selected.any((semantics) => semantics.properties.selected == true),
            isTrue,
          );
        } else {
          expect(find.textContaining('240 мин'), findsOneWidget);
        }
      }
    },
  );
}
