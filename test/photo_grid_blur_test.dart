import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/ui/photo_grid.dart';
import 'package:phototree/ui/thumbnail_images.dart';
import 'package:phototree/ui/visual_style.dart';

import 'thumbnail_continuity_test.dart' show IdentityMedia, identityMedia;
import 'thumbnail_images_test.dart' show finishImages;
import 'physical_operations_test.dart' show Harness;

class _DetailGate extends IdentityMedia {
  _DetailGate(IdentityMedia source) {
    items = source.items;
    images.addAll(source.images);
  }
  bool hold = false, fail = false;
  int details = 0;
  final gate = Completer<void>();
  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) async {
    if (pixels > 128) {
      details++;
      if (hold) await gate.future;
      if (fail) throw const MediaFailure(MediaFailureKind.unavailable);
    }
    return super.thumbnail(photo, pixels);
  }
}

void main() {
  late _DetailGate source;
  late PhotoBrowser browser;
  late ThumbnailImages images;
  late ScrollController scroll;
  Widget app({bool dark = false, bool reduced = false, String title = '图库'}) =>
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(400, 800),
            devicePixelRatio: 3,
            disableAnimations: reduced,
          ),
          child: Scaffold(
            body: ThumbnailScope(
              images: images,
              child: Column(
                children: [
                  const GlassSurface(child: Text('独立侧栏表面')),
                  Expanded(
                    child: PhotoGrid(browser: browser, scopeTitle: title),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
  Finder getGridFilter() => find.descendant(
    of: find.byType(PhotoGrid),
    matching: find.byType(BackdropFilter),
  );
  bool blur(WidgetTester t) =>
      t.widget<BackdropFilter>(getGridFilter()).enabled;
  Future<void> mount(
    WidgetTester t, {
    bool dark = false,
    bool reduced = false,
  }) async {
    t.view.physicalSize = const Size(1200, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    cache.maximumSize = 120;
    cache.maximumSizeBytes = 48 * 1024 * 1024;
    source = _DetailGate(await identityMedia(t, count: 100));
    browser = PhotoBrowser(source);
    await browser.refresh();
    images = ThumbnailImages(browser);
    await t.pumpWidget(app(dark: dark, reduced: reduced));
    await t.pump(const Duration(milliseconds: 150));
    await finishImages(t, images);
    scroll = t
        .widget<ListView>(find.byKey(const ValueKey('photo-grid')))
        .controller!;
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      images.dispose();
      browser.dispose();
      if (!source.gate.isCompleted) source.gate.complete();
      await finishImages(t, images);
      cache.clear();
      cache.clearLiveImages();
    });
  }

  testWidgets('grid blur waits for visible detail without rebuilding photos', (
    t,
  ) async {
    await mount(t);
    expect(blur(t), isTrue);
    source.hold = true;
    final before = source.details;
    scroll.jumpTo(900);
    await t.pump();
    expect(blur(t), isFalse);
    final list = t.widget<ListView>(find.byKey(const ValueKey('photo-grid')));
    expect(
      t.widgetList<BackdropFilter>(find.byType(BackdropFilter)).first.enabled,
      isTrue,
    );
    await t.pump(const Duration(milliseconds: 149));
    expect(
      source.details,
      before,
      reason: 'blur must not advance clear eligibility',
    );
    await t.pump(const Duration(milliseconds: 1));
    expect(blur(t), isFalse);
    source.hold = false;
    source.gate.complete();
    await finishImages(t, images);
    await t.pump();
    expect(blur(t), isTrue);
    expect(
      identical(
        t.widget<ListView>(find.byKey(const ValueKey('photo-grid'))),
        list,
      ),
      isTrue,
    );
  });

  for (final fail in [false, true]) {
    testWidgets('grid blur deadline survives stalled or failed details $fail', (
      t,
    ) async {
      await mount(t);
      source.hold = true;
      source.fail = fail;
      scroll.jumpTo(900);
      await t.pump();
      expect(blur(t), isFalse);
      await t.pump(const Duration(milliseconds: 500));
      if (fail) {
        source.gate.complete();
        await t.pump();
      }
      await t.pumpWidget(app(title: '重建不延长期限'));
      await t.pump(const Duration(milliseconds: 499));
      expect(blur(t), isFalse);
      await t.pump(const Duration(milliseconds: 1));
      expect(blur(t), isTrue);
    });
  }

  testWidgets('reverse motion invalidates old blur restoration deadline', (
    t,
  ) async {
    await mount(t);
    source.hold = true;
    scroll.jumpTo(900);
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    scroll.jumpTo(750);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(
      blur(t),
      isFalse,
      reason: 'the earlier stop cannot restore during a newer interval',
    );
    await t.pump(const Duration(milliseconds: 600));
    expect(blur(t), isTrue);
  });

  testWidgets('background cancels pending grid blur restoration', (t) async {
    await mount(t);
    source.hold = true;
    scroll.jumpTo(900);
    await t.pump();
    expect(blur(t), isFalse);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    expect(blur(t), isTrue);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    source.hold = false;
    source.gate.complete();
    await finishImages(t, images);
    await t.pump();
    expect(blur(t), isTrue);
  });

  testWidgets('continuous scrolling does not consume the post-stop deadline', (
    t,
  ) async {
    await mount(t);
    source.hold = true;
    unawaited(
      scroll.animateTo(
        900,
        duration: const Duration(milliseconds: 1500),
        curve: Curves.linear,
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 1400));
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    expect(blur(t), isFalse);
    await t.pump(const Duration(milliseconds: 100));
    scroll.jumpTo(scroll.offset);
    await t.pump();
    await t.pump(const Duration(milliseconds: 999));
    expect(blur(t), isFalse);
    await t.pump(const Duration(milliseconds: 1));
    expect(blur(t), isTrue);
  });

  testWidgets(
    'new image session detaches readiness and old restoration callbacks',
    (t) async {
      await mount(t);
      final oldImages = images, oldBrowser = browser, oldSource = source;
      source.hold = true;
      scroll.jumpTo(900);
      await t.pump();
      source = _DetailGate(await identityMedia(t, count: 100));
      browser = PhotoBrowser(source);
      await browser.refresh();
      images = ThumbnailImages(browser);
      await t.pumpWidget(app());
      await t.pump(const Duration(milliseconds: 150));
      await finishImages(t, images);
      await t.pump();
      expect(blur(t), isTrue);
      oldImages.dispose();
      oldBrowser.dispose();
      oldSource.gate.complete();
      await finishImages(t, oldImages);
      source.hold = true;
      scroll.jumpTo(1400);
      await t.pump();
      expect(blur(t), isFalse);
      await t.pump(const Duration(milliseconds: 999));
      expect(blur(t), isFalse);
      await t.pump(const Duration(milliseconds: 1));
      expect(blur(t), isTrue);
    },
  );

  testWidgets(
    'selection suspends both grid toolbars without replacing their material',
    (t) async {
      await mount(t);
      final physical = Harness();
      await physical.init();
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(400, 800),
              devicePixelRatio: 3,
            ),
            child: Scaffold(
              body: ThumbnailScope(
                images: images,
                child: PhotoGrid(
                  browser: browser,
                  scopeTitle: '图库',
                  physical: physical.ops,
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byTooltip('选择媒体'));
      await t.pump();
      final filters = find.descendant(
        of: find.byType(PhotoGrid),
        matching: find.byType(BackdropFilter),
      );
      expect(filters, findsNWidgets(2));
      expect(
        t.widgetList<BackdropFilter>(filters).every((f) => f.enabled),
        isTrue,
      );
      source.hold = true;
      scroll = t
          .widget<ListView>(find.byKey(const ValueKey('photo-grid')))
          .controller!;
      scroll.jumpTo(900);
      await t.pump();
      expect(
        t.widgetList<BackdropFilter>(filters).every((f) => !f.enabled),
        isTrue,
      );
      await t.pump(const Duration(seconds: 1));
      expect(
        t.widgetList<BackdropFilter>(filters).every((f) => f.enabled),
        isTrue,
      );
      await t.pumpWidget(const SizedBox());
      physical.dispose();
    },
  );

  for (final dark in [false, true]) {
    testWidgets('grid blur preserves material and reduced motion $dark', (
      t,
    ) async {
      await mount(t, dark: dark);
      final initial = t.widget<GlassSurface>(
        find.descendant(
          of: find.byType(PhotoGrid),
          matching: find.byType(GlassSurface),
        ),
      );
      source.hold = true;
      scroll.jumpTo(900);
      await t.pump();
      expect(blur(t), isFalse);
      final moving = t.widget<GlassSurface>(
        find.descendant(
          of: find.byType(PhotoGrid),
          matching: find.byType(GlassSurface),
        ),
      );
      expect(moving.opacity, initial.opacity);
      expect(moving.borderRadius, initial.borderRadius);
      expect(moving.highOpacity, initial.highOpacity);
      await t.pumpWidget(app(dark: dark, reduced: true));
      await t.pump(const Duration(seconds: 1));
      expect(
        blur(t),
        isFalse,
        reason: 'reduced motion keeps its existing opaque material',
      );
    });
  }
}
