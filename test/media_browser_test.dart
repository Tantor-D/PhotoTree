import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/browser.dart';

class FakeMedia implements MediaSource {
  @override
  Stream<void> get changes => const Stream.empty();
  int? revision = 1;
  @override
  Future<int?> collectionRevision() async => revision;
  String? version = 'test-library';
  Future<String?> Function()? versionQuery;
  @override
  Future<String?> libraryVersion() async =>
      versionQuery == null ? version : versionQuery!();
  @override
  Future<Uint8List> display(Photo photo, int pixels) =>
      thumbnail(photo, pixels);
  @override
  Future<Uri> playbackUri(Photo photo, String libraryVersion) async =>
      Uri.parse('content://media/external_primary/video/media/${photo.id}');

  PhotoAccess access = PhotoAccess.full;
  PhotoAccess? videoAccess;
  List<Photo> items = [];
  Future<PhotoAccess> Function()? permissionQuery;
  Future<List<Photo>> Function(int)? query;
  Future<Uint8List> Function()? image;
  @override
  Future<MediaPermissions> permission({bool request = false}) async {
    final images = permissionQuery == null ? access : await permissionQuery!();
    return MediaPermissions(images: images, videos: videoAccess ?? images);
  }

  @override
  Future<void> reselect() async {}
  @override
  Future<void> openSettings() async {}
  @override
  Future<List<Photo>> page({required int afterId}) async => query != null
      ? query!(afterId)
      : items.where((p) => p.id > afterId).take(256).toList();
  @override
  Future<Uint8List> thumbnail(Photo photo, int pixels) async =>
      image != null ? image!() : Uint8List(1);
}

