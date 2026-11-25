import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';

import 'media_browser_test.dart' show FakeMedia;

void main() {
  const image = Photo(id: 1, directory: 'Pictures/Mixed/');
  const video = Photo(
    id: 2,
    directory: 'Pictures/Mixed/',
    kind: MediaKind.video,
  );

  test('only both full grants describe a complete all-media snapshot', () {
    for (final images in PhotoAccess.values) {
      for (final videos in PhotoAccess.values) {
        final p = MediaPermissions(images: images, videos: videos);
        expect(
          p.combined == PhotoAccess.full,
          images == PhotoAccess.full && videos == PhotoAccess.full,
        );
        expect(
          p.combined == PhotoAccess.denied,
          images == PhotoAccess.denied && videos == PhotoAccess.denied,
        );
        expect(p.forKind(MediaKind.image), images);
        expect(p.forKind(MediaKind.video), videos);
        expect(p, MediaPermissions(images: images, videos: videos));
      }
    }
  });

  test(
    'image-only and video-only grants publish only the granted type',
    () async {
      final source = FakeMedia()..items = [image, video];
      final browser = PhotoBrowser(source);
      addTearDown(browser.dispose);
      for (final images in PhotoAccess.values) {
        for (final videos in PhotoAccess.values) {
          source.access = images;
          source.videoAccess = videos;
          await browser.refresh();
          expect(browser.photos.map((p) => p.key).toSet(), {
            if (images != PhotoAccess.denied) image.key,
            if (videos != PhotoAccess.denied) video.key,
          });
          expect(
            browser.permissions,
            MediaPermissions(images: images, videos: videos),
          );
        }
      }
    },
  );

  test(
    'permission type swap cannot pass a stable aggregate limited check',
    () async {
      final source = FakeMedia()
        ..items = [image, video]
        ..access = PhotoAccess.full
        ..videoAccess = PhotoAccess.denied;
      source.query = (after) async {
        if (after == 0) return [image];
        source.access = PhotoAccess.denied;
        source.videoAccess = PhotoAccess.full;
        return [];
      };
      final browser = PhotoBrowser(source);
      addTearDown(browser.dispose);
      await browser.refresh();
      expect(browser.phase, BrowsePhase.failed);
      expect(browser.failure, MediaFailureKind.stale);
      expect(browser.photos, isEmpty);
    },
  );

  test(
    'permission narrowing hides previous full snapshot before delayed query',
    () async {
      final source = FakeMedia()..items = [image, video];
      final browser = PhotoBrowser(source);
      addTearDown(browser.dispose);
      await browser.refresh();
      source.videoAccess = PhotoAccess.denied;
      final query = Completer<List<Photo>>();
      source.query = (after) async => after == 0 ? query.future : [];
      final refresh = browser.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(browser.photos, isEmpty);
      query.complete([image, video]);
      await refresh;
      expect(browser.photos.single.key, image.key);
    },
  );

  test('mixed pages beyond 256 preserve one collection and stable typed identities', () async {
    final source = FakeMedia()
      ..items = List.generate(
        700,
        (i) => Photo(
          id: i + 1,
          directory: i.isEven ? 'Pictures/Mixed/' : 'Pictures/Video/',
          kind: i.isEven ? MediaKind.image : MediaKind.video,
        ),
      );
    final browser = PhotoBrowser(source);
    addTearDown(browser.dispose);
    final counts = <int>[];
    browser.addListener(() => counts.add(browser.photos.length));
    await browser.refresh();
    expect(browser.photos.length, 700);
    expect(browser.photos.map((p) => p.key).toSet().length, 700);
    expect(counts.toSet(), {0, 700});
    expect(browser.albums.length, 2);
    expect(browser.photos.where((p) => p.kind == MediaKind.video).length, 350);
  });
}
