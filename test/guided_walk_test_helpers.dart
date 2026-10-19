import 'package:flutter_test/flutter_test.dart';

Future<void> guidedTap(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> guidedToInterests(WidgetTester tester, {String? preset}) async {
  await guidedTap(tester, 'Продолжить');
  await guidedTap(tester, 'Продолжить');
  if (preset != null) await guidedTap(tester, preset);
  await guidedTap(tester, 'Продолжить');
}

Future<void> guidedPublish(WidgetTester tester) async {
  await guidedTap(tester, 'Продолжить с выбранным маршрутом');
  await guidedTap(tester, 'Пропустить экологический анализ');
  await guidedTap(tester, 'Показать маршрут на карте');
}
