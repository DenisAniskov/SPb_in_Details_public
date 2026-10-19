import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/ui/widgets/assistant_markdown.dart';

Future<void> _mount(
  WidgetTester tester,
  String data, {
  bool dark = false,
  Future<bool> Function(Uri uri)? openLink,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: AssistantMarkdown(data: data, onOpenLink: openLink),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

bool _hasStyledText(
  WidgetTester tester,
  String text, {
  FontWeight? weight,
  FontStyle? style,
}) {
  bool walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text == text &&
          (weight == null || span.style?.fontWeight == weight) &&
          (style == null || span.style?.fontStyle == style)) {
        return true;
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (walk(child)) return true;
      }
    }
    return false;
  }

  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    if (walk(rich.text)) return true;
  }
  return false;
}

void main() {
  testWidgets('renders bold, italic, headings, lists and inline code', (
    tester,
  ) async {
    await _mount(
      tester,
      '# Заголовок\n\n'
      '**Жирный** и *курсив* и `код`.\n\n'
      '- первый\n'
      '- второй\n\n'
      '1. один\n'
      '2. два\n\n'
      '> цитата\n\n'
      '```\nпример кода\n```\n',
    );
    expect(
      find.textContaining('Заголовок', findRichText: true),
      findsOneWidget,
    );
    expect(_hasStyledText(tester, 'Жирный', weight: FontWeight.bold), isTrue);
    expect(_hasStyledText(tester, 'курсив', style: FontStyle.italic), isTrue);
    expect(find.textContaining('первый', findRichText: true), findsOneWidget);
    expect(find.textContaining('цитата', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('пример кода', findRichText: true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote images are never loaded and show a neutral notice', (
    tester,
  ) async {
    await _mount(tester, 'Текст\n\n![котик](https://example.com/cat.png)');
    expect(
      find.textContaining('Изображение не загружается: котик'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an external link requires explicit confirmation', (tester) async {
    Uri? opened;
    await _mount(
      tester,
      '[сайт](https://example.com/path)',
      openLink: (uri) async {
        opened = uri;
        return true;
      },
    );
    await tester.tapOnText(find.textRange.ofSubstring('сайт'));
    await tester.pumpAndSettle();
    expect(find.text('Открыть внешнюю ссылку?'), findsOneWidget);
    expect(find.text('https://example.com/path'), findsOneWidget);
    expect(opened, isNull);

    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(opened, Uri.parse('https://example.com/path'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unsupported scheme is refused without a dialog',
      (tester) async {
    await _mount(tester, '[опасно](javascript:alert(1))');
    await tester.tapOnText(find.textRange.ofSubstring('опасно'));
    await tester.pumpAndSettle();
    expect(find.text('Открыть внешнюю ссылку?'), findsNothing);
    expect(find.text('Ссылка имеет неподдерживаемый формат.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('partial Markdown during streaming does not crash', (
    tester,
  ) async {
    for (final partial in [
      '**незакрытый',
      '- пункт\n- ',
      '```dart\nfinal x = ',
      '[ссылка](https://example.com',
      '# ',
    ]) {
      await _mount(tester, partial);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('renders in the dark theme', (tester) async {
    await _mount(tester, '**Тёмный** ответ', dark: true);
    expect(_hasStyledText(tester, 'Тёмный', weight: FontWeight.bold), isTrue);
    expect(tester.takeException(), isNull);
  });
}
