import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/organization/organization.dart';

import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;

void main() {
  late FakeMedia media;
  late PhotoBrowser browser;
  late MemoryOrganization store;
  late Organization org;
  setUp(() async {
    media = FakeMedia()
      ..items = [
        for (var i = 1; i <= 4; i++) photo(i, directory: 'Pictures/$i/'),
      ];
    browser = PhotoBrowser(media);
    await browser.refresh();
    store = MemoryOrganization();
    org = Organization(store, browser);
    await org.load();
  });
  tearDown(() {
    org.dispose();
    browser.dispose();
  });
  Future<void> drain() async {
    while (org.busy) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<String> create(String parent, String name) async {
    expect(await org.create(parent, name), isNull);
    return org.snapshot.children(parent).singleWhere((f) => f.name == name).id;
  }

  Future<String?> save(
    String parent, {
    List<String>? folders,
    List<String>? albums,
    OrganizationSnapshot? base,
    int? generation,
  }) => org.saveOrder(
    parent: parent,
    base: base ?? org.snapshot,
    generation: generation ?? browser.generation,
    folders: folders ?? org.snapshot.children(parent).map((f) => f.id).toList(),
    albums:
        albums ??
        org.snapshot.albums(parent, browser.albums).map((a) => a.key).toList(),
  );
  test(
    '012-01 root and five layers persist both types over three reloads',
    () async {
      var parent = rootFolder;
      final expected = <String, List<String>>{};
      for (var level = 0; level <= 5; level++) {
        final a = await create(parent, 'A'), b = await create(parent, 'B');
        for (final album in browser.albums) {
          expect(
            await org.moveAlbum(
              album.key,
              parent,
              generation: browser.generation,
            ),
            isNull,
          );
        }
        final keys = org.snapshot
            .albums(parent, browser.albums)
            .map((a) => a.key)
            .toList()
            .reversed
            .toList();
        expect(await save(parent, folders: [b, a], albums: keys), isNull);
        expect(org.snapshot.albumOrders[parent], keys);
        expected[parent] = [b, a];
        parent = a;
      }
      for (var i = 0; i < 3; i++) {
        await org.load();
        await drain();
        for (final e in expected.entries) {
          expect(org.snapshot.children(e.key).map((f) => f.id), e.value);
        }
        expect(org.snapshot.path(parent).length, 7);
      }
    },
  );
  test('012-02 defaults, renamed positions, new and moved nodes append; empty custom groups persist', () async {
    store.data = OrganizationSnapshot([
      const AlbumFolder('z', rootFolder, 'Z'),
      const AlbumFolder('a', rootFolder, 'A'),
    ], {});
    await org.load();
    expect(org.snapshot.children(rootFolder).map((f) => f.id), ['a', 'z']);
    expect(
      await save(
        rootFolder,
        folders: ['z', 'a'],
        albums: browser.albums.map((a) => a.key).toList().reversed.toList(),
      ),
      isNull,
    );
    await org.rename('z', '0');
    final b = await create(rootFolder, 'Before');
    expect(org.snapshot.children(rootFolder).map((f) => f.id), ['z', 'a', b]);
    final nested = await create('a', 'Nested');
    await org.moveFolder(nested, rootFolder);
    expect(org.snapshot.children(rootFolder).last.id, nested);
    final key = browser.albums.first.key;
    await org.moveAlbum(key, 'a', generation: browser.generation);
    await org.moveAlbum(key, rootFolder, generation: browser.generation);
    expect(org.snapshot.albumOrders[rootFolder]!.last, key);
    expect(org.snapshot.placements.containsKey(key), isFalse);
    final old = org.snapshot.albumOrders[rootFolder]!;
    media.items.add(photo(9, directory: 'Pictures/0/'));
    await browser.refresh();
    await drain();
    expect(org.snapshot.albumOrders[rootFolder], [
      ...old,
      media.items.last.albumKey,
    ]);
    await org.load();
    await drain();
    expect(org.snapshot.albumOrders['a'], isEmpty);
    await org.deleteEmpty('a');
    expect(org.snapshot.folderOrders.containsKey('a'), isFalse);
  });
  test('012-03 hidden root and placed slots survive subset reorder, denial, restoration', () async {
    final all = [...media.items];
    final keys = browser.albums.map((a) => a.key).toList();
    final f = await create(rootFolder, 'Group');
    for (final parent in [rootFolder, f]) {
      for (final key in keys) {
        await org.moveAlbum(key, parent, generation: browser.generation);
      }
      expect(await save(parent, albums: keys), isNull);
      media.items = [all[0], all[2]];
      media.access = PhotoAccess.limited;
      await browser.refresh();
      await drain();
      expect(await save(parent, albums: [keys[2], keys[0]]), isNull);
      expect(org.snapshot.albumOrders[parent], [
        keys[2],
        keys[1],
        keys[0],
        keys[3],
      ]);
      media.access = PhotoAccess.denied;
      await browser.refresh();
      expect(await save(parent, albums: []), isNull);
      expect(org.snapshot.albumOrders[parent], [
        keys[2],
        keys[1],
        keys[0],
        keys[3],
      ]);
      media.access = PhotoAccess.full;
      media.items = all;
      await browser.refresh();
      await drain();
      expect(org.snapshot.albums(parent, browser.albums).map((a) => a.key), [
        keys[2],
        keys[1],
        keys[0],
        keys[3],
      ]);
    }
    expect(org.snapshot.placements.length, 4);
  });
  test('012-04 failed, queued stale, modified caller lists and permission changes never overwrite confirmed data', () async {
    final a = await create(rootFolder, 'A'), b = await create(rootFolder, 'B');
    final base = org.snapshot;
    store.failWrite = true;
    expect(await save(rootFolder, folders: [b, a]), contains('保存失败'));
    expect(org.snapshot, same(base));
    store.failWrite = false;
    await org.rename(a, 'Changed');
    expect(await save(rootFolder, base: base), contains('过期'));
    final generation = browser.generation;
    await browser.refresh();
    expect(await save(rootFolder, generation: generation), contains('过期'));
    expect(await save(rootFolder, folders: [a, a]), isNotNull);
    store.pending = Completer<void>();
    final list = [b, a];
    final saving = save(rootFolder, folders: list);
    final queued = save(rootFolder);
    list.clear();
    await Future<void>.delayed(Duration.zero);
    expect(org.snapshot.children(rootFolder).map((f) => f.id), [a, b]);
    browser.suspend();
    store.pending!.complete();
    expect(await saving, isNull);
    expect(await queued, contains('过期'));
    expect(org.snapshot.children(rootFolder).map((f) => f.id), [b, a]);
    expect(browser.photos, isEmpty);
  });
  test('reject corrupted order graphs and preserve hidden relations on first partial save', () async {
    final f = await create(rootFolder, 'Group');
    final keys = browser.albums.map((a) => a.key).toList();
    store.data = OrganizationSnapshot(org.snapshot.folders.values, {
      for (final k in keys) k: f,
    });
    await org.load();
    media.items = [media.items.first];
    await browser.refresh();
    expect(await save(f), isNull);
    expect(org.snapshot.albumOrders[f]!.toSet(), keys.toSet());
    for (final orders in [
      {
        f: [keys[0], keys[0]],
      },
      {
        rootFolder: [keys[0]],
      },
      {
        f: [keys[0]],
      },
    ]) {
      expect(
        () => OrganizationSnapshot(
          org.snapshot.folders.values,
          org.snapshot.placements,
          albumOrders: orders,
        ),
        throwsA(isA<OrganizationError>()),
      );
    }
  });
  test('new discovery persistence failure stays explicit and retry preserves old slots', () async {
    expect(await save(rootFolder), isNull);
    final old = org.snapshot.albumOrders[rootFolder]!;
    store.failWrite = true;
    media.items.add(photo(9, directory: 'Pictures/0/'));
    await browser.refresh();
    await drain();
    expect(org.discoveryError, isNotNull);
    expect(org.snapshot.albumOrders[rootFolder], old);
    store.failWrite = false;
    await org.retryDiscovery();
    expect(org.discoveryError, isNull);
    expect(org.snapshot.albumOrders[rootFolder], [
      ...old,
      media.items.last.albumKey,
    ]);
  });
}
