import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/ui/photo_grid.dart';
import 'package:phototree/ui/photo_viewer.dart';
import 'package:phototree/ui/media_operation_dialog.dart';
import 'package:phototree/ui/visual_style.dart';

import 'media_browser_test.dart' show photo;
import 'physical_operations_test.dart' show Harness;

void main() {
  testWidgets('density, text scaling and rotation retain a stable photo key', (
    tester,
  ) async {
    final f = await _Fixture.mount(tester, size: const Size(320, 700));
    expect(tester.getSize(find.byType(PhotoTile).first).width, 78.5);
    f.scroll(tester).jumpTo(700);
    await tester.pumpAndSettle();
    final key = f.position.anchor!;
    final y = tester.getTopLeft(_tile(key)).dy;
    f.density.value = GridDensity.comfortable;
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_tile(key)).dy, closeTo(y, 1));
    expect(tester.getSize(_tile(key)).width, closeTo(316 / 3, .01));
    f.density.value = GridDensity.dense;
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_tile(key)).dy, closeTo(y, 1));
    expect(tester.getSize(_tile(key)).width, closeTo(312 / 5, .01));
    await tester.pumpWidget(f.page(textScale: 2));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_tile(key)).dy, closeTo(y, 1));
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(320, 240);
    await tester.pumpAndSettle();
    // Seven requested landscape columns must yield to the 48dp target limit.
    expect(tester.getSize(_tile(key)).width, closeTo(310 / 6, .01));
    expect(f.position.anchor, key);
    expect(f.scans, 0);
    await f.close(tester);
  });

  testWidgets(
    'integrated selection keeps navigation and safe physical preview',
    (tester) async {
      final f = await _Fixture.mount(
        tester,
        size: const Size(320, 700),
        textScale: 2,
      );
      await tester.tap(find.byTooltip('选择媒体'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PhotoTile).first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.byTooltip('相册侧栏'));
      await tester.pumpAndSettle();
      expect(f.navigationCount, 1);
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.byTooltip('全选当前列表'));
      await tester.pumpAndSettle();
      expect(find.text('已选 160 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaOperationDialog), findsOneWidget);
      expect(f.h.ops.preview, isNull);
      expect(find.text('永久删除 160 项媒体？'), findsOneWidget);
      expect(f.h.access.writes, 0);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('已选 160 项'), findsOneWidget);
      expect(f.h.guard.held, isFalse);
      expect(f.h.access.writes, 0);
      await f.close(tester);
    },
  );

  testWidgets(
    'unknown empty directory is not counted as zero; permission wins',
    (tester) async {
      final f = await _Fixture.mount(tester, count: 0);
      await tester.pumpWidget(
        f.page(emptyContent: const Center(child: Text('目录状态待核对'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('目录状态待核对'), findsOneWidget);
      expect(find.text('0 项'), findsNothing);
      expect(find.byTooltip('相册侧栏'), findsOneWidget);
      f.h.media.access = PhotoAccess.denied;
      await f.h.browser.refresh();
      await tester.pumpAndSettle();
      expect(find.text('目录状态待核对'), findsNothing);
      expect(find.text('访问媒体以浏览本机图片和视频'), findsOneWidget);
      expect(find.byTooltip('相册侧栏'), findsOneWidget);
      await f.close(tester);
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'pinch threshold, reversal, endpoints and focal anchor: reduced=$reduced',
      (tester) async {
        final f = await _Fixture.mount(tester, reduced: reduced);
        f.scroll(tester).jumpTo(650);
        await tester.pumpAndSettle();
        final photo = _nearestPhoto(tester, const Offset(200, 400));
        final center = tester.getCenter(_tile(photo.key));
        final pair = await _Pair.down(tester, center, 100);
        await pair.span(116);
        expect(f.density.value, GridDensity.compact);
        await pair.span(118);
        expect(f.density.value, GridDensity.comfortable);
        expect(tester.getCenter(_tile(photo.key)).dy, closeTo(center.dy, 1));
        await pair.span(160); // Endpoint is clamped, not a fourth density.
        expect(f.density.value, GridDensity.comfortable);
        await pair.span(135);
        expect(f.density.value, GridDensity.compact);
        expect(tester.getCenter(_tile(photo.key)).dy, closeTo(center.dy, 1));
        await pair.span(113);
        expect(f.density.value, GridDensity.dense);
        expect(tester.getCenter(_tile(photo.key)).dy, closeTo(center.dy, 1));
        await pair.span(80);
        expect(f.density.value, GridDensity.dense);
        await pair.span(95);
        expect(f.density.value, GridDensity.compact);
        expect(f.changes, [
          GridDensity.comfortable,
          GridDensity.compact,
          GridDensity.dense,
          GridDensity.compact,
        ]);
        await pair.up();
        expect(find.byType(PhotoViewer), findsNothing);
        expect(find.text('已选 1 项'), findsNothing);
        expect(f.scans, 0);
        expect(f.h.access.writes, 0);
        await f.close(tester);
      },
    );
  }

  for (final frameBeforeUp in [false, true]) {
    testWidgets(
      'final reverse move before pointer-up is evaluated: frame=$frameBeforeUp',
      (tester) async {
        final f = await _Fixture.mount(tester);
        f.scroll(tester).jumpTo(650);
        await tester.pumpAndSettle();
        final photo = _nearestPhoto(tester, const Offset(200, 350));
        final center = tester.getCenter(_tile(photo.key));
        final pair = await _Pair.down(tester, center, 100);
        await pair.span(118);
        expect(f.density.value, GridDensity.comfortable);
        await pair.span(100, pump: false);
        if (frameBeforeUp) await tester.pump(const Duration(milliseconds: 16));
        await pair.up();
        expect(f.density.value, GridDensity.compact);
        expect(f.changes, [GridDensity.comfortable, GridDensity.compact]);
        expect(tester.getCenter(_tile(photo.key)).dy, closeTo(center.dy, 1));
        expect(find.byType(PhotoViewer), findsNothing);
        await f.close(tester);
      },
    );
  }

  testWidgets(
    'API34 30-step pinch reversal ending before a frame returns to compact',
    (tester) async {
      final f = await _Fixture.mount(tester);
      final pair = await _Pair.down(tester, const Offset(200, 350), 300);
      for (var step = 1; step <= 30; step++) {
        await pair.span(300 + 70 * step / 30, pump: false);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(f.density.value, GridDensity.comfortable);
      for (var step = 1; step < 30; step++) {
        await pair.span(370 - 70 * step / 30, pump: false);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pair.span(300, pump: false);
      await pair.up();
      expect(f.density.value, GridDensity.compact);
      expect(f.changes, [GridDensity.comfortable, GridDensity.compact]);
      expect(f.scans, 0);
      expect(f.h.access.writes, 0);
      await f.close(tester);
    },
  );

  testWidgets(
    'cancelled final reverse move is discarded before the next frame',
    (tester) async {
      final f = await _Fixture.mount(tester);
      final pair = await _Pair.down(tester, const Offset(200, 350), 100);
      await pair.span(118);
      await pair.span(100, pump: false);
      await pair.left.cancel();
      await pair.right.up();
      await tester.pumpAndSettle();
      expect(f.density.value, GridDensity.comfortable);
      expect(f.changes, [GridDensity.comfortable]);
      expect(find.byType(PhotoViewer), findsNothing);
      expect(f.scans, 0);
      await f.close(tester);
    },
  );

  testWidgets(
    'two-finger translation and cancelled sequence never change density',
    (tester) async {
      final f = await _Fixture.mount(tester);
      f.scroll(tester).jumpTo(500);
      await tester.pumpAndSettle();
      final pair = await _Pair.down(tester, const Offset(200, 400), 100);
      await pair.translate(const Offset(0, -80));
      expect(f.changes, isEmpty);
      expect(f.scroll(tester).offset, closeTo(500, .01));
      await pair.left.cancel();
      await pair.right.moveBy(const Offset(90, -80));
      await tester.pumpAndSettle();
      expect(f.changes, isEmpty);
      expect(f.scroll(tester).offset, closeTo(500, .01));
      await pair.right.up();
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsNothing);
      await f.close(tester);
    },
  );

  testWidgets(
    'second finger stops an already active scroll until all fingers lift',
    (tester) async {
      final f = await _Fixture.mount(tester);
      f.scroll(tester).jumpTo(500);
      await tester.pumpAndSettle();
      final first = await tester.startGesture(
        const Offset(140, 500),
        pointer: 1,
      );
      await first.moveBy(const Offset(0, -100));
      await tester.pump();
      await first.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(f.scroll(tester).offset, greaterThan(500));
      final second = await tester.startGesture(
        const Offset(260, 340),
        pointer: 2,
      );
      await tester.pump();
      final stopped = f.scroll(tester).offset;
      await first.moveBy(const Offset(-20, 0));
      await second.moveBy(const Offset(20, 0));
      await tester.pumpAndSettle();
      expect(f.density.value, GridDensity.comfortable);
      await second.up();
      await tester.pump();
      final afterPinch = f.scroll(tester).offset;
      await first.moveBy(const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(f.scroll(tester).offset, closeTo(afterPinch, .01));
      final replacement = await tester.startGesture(
        const Offset(300, 240),
        pointer: 3,
      );
      await replacement.moveBy(const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(f.density.value, GridDensity.comfortable);
      await replacement.up();
      await first.up();
      await tester.pumpAndSettle();
      expect(stopped, greaterThan(500));
      expect(find.byType(PhotoViewer), findsNothing);
      expect(find.text('已选 1 项'), findsNothing);
      final beforeSingle = f.scroll(tester).offset;
      await tester.drag(
        find.byKey(const ValueKey('photo-grid')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(f.scroll(tester).offset, greaterThan(beforeSingle));
      expect(f.scans, 0);
      await f.close(tester);
    },
  );

  testWidgets(
    'second finger cancels pending long press and preserves existing selection',
    (tester) async {
      final f = await _Fixture.mount(tester);
      final pair = await _Pair.down(tester, const Offset(200, 350), 100);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('已选 1 项'), findsNothing);
      await pair.span(120);
      await pair.up();
      expect(find.byType(PhotoViewer), findsNothing);
      await tester.tap(find.byTooltip('选择媒体'));
      await tester.pumpAndSettle();
      await tester.tap(
        _tile(_nearestPhoto(tester, const Offset(200, 350)).key),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      final secondPair = await _Pair.down(tester, const Offset(200, 350), 120);
      await secondPair.span(100);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('已选 1 项'), findsOneWidget);
      await secondPair.up();
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(f.scans, 0);
      expect(f.h.access.writes, 0);
      await f.close(tester);
    },
  );

  testWidgets(
    'an accepted long press remains selected when the second finger starts pinch',
    (tester) async {
      final f = await _Fixture.mount(tester);
      final target = _nearestPhoto(tester, const Offset(150, 350));
      final center = tester.getCenter(_tile(target.key));
      final first = await tester.startGesture(center, pointer: 1);
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('已选 1 项'), findsOneWidget);
      final second = await tester.startGesture(
        center + const Offset(100, 0),
        pointer: 2,
      );
      await tester.pump();
      await first.moveBy(const Offset(-20, 0));
      await second.moveBy(const Offset(20, 0));
      await tester.pumpAndSettle();
      expect(f.density.value, GridDensity.comfortable);
      expect(find.text('已选 1 项'), findsOneWidget);
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.byType(PhotoViewer), findsNothing);
      expect(f.h.access.writes, 0);
      await f.close(tester);
    },
  );

  testWidgets(
    'bottom bound and clamped landscape columns keep the focal photo',
    (tester) async {
      final f = await _Fixture.mount(tester, size: const Size(320, 240));
      f.scroll(tester).jumpTo(f.scroll(tester).position.maxScrollExtent);
      await tester.pumpAndSettle();
      final target = _nearestPhoto(tester, const Offset(160, 180));
      final center = tester.getCenter(_tile(target.key));
      final pair = await _Pair.down(tester, center, 80);
      await pair.span(66);
      // compact=6 and dense=7 both fit only six columns in this landscape.
      expect(f.density.value, GridDensity.dense);
      expect(tester.getCenter(_tile(target.key)).dy, closeTo(center.dy, 1));
      await pair.span(80);
      expect(f.density.value, GridDensity.compact);
      await pair.span(96);
      expect(f.density.value, GridDensity.comfortable);
      expect(
        tester
            .getRect(_tile(target.key))
            .overlaps(tester.getRect(find.byKey(const ValueKey('photo-grid')))),
        isTrue,
      );
      expect(
        f.scroll(tester).offset,
        lessThanOrEqualTo(f.scroll(tester).position.maxScrollExtent),
      );
      await pair.up();
      expect(f.scans, 0);
      await f.close(tester);
    },
  );

  testWidgets(
    'viewer two-finger zoom cannot change the underlying grid density',
    (tester) async {
      final f = await _Fixture.mount(tester);
      await tester.tap(
        _tile(_nearestPhoto(tester, const Offset(200, 350)).key),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsOneWidget);
      final pair = await _Pair.down(tester, const Offset(200, 400), 100);
      await pair.span(160);
      await pair.up();
      expect(f.changes, isEmpty);
      expect(f.density.value, GridDensity.compact);
      await tester.tap(find.byTooltip('返回媒体网格'));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsNothing);
      expect(f.scans, 0);
      await f.close(tester);
    },
  );

  testWidgets('scope disposal during pinch ignores the old pointer sequence', (
    tester,
  ) async {
    final f = await _Fixture.mount(tester);
    final pair = await _Pair.down(tester, const Offset(200, 350), 100);
    await tester.pumpWidget(const SizedBox());
    await pair.left.moveBy(const Offset(-30, 0));
    await pair.right.moveBy(const Offset(30, 0));
    await pair.up();
    expect(tester.takeException(), isNull);
    expect(f.changes, isEmpty);
    await f.close(tester);
  });

  testWidgets(
    'pinch at list bounds keeps its photo visible and cancels on permission loss',
    (tester) async {
      final f = await _Fixture.mount(tester);
      final photo = _nearestPhoto(tester, const Offset(200, 155));
      final pair = await _Pair.down(
        tester,
        tester.getCenter(_tile(photo.key)),
        100,
      );
      await pair.span(82);
      expect(f.density.value, GridDensity.dense);
      final list = tester.getRect(find.byKey(const ValueKey('photo-grid')));
      expect(tester.getRect(_tile(photo.key)).overlaps(list), isTrue);
      expect(f.scroll(tester).offset, greaterThanOrEqualTo(0));
      f.h.media.access = PhotoAccess.denied;
      await f.h.browser.refresh();
      await tester.pumpAndSettle();
      await pair.span(130);
      expect(f.changes, [GridDensity.dense]);
      await pair.up();
      expect(find.byType(PhotoViewer), findsNothing);
      expect(find.byType(PhotoTile), findsNothing);
      await f.close(tester);
    },
  );
}

Finder _tile(String key) => find.byWidgetPredicate(
  (widget) => widget is PhotoTile && widget.photo.key == key,
);

Photo _nearestPhoto(WidgetTester tester, Offset point) {
  final tiles = tester.widgetList<PhotoTile>(find.byType(PhotoTile)).toList();
  tiles.sort(
    (a, b) => (tester.getCenter(_tile(a.photo.key)) - point).distanceSquared
        .compareTo(
          (tester.getCenter(_tile(b.photo.key)) - point).distanceSquared,
        ),
  );
  return tiles.first.photo;
}

class _Fixture {
  final h = Harness();
  final density = ValueNotifier(GridDensity.compact);
  final position = GridPosition();
  final changes = <GridDensity>[];
  int navigationCount = 0, scans = 0;
  bool reduced = false;

  static Future<_Fixture> mount(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    int count = 160,
    double textScale = 1,
    bool reduced = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = _Fixture()..reduced = reduced;
    f.h.media.items = List.generate(count, (i) => photo(i + 1, added: 1000));
    f.h.media.image = () async => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    );
    await f.h.init();
    f.h.media.query = (after) async {
      f.scans++;
      return f.h.media.items.where((p) => p.id > after).take(256).toList();
    };
    await tester.pumpWidget(f.page(textScale: textScale));
    await tester.pumpAndSettle();
    return f;
  }

  Widget page({double textScale = 1, Widget? emptyContent}) =>
      ValueListenableBuilder<GridDensity>(
        valueListenable: density,
        builder: (_, value, _) => MaterialApp(
          theme: photoTreeTheme(Brightness.light),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                disableAnimations: reduced,
              ),
              child: Scaffold(
                body: PhotoGrid(
                  browser: h.browser,
                  physical: h.ops,
                  position: position,
                  scopeTitle: '所有媒体',
                  density: value,
                  onDensityChanged: (value) {
                    changes.add(value);
                    density.value = value;
                  },
                  navigationButton: IconButton(
                    tooltip: '相册侧栏',
                    icon: const Icon(Icons.menu),
                    onPressed: () => navigationCount++,
                  ),
                  menuButton: IconButton(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () {},
                  ),
                  emptyContent: emptyContent,
                ),
              ),
            ),
          ),
        ),
      );

  ScrollController scroll(WidgetTester tester) => tester
      .widget<ListView>(find.byKey(const ValueKey('photo-grid')))
      .controller!;

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    h.dispose();
    density.dispose();
  }
}

class _Pair {
  _Pair(this.tester, this.left, this.right, this.middle);
  final WidgetTester tester;
  final TestGesture left, right;
  Offset middle;
  double distance = 100;

  static Future<_Pair> down(
    WidgetTester tester,
    Offset middle,
    double span,
  ) async {
    final left = await tester.startGesture(
      middle - Offset(span / 2, 0),
      pointer: 1,
    );
    final right = await tester.startGesture(
      middle + Offset(span / 2, 0),
      pointer: 2,
    );
    await tester.pump();
    return _Pair(tester, left, right, middle)..distance = span;
  }

  Future<void> span(double value, {bool pump = true}) async {
    distance = value;
    await left.moveTo(middle - Offset(value / 2, 0));
    await right.moveTo(middle + Offset(value / 2, 0));
    if (pump) await tester.pumpAndSettle();
  }

  Future<void> translate(Offset delta) async {
    middle += delta;
    await left.moveTo(middle - Offset(distance / 2, 0));
    await right.moveTo(middle + Offset(distance / 2, 0));
    await tester.pumpAndSettle();
  }

  Future<void> up() async {
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
  }
}
