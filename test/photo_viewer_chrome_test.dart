import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/ui/photo_viewer.dart';
import 'package:phototree/ui/visual_style.dart';

import 'media_browser_test.dart' show FakeMedia, photo;

void main() {
  for (final initiallyReduced in [true, false]) {
    testWidgets(
      'viewer chrome remains readable and exits once; initially reduced=$initiallyReduced',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = FakeMedia()..items = [photo(1)];
        source.image = () async => base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jw1kAAAAASUVORK5CYII=',
        );
        final browser = PhotoBrowser(source);
        await browser.refresh();
        final returned = <String?>[];
        final reduced = ValueNotifier(initiallyReduced);
        addTearDown(reduced.dispose);
        var physicalCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: photoTreeTheme(Brightness.light),
            builder: (context, child) => ValueListenableBuilder<bool>(
              valueListenable: reduced,
              child: child,
              builder: (context, value, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  disableAnimations: value,
                  textScaler: const TextScaler.linear(2),
                ),
                child: photoTreeAppBuilder(context, child),
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    returned.add(
                      await Navigator.of(context).push<String>(
                        PageRouteBuilder<String>(
                          opaque: false,
                          transitionDuration: Duration.zero,
                          reverseTransitionDuration: Duration.zero,
                          pageBuilder: (_, _, _) => PhotoViewer(
                            browser: browser,
                            photos: browser.photos,
                            initialKey: browser.photos.single.key,
                            origin: const Rect.fromLTWH(10, 100, 90, 90),
                            locate: (_) async =>
                                const Rect.fromLTWH(10, 100, 90, 90),
                            onPhysicalAction: (_, _) => physicalCalls++,
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        final toolbar = find.byKey(const ValueKey('viewer-toolbar'));
        expect(toolbar, findsOneWidget);
        expect(find.text('1 / 1'), findsOneWidget);
        expect(
          Theme.of(tester.element(find.text('1 / 1'))).brightness,
          Brightness.dark,
        );
        expect(tester.takeException(), isNull);
        final viewerBars = find.descendant(
          of: find.byType(PhotoViewer),
          matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        );
        final viewerStyle = tester
            .widget<AnnotatedRegion<SystemUiOverlayStyle>>(viewerBars)
            .value;
        expect(viewerStyle.statusBarIconBrightness, Brightness.light);
        expect(viewerStyle.systemNavigationBarIconBrightness, Brightness.light);
        expect(viewerStyle.statusBarBrightness, Brightness.dark);
        expect(viewerStyle.systemNavigationBarColor, Colors.black);
        await tester.tap(find.byTooltip('媒体操作'));
        await tester.pumpAndSettle();
        expect(tester.widget<GlassSurface>(toolbar).enabled, false);
        expect(find.text('删除媒体'), findsOneWidget);
        await tester.tapAt(const Offset(20, 500));
        await tester.pumpAndSettle();
        expect(tester.widget<GlassSurface>(toolbar).enabled, true);
        await tester.tap(find.byTooltip('返回媒体网格'));
        if (!initiallyReduced) {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(find.byType(PhotoViewer), findsOneWidget);
          reduced.value = true;
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(find.byType(PhotoViewer), findsNothing);
        final restoredStyle = tester
            .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
              find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
            )
            .value;
        expect(restoredStyle.statusBarIconBrightness, Brightness.dark);
        expect(
          restoredStyle.systemNavigationBarIconBrightness,
          Brightness.dark,
        );
        expect(
          restoredStyle.systemNavigationBarColor,
          PhotoTreeStyle.lightBackground,
        );
        expect(returned, [browser.photos.single.key]);
        expect(physicalCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        browser.dispose();
      },
    );
  }
}
