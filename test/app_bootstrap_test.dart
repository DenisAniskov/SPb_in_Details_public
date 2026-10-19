import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/config/app_bootstrap.dart';
import 'package:smart_navigator_spb/core/config/app_configuration.dart';
import 'package:smart_navigator_spb/main.dart';

void main() {
  test(
    'MapKit waits for configuration and receives the selected key unchanged',
    () async {
      final pendingConfiguration = Completer<AppConfiguration>();
      final events = <String>[];
      String? sdkKey;
      final startup = initializeApplication(
        loadConfiguration: () {
          events.add('load');
          return pendingConfiguration.future;
        },
        initializeMapKit: (key) async {
          events.add('sdk');
          sdkKey = key;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, ['load']);
      expect(sdkKey, isNull);

      const clientKey = 'synthetic-selected-mapkit-key';
      final selectedConfiguration = AppConfiguration.resolve(
        defines: const {'MAPKIT_API_KEY': clientKey},
        isDebug: true,
      );
      pendingConfiguration.complete(selectedConfiguration);
      final configuration = await startup;
      expect(events, ['load', 'sdk']);
      expect(sdkKey, clientKey);
      expect(configuration, same(selectedConfiguration));
    },
  );

  test('invalid configuration never initializes the native SDK', () async {
    var sdkCalls = 0;
    await expectLater(
      initializeApplication(
        loadConfiguration: () => AppConfiguration.load(
          defines: const {},
          isDebug: true,
          readDevelopmentValues: () async => const {
            'MAPKIT_API_KEY': 'YOUR_MAPKIT_KEY',
          },
        ),
        initializeMapKit: (_) async {
          sdkCalls++;
        },
      ),
      throwsA(isA<AppConfigurationException>()),
    );
    expect(sdkCalls, 0);
  });

  testWidgets(
    'configuration failure presents readable, selectable instructions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const message =
          'MAPKIT_API_KEY: укажите ключ в .env.dev или --dart-define.\n\n'
          'API_BASE_URL: нужен абсолютный http(s) URL backend.';
      await tester.pumpWidget(const ConfigurationErrorApp(message: message));

      expect(find.text('Ошибка конфигурации'), findsOneWidget);
      expect(find.text(message), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
