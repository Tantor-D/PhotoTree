import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/ui/photo_grid.dart';
import 'package:phototree/media/media_source.dart';

import 'physical_operations_test.dart' show Harness;
import 'media_browser_test.dart' show photo;
import 'thumbnail_continuity_test.dart' show decodePending;

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

  Future<void> decodeVisible(WidgetTester t) async {
    await decodePending(t);
    final target = find.descendant(
      of: tile(119),
      matching: find.byType(RawImage),
    );
    expect(t.widget<RawImage>(target).image, isNotNull);
  }

  testWidgets(
    'selection preserves the list position and decoded photos for ten cycles',
    (t) async {
      final h = await mount(t);
      await decodeVisible(t);
      final list = t.element(find.byKey(const ValueKey('photo-grid')));
      final scroll = t
          .widget<ListView>(find.byKey(const ValueKey('photo-grid')))
          .controller!;
      final position = scroll.position;
      final before = t.state(tile(119));
      final point = t.getTopLeft(tile(119));
      var requests = 0;
      final original = h.media.image!;
      h.media.image = () {
        requests++;
        return original();
      };
      for (var cycle = 0; cycle < 10; cycle++) {
        if (cycle.isEven) {
          await t.longPress(tile(119));
        } else {
          await t.tap(find.byTooltip('选择媒体'));
        }
        for (var frame = 0; frame < 3; frame++) {
          await t.pump(const Duration(milliseconds: 16));
          expect(
            t.element(find.byKey(const ValueKey('photo-grid'))),
            same(list),
          );
          expect(scroll.position, same(position));
          expect(t.state(tile(119)), same(before));
          expect(t.getTopLeft(tile(119)), point);
          final images = t.widgetList<RawImage>(
            find.descendant(of: tile(119), matching: find.byType(RawImage)),
          );
          expect(images.single.image, isNotNull);
        }
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
        expect(t.element(find.byKey(const ValueKey('photo-grid'))), same(list));
        expect(scroll.position, same(position));
      }
      expect(requests, 0);
    },
  );

  testWidgets(
    'middle and end selection only clamp when bottom inset is removed',
    (t) async {
      await mount(t);
      final scroll = t
          .widget<ListView>(find.byKey(const ValueKey('photo-grid')))
          .controller!;
      scroll.jumpTo(600);
      await t.pumpAndSettle();
      final list = t.element(find.byKey(const ValueKey('photo-grid')));
      await t.tap(find.byTooltip('选择媒体'));
      await t.pumpAndSettle();
      expect(scroll.offset, 600);
      expect(t.element(find.byKey(const ValueKey('photo-grid'))), same(list));
      // Lazy-list extent estimates converge as the final rows are laid out.
      for (var i = 0; i < 5; i++) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await t.pumpAndSettle();
      }
      expect(tile(1), findsOneWidget);
      final oldEnd = scroll.offset;
      await t.tap(find.byTooltip('退出选择'));
      await t.pumpAndSettle();
      expect(scroll.offset, scroll.position.maxScrollExtent);
      expect(oldEnd - scroll.offset, greaterThan(0));
      expect(oldEnd - scroll.offset, lessThan(100));
      expect(t.element(find.byKey(const ValueKey('photo-grid'))), same(list));
    },
  );
}
