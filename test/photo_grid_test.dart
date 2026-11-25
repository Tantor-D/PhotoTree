import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/ui/photo_grid.dart';
import 'package:phototree/ui/photo_viewer.dart';

import 'media_browser_test.dart' show FakeMedia, photo;
import 'thumbnail_continuity_test.dart' show decodePending, identityMedia;

void main() {
  testWidgets('density regrouping keeps already decoded visible thumbnails', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = _DelayedThumbnails()
      ..items = List.generate(
        160,
        (i) => photo(
          i + 1,
          taken: DateTime(
            i < 2
                ? 2047
                : i < 4
                ? 2046
                : 2030,
            1,
            1,
          ).millisecondsSinceEpoch,
        ),
      );
    final browser = PhotoBrowser(source);
    final density = ValueNotifier(GridDensity.compact);
    await browser.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<GridDensity>(
            valueListenable: density,
            builder: (_, value, _) =>
                PhotoGrid(browser: browser, density: value, scopeTitle: '所有照片'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await decodePending(tester);
    Finder tile(String key) =>
        find.byWidgetPredicate((w) => w is PhotoTile && w.photo.key == key);
    final previous = <String, State>{
      for (final item
          in tester
              .widgetList<PhotoTile>(find.byType(PhotoTile))
              .where(
                (item) => tester
                    .getRect(find.byWidget(item))
                    .overlaps(
                      tester
                          .getRect(find.byKey(const ValueKey('photo-grid')))
                          .deflate(1),
                    ),
              ))
        item.photo.key: tester.state(tile(item.photo.key)),
    };
    for (final key in previous.keys) {
      expect(
        tester
            .renderObject<RenderImage>(
              find.descendant(of: tile(key), matching: find.byType(RawImage)),
            )
            .image,
        isNotNull,
      );
    }
    source.delay = true;
    density.value = GridDensity.dense;
    await tester.pump();
    final lost = <String>[];
    final missingRaw = <String>[];
    final recreated = <String>[];
    for (final entry in previous.entries) {
      final current = tile(entry.key);
      if (current.evaluate().isEmpty) continue;
      if (!identical(tester.state(current), entry.value)) {
        recreated.add(entry.key);
      }
      final raw = find.descendant(of: current, matching: find.byType(RawImage));
      if (raw.evaluate().isEmpty) missingRaw.add(entry.key);
      if (raw.evaluate().isEmpty ||
          tester.renderObject<RenderImage>(raw).image == null) {
        lost.add(entry.key);
      }
    }
    source.release();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    browser.dispose();
    density.dispose();
    expect(
      lost,
      isEmpty,
      reason:
          'existing thumbnails blank during regroup; recreated=$recreated missingRaw=$missingRaw',
    );
    expect(browser.maxActive, lessThanOrEqualTo(4));
    expect(browser.maxPixels, lessThanOrEqualTo(512));
  });

  for (final permissionLost in [false, true]) {
    testWidgets(
      'retained resize frame clears on image invalidation: permissionLost=$permissionLost',
      (tester) async {
        final source = _DelayedThumbnails()..items = [photo(1)];
        final browser = PhotoBrowser(source);
        final density = ValueNotifier(GridDensity.compact);
        await browser.refresh();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<GridDensity>(
                valueListenable: density,
                builder: (_, value, _) => PhotoGrid(
                  browser: browser,
                  density: value,
                  scopeTitle: '所有照片',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(
          tester.renderObject<RenderImage>(find.byType(RawImage)).image,
          isNotNull,
        );
        final oldGeneration = browser.imageGeneration;
        source.delay = true;
        density.value = GridDensity.dense;
        await tester.pump();
        expect(
          tester.renderObject<RenderImage>(find.byType(RawImage)).image,
          isNotNull,
        );
        if (permissionLost) {
          source.access = PhotoAccess.denied;
        } else {
          source.revision = source.revision! + 1;
        }
        await browser.refresh();
        await tester.pump();
        expect(browser.imageGeneration, greaterThan(oldGeneration));
        expect(
          find.byType(RawImage),
          findsNothing,
          reason: 'invalidated identity must not keep the resize frame',
        );
        source.release();
        await tester.pumpAndSettle();
        if (permissionLost) expect(find.byType(PhotoTile), findsNothing);
        expect(browser.maxActive, lessThanOrEqualTo(4));
        expect(browser.maxPixels, lessThanOrEqualTo(512));
        await tester.pumpWidget(const SizedBox());
        browser.dispose();
        density.dispose();
      },
    );
  }

  for (final (turnToNext, integrated) in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    testWidgets(
      'viewer return preserves an already visible tile: next=$turnToNext integrated=$integrated',
      (tester) async {
        final (browser, _) = await _viewerBrowser(tester);
        final position = GridPosition();
        Widget page() => MaterialApp(
          home: Scaffold(
            body: PhotoGrid(
              browser: browser,
              position: position,
              scopeTitle: integrated ? '所有照片' : null,
            ),
          ),
        );
        await tester.pumpWidget(page());
        await tester.pumpAndSettle();
        final list = find.byKey(const ValueKey('photo-grid'));
        final scroll = tester.widget<ListView>(list).controller!;
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        final target = browser.photos[turnToNext ? 1 : 0].key;
        final tile = find.byWidgetPredicate(
          (w) => w is PhotoTile && w.photo.key == target,
        );
        final offset = scroll.offset;
        final y = tester.getTopLeft(tile).dy;
        await _openViewer(tester);
        if (turnToNext) {
          await tester.drag(
            find.byKey(const ValueKey('viewer-gesture')),
            const Offset(-180, 0),
          );
          await tester.pumpAndSettle();
          expect(find.text('2 / 48'), findsOneWidget);
        }
        await tester.tap(find.byTooltip('返回媒体网格'));
        await tester.pumpAndSettle();
        expect(find.byType(PhotoViewer), findsNothing);
        expect(scroll.offset, closeTo(offset, 1));
        expect(tester.getTopLeft(tile).dy, closeTo(y, 1));
        // Saved relative position must survive rebuilding the grid as well.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.pumpWidget(page());
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(tile).dy, closeTo(y, 1));
        await tester.pumpWidget(const SizedBox());
        browser.dispose();
      },
    );
  }

  testWidgets(
    'viewer can still locate an offscreen photo and reject a removed target',
    (tester) async {
      final (browser, source) = await _viewerBrowser(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PhotoGrid(browser: browser)),
        ),
      );
      await tester.pumpAndSettle();
      final target = browser.photos[40];
      final targetTile = find.byWidgetPredicate(
        (w) => w is PhotoTile && w.photo.key == target.key,
      );
      expect(targetTile, findsNothing);
      await _openViewer(tester);
      final viewer = tester.widget<PhotoViewer>(find.byType(PhotoViewer));
      final locate = viewer.locate(target.key);
      await tester.pump();
      final rect = await locate;
      expect(rect, isNotNull);
      expect(rect, tester.getRect(targetTile));
      final list = find.byKey(const ValueKey('photo-grid'));
      expect(rect!.top, greaterThanOrEqualTo(tester.getTopLeft(list).dy));
      expect(rect.bottom, lessThanOrEqualTo(tester.getBottomRight(list).dy));
      source.items = source.items.where((p) => p.key != target.key).toList();
      await browser.refresh();
      await tester.pumpAndSettle();
      final missing = viewer.locate(target.key);
      await tester.pump();
      expect(await missing, isNull);
      expect(targetTile, findsNothing);
      await tester.pumpWidget(const SizedBox());
      browser.dispose();
    },
  );

  testWidgets('a resized pending tile retries after an unchanged refresh', (
    tester,
  ) async {
    final bytes = (await identityMedia(tester, count: 1)).images[1]!;
    final source = FakeMedia()..items = [photo(1)];
    final pending = Completer<Uint8List>();
    var calls = 0;
    source.image = () async => ++calls == 2 ? pending.future : bytes;
    final browser = PhotoBrowser(source);
    await browser.refresh();
    Widget tile(double scale) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(devicePixelRatio: scale),
        child: ListenableBuilder(
          listenable: browser,
          builder: (_, _) => PhotoTile(
            browser: browser,
            photo: browser.photos.single,
            size: 64,
          ),
        ),
      ),
    );
    await tester.pumpWidget(tile(1));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 5));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    await tester.pumpWidget(tile(3));
    await tester.pump(const Duration(milliseconds: 150));
    expect(calls, 2);
    await browser.refresh();
    await tester.pumpAndSettle();
    pending.complete(bytes);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
    expect(calls, 3);
    expect(find.byTooltip('图片不可用，重试'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    browser.dispose();
  });
  testWidgets(
    'rotation, refresh deletion and recreated album preserve the photo anchor',
    (tester) async {
      final source = FakeMedia()
        ..items = List.generate(90, (i) => photo(i + 1, added: 1000));
      source.image = () async => Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jw1kAAAAASUVORK5CYII=',
        ),
      );
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final saved = GridPosition();
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget page() => MaterialApp(
        home: Scaffold(
          body: PhotoGrid(browser: browser, position: saved),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('photo-grid'));
      var scroll = tester.widget<ListView>(list).controller!;
      scroll.jumpTo(500);
      await tester.pumpAndSettle();
      final anchor = saved.anchor;
      expect(anchor, isNotNull);
      tester.view.physicalSize = const Size(800, 400);
      await tester.pumpAndSettle();
      expect(saved.anchor, anchor);
      final tiles = tester.widgetList<PhotoTile>(find.byType(PhotoTile));
      expect(tiles.any((tile) => tile.photo.key == anchor), isTrue);
      final tileFinder = find.byWidgetPredicate(
        (w) => w is PhotoTile && w.photo.key == anchor,
      );
      final beforeRefresh = tester.getTopLeft(tileFinder).dy;
      await browser.refresh();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(tileFinder).dy, closeTo(beforeRefresh, 1));
      final refreshedAnchor = saved.anchor;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(saved.anchor, refreshedAnchor);
      expect(tester.getTopLeft(tileFinder).dy, closeTo(beforeRefresh, 1));
      scroll = tester.widget<ListView>(list).controller!;
      expect(scroll.offset, greaterThan(0));
      source.items = source.items
          .where((p) => p.key != refreshedAnchor)
          .toList();
      await browser.refresh();
      await tester.pumpAndSettle();
      expect(saved.anchor, isNot(refreshedAnchor));
      source.items = [];
      await browser.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(PhotoTile), findsNothing);
      await tester.pumpWidget(const SizedBox());
      browser.dispose();
    },
  );
  testWidgets(
    'refresh keeps a visible anchor that arrives in a later metadata batch',
    (tester) async {
      final source = FakeMedia()
        ..items = List.generate(1000, (i) => photo(i + 1, added: 1000));
      source.image = () async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jw1kAAAAASUVORK5CYII=',
      );
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final saved = GridPosition();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoGrid(browser: browser, position: saved),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<ListView>(find.byKey(const ValueKey('photo-grid')))
          .controller!;
      scroll.jumpTo(800);
      await tester.pumpAndSettle();
      final key = saved.anchor;
      final anchor = find.byWidgetPredicate(
        (w) => w is PhotoTile && w.photo.key == key,
      );
      final y = tester.getTopLeft(anchor).dy;
      source.query = (after) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return source.items.where((p) => p.id > after).take(256).toList();
      };
      final existingState = tester.state(find.byType(PhotoTile).first);
      final refresh = browser.refresh();
      await tester.pump(const Duration(milliseconds: 1));
      expect(anchor, findsOneWidget);
      expect(tester.state(find.byType(PhotoTile).first), same(existingState));
      expect(tester.getTopLeft(anchor).dy, closeTo(y, 1));
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      await refresh;
      await tester.pumpAndSettle();
      expect(anchor, findsOneWidget);
      expect(tester.getTopLeft(anchor).dy, closeTo(y, 1));
      await tester.pumpWidget(const SizedBox());
      browser.dispose();
    },
  );
}

class _DelayedThumbnails extends FakeMedia {
  bool delay = false;
  final pending = <Completer<Uint8List>>[];
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) async {
    if (!delay) return bytes;
    final result = Completer<Uint8List>();
    pending.add(result);
    return result.future;
  }

  void release() {
    delay = false;
    for (final result in pending) {
      if (!result.isCompleted) result.complete(bytes);
    }
  }
}

Future<(PhotoBrowser, FakeMedia)> _viewerBrowser(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final source = FakeMedia()
    ..items = List.generate(48, (i) => photo(i + 1, added: 1000));
  source.image = () async => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  final browser = PhotoBrowser(source);
  await browser.refresh();
  return (browser, source);
}

Future<void> _openViewer(WidgetTester tester) async {
  await tester.tap(find.byType(PhotoTile).first);
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
  expect(find.byType(PhotoViewer), findsOneWidget);
  expect(find.text('1 / 48'), findsOneWidget);
}
