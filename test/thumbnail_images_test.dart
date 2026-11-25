import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:phototree/ui/photo_grid.dart';
import 'package:phototree/ui/library_shell.dart';
import 'package:phototree/organization/organization.dart';

import 'organization_test.dart' show MemoryOrganization;

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/ui/thumbnail_images.dart';

import 'thumbnail_continuity_test.dart'
    show identityMedia, IdentityMedia, checkFrame;

Future<void> finishImages(
  WidgetTester tester,
  ThumbnailImages images, {
  VoidCallback? scrolling,
}) async {
  for (var i = 0; i < 1000; i++) {
    scrolling?.call();
    await tester.pump(const Duration(milliseconds: 5));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await tester.pump();
    if (images.active == 0 && images.queued == 0) return;
  }
  fail('image work did not finish');
}

void main() {
  setUp(() {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    cache.maximumSize = 120;
    cache.maximumSizeBytes = 48 * 1024 * 1024;
  });
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  testWidgets('album cover under app scope loads outside the grid window', (
    tester,
  ) async {
    final source = await identityMedia(tester, count: 3);
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final images = ThumbnailImages(browser);
    images.updateWindow(Object(), [source.items.first], [], 256);
    final cover = source.items.last;
    await tester.pumpWidget(
      MaterialApp(
        home: ThumbnailScope(
          images: images,
          child: Center(
            child: SizedBox(
              width: 32,
              height: 32,
              child: PhotoTile(browser: browser, photo: cover, size: 32),
            ),
          ),
        ),
      ),
    );
    await finishImages(tester, images);
    await tester.pump();
    final raw = find.byType(RawImage);
    expect(
      raw,
      findsOneWidget,
      reason: 'a sidebar cover has its own demand, independently of grid visibility',
    );
    expect(tester.widget<RawImage>(raw).image, isNotNull);
    expect(source.reads.keys.any((k) => k.$1 == cover.id), isTrue);
    expect(
      images.recentCount,
      1,
      reason: 'cover does not pollute grid recency',
    );
    await tester.pumpWidget(const SizedBox());
    images.dispose();
    browser.dispose();
    await tester.pump();
  });

  testWidgets('real sidebar composition shows covers not visible in the grid', (
    tester,
  ) async {
    final source = await identityMedia(tester, count: 80);
    source.items = source.items
        .map(
          (p) => Photo(
            id: p.id,
            directory: 'Pictures/Album${p.id ~/ 30}/',
            addedSeconds: 1000,
            width: 512,
            height: 384,
            kind: p.kind,
            durationMs: p.durationMs,
          ),
        )
        .toList();
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final org = Organization(MemoryOrganization(), browser);
    await org.load();
    final images = ThumbnailImages(browser);
    await tester.pumpWidget(
      MaterialApp(
        home: ThumbnailScope(
          images: images,
          child: LibraryShell(organization: org, browser: browser),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('album-panel-toggle')));
    await tester.pumpAndSettle();
    await finishImages(tester, images);
    await tester.pump();
    final covers = tester
        .widgetList<PhotoTile>(find.byType(PhotoTile))
        .where((tile) => tile.images == null)
        .toList();
    expect(covers.length, 3);
    await checkFrame(tester, covers);
    await tester.pumpWidget(const SizedBox());
    images.dispose();
    org.dispose();
    browser.dispose();
    await tester.pump();
  });

  testWidgets(
    'cover sharing survives one owner leaving and gates cached pixels during refresh',
    (tester) async {
      final source = await identityMedia(tester, count: 1);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser),
          first = Object(),
          second = Object();
      final photo = source.items.single;
      images.attachCover(first, photo, 96);
      images.attachCover(second, photo, 96);
      images.detachCover(first);
      await finishImages(tester, images);
      final shown = images.acquire(photo, 96, coverOwner: second)!;
      expect(source.reads[(photo.id, 96)], 1);
      expect(images.previewEntries, 0);
      shown.dispose();
      final gate = Completer<PhotoAccess>();
      source.permissionQuery = () => gate.future;
      final refresh = browser.refresh();
      expect(images.acquire(photo, 96, coverOwner: second), isNull);
      gate.complete(PhotoAccess.full);
      await refresh;
      final restored = images.acquire(photo, 96, coverOwner: second)!;
      restored.dispose();
      expect(source.reads[(photo.id, 96)], 1);
      browser.suspend();
      expect(images.acquire(photo, 96, coverOwner: second), isNull);
      images.detachCover(second);
      images.dispose();
      browser.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'cached sidebar cover progresses while four grid reads remain pending',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await identityMedia(tester, count: 5);
      final source = _SlowGrid(fixture);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final cover = source.items.last;
      await browser.thumbnail(cover, 32, browser.generation);
      final images = ThumbnailImages(browser);
      images.updateWindow(
        Object(),
        source.items.take(4).toList(),
        [],
        256,
        moving: true,
      );
      await tester.pump();
      expect(browser.activeImages, 4);
      await tester.pumpWidget(
        MaterialApp(
          home: ThumbnailScope(
            images: images,
            child: Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: PhotoTile(browser: browser, photo: cover, size: 32),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        images.scrollActivity();
        await tester.pump(const Duration(milliseconds: 5));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
      }
      await tester.pump();
      final drawable = find.byType(RawImage).evaluate().isNotEmpty;
      if (drawable) {
        await checkFrame(
          tester,
          tester.widgetList<PhotoTile>(find.byType(PhotoTile)).toList(),
        );
      }
      expect(
        browser.activeImages,
        4,
        reason: 'no fake cancellation of grid I/O',
      );
      expect(
        source.reads[(cover.id, 32)],
        1,
        reason: 'cached cover needs no source read',
      );
      source.gate.complete();
      await finishImages(tester, images);
      await tester.pumpWidget(const SizedBox());
      images.dispose();
      browser.dispose();
      await tester.pump();
      expect(
        drawable,
        isTrue,
        reason: 'cover bytes must not wait behind unrelated grid reads',
      );
    },
  );

  testWidgets(
    'native reads overlap bounded decoded work without raising source concurrency',
    (tester) async {
      final source = await identityMedia(tester, count: 8);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser);
      images.updateWindow(Object(), source.items, [], 256, moving: true);
      await tester.pump();
      final readsBeforePixels = source.reads.length;
      expect(images.decodeCount, 0);
      expect(browser.maxActive, lessThanOrEqualTo(4));
      await finishImages(tester, images, scrolling: images.scrollActivity);
      images.dispose();
      browser.dispose();
      await tester.pump();
      expect(
        readsBeforePixels,
        8,
        reason: 'four completed reads must not keep native capacity idle during pixel decoding',
      );
    },
  );

  testWidgets(
    'forward row keeps the expanded one-screen prefetch while its next read waits',
    (tester) async {
      final source = _AheadGate(await identityMedia(tester, count: 12));
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser), owner = Object();
      images.updateWindow(
        owner,
        [source.items.first],
        source.items.sublist(1, 10),
        256,
        moving: true,
        initialPrefetch: 2,
      );
      for (var i = 0; i < 100 && !source.started.contains(4); i++) {
        images.scrollActivity();
        await tester.pump(const Duration(milliseconds: 5));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
      }
      expect(source.started.contains(4), isTrue);
      expect(images.queued, greaterThanOrEqualTo(6));
      images.updateWindow(
        owner,
        [source.items[1]],
        source.items.sublist(2, 11),
        256,
        moving: true,
        initialPrefetch: 2,
      );
      final kept = images.queued;
      images.updateWindow(
        owner,
        [source.items[1]],
        [source.items.first],
        256,
        moving: true,
        initialPrefetch: 2,
        direction: -1,
      );
      expect(
        images.queued,
        0,
        reason: 'reversal still revokes unstarted old-direction work',
      );
      expect(
        browser.activeImages,
        1,
        reason: 'the old native read remains occupied until it really finishes',
      );
      source.gate.complete();
      await finishImages(tester, images, scrolling: images.scrollActivity);
      expect(source.started.where((id) => id >= 5), isEmpty);
      images.dispose();
      browser.dispose();
      await tester.pump();
      expect(
        kept,
        greaterThanOrEqualTo(6),
        reason: 'forward scrolling must not shrink an already expanded ahead window back to two rows',
      );
    },
  );

  for (final transition in [
    'reverse',
    'stop',
    'settle',
    'missing',
    'cover',
    'viewer',
  ]) {
    testWidgets(
      'conditional second prefetch preserves real occupancy on $transition',
      (tester) async {
        final source = _ContinuousGate(await identityMedia(tester, count: 14));
        final browser = PhotoBrowser(source);
        await browser.refresh();
        final images = ThumbnailImages(browser),
            owner = Object(),
            cover = Object();
        images.updateWindow(
          owner,
          [source.items.first],
          source.items.sublist(1, 10),
          256,
          moving: true,
          initialPrefetch: 2,
        );
        for (var i = 0; i < 100 && !source.started.contains(4); i++) {
          images.scrollActivity();
          await tester.pump(const Duration(milliseconds: 5));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
        }
        expect(source.started.contains(4), isTrue);
        expect(
          browser.activeImages,
          1,
          reason: 'a new direction starts with one read',
        );
        images.updateWindow(
          owner,
          [source.items[1]],
          source.items.sublist(2, 11),
          256,
          moving: true,
          initialPrefetch: 2,
        );
        await tester.pump();
        final admitted = browser.activeImages;
        final viewer = <Future<Uint8List>>[];
        switch (transition) {
          case 'reverse':
            images.updateWindow(
              owner,
              [source.items[1]],
              [source.items.first],
              256,
              moving: true,
              initialPrefetch: 2,
              direction: -1,
            );
          case 'stop':
            images.scrollStopped();
          case 'settle':
            await tester.pump(const Duration(milliseconds: 150));
          case 'missing':
            images.updateWindow(
              owner,
              [source.items[1], source.items[11]],
              source.items.sublist(2, 11),
              256,
              moving: true,
              initialPrefetch: 2,
            );
          case 'cover':
            images.attachCover(cover, source.items[11], 96);
          case 'viewer':
            for (final photo in source.items.skip(11)) {
              viewer.add(browser.display(photo, 1024, browser.generation));
            }
        }
        await tester.pump();
        final held = browser.activeImages;
        source.gates[4]!.complete();
        await tester.pump();
        final replenished = source.started.contains(6);
        final afterOne = browser.activeImages;
        for (final gate in source.gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        await finishImages(tester, images);
        await Future.wait(viewer);
        images.detachCover(cover);
        images.dispose();
        browser.dispose();
        await tester.pump();
        expect(
          admitted,
          2,
          reason: 'warmed continuous movement may use the approved second lane',
        );
        final demand = transition == 'viewer'
            ? 2
            : transition == 'missing' || transition == 'cover'
            ? 1
            : 0;
        expect(
          held,
          2 + demand,
          reason: 'both original reads remain occupied until source completion',
        );
        expect(
          afterOne,
          1 + demand,
          reason: 'one real completion releases only its own slot',
        );
        expect(
          replenished,
          isFalse,
          reason: 'withdrawn second-lane permission cannot start another ahead read',
        );
        expect(browser.maxActiveSpeculative, 2);
        expect(browser.maxActive, lessThanOrEqualTo(4));
        expect(browser.maxActiveDisplay, lessThanOrEqualTo(2));
        expect(images.maxActive, lessThanOrEqualTo(8));
        expect(images.maxDecoding, lessThanOrEqualTo(4));
      },
    );
  }

  testWidgets(
    'smaller grid target keeps sufficient clear pixels without another read or decode',
    (tester) async {
      final source = await identityMedia(tester, count: 4);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser), owner = Object();
      images.updateWindow(owner, source.items, [], 512);
      await finishImages(tester, images);
      await tester.pump(const Duration(milliseconds: 150));
      await finishImages(tester, images);
      final reads = Map.of(source.reads), decodes = images.decodeCount;
      images.updateWindow(owner, source.items, [], 256);
      for (final p in source.items) {
        final frame = images.acquire(p, 256)!;
        expect(frame.quality, ThumbnailQuality.detail);
        expect(frame.image.width, 512);
        frame.dispose();
      }
      await finishImages(tester, images);
      final afterReads = Map.of(source.reads),
          afterDecodes = images.decodeCount;
      images.dispose();
      browser.dispose();
      await tester.pump();
      expect(
        afterReads,
        reads,
        reason: 'the already displayed 512px image meets a 256px grid target',
      );
      expect(afterDecodes, decodes);
    },
  );

  testWidgets(
    'simultaneous preview completions publish before scheduling more work',
    (tester) async {
      final source = await identityMedia(tester, count: 4);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser);
      images.updateWindow(Object(), source.items, [], 256, moving: true);
      await finishImages(tester, images, scrolling: images.scrollActivity);
      expect(
        images.decodeCount,
        4,
        reason:
            'one decode per uncached preview, no completion-to-publication gap',
      );
      expect(source.reads.values.every((n) => n == 1), isTrue);
      images.dispose();
      browser.dispose();
      await tester.pump();
    },
  );

  testWidgets('queued obsolete bytes do not enter decoding after reversal', (
    tester,
  ) async {
    final source = await identityMedia(tester, count: 16);
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final images = ThumbnailImages(browser), owner = Object();
    images.updateWindow(
      owner,
      source.items.take(8).toList(),
      [],
      256,
      moving: true,
    );
    await tester.pump();
    expect(source.reads.length, 8);
    expect(
      browser.activeImages,
      0,
      reason: 'native reads have really finished',
    );
    expect(images.active, 8, reason: 'decoded results are still outstanding');
    expect(images.decodeCount, 0);
    final alreadyDecoding = images.maxDecoding;
    expect(alreadyDecoding, 4);
    images.updateWindow(
      owner,
      source.items.skip(8).toList(),
      [],
      256,
      moving: true,
    );
    await finishImages(tester, images, scrolling: images.scrollActivity);
    expect(
      images.decodeCount,
      lessThanOrEqualTo(8 + alreadyDecoding),
      reason:
          'already-started codecs may finish; queued old pixels must not start',
    );
    for (final photo in source.items.skip(8)) {
      final frame = images.acquire(photo, 256)!;
      frame.dispose();
    }
    images.dispose();
    browser.dispose();
    await tester.pump();
  });

  testWidgets(
    'completed native prefetch releases its read quota before pixel decoding',
    (tester) async {
      final source = await identityMedia(tester, count: 4);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser);
      images.updateWindow(
        Object(),
        [source.items.first],
        source.items.skip(1).toList(),
        256,
        moving: true,
        initialPrefetch: 3,
      );
      await tester.pump();
      expect(images.decodeCount, 0);
      expect(
        browser.activeImages,
        0,
        reason: 'the immediate native futures have genuinely completed',
      );
      expect(
        source.reads.length,
        4,
        reason: 'a completed speculative read must not hold the next native read hostage to pixel delivery',
      );
      expect(images.active, lessThanOrEqualTo(4));
      expect(browser.maxActiveSpeculative, 1);
      await finishImages(tester, images, scrolling: images.scrollActivity);
      expect(images.maxActive, lessThanOrEqualTo(8));
      expect(images.maxReading, lessThanOrEqualTo(4));
      images.dispose();
      browser.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'two-row prefetch advances while scrolling without another row change',
    (tester) async {
      final source = await identityMedia(tester, count: 9);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser);
      images.updateWindow(
        Object(),
        [source.items.first],
        source.items.skip(1).toList(),
        256,
        moving: true,
        initialPrefetch: 2,
      );
      await finishImages(tester, images, scrolling: images.scrollActivity);
      expect(
        source.reads[(source.items.last.id, 128)],
        1,
        reason: 'finishing the initial rows must fill the already authorized ahead window during motion',
      );
      expect(source.reads.keys.every((k) => k.$2 == 128), isTrue);
      images.dispose();
      browser.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'detail retry after resizing preserves the existing clear image',
    (tester) async {
      final fixture = await identityMedia(tester, count: 1);
      final source = _ResizeFailure(fixture)..items = fixture.items;
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser),
          owner = Object(),
          photo = source.items.single;
      images.updateWindow(owner, [photo], [], 256);
      await finishImages(tester, images);
      await tester.pump(const Duration(milliseconds: 150));
      await finishImages(tester, images);
      final clear = images.acquire(photo, 256)!;
      expect(clear.quality, ThumbnailQuality.detail);
      images.updateWindow(owner, [photo], [], 512);
      await finishImages(tester, images);
      expect(images.failed(photo), isTrue);
      images.retry(photo);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 5));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        final frame = images.acquire(photo, 512)!;
        expect(
          frame.quality,
          ThumbnailQuality.detail,
          reason: 'retry cannot downgrade the retained clear frame',
        );
        frame.dispose();
      }
      source.release.complete();
      await finishImages(tester, images);
      clear.dispose();
      images.dispose();
      browser.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'real decode failure stays retryable without an automatic retry loop',
    (tester) async {
      final fixture = await identityMedia(tester, count: 1);
      final source = _FailOnce(fixture)..items = fixture.items;
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser),
          owner = Object(),
          photo = source.items.single;
      images.updateWindow(owner, [photo], [], 256, moving: true);
      await finishImages(tester, images);
      expect(images.failed(photo), isTrue);
      expect(source.calls, 1);
      images.updateWindow(owner, [photo], [], 256, moving: true);
      await tester.pump();
      expect(source.calls, 1);
      images.retry(photo);
      await finishImages(tester, images);
      expect(images.failed(photo), isFalse);
      expect(source.calls, 2);
      final frame = images.acquire(photo, 256)!;
      expect(frame.quality, ThumbnailQuality.preview);
      frame.dispose();
      images.dispose();
      browser.dispose();
      await tester.pump();
      expect(images.previewBytes, 0);
    },
  );

  testWidgets(
    'decoded detail hit precedes bytes, previews and decoding; key isolates identity',
    (tester) async {
      final source = await identityMedia(tester, count: 150);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser), owner = Object();
      final photo = source.items.first;
      images.updateWindow(owner, [photo], [], 256);
      await finishImages(tester, images);
      await tester.pump(const Duration(milliseconds: 150));
      await finishImages(tester, images);
      final first = images.acquire(photo, 256)!;
      expect(first.quality, ThumbnailQuality.detail);
      images.detachWindow(owner);
      // Evict bytes by filling the production 120-entry cache with other media.
      for (final other in source.items.skip(1)) {
        await browser.thumbnail(other, 128, browser.generation);
      }
      expect(browser.thumbnailCacheEntries, 120);
      // Discard the preview, leaving only Flutter's decoded detail cache.
      images.didHaveMemoryPressure();
      first.dispose();
      await tester.pump();
      expect(images.previewEntries, 0);
      final reads = Map.of(source.reads), decodes = images.decodeCount;
      images.updateWindow(owner, [photo], [], 256);
      final returned = images.acquire(photo, 256)!;
      expect(returned.quality, ThumbnailQuality.detail);
      expect(source.reads, reads);
      expect(images.decodeCount, decodes);
      final k = images.key(photo, 256, ThumbnailQuality.detail);
      expect(k, isNot(images.key(photo, 128, ThumbnailQuality.detail)));
      expect(k, isNot(images.key(photo, 256, ThumbnailQuality.preview)));
      expect(
        k,
        isNot(
          ThumbnailKey(
            PhotoBrowser(source),
            k.generation,
            photo,
            256,
            ThumbnailQuality.detail,
          ),
        ),
      );
      expect(
        k,
        isNot(
          ThumbnailKey(
            browser,
            k.generation + 1,
            photo,
            256,
            ThumbnailQuality.detail,
          ),
        ),
      );
      expect(
        k,
        isNot(
          images.key(
            Photo(id: photo.id, directory: 'changed/'),
            256,
            ThumbnailQuality.detail,
          ),
        ),
      );
      returned.dispose();
      images.dispose();
      browser.dispose();
      await tester.pump();
      expect(images.previewEntries, 0);
      expect(images.previewBytes, 0);
    },
  );

  testWidgets(
    'checking, background, replaced identity and late decode cannot expose cached pixels',
    (tester) async {
      final source = await identityMedia(tester, count: 3);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser), owner = Object();
      final photo = source.items.first;
      images.updateWindow(owner, [photo], [], 256);
      await finishImages(tester, images);
      final shown = images.acquire(photo, 256)!;
      shown.dispose();
      await tester.pump();
      final gate = Completer<PhotoAccess>();
      source.permissionQuery = () => gate.future;
      final refresh = browser.refresh();
      expect(browser.cachedThumbnail(photo, 128, browser.generation), isNull);
      expect(images.acquire(photo, 256), isNull);
      gate.complete(PhotoAccess.full);
      await refresh;
      final restored = images.acquire(photo, 256);
      expect(restored, isNotNull);
      restored?.dispose();
      final frame = images.acquire(photo, 256)!;
      frame.dispose();
      source.permissionQuery = null;
      browser.suspend();
      expect(images.acquire(photo, 256), isNull);
      await tester.pump();
      source.items = [
        Photo(id: photo.id, directory: 'changed/', width: 512, height: 384),
      ];
      await browser.refresh();
      expect(browser.canDisplayImage(photo, browser.imageGeneration), isFalse);
      images.updateWindow(owner, source.items, [], 256);
      browser.suspend();
      await finishImages(tester, images);
      expect(images.previewEntries, 0);
      expect(images.acquire(source.items.first, 256), isNull);
      images.dispose();
      browser.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'preview retention counts retired handles and stays bounded across 20 windows',
    (tester) async {
      final source = await identityMedia(tester, count: 600);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser), owner = Object();
      ThumbnailFrame? held;
      for (var round = 0; round < 20; round++) {
        final start = (round * 31) % 500;
        images.updateWindow(
          owner,
          source.items.sublist(start, start + 40),
          source.items.sublist(start + 40, start + 80),
          256,
          moving: true,
        );
        await finishImages(
          tester,
          images,
          scrolling: () => images.scrollActivity(),
        );
        expect(images.previewEntries, lessThanOrEqualTo(256));
        expect(images.previewBytes, lessThanOrEqualTo(16 * 1024 * 1024));
        expect(images.speculativeEntries, lessThanOrEqualTo(64));
        expect(images.recentCount, lessThanOrEqualTo(192));
        expect(browser.thumbnailCacheEntries, lessThanOrEqualTo(120));
        expect(browser.thumbnailCacheBytes, lessThanOrEqualTo(8 * 1024 * 1024));
        held?.dispose();
        held = images.acquire(source.items[start], 256);
        expect(held, isNotNull);
        images.detachWindow(owner);
      }
      images.dispose();
      expect(
        images.previewEntries,
        greaterThanOrEqualTo(1),
        reason: 'tile handle still counts after Map removal',
      );
      held!.dispose();
      await tester.pump();
      expect(images.previewEntries, 0);
      expect(images.previewBytes, 0);
      expect(images.active, 0);
      expect(images.queued, 0);
      expect(images.maxActive, lessThanOrEqualTo(8));
      expect(images.maxReading, lessThanOrEqualTo(4));
      expect(images.maxDecoding, lessThanOrEqualTo(4));
      expect(browser.maxActive, lessThanOrEqualTo(4));
      expect(browser.maxActiveSpeculative, lessThanOrEqualTo(1));
      expect(browser.maxActiveDetail, lessThanOrEqualTo(2));
      browser.dispose();
    },
  );

  testWidgets(
    '150ms detail eligibility keeps preview visible and does not downgrade on restart',
    (tester) async {
      final fixture = await identityMedia(tester, count: 1);
      final source = _DetailGate(fixture)..items = fixture.items;
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final images = ThumbnailImages(browser),
          owner = Object(),
          photo = source.items.single;
      images.updateWindow(owner, [photo], [], 256, moving: true);
      await finishImages(tester, images);
      expect(source.details, 0);
      final preview = images.acquire(photo, 256)!;
      expect(preview.quality, ThumbnailQuality.preview);
      await tester.pump(const Duration(milliseconds: 150));
      expect(source.details, 1);
      final waiting = images.acquire(photo, 256)!;
      expect(waiting.image.isCloneOf(preview.image), isTrue);
      source.gate.complete();
      await finishImages(tester, images);
      final detail = images.acquire(photo, 256)!;
      expect(detail.quality, ThumbnailQuality.detail);
      expect(detail.image.width, 256);
      images.updateWindow(owner, [photo], [], 256, moving: true);
      final restarted = images.acquire(photo, 256)!;
      expect(restarted.image.isCloneOf(detail.image), isTrue);
      for (final frame in [preview, waiting, detail, restarted]) {
        frame.dispose();
      }
      images.dispose();
      browser.dispose();
      await tester.pump();
    },
  );
}

