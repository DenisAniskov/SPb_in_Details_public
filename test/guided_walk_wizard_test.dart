import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/auto_walk_proposal_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/route_point_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/location_provider.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/controllers/guided_walk_controller.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/walk_planner_sheet.dart';

import 'guided_walk_test_helpers.dart';
import 'location_foundation_test.dart' show MockDeviceLocationService;
import 'smart_walk_audit_test.dart'
    show PendingRepository, NativeRouteAdapter, poi, proposal;

class _Repository extends PendingRepository {
  int calls = 0;
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async => List.generate(10, (i) => poi(i + 1));
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
    return proposal(budget: timeBudgetMinutes);
  }
}

Future<void> _mount(
  WidgetTester tester,
  GuidedWalkController controller,
  _Repository repository, {
  bool dark = false,
  double scale = 1,
  LocationProvider? location,
  Future<RoutePointModel?> Function()? chooseMapStart,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<RoutingProvider>.value(
          value: controller.routing,
        ),
        if (location != null)
          ChangeNotifierProvider<LocationProvider>.value(value: location),
      ],
      child: RepaintBoundary(
        key: const Key('guided-walk-capture'),
        child: MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => SmartWalkWizardSheet(
                    controller: controller,
                    repository: repository,
                    chooseMapStart: chooseMapStart,
                  ),
                ),
                child: const Text('Открыть мастер'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await guidedTap(tester, 'Открыть мастер');
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['C10_CAPTURE_UI'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('guided-walk-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('D:/SmartNavigator_C10_Validation/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets('system Back closes an externally locked advanced wizard', (
    tester,
  ) async {
    final repository = _Repository();
    final source = RoutingProvider(mapKitService: NativeRouteAdapter());
    final controller = GuidedWalkController(
      source: source,
      repository: repository,
    );
    addTearDown(controller.dispose);
    addTearDown(source.dispose);
    await _mount(tester, controller, repository);
    await guidedToInterests(tester);
    source.setNavigationLocked(true);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SmartWalkWizardSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final dark in [false, true]) {
    testWidgets(
      'all guided steps fit 320x480, text 1.8, dark=$dark and never start navigation',
      (tester) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = _Repository();
        final native = NativeRouteAdapter();
        final source = RoutingProvider(mapKitService: native);
        final navigation = NavigationProvider(routingProvider: source);
        final controller = GuidedWalkController(
          source: source,
          repository: repository,
          navigation: navigation,
        );
        addTearDown(controller.dispose);
        addTearDown(navigation.dispose);
        addTearDown(source.dispose);
        await _mount(tester, controller, repository, dark: dark, scale: 1.8);
        await _capture(
          tester,
          'wizard_welcome_${dark ? 'dark' : 'light'}_320x480',
        );
        final semantics = tester.ensureSemantics();
        await tester.pump();
        expect(
          tester
              .getSemantics(find.byTooltip('Закрыть мастер'))
              .getSemanticsData()
              .tooltip,
          'Закрыть мастер',
        );
        semantics.dispose();
        expect(find.text('Точка отправления'), findsOneWidget);
        await guidedToInterests(tester, preset: 'Быстрая прогулка');
        expect(controller.preset.timeBudgetMinutes, 60);
        await guidedTap(tester, 'Сформировать прогулку');
        expect(repository.calls, 1);
        expect(
          find.textContaining('Геометрическая оценка до MapKit'),
          findsOneWidget,
        );
        expect(source.hasRoute, isFalse);
        await guidedTap(tester, 'Построить прогулку');
        expect(controller.step, GuidedWalkStep.scenic);
        expect(find.textContaining('Подтверждено MapKit'), findsOneWidget);
        expect(source.hasRoute, isFalse);
        await guidedTap(tester, 'Продолжить с выбранным маршрутом');
        expect(controller.step, GuidedWalkStep.environment);
        await guidedTap(tester, 'Пропустить экологический анализ');
        expect(find.text('Ваша прогулка готова!'), findsOneWidget);
        await _capture(
          tester,
          'wizard_report_${dark ? 'dark' : 'light'}_320x480',
        );
        expect(find.textContaining('По MapKit:'), findsOneWidget);
        expect(find.text('Проверка пропущена'), findsNWidgets(4));
        expect(navigation.isActive, isFalse);
        await guidedTap(tester, 'Показать маршрут на карте');
        expect(source.hasRoute, isTrue);
        expect(navigation.isActive, isFalse);
        expect(find.byType(SmartWalkWizardSheet), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('system Back retains preset, interests and unusual preference', (
    tester,
  ) async {
    final repository = _Repository();
    final source = RoutingProvider(mapKitService: NativeRouteAdapter());
    final controller = GuidedWalkController(
      source: source,
      repository: repository,
    );
    addTearDown(controller.dispose);
    addTearDown(source.dispose);
    await _mount(tester, controller, repository);
    await guidedToInterests(tester, preset: 'Быстрая прогулка');
    await guidedTap(tester, 'Искусство');
    await guidedTap(tester, 'Нет, лучше известные достопримечательности');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(controller.step, GuidedWalkStep.duration);
    expect(controller.preset.timeBudgetMinutes, 60);
    await guidedTap(tester, 'Продолжить');
    expect(controller.categories, {PlaceCategoryEnum.art});
    expect(controller.preferUnusual, isFalse);
    expect(find.text('Ваши интересы'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual flow reuses planner and retains ordered draft on Back', (
    tester,
  ) async {
    final repository = _Repository();
    final source = RoutingProvider(mapKitService: NativeRouteAdapter());
    source.addPlaceToWalk(poi(10));
    await source.buildWalkRoute();
    final previous = source.currentRoute;
    final controller = GuidedWalkController(
      source: source,
      repository: repository,
    );
    addTearDown(controller.dispose);
    addTearDown(source.dispose);
    await _mount(tester, controller, repository);
    await guidedTap(tester, 'Продолжить');
    await guidedTap(tester, 'Собственный маршрут');
    await guidedTap(tester, 'Продолжить');
    expect(find.byType(WalkPlannerSheet), findsOneWidget);
    await tester.ensureVisible(
      find.byTooltip('Добавить ${poi(1).title} в прогулку'),
    );
    await tester.tap(find.byTooltip('Добавить ${poi(1).title} в прогулку'));
    await tester.pumpAndSettle();
    expect(controller.routing.walkPlaces.map((p) => p.id), [10, 1]);
    expect(source.currentRoute, same(previous));
    await guidedTap(tester, 'Назад');
    await guidedTap(tester, 'Продолжить');
    expect(controller.routing.walkPlaces.map((p) => p.id), [10, 1]);
    expect(find.text('Выбрать место на карте'), findsOneWidget);
    await guidedTap(tester, 'Построить прогулку');
    await guidedPublish(tester);
    expect(source.walkPlaces.map((p) => p.id), [10, 1]);
    expect(repository.calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'GPS denial leaves preset selection available without requesting location on open',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository();
      final source = RoutingProvider(mapKitService: NativeRouteAdapter());
      final controller = GuidedWalkController(
        source: source,
        repository: repository,
      );
      final device = MockDeviceLocationService()
        ..requestPermissionResult = LocationPermissionStatus.denied;
      final location = LocationProvider(locationService: device);
      addTearDown(controller.dispose);
      addTearDown(source.dispose);
      addTearDown(location.dispose);
      await _mount(
        tester,
        controller,
        repository,
        location: location,
        scale: 1.8,
      );
      expect(location.permissionStatus, LocationPermissionStatus.notRequested);
      await guidedTap(tester, 'Выбрать точку отправления');
      expect(location.permissionStatus, LocationPermissionStatus.notRequested);
      await guidedTap(tester, 'Моё местоположение');
      expect(location.permissionStatus, LocationPermissionStatus.denied);
      final palace = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Дворцовая площадь'),
          )
          .last;
      await tester.ensureVisible(palace);
      await tester.tap(palace);
      await tester.pumpAndSettle();
      expect(controller.routing.startPoint.id, 'palace_square');
      await guidedTap(tester, 'Продолжить');
      expect(controller.step, GuidedWalkStep.mode);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'map callback changes only draft and cancellation keeps previous route',
    (tester) async {
      final repository = _Repository();
      final source = RoutingProvider(mapKitService: NativeRouteAdapter());
      source.addPlaceToWalk(poi(1));
      await source.buildWalkRoute();
      final previous = source.currentRoute;
      final controller = GuidedWalkController(
        source: source,
        repository: repository,
      );
      addTearDown(controller.dispose);
      addTearDown(source.dispose);
      await _mount(
        tester,
        controller,
        repository,
        chooseMapStart: () async => RoutePointModel.defaultStart.copyWith(
          title: 'Мой старт',
          latitude: 59.95,
        ),
      );
      await guidedTap(tester, 'Выбрать точку отправления');
      await guidedTap(tester, 'Выбрать на карте');
      expect(controller.routing.startPoint.title, 'Мой старт');
      expect(source.startPoint.title, 'Дворцовая площадь');
      await tester.tap(find.byTooltip('Закрыть мастер'));
      await tester.pumpAndSettle();
      expect(source.currentRoute, same(previous));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('two rapid proposal taps share one backend request', (
    tester,
  ) async {
    final repository = _Repository();
    final source = RoutingProvider(mapKitService: NativeRouteAdapter());
    final controller = GuidedWalkController(
      source: source,
      repository: repository,
    );
    addTearDown(controller.dispose);
    addTearDown(source.dispose);
    await _mount(tester, controller, repository);
    await guidedToInterests(tester);
    final button = find.widgetWithText(FilledButton, 'Сформировать прогулку');
    final callback = tester.widget<FilledButton>(button).onPressed!;
    callback();
    callback();
    await tester.pumpAndSettle();
    expect(repository.calls, 1);
    expect(controller.step, GuidedWalkStep.proposal);
    expect(tester.takeException(), isNull);
  });
}
