import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/core/network/ui_error.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/models/external_map_point.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/providers/search_provider.dart';
import 'package:smart_navigator_spb/services/mapkit_service.dart';
import 'package:smart_navigator_spb/ui/screens/main_map_screen.dart';
import 'package:smart_navigator_spb/ui/screens/place_detail_screen.dart';
import 'package:smart_navigator_spb/ui/screens/route_details_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/place_preview_card.dart';
import 'package:smart_navigator_spb/ui/widgets/external_point_preview_card.dart';
import 'package:smart_navigator_spb/ui/widgets/walk_planner_sheet.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';

import 'smart_walk_audit_test.dart' show NativeRouteAdapter, poi;

class UiRepository extends PlacesRepository {
  final place = PlaceModel(
    id: 1,
    title: 'Очень длинное название места Санкт-Петербурга для проверки',
    shortDescription: 'Редакторское описание',
    fullDescription: 'Длинное описание. ' * 100,
    category: PlaceCategoryEnum.historyArchitecture,
    latitude: 59.94,
    longitude: 30.31,
    address: 'Санкт-Петербург',
    rating: 4.9,
    photoUrl: 'https://example.invalid/photo.jpg',
    workingHours: 'Недостоверные часы',
    isUnusual: true,
    recommendedVisitMinutes: 30,
  );
  @override
  Future<List<PlaceModel>> getPlaces({
    List<PlaceCategoryEnum>? categories,
    bool? isUnusual,
    String? searchQuery,
  }) async => [place];
  @override
  Future<List<CategoryModel>> getCategories() async => [];
  @override
  Future<PlaceModel?> getPlaceDetail(int id) async => place;
}

void main() {
  for (final size in [
    const Size(320, 480),
    const Size(360, 640),
    const Size(412, 892),
    const Size(640, 360),
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        'production UI ${size.width}x${size.height} dark=$dark font=1.6',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          final oldHandler = FlutterError.onError;
          FlutterError.onError = (details) {
            FlutterError.dumpErrorToConsole(details);
            oldHandler!(details);
          };
          addTearDown(() => FlutterError.onError = oldHandler);
          final repo = UiRepository();
          final places = PlacesProvider(repository: repo);
          final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
          final search = SearchProvider();
          routing.addPlaceToWalk(repo.place);
          routing.addPlaceToWalk(poi(2));
          MapKitService.isMapKitInitialized = false;
          Future<void> mount(Widget body, {bool screen = false}) async {
            await tester.pumpWidget(
              MultiProvider(
                providers: [
                  Provider<PlacesRepository>.value(value: repo),
                  ChangeNotifierProvider<PlacesProvider>.value(value: places),
                  ChangeNotifierProvider<RoutingProvider>.value(value: routing),
                  ChangeNotifierProvider<SearchProvider>.value(value: search),
                ],
                child: MaterialApp(
                  theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: const TextScaler.linear(1.6)),
                    child: child!,
                  ),
                  home: screen
                      ? body
                      : Scaffold(body: SingleChildScrollView(child: body)),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final error = tester.takeException();
            if (error != null) {
              debugPrint(error.toString());
            }
            expect(error, isNull, reason: '${body.runtimeType}');
          }

          await mount(PlacePreviewCard(place: repo.place));
          expect(find.text('4.9'), findsNothing);
          final card = tester.widget<Container>(
            find
                .descendant(
                  of: find.byType(PlacePreviewCard),
                  matching: find.byType(Container),
                )
                .first,
          );
          expect(
            (card.decoration! as BoxDecoration).color,
            dark ? AppColors.darkSurface : AppColors.surface,
          );
          expect(
            tester.getSize(find.byTooltip('Закрыть карточку')).width,
            greaterThanOrEqualTo(48),
          );
          await mount(
            const ExternalPointPreviewCard(
              point: ExternalMapPoint(
                title: 'Московский вокзал — очень длинное название внешнего объекта',
                address: 'Санкт-Петербург, Невский проспект',
                latitude: 59.93,
                longitude: 30.36,
              ),
            ),
          );
          await mount(const WalkPlannerSheet());
          await mount(const SmartWalkWizardSheet());
          await mount(PlaceDetailScreen(place: repo.place), screen: true);
          expect(find.byType(Image), findsNothing);
          expect(find.text('4.9'), findsNothing);
          expect(find.text('Недостоверные часы'), findsNothing);
          await routing.buildWalkRoute();
          await mount(const RouteDetailsSheet());
          routing.clearRoute();
          places.selectPlace(repo.place);
          await mount(const MainMapScreen(), screen: true);
          tester.view.viewInsets = FakeViewPadding(bottom: size.height * 0.35);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'main map keyboard');
          await tester.pumpWidget(const SizedBox());
          places.dispose();
          routing.dispose();
          search.dispose();
        },
      );
    }
  }
  testWidgets(
    'visible planner handle reorders provider and invalidates route',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final native = NativeRouteAdapter();
      final routing = RoutingProvider(mapKitService: native);
      routing.addPlaceToWalk(poi(1));
      routing.addPlaceToWalk(poi(2));
      await routing.buildWalkRoute();
      await tester.pumpWidget(
        ChangeNotifierProvider<RoutingProvider>.value(
          value: routing,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: WalkPlannerSheet()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final handles = find.byTooltip('Изменить порядок места');
      expect(handles, findsNWidgets(2));
      expect(handles.hitTestable(), findsNWidgets(2));
      expect(tester.getSize(handles.first), const Size(48, 48));
      final start = tester.getCenter(handles.last);
      final target = tester.getCenter(handles.first) - const Offset(0, 25);
      final gesture = await tester.startGesture(start);
      for (var step = 1; step <= 12; step++) {
        await gesture.moveTo(Offset.lerp(start, target, step / 12)!);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(routing.walkPlaces.map((place) => place.id).toList(), [2, 1]);
      expect(native.calls.last.$2.map((place) => place.id).toList(), [2, 1]);
      expect(routing.hasRoute, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      routing.dispose();
    },
  );
  test(
    'native failures are friendly and actionable budget remains visible',
    () {
      expect(
        routeUiError(
          StateError('DioException HTTP 403 secret diagnostic'),
          walk: false,
        ),
        isNot(contains('DioException')),
      );
      expect(
        routeUiError(
          StateError('Даже одно подходящее место не помещается в 30 мин'),
          walk: true,
        ),
        contains('30 мин'),
      );
    },
  );
}
