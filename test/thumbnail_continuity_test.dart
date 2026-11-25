import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/ui/photo_grid.dart';

import 'media_browser_test.dart' show FakeMedia;

// Real dimensions and distinct RGB identity survive resizing at either quality.
class IdentityMedia extends FakeMedia {
  final images = <int, Uint8List>{};
  final reads = <(int, int), int>{};
  @override
  Future<Uint8List> thumbnail(Photo item, int pixels) async {
    final key = (item.id, pixels);
    reads.update(key, (n) => n + 1, ifAbsent: () => 1);
    return Uint8List.fromList(images[item.id]!);
  }
}

Future<IdentityMedia> identityMedia(
  WidgetTester tester, {
  int count = 600,
}) async {
  final source = IdentityMedia();
  source.items = List.generate(
    count,
    (i) => Photo(
      id: i + 1,
      directory: 'Pictures/Test/',
      addedSeconds: 1000,
      width: 512,
      height: 384,
      kind: i % 11 == 0 ? MediaKind.video : MediaKind.image,
      durationMs: 1234,
    ),
  );
  await tester.runAsync(() async {
    for (final photo in source.items) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Color(0xff000000 | photo.id * 997), BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(512, 384);
      source.images[photo.id] = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
    }
  });
  return source;
}

Future<void> decodePending(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 150));
  for (var i = 0; i < 500; i++) {
    await tester.pump(const Duration(milliseconds: 5));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await tester.pump();
    final tiles = tester.widgetList<PhotoTile>(find.byType(PhotoTile));
    if (tiles.isNotEmpty &&
        tiles.first.images!.active == 0 &&
        tiles.first.images!.queued == 0) {
      break;
    }
  }
  await tester.pump();
}

List<PhotoTile> visibleTiles(WidgetTester tester) => tester
    .widgetList<PhotoTile>(find.byType(PhotoTile))
    .where(
      (w) => tester
          .getRect(find.byWidget(w))
          .overlaps(const Rect.fromLTWH(0, 0, 400, 800)),
    )
    .toList();

Future<void> checkFrame(WidgetTester tester, List<PhotoTile> tiles) async {
  // Capture the exact frame before any asynchronous decoding can advance it.
  final captured = <(Photo, ui.Image?)>[];
  for (final tile in tiles) {
    final raw = find.descendant(
      of: find.byWidget(tile),
      matching: find.byType(RawImage),
    );
    captured.add((
      tile.photo,
      raw.evaluate().isEmpty
          ? null
          : tester.renderObject<RenderImage>(raw.first).image?.clone(),
    ));
  }
  final missing = captured
      .where((e) => e.$2 == null)
      .map((e) => e.$1.key)
      .toList();
  try {
    expect(
      missing,
      isEmpty,
      reason: 'FIRST FRAME must contain the correct recently viewed image',
    );
    await tester.runAsync(() async {
      for (final entry in captured) {
        final bytes = (await entry.$2!.toByteData())!.buffer.asUint8List();
        final rgb = (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
        expect(
          rgb,
          entry.$1.id * 997,
          reason: 'wrong media pixels for ${entry.$1.key}',
        );
      }
    });
  } finally {
    for (final entry in captured) {
      entry.$2?.dispose();
    }
  }
}

void main() {
  for (final dpr in [1.0, 3.0]) {
    for (final density in GridDensity.values) {
      testWidgets('recent first frame ${density.name} DPR$dpr', (tester) async {
        tester.view.physicalSize = Size(400 * dpr, 800 * dpr);
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final cache = PaintingBinding.instance.imageCache;
        final oldItems = cache.maximumSize, oldBytes = cache.maximumSizeBytes;
        cache.clear();
        cache.clearLiveImages();
        cache.maximumSize = 120;
        cache.maximumSizeBytes = 48 * 1024 * 1024;
        addTearDown(() {
          cache.clear();
          cache.clearLiveImages();
          cache.maximumSize = oldItems;
          cache.maximumSizeBytes = oldBytes;
        });
        final source = await identityMedia(tester);
        final browser = PhotoBrowser(source);
        await browser.refresh();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PhotoGrid(browser: browser, density: density),
            ),
          ),
        );
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        await decodePending(tester);
        scroll.position.jumpTo(1600);
        await decodePending(tester);
        await checkFrame(tester, visibleTiles(tester));
        final initial = visibleTiles(tester).map((t) => t.photo.id).toSet();
        final before = Map.of(source.reads);
        final seen = <String>{...visibleTiles(tester).map((t) => t.photo.key)};
        for (var round = 0; round < 20; round++) {
          for (final offset in [2000.0, 2400.0]) {
            scroll.position.jumpTo(offset);
            await decodePending(tester);
            seen.addAll(visibleTiles(tester).map((t) => t.photo.key));
          }
          expect(seen.length, lessThanOrEqualTo(192));
          scroll.position.jumpTo(1600);
          await tester.pump();
          await checkFrame(tester, visibleTiles(tester));
        }
        for (final read in source.reads.entries.where(
          (e) => initial.contains(e.key.$1) && e.key.$2 == 128,
        )) {
          expect(
            read.value,
            before[read.key],
            reason: 'recent preview must not reread',
          );
        }
        expect(cache.currentSize, lessThanOrEqualTo(120));
        expect(cache.currentSizeBytes, lessThanOrEqualTo(48 * 1024 * 1024));
        await tester.pumpWidget(const SizedBox());
        browser.dispose();
      });
    }
  }
}
