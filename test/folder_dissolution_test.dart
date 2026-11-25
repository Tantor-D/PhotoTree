import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';

import 'organization_test.dart' show MemoryOrganization;
import 'media_browser_test.dart' show FakeMedia, photo;

void main() {
  late FakeMedia source;
  late PhotoBrowser browser;
  late MemoryOrganization store;
  late Organization org;
  setUp(() async {
    source = FakeMedia()
      ..items = [photo(1), photo(2, directory: 'Pictures/B/')];
    browser = PhotoBrowser(source);
    await browser.refresh();
    store = MemoryOrganization();
    org = Organization(store, browser);
  });
  tearDown(() {
    org.dispose();
    browser.dispose();
  });

  Future<void> seed() async {
    const parent = rootFolder;
    store.data = OrganizationSnapshot(
      [
        AlbumFolder('container', parent, 'Container'),
        AlbumFolder('existing', parent, 'Existing'),
        const AlbumFolder('z', 'container', 'Z'),
        const AlbumFolder('a', 'container', 'A'),
        const AlbumFolder('descendant', 'a', 'Descendant'),
      ],
      {
        source.items.first.albumKey: 'container',
        'hidden': 'container',
        'deep-hidden': 'descendant',
      },
      folderOrders: {
        parent: ['container', 'existing'],
        'container': ['z', 'a'],
      },
      albumOrders: {
        'container': ['hidden', source.items.first.albumKey],
        parent: [source.items.last.albumKey, 'old-hidden'],
      },
    );
    await org.load();
  }

  for (final parent in [rootFolder, 'parent']) {
    test(
      'promotes direct children to $parent preserving both orders and hidden relationships',
      () async {
        // Build non-root fixture with an explicit hidden destination placement.
        if (parent == rootFolder) {
          await seed();
        } else {
          await seed();
          final s = store.data;
          store.data = OrganizationSnapshot(
            [
              const AlbumFolder('parent', rootFolder, 'Parent'),
              for (final f in s.folders.values)
                if (f.parent == rootFolder)
                  AlbumFolder(f.id, 'parent', f.name)
                else
                  f,
            ],
            {
              ...s.placements,
              source.items.last.albumKey: 'parent',
              'old-hidden': 'parent',
            },
            folderOrders: {
              'parent': s.folderOrders[rootFolder]!,
              'container': ['z', 'a'],
            },
            albumOrders: {
              'parent': s.albumOrders[rootFolder]!,
              'container': s.albumOrders['container']!,
            },
          );
          await org.load();
        }
        final preview = org.previewDissolution('container');
        expect(preview.childFolders, 2);
        expect(preview.albums, 2);
        expect(preview.hiddenAlbums, 1);
        expect(await org.dissolve(preview), isNull);
        final s = org.snapshot;
        expect(s.folders.containsKey('container'), false);
        expect(s.children(parent).map((f) => f.id), ['existing', 'z', 'a']);
        expect(s.folders['descendant']!.parent, 'a');
        expect(s.placements['deep-hidden'], 'descendant');
        expect(s.albumOrders[parent], [
          source.items.last.albumKey,
          'old-hidden',
          'hidden',
          source.items.first.albumKey,
        ]);
        expect(s.parentOfAlbum('hidden'), parent);
        expect(s.folderOrders.containsKey('container'), false);
        expect(s.albumOrders.containsKey('container'), false);
        await org.load();
        expect(org.snapshot.albumOrders[parent], s.albumOrders[parent]);
      },
    );
  }

  test('permission denied promotes hidden relations and restores visibility at root', () async {
    await seed();
    source.access = PhotoAccess.denied;
    await browser.refresh();
    final preview = org.previewDissolution('container');
    expect(preview.hiddenAlbums, 2);
    expect(await org.dissolve(preview), isNull);
    source.access = PhotoAccess.full;
    await browser.refresh();
    expect(org.snapshot.parentOfAlbum(source.items.first.albumKey), rootFolder);
    expect(org.snapshot.albumOrders[rootFolder], contains('hidden'));
  });

  test('root and all collisions reject unchanged; removed container name is not a collision', () async {
    store.data = OrganizationSnapshot([
      const AlbumFolder('container', rootFolder, 'Container'),
      const AlbumFolder('same', 'container', 'Container'),
      const AlbumFolder('x', rootFolder, 'X'),
      const AlbumFolder('y', rootFolder, 'Y'),
      const AlbumFolder('cx', 'container', 'X'),
      const AlbumFolder('cy', 'container', 'Y'),
    ], {});
    await org.load();
    expect(
      () => org.previewDissolution(rootFolder),
      throwsA(isA<OrganizationError>()),
    );
    expect(
      () => org.previewDissolution('container'),
      throwsA(
        isA<OrganizationError>().having(
          (e) => e.message,
          'all names',
          contains('X、Y'),
        ),
      ),
    );
    expect(store.writes, 0);
    await org.deleteEmpty('cx');
    await org.deleteEmpty('cy');
    expect(await org.dissolve(org.previewDissolution('container')), isNull);
    expect(org.snapshot.folders['same']!.parent, rootFolder);
  });

  test('refresh in progress cannot preview counts that change in the same generation', () async {
    await seed();
    final page = Completer<List<Photo>>();
    source.query = (_) => page.future;
    final refreshing = browser.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(browser.phase, BrowsePhase.loading);
    final generation = browser.generation;
    expect(
      () => org.previewDissolution('container'),
      throwsA(isA<OrganizationError>()),
    );
    page.complete([]);
    await refreshing;
    expect(browser.generation, generation);
    expect(org.previewDissolution('container').hiddenAlbums, 2);
  });

  test('empty and uncustomized folders retain default relative order on dissolution', () async {
    store.data = OrganizationSnapshot([
      const AlbumFolder('container', rootFolder, 'Container'),
      const AlbumFolder('existing', rootFolder, 'Existing'),
      const AlbumFolder('z', 'container', 'Z'),
      const AlbumFolder('a', 'container', 'A'),
    ], {});
    await org.load();
    expect(await org.dissolve(org.previewDissolution('container')), isNull);
    expect(org.snapshot.folderOrders[rootFolder], ['existing', 'a', 'z']);
    expect(await org.dissolve(org.previewDissolution('existing')), isNull);
    expect(org.snapshot.folderOrders[rootFolder], ['a', 'z']);
  });

  test('stale tree and media previews and queued changes reject; failed save preserves exact snapshot', () async {
    await seed();
    var preview = org.previewDissolution('container');
    await org.rename('existing', 'Changed');
    expect(await org.dissolve(preview), contains('过期'));
    preview = org.previewDissolution('container');
    await browser.refresh();
    expect(await org.dissolve(preview), contains('过期'));
    preview = org.previewDissolution('container');
    store.pending = Completer<void>();
    final saving = org.rename('existing', 'Queued');
    final queued = org.dissolve(preview);
    await Future<void>.delayed(Duration.zero);
    store.pending!.complete();
    expect(await saving, isNull);
    expect(await queued, contains('过期'));
    store.pending = null;
    final before = org.snapshot;
    store.failWrite = true;
    expect(
      await org.dissolve(org.previewDissolution('container')),
      contains('保存失败'),
    );
    expect(org.snapshot, same(before));
    expect(store.data, same(before));
    store.failWrite = false;
    expect(await org.dissolve(org.previewDissolution('container')), isNull);
  });
}
