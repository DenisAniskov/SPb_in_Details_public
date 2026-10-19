import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigator_spb/providers/theme_provider.dart';

import 'branding_1_0_test.dart' show mountMapHeader;

/// Renders the production map screen into PNG files so the Branding 1.0 header
/// can be reviewed without a device.
///
/// Capturing needs real glyphs: flutter_test installs a font without them, so
/// the run points `BRANDING_CAPTURE_FONT_DIR` at the Flutter bundled font
/// directory (Roboto regular/bold plus Material icons). Text without an
/// explicit family would otherwise keep the glyph-less test font, therefore the
/// loaded faces are registered under the default families as well. Without
/// `BRANDING_CAPTURE_DIR` the test only checks that the screen renders, which
/// keeps the normal `flutter test` run untouched.
void main() {
  final captureDir = Platform.environment['BRANDING_CAPTURE_DIR'];
  final fontDir = Platform.environment['BRANDING_CAPTURE_FONT_DIR'];

  Future<void> loadFonts(WidgetTester tester) async {
    if (fontDir == null) return;
    await tester.runAsync(() async {
      final faces = [
        await File('$fontDir/roboto-regular.ttf').readAsBytes(),
        await File('$fontDir/roboto-bold.ttf').readAsBytes(),
      ];
      for (final family in ['Roboto', 'Ahem', 'FlutterTest']) {
        final loader = FontLoader(family);
        for (final face in faces) {
          loader.addFont(Future.value(ByteData.view(face.buffer)));
        }
        await loader.load();
      }
      final iconBytes = await File(
        '$fontDir/materialicons-regular.otf',
      ).readAsBytes();
      final icons = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.view(iconBytes.buffer)));
      await icons.load();
    });
  }

  final scenarios = <({
    String name,
    Size size,
    double textScale,
    AppThemePreference preference,
})>[
    (
      name: 'main_screen_light_360x640',
      size: const Size(360, 640),
      textScale: 1.0,
      preference: AppThemePreference.light,
    ),
    (
      name: 'main_screen_dark_360x640',
      size: const Size(360, 640),
      textScale: 1.0,
      preference: AppThemePreference.dark,
    ),
    (
      name: 'main_screen_light_320x480_text2',
      size: const Size(320, 480),
      textScale: 2.0,
      preference: AppThemePreference.light,
    ),
  ];

  for (final scenario in scenarios) {
    testWidgets('renders ${scenario.name}', (tester) async {
      await loadFonts(tester);
      final boundaryKey = GlobalKey();
      await mountMapHeader(
        tester,
        size: scenario.size,
        textScale: scenario.textScale,
        preference: scenario.preference,
        boundaryKey: boundaryKey,
        fontFamily: fontDir == null ? null : 'Roboto',
      );
      expect(tester.takeException(), isNull);
      if (captureDir == null) return;
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final target = Directory(captureDir)..createSync(recursive: true);
        File('${target.path}/${scenario.name}.png').writeAsBytesSync(
          bytes!.buffer.asUint8List(),
        );
        image.dispose();
      });
    });
  }
}
