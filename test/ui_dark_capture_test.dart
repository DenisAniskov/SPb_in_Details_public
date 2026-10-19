import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/theme/app_theme.dart';
import 'package:smart_navigator_spb/providers/places_provider.dart';
import 'package:smart_navigator_spb/providers/routing_provider.dart';
import 'package:smart_navigator_spb/ui/widgets/place_preview_card.dart';

import 'ui_refactor_audit_test.dart' show UiRepository;
import 'smart_walk_audit_test.dart' show NativeRouteAdapter;

void main() {
  testWidgets('dark production card close remains inside header and 48dp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fontPath = Platform.environment['UI_AUDIT_FONT'];
    if (fontPath != null) {
      await tester.runAsync(() async {
        final bytes = await File(fontPath).readAsBytes();
        final loader = FontLoader('AuditFont')
          ..addFont(Future.value(ByteData.view(bytes.buffer)));
        await loader.load();
        final ahem = FontLoader('Ahem')
          ..addFont(Future.value(ByteData.view(bytes.buffer)));
        await ahem.load();
        final roboto = FontLoader('Roboto')
          ..addFont(Future.value(ByteData.view(bytes.buffer)));
        await roboto.load();
        final iconPath = Platform.environment['UI_AUDIT_ICONS'];
        if (iconPath != null) {
          final iconBytes = await File(iconPath).readAsBytes();
          final icons = FontLoader('MaterialIcons')
            ..addFont(Future.value(ByteData.view(iconBytes.buffer)));
          await icons.load();
        }
      });
    }
    final repo = UiRepository();
    final routing = RoutingProvider(mapKitService: NativeRouteAdapter());
    final places = PlacesProvider(repository: repo);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RoutingProvider>.value(value: routing),
          ChangeNotifierProvider<PlacesProvider>.value(value: places),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme.copyWith(
            textTheme: AppTheme.darkTheme.textTheme.apply(
              fontFamily: fontPath == null ? null : 'AuditFont',
            ),
          ),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: SingleChildScrollView(
                child: PlacePreviewCard(place: repo.place),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final close = tester.getRect(find.byTooltip('Закрыть карточку'));
    final title = tester.getRect(find.text(repo.place.title));
    expect(close.width, greaterThanOrEqualTo(48));
    expect(close.height, greaterThanOrEqualTo(48));
    expect(close.right, lessThanOrEqualTo(344));
    expect(close.bottom, lessThanOrEqualTo(title.top));
    expect(close.left, greaterThan(260));
    final output = Platform.environment['UI_AUDIT_CAPTURE'];
    if (output != null) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox());
    routing.dispose();
    places.dispose();
  });
}
