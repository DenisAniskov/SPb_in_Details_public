import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/live_navigation_state.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/user_location_state.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/live_navigation_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/maneuver_icons.dart';

/// Phase C4 Part D/H: primary guidance card, maneuver icons, upcoming steps,
/// multi-stop presentation, narrow screens, enlarged text and semantics.
/// Presentation fake matching the established test pattern: the real
/// guidance service computes the snapshot, only the state is canned.
class GuidancePresentation extends NavigationProvider {
  GuidancePresentation(this.snapshot);
  final LiveNavigationState snapshot;
  @override
  LiveNavigationState get state => snapshot;
  @override
  NavigationStatus get status => snapshot.status;
}

void main() {
  const a = GeoCoord(60.0, 30.0);
  const b = GeoCoord(60.0005, 30.0);

  PedestrianManeuverModel turn(
    PedestrianManeuverKind kind,
    double offset, {
    int legIndex = 0,
  }) =>
      PedestrianManeuverModel(
        kind: kind,
        segmentIndex: 0,
        segmentPosition: 0.5,
        offsetMeters: offset,
        legIndex: legIndex,
      );

  RouteLegModel leg(
    String to,
    List<PedestrianManeuverModel> maneuvers, {
    int? visitMinutes,
  }) =>
      RouteLegModel(
        fromTitle: 'Старт',
        toTitle: to,
        distanceMeters: 55.6,
        durationSeconds: 60,
        geometryPoints: const [a, b],
        maneuvers: maneuvers,
        visitMinutes: visitMinutes,
      );

  PedestrianRouteModel route(List<RouteLegModel> legs) => PedestrianRouteModel(
        distanceMeters: 55.6 * legs.length,
        durationSeconds: 60 * legs.length,
        geometryPoints: const [a, b],
        steps: const [],
        legs: legs,
        placesCount: legs.length,
      );

  LiveNavigationState nativeState(List<RouteLegModel> legs) =>
      LiveNavigationState(
        status: NavigationStatus.active,
        route: route(legs),
        currentLegIndex: 0,
        currentManeuverIndex: 0,
        currentLocation: UserLocationSnapshot(
          coordinate: a,
          timestamp: DateTime.now(),
        ),
        projectedPoint: a,
        progressOnCurrentLegMeters: 0,
        remainingDistanceOnCurrentLegMeters: 55.6,
        totalProgressMeters: 0,
        totalRemainingMeters: 55.6 * legs.length,
      );

  Future<void> pumpSheet(
    WidgetTester tester,
    NavigationProvider nav, {
    Size surface = const Size(412, 900),
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<NavigationProvider>.value(
        value: nav,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: LiveNavigationSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Maneuver icons (Part D2)', () {
    test('typed native actions map to distinct icons', () {
      final straight = maneuverIcon(PedestrianManeuverKind.straight);
      final left = maneuverIcon(PedestrianManeuverKind.left);
      final right = maneuverIcon(PedestrianManeuverKind.right);
      expect(straight, Icons.straight);
      expect(left, Icons.turn_left);
      expect(right, Icons.turn_right);
      expect(left, isNot(right));
      expect(
        maneuverIcon(PedestrianManeuverKind.crosswalk),
        Icons.directions_walk,
      );
      expect(maneuverIcon(PedestrianManeuverKind.stairs), Icons.stairs);
      expect(maneuverIcon(PedestrianManeuverKind.stairsUp), Icons.north);
      expect(maneuverIcon(PedestrianManeuverKind.stairsDown), Icons.south);
    });

    testWidgets('native guidance shows the directional turn icon', (tester) async {
      final nav = GuidancePresentation(
        nativeState([
          leg('Эрмитаж', [turn(PedestrianManeuverKind.right, 55.6)]),
        ]),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav);
      expect(find.byIcon(Icons.turn_right), findsOneWidget);
      expect(find.text('Через 60 м поверните направо'), findsOneWidget);
    });

    testWidgets('fallback guidance never shows a directional turn icon', (
      tester,
    ) async {
      final nav = GuidancePresentation(
        nativeState([leg('Эрмитаж', const [])]),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav);
      expect(find.byIcon(Icons.turn_right), findsNothing);
      expect(find.byIcon(Icons.turn_left), findsNothing);
      expect(find.byIcon(Icons.straight), findsNothing);
      // Neutral walking icon instead.
      expect(find.byIcon(Icons.directions_walk), findsWidgets);
      expect(
        find.text(
          'Продолжайте движение по отображённому пешеходному маршруту '
          'к следующей точке.',
        ),
        findsOneWidget,
      );
      // Honest fallback indication for the steps block.
      expect(
        find.textContaining('Пошаговые манёвры для этого участка недоступны'),
        findsOneWidget,
      );
    });
  });

  group('Primary guidance card (Part D1)', () {
    testWidgets('secondary «Затем …» line appears for close maneuvers', (
      tester,
    ) async {
      final nav = GuidancePresentation(
        nativeState([
          leg('Эрмитаж', [
            turn(PedestrianManeuverKind.right, 55.6),
            turn(PedestrianManeuverKind.straight, 70.6),
          ]),
        ]),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav);
      expect(find.text('Через 60 м поверните направо'), findsOneWidget);
      expect(find.text('Затем продолжайте прямо'), findsOneWidget);
      expect(find.byIcon(Icons.straight), findsOneWidget);
    });

    testWidgets('progress details show remaining distance and walking time', (
      tester,
    ) async {
      final nav = GuidancePresentation(
        nativeState([
          leg('Эрмитаж', [turn(PedestrianManeuverKind.right, 55.6)]),
        ]),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav);
      expect(find.textContaining('до точки:'), findsOneWidget);
      expect(find.textContaining('пешком: ~'), findsOneWidget);
      expect(find.textContaining('всего осталось:'), findsOneWidget);
    });

    testWidgets('visiting duration appears when the leg carries one', (
      tester,
    ) async {
      final nav = GuidancePresentation(
        nativeState([
          leg('Эрмитаж', [turn(PedestrianManeuverKind.right, 55.6)],
              visitMinutes: 45),
        ]),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav);
      expect(find.textContaining('осмотр: ~45 мин'), findsOneWidget);
    });

    testWidgets('long instructions wrap without overflow', (tester) async {
      final nav = GuidancePresentation(
        nativeState([
          leg(
            'Таврический дворец с очень длинным названием',
            [turn(PedestrianManeuverKind.crosswalk, 55.6)],
          ),
        ]),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav);
      expect(
        find.text('Через 60 м перейдите по пешеходному переходу'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Upcoming steps (Part D3)', () {
    testWidgets('verified steps expand with distances, active first', (
      tester,
    ) async {
      final nav = GuidancePresentation(
        nativeState([
          leg('Эрмитаж', [
            turn(PedestrianManeuverKind.right, 55.6),
            turn(PedestrianManeuverKind.left, 75.6),
            turn(PedestrianManeuverKind.crosswalk, 120.6),
          ]),
        ]),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav);
      expect(find.text('Далее по участку: 2 манёвра'), findsOneWidget);
      await tester.tap(find.text('Далее по участку: 2 манёвра'));
      await tester.pumpAndSettle();
      // The two later verified maneuvers with their distances.
      expect(find.text('Поверните налево'), findsOneWidget);
      expect(find.text('Перейдите по пешеходному переходу'), findsOneWidget);
      expect(find.textContaining('через 80 м'), findsOneWidget);
      expect(find.textContaining('через 120 м'), findsOneWidget);
    });
  });

  group('Multi-stop Smart Walk (Part D4)', () {
    testWidgets('shows the approaching stop and its sequence number', (
      tester,
    ) async {
      final nav = GuidancePresentation(
        LiveNavigationState(
          status: NavigationStatus.active,
          route: route([
            leg('Таврический дворец', [turn(PedestrianManeuverKind.right, 55.6)]),
            leg('Летний сад', const []),
          ]),
          currentLegIndex: 1,
          currentManeuverIndex: 0,
          currentLocation: UserLocationSnapshot(
            coordinate: a,
            timestamp: DateTime.now(),
          ),
          projectedPoint: a,
          progressOnCurrentLegMeters: 0,
          remainingDistanceOnCurrentLegMeters: 55.6,
          totalProgressMeters: 55.6,
          totalRemainingMeters: 55.6,
        ),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav);
      expect(find.text('Следующая остановка:'), findsOneWidget);
      expect(find.text('Летний сад'), findsOneWidget);
      expect(find.text('Остановка 2 из 2'), findsOneWidget);
    });
  });

  group('Layout and accessibility (Part H2)', () {
    testWidgets('320 dp screen renders without overflow', (tester) async {
      final nav = GuidancePresentation(
        nativeState([
          leg('Эрмитаж', [
            turn(PedestrianManeuverKind.right, 55.6),
            turn(PedestrianManeuverKind.left, 75.6),
          ]),
        ]),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav, surface: const Size(320, 640));
      expect(tester.takeException(), isNull);
    });

    testWidgets('enlarged text renders without overflow', (tester) async {
      final nav = GuidancePresentation(
        nativeState([
          leg('Таврический дворец', [
            turn(PedestrianManeuverKind.right, 55.6),
            turn(PedestrianManeuverKind.crosswalk, 75.6),
          ]),
        ]),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav, textScale: 1.6);
      expect(tester.takeException(), isNull);
    });

    testWidgets('primary guidance card exposes navigation semantics', (
      tester,
    ) async {
      final nav = GuidancePresentation(
        nativeState([
          leg('Эрмитаж', [turn(PedestrianManeuverKind.right, 55.6)]),
        ]),
      );
      addTearDown(nav.dispose);
      final semantics = tester.ensureSemantics();
      await pumpSheet(tester, nav);
      // The card announces itself and its typed maneuver to screen readers.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label == 'Подсказка навигации',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              w.semanticLabel == 'Манёвр: Поверните направо',
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('suspended guidance shows no maneuver commands', (tester) async {
      final nav = GuidancePresentation(
        nativeState([
          leg('Эрмитаж', [turn(PedestrianManeuverKind.right, 55.6)]),
        ]).copyWith(
          status: NavigationStatus.active,
          isGpsLost: true,
          errorMessage: 'Нет свежего сигнала GPS.',
        ),
      );
      addTearDown(nav.dispose);
      await pumpSheet(tester, nav);
      expect(find.textContaining('поверните направо'), findsNothing);
      expect(find.text('Ожидаем сигнал GPS'), findsOneWidget);
    });
  });
}
