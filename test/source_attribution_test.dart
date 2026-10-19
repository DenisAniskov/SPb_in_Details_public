import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/ui/widgets/source_attribution.dart';

void main() {
  testWidgets(
    'visible credit opens accessible source and licence information',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const Scaffold(body: SourceAttribution()),
        ),
      );
      final credit = find.text(
        'Места: © OpenStreetMap contributors • Карты: Яндекс',
      );
      expect(credit, findsOneWidget);
      await tester.tap(credit);
      await tester.pumpAndSettle();
      expect(find.text('Источники и условия'), findsOneWidget);
      expect(find.textContaining('ODbL 1.0'), findsOneWidget);
      expect(
        find.text(SourceLicensesDialog.osmCopyright.toString()),
        findsOneWidget,
      );
      expect(
        find.text(SourceLicensesDialog.yandexTerms.toString()),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Понятно'));
      await tester.pumpAndSettle();
      expect(find.byType(SourceLicensesDialog), findsNothing);
    },
  );

  testWidgets('public source and Yandex hyperlinks open their exact URLs', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceLicensesDialog(
            openLink: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    for (final label in [
      'OpenStreetMap: источники и лицензия',
      'Open Database License 1.0',
      'Условия использования сервиса Яндекс.Карты',
    ]) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
    }
    expect(opened.map((uri) => uri.toString()), [
      'https://www.openstreetmap.org/copyright',
      'https://opendatacommons.org/licenses/odbl/1-0/',
      'https://yandex.ru/legal/maps_termsofuse/',
    ]);
    expect(find.text('Каталог SmartNavigator (ODbL)'), findsNothing);
    expect(
      find.textContaining('raw.githubusercontent.com/DenisAniskov'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final throws in [false, true]) {
    testWidgets('link failure remains usable (throws=$throws)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceLicensesDialog(
              openLink: (_) async {
                if (throws) throw StateError('no browser');
                return false;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('OpenStreetMap: источники и лицензия'));
      await tester.pump();
      expect(find.text('Не удалось открыть ссылку'), findsOneWidget);
      expect(
        find.text(SourceLicensesDialog.osmCopyright.toString()),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