Photo photo(
  int id, {
  String directory = 'Pictures/A/',
  int taken = 0,
  int added = 0,
}) => Photo(id: id, directory: directory, takenMs: taken, addedSeconds: added);
void main() {
  test(
    'cold and resume publish one complete collection, never partial pages',
    () async {
      final source = FakeMedia()
        ..items = List.generate(600, (i) => photo(i + 1));
      final browser = PhotoBrowser(source);
      final visibleCounts = <int>[];
      browser.addListener(() => visibleCounts.add(browser.photos.length));
      await browser.refresh();
      expect(visibleCounts.toSet(), {0, 600});
      expect(browser.albums.single.photos.length, 600);
      visibleCounts.clear();
      browser.suspend();
      await browser.refresh();
      expect(visibleCounts.toSet(), {0, 600});
      browser.dispose();
    },
  );

  test(
    'failed final permission check never exposes accumulated cold pages',
    () async {
      final source = FakeMedia();
      source.query = (after) async {
        if (after == 0) return [photo(1)];
        source.access = PhotoAccess.denied;
        return [];
      };
      final browser = PhotoBrowser(source);
      final visibleCounts = <int>[];
      browser.addListener(() => visibleCounts.add(browser.photos.length));
      await browser.refresh();
      expect(visibleCounts.toSet(), {0});
      expect(browser.phase, BrowsePhase.failed);
      browser.dispose();
    },
  );

  test('foreground refresh retains the confirmed collection until atomic completion', () async {
    final source = FakeMedia()..items = [photo(1)];
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final confirmed = browser.photos;
    final pending = Completer<List<Photo>>();
    source.query = (after) async => after == 0 ? pending.future : [];
    final refresh = browser.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(browser.photos, same(confirmed));
    pending.complete([photo(1), photo(2)]);
    await refresh;
    expect(browser.photos.map((p) => p.id), [2, 1]);
    browser.dispose();
  });
  test('unchanged refresh preserves image identity; query failure is an update failure', () async {
    final source = FakeMedia()..items = [photo(1)];
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final images = browser.imageGeneration;
    final collection = browser.photos;
    await browser.refresh();
    expect(browser.imageGeneration, images);
    expect(browser.photos, same(collection));
    source.query = (_) async =>
        throw const MediaFailure(MediaFailureKind.query);
    await browser.refresh();
    expect(browser.phase, BrowsePhase.ready);
    expect(browser.failure, MediaFailureKind.query);
    expect(browser.photos, same(collection));
    browser.dispose();
  });
  test('permission narrowing and suspension hide retained content and reject late scans', () async {
    for (final access in [PhotoAccess.limited, PhotoAccess.denied]) {
      final source = FakeMedia()..items = [photo(1)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      source.access = access;
      final page = Completer<List<Photo>>();
      source.query = (_) => page.future;
      final work = browser.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(browser.photos, isEmpty);
      browser.suspend();
      page.complete([photo(2)]);
      await work;
      expect(browser.photos, isEmpty);
      browser.dispose();
    }
  });
  test(
    'failed update cannot retain content if permission verification is unknown',
    () async {
      final source = FakeMedia()..items = [photo(1)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      source.query = (_) async {
        source.permissionQuery = () async =>
            throw const MediaFailure(MediaFailureKind.query);
        throw const MediaFailure(MediaFailureKind.query);
      };
      await browser.refresh();
      expect(browser.phase, BrowsePhase.failed);
      expect(browser.photos, isEmpty);
      browser.dispose();
    },
  );
  test(
    'unknown revision cannot reuse images with otherwise identical metadata',
    () async {
      final source = FakeMedia()
        ..revision = null
        ..items = [photo(1)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final imageGeneration = browser.imageGeneration;
      await browser.refresh();
      expect(browser.imageGeneration, greaterThan(imageGeneration));
      browser.dispose();
    },
  );
  test(
    'late version lookup cannot overwrite a newer confirmed snapshot',
    () async {
      final source = FakeMedia()..items = [photo(1)];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      final late = Completer<String?>();
      source.versionQuery = () => late.future;
      final first = browser.refresh();
      await Future<void>.delayed(Duration.zero);
      source.versionQuery = null;
      source.version = 'new-library';
      await browser.refresh();
      late.complete('obsolete-library');
      await first;
      expect(browser.libraryVersion, 'new-library');
      expect(browser.phase, BrowsePhase.ready);
      browser.dispose();
    },
  );
  test('unknown version invalidates the snapshot even if a later failure recheck could recover it', () async {
    final source = FakeMedia()..items = [photo(1)];
    final browser = PhotoBrowser(source);
    await browser.refresh();
    source.version = null;
    source.query = (_) async {
      source.version = 'test-library';
      throw const MediaFailure(MediaFailureKind.query);
    };
    await browser.refresh();
    expect(browser.phase, BrowsePhase.failed);
    expect(browser.libraryVersion, isNull);
    expect(browser.collectionRevision, isNull);
    expect(browser.photos, isEmpty);
    browser.dispose();
  });
  test('refresh gates new image reads until identity is checked and rejects replaced library', () async {
    final source = FakeMedia()..items = [photo(1)];
    var imageCalls = 0;
    source.image = () async {
      imageCalls++;
      return Uint8List(1);
    };
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final old = browser.photos.single;
    final version = Completer<String?>();
    final page = Completer<List<Photo>>();
    source.versionQuery = () => version.future;
    source.query = (_) => page.future;
    final work = browser.refresh();
    final image = browser
        .thumbnail(old, 128, browser.generation)
        .then<Object>((v) => v, onError: (Object e) => e);
    await Future<void>.delayed(Duration.zero);
    expect(imageCalls, 0);
    version.complete('replaced-library');
    await Future<void>.delayed(Duration.zero);
    expect(browser.photos, isEmpty);
    expect(await image, isA<MediaFailure>());
    expect(imageCalls, 0);
    browser.suspend();
    page.complete([]);
    await work;
    browser.dispose();
  });
  test('effective timestamp keeps milliseconds, falls back, ties use numeric ID, unknown last', () {
    final sorted = orderedPhotos([
      photo(2),
      photo(10),
      photo(7, taken: 100001),
      photo(8, taken: 100099),
      photo(9, added: 100),
      photo(11, taken: 100099),
      photo(4, taken: -1, added: 99),
    ]);
    expect(sorted.map((p) => p.id), [11, 8, 7, 9, 4, 10, 2]);
    expect(photoDay(photo(1)), '日期未知');
    final before = DateTime(
      2026,
      9,
      30,
      23,
      59,
      59,
      999,
    ).millisecondsSinceEpoch;
    expect(photoDay(photo(1, taken: before)), '2026-09-30');
    expect(photoDay(photo(2, taken: before + 1)), '2026-10-01');
  });
  test('directory identity preserves case and hierarchy; derived covers and counts', () {
    final albums = albumsOf(
      orderedPhotos([
        photo(1, directory: 'Pictures/A/Same/'),
        photo(2, directory: 'Pictures/B/Same/'),
        photo(3, directory: 'Pictures/a/Same/'),
      ]),
    );
    expect(albums.length, 3);
    expect(albums.map((a) => a.name).toSet(), {'Same'});
    expect(albums.map((a) => a.photos.length), [1, 1, 1]);
  });
  test(
    '272 and 1000 items cross cursor batches with no loss or duplicate',
    () async {
      for (final count in [272, 1000]) {
        final source = FakeMedia()
          ..items = List.generate(count, (i) => photo(i + 1, taken: i % 13));
        final browser = PhotoBrowser(source);
        await browser.refresh();
        expect(browser.phase, BrowsePhase.ready);
        expect(browser.photos.length, count);
        expect(browser.photos.map((p) => p.key).toSet().length, count);
        expect(
          browser.photos.map((p) => p.id),
          orderedPhotos(source.items).map((p) => p.id),
        );
        browser.dispose();
      }
    },
  );
  test('overlapping refresh never publishes late query or old count', () async {
    final first = Completer<List<Photo>>();
    final source = FakeMedia()..query = (_) => first.future;
    final browser = PhotoBrowser(source);
    final pending = browser.refresh();
    await Future<void>.delayed(Duration.zero);
    source.query = (after) async => after == 0 ? [photo(2)] : [];
    await browser.refresh();
    first.complete([photo(1)]);
    await pending;
    expect(browser.photos.map((p) => p.id), [2]);
    browser.dispose();
  });
  test('permission denial, limited empty, full empty and query error remain distinct', () async {
    final source = FakeMedia();
    final browser = PhotoBrowser(source);
    source.access = PhotoAccess.denied;
    await browser.refresh();
    expect(browser.phase, BrowsePhase.denied);
    source.access = PhotoAccess.limited;
    await browser.refresh();
    expect(browser.phase, BrowsePhase.ready);
    expect(browser.access, PhotoAccess.limited);
    source.access = PhotoAccess.full;
    await browser.refresh();
    expect(browser.access, PhotoAccess.full);
    source.query = (_) async =>
        throw const MediaFailure(MediaFailureKind.query);
    await browser.refresh();
    expect(browser.phase, BrowsePhase.failed);
    expect(browser.photos, isEmpty);
    source.query = (_) async =>
        throw const MediaFailure(MediaFailureKind.permission);
    await browser.refresh();
    expect(browser.phase, BrowsePhase.denied);
    browser.dispose();
  });
  test(
    'missing directory reports attribution failure, no fabricated album',
    () async {
      final source = FakeMedia()..items = [photo(1, directory: '')];
      final browser = PhotoBrowser(source);
      await browser.refresh();
      expect(browser.phase, BrowsePhase.failed);
      expect(browser.albums, isEmpty);
      browser.dispose();
    },
  );
  test('at most four native requests, bounded size, late results cannot refill after narrowing', () async {
    final source = FakeMedia()..items = List.generate(8, (i) => photo(i + 1));
    final running = <Completer<Uint8List>>[];
    source.image = () {
      final c = Completer<Uint8List>();
      running.add(c);
      return c.future;
    };
    final browser = PhotoBrowser(source);
    await browser.refresh();
    final requests = browser.photos
        .map(
          (p) => browser
              .thumbnail(p, 2000, browser.generation)
              .then<Object>((v) => v, onError: (Object e) => e),
        )
        .toList();
    await Future<void>.delayed(Duration.zero);
    expect(running.length, 4);
    expect(browser.maxActive, 4);
    expect(browser.maxPixels, 512);
    source.access = PhotoAccess.denied;
    await browser.refresh();
    for (final c in running) {
      c.complete(Uint8List(1));
    }
    final outcomes = await Future.wait(requests);
    expect(outcomes.every((e) => e is MediaFailure), isTrue);
    expect(browser.photos, isEmpty);
    expect(browser.staleResults, 4);
    browser.dispose();
  });
  test(
    'dispose cancels queued work and cannot publish to released listener',
    () async {
      final pending = Completer<List<Photo>>();
      final source = FakeMedia()..query = (_) => pending.future;
      final browser = PhotoBrowser(source);
      var updates = 0;
      browser.addListener(() => updates++);
      final work = browser.refresh();
      await Future<void>.delayed(Duration.zero);
      final before = updates;
      browser.dispose();
      pending.complete([photo(1)]);
      await work;
      expect(updates, before);
    },
  );
  test(
    'single image failure does not fail the media collection and can retry',
    () async {
      final source = FakeMedia()
        ..items = [photo(1)]
        ..image = () async =>
            throw const MediaFailure(MediaFailureKind.unavailable);
      final browser = PhotoBrowser(source);
      await browser.refresh();
      await expectLater(
        browser.thumbnail(browser.photos.first, 128, browser.generation),
        throwsA(isA<MediaFailure>()),
      );
      expect(browser.phase, BrowsePhase.ready);
      expect(browser.photos.length, 1);
      source.image = null;
      expect(
        await browser.thumbnail(browser.photos.first, 128, browser.generation),
        hasLength(1),
      );
      browser.dispose();
    },
  );
}
