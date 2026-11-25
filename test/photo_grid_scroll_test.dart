import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/ui/photo_grid.dart';

import 'media_browser_test.dart' show FakeMedia, photo;
import 'thumbnail_continuity_test.dart' show decodePending;

class ScrollMedia extends FakeMedia {
  bool hold = false;
  final pending = <Completer<void>>[];
  final reads = <String, int>{};
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );

  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) async {
    reads.update(photo.key, (value) => value + 1, ifAbsent: () => 1);
    if (hold) {
      final gate = Completer<void>();
      pending.add(gate);
      await gate.future;
    }
    // A platform read returns a fresh buffer, even for the same media.
    return Uint8List.fromList(bytes);
  }

  void release() {
    hold = false;
    for (final gate in pending) {
      if (!gate.isCompleted) gate.complete();
    }
    pending.clear();
  }
}

void main() {
  testWidgets('a quick return reuses unfinished visible thumbnail reads', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = ScrollMedia()
      ..hold = true
      ..items = List.generate(180, (i) => photo(i + 1, added: 1000));
    final browser = PhotoBrowser(source);
    await browser.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhotoGrid(browser: browser)),
      ),
    );
    final started = source.reads.keys.toList();
    expect(started, hasLength(4));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(2400);
    await tester.pump();
    scroll.position.jumpTo(0);
    await tester.pump();
    // Release only the original platform reads. A second read for the same
    // visible photo stays blocked, exposing the extra placeholder window.
    for (final gate in source.pending.toList()) {
      gate.complete();
    }
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump();
    }
    final blanks = <String>[];
    for (final key in started) {
      final tile = find.byWidgetPredicate(
        (w) => w is PhotoTile && w.photo.key == key,
      );
      final raw = find.descendant(of: tile, matching: find.byType(RawImage));
      if (raw.evaluate().isEmpty ||
          tester.renderObject<RenderImage>(raw).image == null) {
        blanks.add(key);
      }
    }
    final repeats = started.where((key) => source.reads[key] != 1).toList();
    source.release();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    browser.dispose();
    expect(
      blanks,
      isEmpty,
      reason: 'completed visible reads should display immediately on return',
    );
    expect(
      repeats,
      isEmpty,
      reason: 're-entered tiles must share the original read',
    );
  });

  testWidgets('neighboring rows are decoded before entering the viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = ScrollMedia()
      ..items = List.generate(180, (i) => photo(i + 1, added: 1000));
    final browser = PhotoBrowser(source);
    await browser.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhotoGrid(browser: browser)),
      ),
    );
    await tester.pumpAndSettle();
    await decodePending(tester);
    source.hold = true;
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(400);
    await tester.pump();
    final blanks = <String>[];
    for (final element in find.byType(PhotoTile).evaluate()) {
      final finder = find.byWidget(element.widget);
      if (!tester
          .getRect(finder)
          .overlaps(const Rect.fromLTWH(0, 0, 400, 800))) {
        continue;
      }
      final raw = find.descendant(of: finder, matching: find.byType(RawImage));
      if (raw.evaluate().isEmpty ||
          tester.renderObject<RenderImage>(raw).image == null) {
        blanks.add((element.widget as PhotoTile).photo.key);
      }
    }
    source.release();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    browser.dispose();
    expect(
      blanks,
      isEmpty,
      reason: 'Nearby cold rows should be prefetched, not wait until visible',
    );
  });

  testWidgets('recently decoded photos return without a placeholder frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = ScrollMedia()
      ..items = List.generate(180, (i) => photo(i + 1, added: 1000));
    final browser = PhotoBrowser(source);
    await browser.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhotoGrid(browser: browser)),
      ),
    );
    await tester.pumpAndSettle();
    await decodePending(tester);
    Finder tile(String key) => find.byWidgetPredicate(
      (widget) => widget is PhotoTile && widget.photo.key == key,
    );
    final keys = tester
        .widgetList<PhotoTile>(find.byType(PhotoTile))
        .where(
          (widget) => tester
              .getRect(tile(widget.photo.key))
              .overlaps(const Rect.fromLTWH(0, 0, 400, 800)),
        )
        .map((widget) => widget.photo.key)
        .toList();
    for (final key in keys) {
      final raw = find.descendant(
        of: tile(key),
        matching: find.byType(RawImage),
      );
      expect(tester.renderObject<RenderImage>(raw).image, isNotNull);
    }
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final blanks = <String>[];
    final readsBefore = Map<String, int>.of(source.reads);
    source.hold = true;
    for (var round = 0; round < 10; round++) {
      scroll.position.jumpTo(2400);
      await tester.pump();
      expect(tile(keys.first), findsNothing);
      scroll.position.jumpTo(0);
      await tester.pump();
      for (final key in keys) {
        final raw = find.descendant(
          of: tile(key),
          matching: find.byType(RawImage),
        );
        if (raw.evaluate().isEmpty ||
            tester.renderObject<RenderImage>(raw).image == null) {
          blanks.add('$round:$key');
        }
      }
    }
    source.release();
    await tester.pumpAndSettle();
    final repeated = keys
        .where((key) => source.reads[key] != readsBefore[key])
        .toList();
    await tester.pumpWidget(const SizedBox());
    browser.dispose();
    expect(
      blanks,
      isEmpty,
      reason: 'Previously decoded photos flashed placeholders',
    );
    expect(repeated, isEmpty, reason: 'Warm photos were read again');
  });
}
