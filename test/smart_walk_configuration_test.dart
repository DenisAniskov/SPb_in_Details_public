import 'guided_walk_test_helpers.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/config/app_configuration.dart';
import 'package:smart_navigator_spb/core/network/api_client.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';
import 'package:smart_navigator_spb/data/repositories/places_repository.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/smart_walk_wizard_sheet.dart';

class _ProposalAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  Iterable<RequestOptions> get proposals =>
      requests.where((request) => request.method == 'POST');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final Object response;
    if (options.uri.path.endsWith('/routes/propose-walk')) {
      response = {
        'status': 'empty',
        'message': 'Configured backend proposal',
        'time_budget_minutes': 120,
        'items': [],
      };
    } else if (options.uri.path.endsWith('/places/categories')) {
      response = [];
    } else if (options.uri.path.endsWith('/places')) {
      response = {'total': 0, 'items': []};
    } else {
      throw StateError('Unexpected backend request: ${options.uri.path}');
    }
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

({PlacesRepository repository, _ProposalAdapter adapter}) _backend(
  String baseUrl, {
  bool isDebug = true,
}) {
  final configuration = AppConfiguration.resolve(
    defines: {
      'MAPKIT_API_KEY': 'synthetic-mapkit-key',
      'API_BASE_URL': baseUrl,
      'APP_ENV': isDebug ? 'development' : 'production',
    },
    isDebug: isDebug,
  );
  final client = ApiClient(customBaseUrl: configuration.apiBaseUrl);
  final adapter = _ProposalAdapter();
  client.dio.httpClientAdapter = adapter;
  addTearDown(() => client.dio.close(force: true));
  return (repository: PlacesRepository(apiClient: client), adapter: adapter);
}

Future<void> _generateProposal(
  WidgetTester tester,
  PlacesRepository sharedRepository, {
  PlacesRepository? explicitRepository,
}) async {
  final routing = RoutingProvider();
  routing.setCustomStartPoint(59.94, 30.31);
  final places = PlacesProvider(repository: sharedRepository);
  addTearDown(routing.dispose);
  addTearDown(places.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<PlacesRepository>.value(value: sharedRepository),
        ChangeNotifierProvider<RoutingProvider>.value(value: routing),
        ChangeNotifierProvider<PlacesProvider>.value(value: places),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SmartWalkWizardSheet(repository: explicitRepository),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await guidedToInterests(tester);
  final generate = find.text('Сформировать прогулку');
  await tester.ensureVisible(generate);
  await tester.pumpAndSettle();
  await tester.tap(generate);
  await tester.pumpAndSettle();
  expect(find.text('Configured backend proposal'), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  test('repository defaults automatic proposals to unusual preference and keeps category payload', () async {
    final backend = _backend('https://configured.example.test');
    await backend.repository.proposeWalk(
      startLatitude: 59.94,
      startLongitude: 30.31,
      timeBudgetMinutes: 120,
      categories: [PlaceCategoryEnum.nature],
    );
    expect(backend.adapter.proposals.single.data, {
      'start_point': {'latitude': 59.94, 'longitude': 30.31},
      'time_budget_minutes': 120,
      'categories': ['nature'],
      'prefer_unusual': true,
      'max_places': 6,
    });
  });
  for (final baseUrl in [
    'http://192.168.1.100:8000',
    'https://remote.example.test/smartnav',
  ]) {
    testWidgets(
      'Smart Walk submits to the configured shared backend $baseUrl',
      (tester) async {
        final backend = _backend(baseUrl, isDebug: baseUrl.startsWith('http:'));
        await _generateProposal(tester, backend.repository);

        expect(backend.adapter.proposals, hasLength(1));
        final request = backend.adapter.proposals.single;
        expect(request.uri.toString(), '$baseUrl/api/v1/routes/propose-walk');
        expect(request.data, {
          'start_point': {'latitude': 59.94, 'longitude': 30.31},
          'time_budget_minutes': 120,
          'prefer_unusual': true,
          'max_places': 6,
        });
      },
    );
  }

  testWidgets(
    'an explicit wizard repository takes precedence over the provider',
    (tester) async {
      final shared = _backend('https://shared.example.test');
      final explicit = _backend('https://explicit.example.test');
      await _generateProposal(
        tester,
        shared.repository,
        explicitRepository: explicit.repository,
      );

      expect(shared.adapter.proposals, isEmpty);
      expect(explicit.adapter.proposals, hasLength(1));
      expect(
        explicit.adapter.proposals.single.uri.toString(),
        'https://explicit.example.test/api/v1/routes/propose-walk',
      );
    },
  );
}
