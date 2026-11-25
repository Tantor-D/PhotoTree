import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/ui/photo_grid.dart';
import 'package:phototree/media/media_source.dart';

import 'physical_operations_test.dart' show Harness;
import 'media_browser_test.dart' show photo;

void main() {
  Future<Harness> mount(WidgetTester t, {int kind = 0}) async {
    final h = Harness();
    h.media.items = List.generate(
      120,
      (i) => kind == 0
          ? photo(i + 1)
          : Photo(
              id: i + 1,
              directory: 'Pictures/A/',
              kind: kind == 1 || i.isEven ? MediaKind.video : MediaKind.image,
            ),
    );
    h.media.image = () async => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    );
    await h.init();
    addTearDown(h.dispose);
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoGrid(
            browser: h.browser,
            physical: h.ops,
            scopeTitle: '所有媒体',
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    return h;
  }

  Finder tile(int id) =>
      find.byWidgetPredicate((w) => w is PhotoTile && w.photo.id == id);

  testWidgets('selection allows ten direct sweeps without another long press', (
    t,
  ) async {
    await mount(t);
    await t.longPress(tile(109));
    await t.pumpAndSettle();
    for (var attempt = 0; attempt < 10; attempt++) {
      final g = await t.startGesture(t.getCenter(tile(119)));
      await g.moveTo(t.getCenter(tile(111)));
      await t.pump();
      expect(find.text(attempt.isEven ? '已选 10 项' : '已选 1 项'), findsOneWidget);
      if (attempt.isEven) {
        await g.up();
      } else {
        await g.cancel();
      }
      await t.pumpAndSettle();
    }
    await t.tap(tile(120));
    await t.pumpAndSettle();
    expect(find.text('已选 2 项'), findsOneWidget);
  });

  for (final kind in [0, 1, 2]) {
    testWidgets(
      'slow vertical direct sweep wins scroll and restarts after second pointer $kind',
      (t) async {
        await mount(t, kind: kind);
        await t.longPress(tile(109));
        await t.pumpAndSettle();
        final scroll = t
            .widget<ListView>(find.byKey(const ValueKey('photo-grid')))
            .controller!;
        final start = t.getCenter(tile(119)), end = t.getCenter(tile(111));
        final g = await t.startGesture(start, pointer: 7);
        for (var i = 1; i <= 20; i++) {
          await g.moveTo(Offset.lerp(start, end, i / 20)!);
          await t.pump(const Duration(milliseconds: 10));
        }
        expect(find.text('已选 10 项'), findsOneWidget);
        expect(scroll.offset, 0);
        await g.moveTo(t.getCenter(tile(115)));
        await t.pump();
        expect(find.text('已选 6 项'), findsOneWidget);
        final second = await t.startGesture(t.getCenter(tile(118)), pointer: 8);
        await t.pump();
        await second.up();
        await g.moveTo(end);
        await g.up();
        await t.pumpAndSettle();
        expect(find.text('已选 6 项'), findsOneWidget);
        final again = await t.startGesture(start, pointer: 7);
        await again.moveTo(t.getCenter(tile(115)));
        await t.pump();
        expect(find.text('已选 1 项'), findsOneWidget);
        await again.up();
        await t.pumpAndSettle();
        // The top inset is blank list content under the floating toolbar.
        await t.dragFrom(const Offset(2, 65), const Offset(0, -60));
        await t.pumpAndSettle();
        expect(scroll.offset, greaterThan(0));
        expect(find.text('已选 1 项'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'dialog back preserves selection and nested route back exits it first',
    (t) async {
      final h = await mount(t);
      final navigator = Navigator.of(t.element(find.byType(PhotoGrid)));
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            body: PhotoGrid(
              browser: h.browser,
              physical: h.ops,
              scopeTitle: '相册',
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.longPress(tile(120));
      await t.pumpAndSettle();
      final selectedContext = t.element(find.byType(PhotoGrid));
      showDialog<void>(
        context: selectedContext,
        builder: (_) => const AlertDialog(content: Text('测试弹窗')),
      );
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('测试弹窗'), findsNothing);
      expect(find.text('已选 1 项'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('相册'), findsOneWidget);
      expect(find.byTooltip('退出选择'), findsNothing);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('所有媒体'), findsOneWidget);
    },
  );

  testWidgets(
    'system back exits selection including empty selection before route',
    (t) async {
      await mount(t);
      for (final empty in [false, true]) {
        await t.longPress(tile(120));
        await t.pumpAndSettle();
        if (empty) {
          await t.tap(tile(120));
          await t.pumpAndSettle();
        }
        final context = t.element(find.byType(PhotoGrid));
        expect(
          ModalRoute.of(context)!.popDisposition,
          RoutePopDisposition.doNotPop,
        );
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
        expect(find.byTooltip('选择媒体'), findsOneWidget);
        expect(find.byTooltip('退出选择'), findsNothing);
        expect(
          ModalRoute.of(context)!.popDisposition,
          RoutePopDisposition.bubble,
        );
      }
    },
  );

  for (final kind in [0, 1, 2]) {
    testWidgets('R2 baseline and second-pointer restart media kind $kind', (
      t,
    ) async {
      final h = await mount(t, kind: kind);
      await t.longPress(tile(109)); // item12 is outside the new range.
      await t.pumpAndSettle();
      final g = await t.startGesture(t.getCenter(tile(119)), pointer: 1);
      await t.pump(const Duration(milliseconds: 600));
      await g.moveTo(t.getCenter(tile(111)));
      await t.pump();
      expect(find.text('已选 10 项'), findsOneWidget);
      await g.moveTo(t.getCenter(tile(115)));
      await t.pump();
      expect(find.text('已选 6 项'), findsOneWidget);
      final second = await t.startGesture(t.getCenter(tile(118)), pointer: 2);
      await t.pump();
      await second.up();
      await g.moveTo(t.getCenter(tile(111)));
      await t.pump();
      expect(find.text('已选 6 项'), findsOneWidget);
      await g.up();
      await t.pumpAndSettle();
      final remove = await t.startGesture(t.getCenter(tile(119)));
      await t.pump(const Duration(milliseconds: 600));
      await remove.moveTo(t.getCenter(tile(115)));
      await t.pump();
      expect(find.text('已选 1 项'), findsOneWidget);
      await remove.moveTo(t.getCenter(tile(117)));
      await t.pump();
      expect(find.text('已选 3 项'), findsOneWidget);
      await remove.cancel();
      await t.pumpAndSettle();
      expect(h.access.writes, 0);
    });
  }

  testWidgets('R2 complete interval shrinks and restarts ten times', (t) async {
    await mount(t);
    // The displayed order is 120,119,...; item 2 -> item 10.
    for (var attempt = 0; attempt < 10; attempt++) {
      final gesture = await t.startGesture(t.getCenter(tile(119)));
      await t.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(t.getCenter(tile(111)));
      await t.pump();
      expect(find.text('已选 9 项'), findsOneWidget);
      await gesture.moveTo(t.getCenter(tile(115)));
      await t.pump();
      expect(find.text('已选 5 项'), findsOneWidget);
      if (attempt.isEven) {
        await gesture.up();
      } else {
        await gesture.cancel();
      }
      await t.pumpAndSettle();
      final remove = await t.startGesture(t.getCenter(tile(119)));
      await t.pump(const Duration(milliseconds: 600));
      await remove.moveTo(t.getCenter(tile(115)));
      await t.pump();
      expect(find.text('已选 0 项'), findsOneWidget);
      await remove.up();
      await t.pumpAndSettle();
    }
  });

  testWidgets(
    'reverse shrinks selection and selected start removes the interval',
    (t) async {
      await mount(t);
      final first = t.getCenter(tile(120)), third = t.getCenter(tile(118));
      final gesture = await t.startGesture(first);
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('已选 1 项'), findsOneWidget);
      await gesture.moveTo(third);
      await t.pump();
      expect(find.text('已选 3 项'), findsOneWidget);
      await gesture.moveTo(first);
      await t.pump();
      expect(find.text('已选 1 项'), findsOneWidget);
      await gesture.up();
      await t.pumpAndSettle();
      final remove = await t.startGesture(first);
      await t.pump(const Duration(milliseconds: 600));
      await remove.moveTo(third);
      await t.pump();
      expect(find.text('已选 0 项'), findsOneWidget);
      await remove.up();
      await t.pumpAndSettle();
    },
  );

  testWidgets(
    'moving beyond viewport holds its last interval without scrolling',
    (t) async {
      await mount(t);
      final start = t.getCenter(tile(120));
      final gesture = await t.startGesture(start);
      await t.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(Offset(start.dx, 850));
      await t.pump(const Duration(milliseconds: 50));
      final selected = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.selected == true,
      );
      expect(selected.evaluate().length, 1);
      final scroll = t
          .widget<ListView>(find.byKey(const ValueKey('photo-grid')))
          .controller!;
      expect(scroll.offset, 0);
      await gesture.up();
      await t.pumpAndSettle();
    },
  );

  testWidgets('toolbar second pointer ends sweep before leaving selection', (
    t,
  ) async {
    await mount(t);
    final gesture = await t.startGesture(t.getCenter(tile(116)), pointer: 1);
    await t.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(const Offset(200, 710));
    await t.pump(const Duration(milliseconds: 50));
    final second = await t.startGesture(
      t.getCenter(find.byTooltip('退出选择')),
      pointer: 2,
    );
    await second.up();
    await t.pump();
    final scroll = t
        .widget<ListView>(find.byKey(const ValueKey('photo-grid')))
        .controller!;
    final offset = scroll.offset;
    await t.pump(const Duration(milliseconds: 100));
    expect(scroll.offset, offset);
    expect(find.byTooltip('选择媒体'), findsOneWidget);
    await gesture.up();
    await t.pumpAndSettle();
  });

  testWidgets(
    'unchanged refresh preserves selected identity and replacement drops it',
    (t) async {
      final h = await mount(t);
      await t.longPress(tile(120));
      await t.pumpAndSettle();
      await h.browser.refresh();
      await t.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      h.media.items = [
        photo(120, added: 100),
        ...h.media.items.where((p) => p.id != 120),
      ];
      await h.browser.refresh();
      await t.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
    },
  );

  testWidgets('edge scroll stops outside grid and after pointer cancellation', (
    t,
  ) async {
    await mount(t);
    final gesture = await t.startGesture(t.getCenter(tile(116)));
    await t.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(const Offset(200, 710));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    final scroll = t
        .widget<ListView>(find.byKey(const ValueKey('photo-grid')))
        .controller!;
    expect(scroll.offset, greaterThan(0));
    await gesture.moveTo(const Offset(420, 710));
    final offset = scroll.offset;
    await t.pump(const Duration(milliseconds: 100));
    expect(scroll.offset, offset);
    await gesture.cancel();
    await t.pumpAndSettle();
    expect(scroll.offset, offset);
  });
}
