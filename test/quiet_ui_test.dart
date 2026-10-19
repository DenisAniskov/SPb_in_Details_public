import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/data/models/pedestrian_route_model.dart';
import 'package:smart_navigator_spb/data/models/quiet_analysis_model.dart';
import 'package:smart_navigator_spb/data/models/scenic_walk_model.dart';
import 'package:smart_navigator_spb/data/models/shade_analysis_model.dart';
import 'package:smart_navigator_spb/providers/navigation_provider.dart';
import 'package:smart_navigator_spb/providers/quiet_assessment_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/services/quiet_analysis_service.dart';
import 'package:smart_navigator_spb/services/shade_analysis_service.dart';
import 'package:smart_navigator_spb/ui/widgets/quiet_assessment_section.dart';

const _a = GeoCoord(59.9300, 30.3100);
const _b = GeoCoord(59.9400, 30.3200);
final _at = DateTime(2026, 10, 17, 14);

class _NoopShade implements BaseShadeAnalysisService {
  @override
  Future<ShadeAnalysisModel> analyzeWalk({
    required DateTime departure,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeSegments = true,
  }) async => throw StateError('shade not exercised');
}

class _QuietService implements BaseQuietAnalysisService {
  _QuietService({this.result, this.failure});
  QuietAnalysisModel? result;
  Object? failure;

  @override
  Future<QuietAnalysisModel> analyzeWalk({
    required DateTime assessedAt,
    required List<RouteLegModel> legs,
    List<int> visitMinutesAfterLeg = const [],
    bool includeLegs = false,
  }) async {
    if (failure != null) throw failure!;
    return result ??
        QuietAnalysisModel(
          status: QuietStatus.available,
          estimate: true,
          confidence: 'low',
          method: 'relative_road_noise_exposure_proxy',
          methodVersion: 'c11_1',
          evaluatedAt: assessedAt,
          temporalModel: 'static_osm_network',
          trafficTimeModeled: false,
          routeLengthMeters: 1300,
          knownMeters: 1300,
          unknownMeters: 0,
          coverageShare: 1,
          roadNoiseExposureIndex: 0.35,
          lowExposureShare: 0.62,
          majorRoadAdjacentShare: 0.08,
          meanNearestRoadDistanceM: 55,
          maxRoadClassNearby: 'secondary',
          legs: null,
          reasons: const [],
          limitations: const [],
          assumptions: const [],
          sourceProvenance: const {'license': 'ODbL-1.0'},
          datasetVersion: 'c11_quiet_spb_central_v1',
          datasetSha256: 'a' * 64,
        );
  }
}

RoutingProvider _routing() =>
    RoutingProvider(shadeAnalysisService: _NoopShade())
      ..setProposedWalkForScenicTest(
        scenic: false,
        comparison: null,
        walkKind: WalkKind.normal,
        route: const PedestrianRouteModel(
          distanceMeters: 1300,
          durationSeconds: 900,
          geometryPoints: [_a, _b],
          steps: [],
          legs: [
            RouteLegModel(
              fromTitle: 'Старт',
              toTitle: 'Финиш',
              distanceMeters: 1300,
              durationSeconds: 900,
              geometryPoints: [_a, _b],
            ),
          ],
          placesCount: 1,
        ),
      );

Future<
  ({
    QuietAssessmentProvider provider,
    RoutingProvider routing,
    NavigationProvider nav,
  })
>
_host(WidgetTester tester, _QuietService service) async {
  final routing = _routing();
  final nav = NavigationProvider(routingProvider: routing);
  final provider = QuietAssessmentProvider(
    service,
    routing: routing,
    navigation: nav,
    now: () => _at,
  );
  addTearDown(() {
    provider.dispose();
    nav.dispose();
    routing.dispose();
  });
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
        ChangeNotifierProvider<QuietAssessmentProvider>.value(value: provider),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: QuietAssessmentSection()),
        ),
      ),
    ),
  );
  return (provider: provider, routing: routing, nav: nav);
}

