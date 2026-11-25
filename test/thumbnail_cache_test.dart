import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';

import 'media_browser_test.dart' show FakeMedia, photo;

class _QueuedMedia extends FakeMedia {
  final started = <int>[];
  final gates = <Completer<Uint8List>>[];
  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) {
    started.add(photo.id);
    final gate = Completer<Uint8List>();
    gates.add(gate);
    return gate.future;
  }
}

void main() {
  test(
    'conditional second native read rechecks permission after queued wait',
    () async {
      final source = _QueuedMedia()
        ..items = List.generate(7, (i) => photo(i + 1));
      final browser = PhotoBrowser(source);
      await browser.refresh();
      var extra = true, needed = true;
      final futures = <Future<void>>[];
      for (var id = 1; id <= 6; id++) {
        futures.add(
          browser
              .thumbnail(
                photo(id),
                128,
                browser.generation,
                work: () => id <= 4
                    ? ThumbnailWork.visiblePreview
                    : ThumbnailWork.speculative,
                isNeeded: () => id <= 4 || needed,
                allowExtraSpeculative: () => extra,
              )
              .then<void>((_) {}, onError: (Object _) {}),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(source.started, [1, 2, 3, 4]);
      extra = false;
      source.gates[0].complete(Uint8List(8));
      source.gates[1].complete(Uint8List(8));
      await Future<void>.delayed(Duration.zero);
      expect(source.started, [
        1,
        2,
        3,
        4,
        5,
      ], reason: 'a queued request cannot retain an old extra-lane grant');
      extra = true;
      browser.reprioritizeImages();
      await Future<void>.delayed(Duration.zero);
      expect(source.started, [1, 2, 3, 4, 5, 6]);
      expect(browser.activeImages, 4);
      needed = false;
      browser.reprioritizeImages();
      futures.add(
        browser
            .thumbnail(
              photo(7),
              128,
              browser.generation,
              work: () => ThumbnailWork.visiblePreview,
            )
            .then<void>((_) {}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(browser.activeImages, 4);
      expect(
        source.started.last,
        6,
        reason:
            'withdrawing interest does not free either actual speculative read',
      );
      for (var i = 0; i < 3; i++) {
        for (final gate in source.gates.toList()) {
          if (!gate.isCompleted) gate.complete(Uint8List(8));
        }
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(futures);
      expect(source.started.last, 7);
      expect(browser.maxActiveSpeculative, 2);
      expect(browser.maxActive, 4);
      expect(browser.activeImages, 0);
      browser.dispose();
    },
  );

  test(
    'R2 reversed speculative queue releases no active native slot early',
    () async {
      final source = _QueuedMedia()
        ..items = List.generate(12, (i) => photo(i + 1));
      final browser = PhotoBrowser(source);
      await browser.refresh();
      var forward = true;
      final futures = <Future<void>>[];
      for (var id = 1; id <= 8; id++) {
        futures.add(
          browser
              .thumbnail(
                photo(id),
                128,
                browser.generation,
                isNeeded: () => forward,
                work: () => ThumbnailWork.speculative,
              )
              .then<void>((_) {}, onError: (Object _) {}),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(source.started, [1]);
      for (var id = 9; id <= 11; id++) {
        futures.add(
          browser
              .thumbnail(
                photo(id),
                256,
                browser.generation,
                work: () => ThumbnailWork.visibleDetail,
              )
              .then<void>((_) {}, onError: (Object _) {}),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(source.started, [1, 9, 10]);
      forward = false;
      browser.reprioritizeImages();
      futures.add(
        browser
            .thumbnail(
              photo(12),
              128,
              browser.generation,
              work: () => ThumbnailWork.visiblePreview,
            )
            .then<void>((_) {}, onError: (Object _) {}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(source.started, [1, 9, 10, 12]);
      expect(browser.activeImages, 4);
      expect(
        browser.queuedImages,
        1,
        reason: 'only the third visible detail remains queued',
      );
      source.gates[0].complete(Uint8List(8));
      await Future<void>.delayed(Duration.zero);
      expect(source.started, [
        1,
        9,
        10,
        12,
      ], reason: 'two details already own their slots');
      source.gates[1].complete(Uint8List(8));
      await Future<void>.delayed(Duration.zero);
      expect(source.started.last, 11);
      for (final gate in source.gates.skip(2)) {
        gate.complete(Uint8List(8));
      }
      await Future.wait(futures);
      expect(browser.maxActive, 4);
      expect(browser.maxActiveDetail, 2);
      expect(browser.maxActiveSpeculative, 1);
      expect(browser.queuedImages, 0);
      browser.dispose();
    },
  );

  test(
    'shared queued reads cancel per caller and skip work with no consumers',
    () async {
      final source = _QueuedMedia()..items = [photo(1), photo(2)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      var needed = true;
      final abandoned = browser
          .thumbnail(photo(1), 128, browser.generation, isNeeded: () => needed)
          .then<Object>((v) => v, onError: (Object e) => e);
      final abandonedToo = browser
          .thumbnail(photo(1), 128, browser.generation, isNeeded: () => needed)
          .then<Object>((v) => v, onError: (Object e) => e);
      needed = false;
      final wanted = browser.thumbnail(photo(2), 128, browser.generation);
      await Future<void>.delayed(Duration.zero);
      expect(source.started, [2]);
      source.gates.single.complete(Uint8List(8));
      await wanted;
      for (final result in await Future.wait([abandoned, abandonedToo])) {
        expect(
          result,
          isA<MediaFailure>().having(
            (e) => e.kind,
            'kind',
            MediaFailureKind.cancelled,
          ),
        );
      }
      browser.dispose();
    },
  );

  test(
    'shared reads reject stale results and failures remain retryable',
    () async {
      final source = _QueuedMedia()..items = [photo(1)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final old = [
        for (var i = 0; i < 2; i++)
          browser
              .thumbnail(photo(1), 128, browser.generation)
              .then<Object>((v) => v, onError: (Object e) => e),
      ];
      await Future<void>.delayed(Duration.zero);
      browser.suspend();
      source.gates.single.complete(Uint8List(8));
      for (final result in await Future.wait(old)) {
        expect(
          result,
          isA<MediaFailure>().having(
            (e) => e.kind,
            'kind',
            MediaFailureKind.stale,
          ),
        );
      }
      expect(browser.thumbnailCacheEntries, 0);
      await browser.refresh();
      final failures = [
        for (var i = 0; i < 2; i++)
          browser
              .thumbnail(photo(1), 128, browser.generation)
              .then<Object>((v) => v, onError: (Object e) => e),
      ];
      await Future<void>.delayed(Duration.zero);
      source.gates.last.completeError(StateError('read failed'));
      for (final result in await Future.wait(failures)) {
        expect(
          result,
          isA<MediaFailure>().having(
            (e) => e.kind,
            'kind',
            MediaFailureKind.unavailable,
          ),
        );
      }
      final retry = browser.thumbnail(
        photo(1),
        128,
        browser.generation,
        reload: true,
      );
      await Future<void>.delayed(Duration.zero);
      source.gates.last.complete(Uint8List(8));
      expect(await retry, hasLength(8));
      expect(source.started, [1, 1, 1]);
      browser.dispose();
    },
  );

  test(
    'retry and different sizes do not join or overwrite each other',
    () async {
      final source = _QueuedMedia()..items = [photo(1)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final old = browser.thumbnail(photo(1), 128, browser.generation);
      await Future<void>.delayed(Duration.zero);
      final retry = browser.thumbnail(
        photo(1),
        128,
        browser.generation,
        reload: true,
      );
      final larger = browser.thumbnail(photo(1), 256, browser.generation);
      await Future<void>.delayed(Duration.zero);
      expect(source.started, [1, 1, 1]);
      source.gates[1].complete(Uint8List.fromList([2]));
      final replacement = await retry;
      source.gates[2].complete(Uint8List.fromList([3]));
      await larger;
      source.gates[0].complete(Uint8List.fromList([1]));
      await old;
      expect(
        await browser.thumbnail(photo(1), 128, browser.generation),
        same(replacement),
      );
      expect(browser.thumbnailCacheEntries, 2);
      browser.dispose();
    },
  );

  test(
    'initial visible requests take slots before neighboring prefetch',
    () async {
      final source = _QueuedMedia()
        ..items = List.generate(8, (i) => photo(i + 1));
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final requests = [
        for (var id = 1; id <= 8; id++)
          browser
              .thumbnail(
                photo(id),
                128,
                browser.generation,
                isPriority: () => id > 4,
              )
              .then<void>((_) {}, onError: (Object _) {}),
      ];
      await Future<void>.delayed(Duration.zero);
      final first = source.started.toList();
      browser.suspend();
      for (final gate in source.gates) {
        gate.complete(Uint8List(8));
      }
      await Future.wait(requests);
      browser.dispose();
      expect(first, [
        5,
        6,
        7,
        8,
      ], reason: 'build order must not reserve all slots for offscreen rows');
    },
  );

  test(
    'returning caller shares an active read after the old tile leaves',
    () async {
      final source = _QueuedMedia()..items = [photo(1)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      var originalNeeded = true;
      final original = browser.thumbnail(
        photo(1),
        128,
        browser.generation,
        isNeeded: () => originalNeeded,
      );
      final cancelled = expectLater(
        original,
        throwsA(
          isA<MediaFailure>().having(
            (error) => error.kind,
            'kind',
            MediaFailureKind.cancelled,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      originalNeeded = false;
      final returning = browser.thumbnail(photo(1), 128, browser.generation);
      await Future<void>.delayed(Duration.zero);
      final reads = source.started.length;
      for (final gate in source.gates) {
        gate.complete(Uint8List(8));
      }
      final bytes = await returning;
      await cancelled;
      expect(
        await browser.thumbnail(photo(1), 128, browser.generation),
        same(bytes),
      );
      browser.dispose();
      expect(
        reads,
        1,
        reason: 're-entering must not start a duplicate platform read',
      );
    },
  );

  test(
    'valid read finishing after scrolling away warms the next visit',
    () async {
      final source = _QueuedMedia()..items = [photo(1)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      var needed = true;
      final load = browser.thumbnail(
        photo(1),
        128,
        browser.generation,
        isNeeded: () => needed,
      );
      final cancelled = expectLater(load, throwsA(isA<MediaFailure>()));
      await Future<void>.delayed(Duration.zero);
      needed = false;
      source.gates.single.complete(Uint8List(8));
      await cancelled;
      expect(
        browser.thumbnailCacheEntries,
        1,
        reason:
            'a valid completed read should not be thrown away with its tile',
      );
      browser.dispose();
    },
  );

  test(
    'thumbnail LRU bounds both count and bytes, retry replaces the buffer',
    () async {
      final source = FakeMedia()
        ..items = List.generate(140, (i) => photo(i + 1));
      var reads = 0;
      var size = 16;
      source.image = () async {
        reads++;
        return Uint8List(size);
      };
      final browser = PhotoBrowser(source);
      await browser.refresh();
      Future<Uint8List> load(int id, {bool reload = false}) =>
          browser.thumbnail(photo(id), 128, browser.generation, reload: reload);
      for (var id = 1; id <= 120; id++) {
        await load(id);
      }
      final first = await load(1);
      expect(reads, 120);
      await load(121);
      expect(browser.thumbnailCacheEntries, 120);
      expect(await load(1), same(first));
      await load(2);
      expect(reads, 122, reason: 'least recently used entry must be evicted');
      final retried = await load(1, reload: true);
      expect(retried, isNot(same(first)));
      expect(reads, 123);
      size = 2 * 1024 * 1024;
      for (var id = 122; id <= 130; id++) {
        await load(id);
        expect(browser.thumbnailCacheBytes, lessThanOrEqualTo(8 * 1024 * 1024));
        expect(browser.thumbnailCacheEntries, lessThanOrEqualTo(120));
      }
      size = 9 * 1024 * 1024;
      await load(131);
      final before = reads;
      await load(131);
      expect(
        reads,
        before + 1,
        reason: 'oversize buffers must not be retained',
      );
      browser.dispose();
      expect(browser.thumbnailCacheBytes, 0);
    },
  );

  test(
    'warm thumbnails survive confirmed refresh but never bypass invalidation',
    () async {
      final source = FakeMedia()
        ..items = [photo(1)]
        ..image = (() async => Uint8List(8));
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final first = await browser.thumbnail(photo(1), 128, browser.generation);
      await browser.refresh();
      expect(
        await browser.thumbnail(photo(1), 128, browser.generation),
        same(first),
      );
      await expectLater(
        browser.thumbnail(
          photo(1),
          128,
          browser.generation,
          isNeeded: () => false,
        ),
        throwsA(
          isA<MediaFailure>().having(
            (e) => e.kind,
            'kind',
            MediaFailureKind.cancelled,
          ),
        ),
      );
      source.revision = source.revision! + 1;
      await browser.refresh();
      expect(browser.thumbnailCacheEntries, 0);
      expect(
        await browser.thumbnail(photo(1), 128, browser.generation),
        isNot(same(first)),
      );
      source.access = PhotoAccess.denied;
      await browser.refresh();
      expect(browser.thumbnailCacheEntries, 0);
      await expectLater(
        browser.thumbnail(photo(1), 128, browser.generation),
        throwsA(isA<MediaFailure>()),
      );
      browser.dispose();
    },
  );

  test('visible requests overtake prefetch and late invalidated data is not cached', () async {
    final source = _QueuedMedia()
      ..items = List.generate(8, (i) => photo(i + 1));
    final browser = PhotoBrowser(source);
    await browser.refresh();
    var visible = false;
    final results = <Future<void>>[];
    for (var id = 1; id <= 6; id++) {
      results.add(
        browser
            .thumbnail(
              photo(id),
              128,
              browser.generation,
              isPriority: () => id == 6 && visible,
            )
            .then<void>((_) {}, onError: (Object _) {}),
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(source.started, [1, 2, 3, 4]);
    visible = true;
    source.gates.first.complete(Uint8List(8));
    await Future<void>.delayed(Duration.zero);
    expect(source.started, [1, 2, 3, 4, 6]);
    expect(browser.maxActive, 4);
    browser.suspend();
    for (final gate in source.gates.skip(1)) {
      gate.complete(Uint8List(8));
    }
    await Future.wait(results);
    expect(browser.thumbnailCacheEntries, 0);
    browser.dispose();
  });
}