class _DetailGate extends IdentityMedia {
  _DetailGate(this.fixture);
  final IdentityMedia fixture;
  final gate = Completer<void>();
  int details = 0;
  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) async {
    if (pixels > 128) {
      details++;
      await gate.future;
    }
    return fixture.thumbnail(photo, pixels);
  }
}

class _FailOnce extends IdentityMedia {
  _FailOnce(this.fixture);
  final IdentityMedia fixture;
  int calls = 0;
  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) async =>
      ++calls == 1 ? Uint8List(3) : fixture.thumbnail(photo, pixels);
}

class _ResizeFailure extends IdentityMedia {
  _ResizeFailure(this.fixture);
  final IdentityMedia fixture;
  final release = Completer<void>();
  int large = 0;
  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) async {
    if (pixels == 512) {
      if (++large == 1) throw const MediaFailure(MediaFailureKind.unavailable);
      await release.future;
    }
    return fixture.thumbnail(photo, pixels);
  }
}

class _SlowGrid extends IdentityMedia {
  _SlowGrid(IdentityMedia fixture) {
    items = fixture.items;
    images.addAll(fixture.images);
  }
  final gate = Completer<void>();
  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) async {
    if (photo.id <= 4) await gate.future;
    return super.thumbnail(photo, pixels);
  }
}

class _AheadGate extends IdentityMedia {
  _AheadGate(IdentityMedia fixture) {
    items = fixture.items;
    images.addAll(fixture.images);
  }
  final gate = Completer<void>();
  final started = <int>{};
  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) async {
    started.add(photo.id);
    if (photo.id >= 4) await gate.future;
    return super.thumbnail(photo, pixels);
  }
}

class _ContinuousGate extends IdentityMedia {
  _ContinuousGate(IdentityMedia fixture) {
    items = fixture.items;
    images.addAll(fixture.images);
  }
  final started = <int>{};
  final gates = {
    for (final id in [4, 5, 12, 13]) id: Completer<void>(),
  };
  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) async {
    started.add(photo.id);
    await gates[photo.id]?.future;
    return super.thumbnail(photo, pixels);
  }

  @override
  Future<Uint8List> display(Photo photo, int pixels) async {
    await gates[photo.id]?.future;
    return images[photo.id]!;
  }
}