void main() {
  testWidgets('the card is opt-in and shows the relative proxy, not silence', (
    tester,
  ) async {
    await _host(tester, _QuietService());
    expect(find.text('Тишина на маршруте'), findsOneWidget);
    expect(find.text('Оценить тишину'), findsOneWidget);
    expect(find.textContaining('не дБ'), findsOneWidget);
    expect(find.textContaining('пока не рассчитывается'), findsNothing);

    await tester.tap(find.text('Оценить тишину'));
    await tester.pumpAndSettle();

    expect(find.textContaining('частично проходит рядом'), findsOneWidget);
    expect(find.text('Технические подробности оценки тишины'), findsOneWidget);
    expect(find.textContaining('Относительный прокси:'), findsNothing);

    await tester.ensureVisible(
      find.text('Технические подробности оценки тишины'),
    );
    await tester.tap(find.text('Технические подробности оценки тишины'));
    await tester.pumpAndSettle();
    expect(find.text('Относительный прокси: 0.35 из 1.00'), findsOneWidget);
    expect(
      find.textContaining('Покрытие дорожными данными: 100%'),
      findsOneWidget,
    );
    expect(find.textContaining('Доля проверенного пути вдали'), findsOneWidget);
    expect(
      find.textContaining('безразмерный относительный показатель'),
      findsOneWidget,
    );
    expect(find.textContaining('пока не рассчитывается'), findsNothing);
  });

  testWidgets('0.39 is explained in words and the index stays technical', (
    tester,
  ) async {
    final index039 = QuietAnalysisModel(
      status: QuietStatus.available,
      estimate: true,
      confidence: 'low',
      method: 'relative_road_noise_exposure_proxy',
      methodVersion: 'c11_1',
      evaluatedAt: _at,
      temporalModel: 'static_osm_network',
      trafficTimeModeled: false,
      routeLengthMeters: 1300,
      knownMeters: 1300,
      unknownMeters: 0,
      coverageShare: 1,
      roadNoiseExposureIndex: 0.39,
      lowExposureShare: 0.40,
      majorRoadAdjacentShare: 0.22,
      meanNearestRoadDistanceM: 42,
      maxRoadClassNearby: 'secondary',
      legs: null,
      reasons: const [],
      limitations: const [],
      assumptions: const [],
      sourceProvenance: const {'license': 'ODbL-1.0'},
      datasetVersion: 'c11_quiet_spb_central_v1',
      datasetSha256: 'a' * 64,
    );
    await _host(tester, _QuietService(result: index039));
    await tester.tap(find.text('Оценить тишину'));
    await tester.pumpAndSettle();
    expect(find.textContaining('частично проходит рядом'), findsOneWidget);
    expect(
      find.textContaining('0.39 из 1.00'),
      findsNothing,
      reason: 'индекс не должен подменять человеческий вывод',
    );
    await tester.ensureVisible(
      find.text('Технические подробности оценки тишины'),
    );
    await tester.tap(find.text('Технические подробности оценки тишины'));
    await tester.pumpAndSettle();
    expect(find.text('Относительный прокси: 0.39 из 1.00'), findsOneWidget);
    expect(
      find.textContaining('не децибелы'),
      findsOneWidget,
      reason: 'индекс явно отделён от дБ',
    );
  });

  testWidgets('outside-coverage answer is factual and has no index', (
    tester,
  ) async {
    final outside = QuietAnalysisModel(
      status: QuietStatus.outsideCoverage,
      estimate: false,
      confidence: 'unavailable',
      method: 'relative_road_noise_exposure_proxy',
      methodVersion: 'c11_1',
      evaluatedAt: _at,
      temporalModel: 'static_osm_network',
      trafficTimeModeled: false,
      routeLengthMeters: 1000,
      knownMeters: 0,
      unknownMeters: 1000,
      coverageShare: 0,
      roadNoiseExposureIndex: null,
      lowExposureShare: null,
      majorRoadAdjacentShare: null,
      meanNearestRoadDistanceM: null,
      maxRoadClassNearby: null,
      legs: null,
      reasons: const ['route_outside_pilot'],
      limitations: const ['Не дБ.'],
      assumptions: const [],
      sourceProvenance: const {'license': 'ODbL-1.0'},
      datasetVersion: 'c11_quiet_spb_central_v1',
      datasetSha256: 'a' * 64,
    );
    final host = await _host(tester, _QuietService(result: outside));
    await host.provider.assess();
    await tester.pumpAndSettle();
    expect(
      find.text('Маршрут вне проверенного пилотного района дорожной сети.'),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.text('Технические подробности оценки тишины'),
    );
    await tester.tap(find.text('Технические подробности оценки тишины'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Относительный прокси:'), findsNothing);
    expect(
      find.textContaining('Подтверждённых дорожных данных нет'),
      findsOneWidget,
    );
  });

  testWidgets('a service failure keeps the walk and shows a safe message', (
    tester,
  ) async {
    final host = await _host(
      tester,
      _QuietService(
        failure: const QuietAnalysisFailure(
          QuietAnalysisFailureKind.serviceUnavailable,
          'Оценка тишины сейчас недоступна. Обычная навигация работает.',
        ),
      ),
    );
    await host.provider.assess();
    await tester.pumpAndSettle();
    expect(find.textContaining('Обычная навигация работает'), findsOneWidget);
    expect(host.routing.currentRoute, isNotNull);
  });
}
