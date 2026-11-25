import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';

import 'media_browser_test.dart' show FakeMedia, photo;

class MemoryOrganization implements OrganizationStore {
  OrganizationSnapshot data = OrganizationSnapshot([], {});
  bool failRead = false, failWrite = false;
  Completer<void>? pending;
  int writes = 0;
  @override
  Future<OrganizationSnapshot> read() async {
    if (failRead) throw StateError('read');
    return data;
  }

  @override
  Future<void> save(
    OrganizationSnapshot before,
    OrganizationSnapshot after,
  ) async {
    writes++;
    await pending?.future;
    if (failWrite) throw StateError('write');
    data = after;
  }

  @override
  Future<void> replace(OrganizationSnapshot snapshot) => save(data, snapshot);

  @override
  Future<void> close() async {}
}

void main() {
  late FakeMedia source;
  late PhotoBrowser browser;
  late MemoryOrganization store;
  late Organization org;
  setUp(() async {
    source = FakeMedia()
      ..items = [photo(1), photo(2, directory: 'Pictures/B/A/')];
    browser = PhotoBrowser(source);
    await browser.refresh();
    store = MemoryOrganization();
    org = Organization(store, browser);
    await org.load();
  });
  tearDown(() {
    org.dispose();
    browser.dispose();
  });
  Future<String> create(String parent, String name) async {
    expect(await org.create(parent, name), isNull);
    return org.snapshot
        .children(parent)
        .singleWhere((f) => f.name == name.trim())
        .id;
  }

  Future<String?> move(String key, String parent) =>
      org.moveAlbum(key, parent, generation: browser.generation);
  Future<String?> drop(
    String key,
    String parent,
    OrganizationSnapshot base, {
    String? expectedParent,
    int? directoryRevision,
  }) => org.moveAlbum(
    key,
    parent,
    generation: browser.generation,
    base: base,
    expectedParent: expectedParent ?? base.parentOfAlbum(key),
    directoryRevision: directoryRevision ?? org.directoryRevision,
  );

  Future<String?> reorder(OrganizationSnapshot base) => org.saveOrder(
    parent: rootFolder,
    base: base,
    generation: browser.generation,
    folders: base
        .children(rootFolder)
        .map((f) => f.id)
        .toList()
        .reversed
        .toList(),
    albums: base
        .albums(rootFolder, org.albums)
        .map((a) => a.key)
        .toList()
        .reversed
        .toList(),
    directoryRevision: org.directoryRevision,
  );

  test(
    'drop binds the original source parent and directory revision',
    () async {
      final target = await create(rootFolder, 'Target');
      final key = source.items.first.albumKey;
      final base = org.snapshot;
      final writes = store.writes;
      expect(await drop(key, target, base, expectedParent: target), isNotNull);
      expect(
        await drop(
          key,
          target,
          base,
          directoryRevision: org.directoryRevision + 1,
        ),
        isNotNull,
      );
      expect(store.writes, writes);
      expect(org.snapshot, same(base));
      expect(await drop(key, target, base), isNull);
      expect(org.snapshot.parentOfAlbum(key), target);
      expect(source.items.first.albumKey, key);
      expect(browser.photos.length, 2);
      await org.load();
      expect(org.snapshot.parentOfAlbum(key), target);
    },
  );

  test(
    'drop rejects stale source or target changes even when both still exist',
    () async {
      final target = await create(rootFolder, 'Target');
      final other = await create(rootFolder, 'Other');
      final key = source.items.first.albumKey;
      var base = org.snapshot;
      expect(await org.moveFolder(target, other), isNull);
      var writes = store.writes;
      expect(await drop(key, target, base), isNotNull);
      expect(store.writes, writes);
      expect(org.snapshot.parentOfAlbum(key), rootFolder);
      base = org.snapshot;
      expect(await move(key, other), isNull);
      writes = store.writes;
      expect(await drop(key, target, base), isNotNull);
      expect(store.writes, writes);
      expect(org.snapshot.parentOfAlbum(key), other);
    },
  );

  test('queued drop and order reject a preceding private edit', () async {
    final target = await create(rootFolder, 'Target');
    final base = org.snapshot;
    store.pending = Completer<void>();
    final saving = org.rename(target, 'Renamed');
    final dropped = drop(source.items.first.albumKey, target, base);
    final ordered = reorder(base);
    await Future<void>.delayed(Duration.zero);
    final writes = store.writes;
    store.pending!.complete();
    expect(await saving, isNull);
    expect(await dropped, isNotNull);
    expect(await ordered, isNotNull);
    expect(store.writes, writes);
    expect(org.snapshot.placements, isEmpty);
    expect(org.snapshot.folders[target]!.name, 'Renamed');
  });

  test(
    'current generation cannot authorize drop or ordering during a refresh',
    () async {
      final target = await create(rootFolder, 'Target');
      final base = org.snapshot;
      final query = Completer<List<Photo>>();
      source.query = (after) async => after == 0 ? query.future : [];
      final refreshing = browser.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(browser.phase, BrowsePhase.loading);
      expect(
        org.albums,
        isNotEmpty,
      ); // Retained images are not write authority.
      final writes = store.writes;
      expect(await drop(source.items.first.albumKey, target, base), isNotNull);
      expect(await reorder(base), isNotNull);
      expect(store.writes, writes);
      query.complete(source.items);
      await refreshing;
      final previousAlbums = org.albums.map((a) => a.key).toList();
      source.access = PhotoAccess.denied;
      await browser.refresh();
      expect(await drop(source.items.first.albumKey, target, base), isNotNull);
      expect(
        await org.saveOrder(
          parent: rootFolder,
          base: base,
          generation: browser.generation,
          folders: [target],
          albums: previousAlbums,
          directoryRevision: org.directoryRevision,
        ),
        isNotNull,
      );
      expect(store.writes, writes);
      expect(org.snapshot, same(base));
    },
  );

  test(
    'denied folder-only ordering preserves hidden placements and album slots',
    () async {
      final a = await create(rootFolder, 'A');
      final b = await create(rootFolder, 'B');
      final key = source.items.first.albumKey;
      expect(await move(key, a), isNull);
      final slots = org.snapshot.albumOrders[a]!;
      source.access = PhotoAccess.denied;
      await browser.refresh();
      expect(await reorder(org.snapshot), isNull);
      expect(org.snapshot.children(rootFolder).map((f) => f.id), [b, a]);
      expect(org.snapshot.parentOfAlbum(key), a);
      expect(org.snapshot.albumOrders[a], slots);
      await org.load();
      expect(org.snapshot.children(rootFolder).map((f) => f.id), [b, a]);
      expect(org.snapshot.parentOfAlbum(key), a);
      expect(org.snapshot.albumOrders[a], slots);
    },
  );

  test(
    'failed drop and order preserve confirmed state and can be retried',
    () async {
      final target = await create(rootFolder, 'Target');
      final key = source.items.first.albumKey;
      final base = org.snapshot;
      store.failWrite = true;
      expect(await drop(key, target, base), isNotNull);
      expect(org.snapshot, same(base));
      expect(store.data, same(base));
      expect(await reorder(base), isNotNull);
      expect(org.snapshot, same(base));
      store.failWrite = false;
      expect(await drop(key, target, base), isNull);
      expect(org.snapshot.parentOfAlbum(key), target);
      expect(await reorder(org.snapshot), isNull);
      await org.load();
      expect(org.snapshot.parentOfAlbum(key), target);
    },
  );

  test(
    'media guard blocks immediate and queued classification or ordering',
    () async {
      final target = await create(rootFolder, 'Target');
      final base = org.snapshot;
      final key = source.items.first.albumKey;
      final owner = Object();
      var writes = store.writes;
      org.operationGuard.acquire(owner);
      expect(await drop(key, target, base), isNotNull);
      expect(await reorder(base), isNotNull);
      expect(store.writes, writes);
      org.operationGuard.release(owner);

      // A no-op queued ahead does not change the snapshot. The guard itself
      // must be checked again when the two accepted requests reach execution.
      final preceding = org.rename(target, 'Target');
      final dropped = drop(key, target, base);
      final ordered = reorder(base);
      org.operationGuard.acquire(owner);
      writes = store.writes;
      expect(await preceding, isNull);
      expect(await dropped, isNotNull);
      expect(await ordered, isNotNull);
      expect(store.writes, writes);
      expect(org.snapshot, same(base));
      org.operationGuard.release(owner);
      expect(await drop(key, target, base), isNull);
    },
  );
  test('five levels, empty folders, unique root, same-name directory distinction and single parent', () async {
    var parent = rootFolder;
    for (var i = 1; i <= 5; i++) {
      parent = await create(parent, 'Level $i');
      expect(org.snapshot.path(parent).length, i + 1);
    }
    expect(await move(source.items.first.albumKey, parent), isNull);
    expect(org.snapshot.parentOfAlbum(source.items.first.albumKey), parent);
    expect(org.snapshot.parentOfAlbum(source.items.last.albumKey), rootFolder);
    expect(org.snapshot.photoCount(rootFolder, browser.albums), 2);
    expect(org.snapshot.photoCount(parent, browser.albums), 1);
    expect(await move(source.items.first.albumKey, rootFolder), isNull);
    expect(org.snapshot.placements, isEmpty);
    final writes = store.writes;
    expect(await move(source.items.first.albumKey, rootFolder), isNull);
    expect(store.writes, writes);
  });
  test('Unicode names, controls, duplicates and root management reject without writes', () async {
    final a = await create(rootFolder, ' A ');
    await create(rootFolder, 'a');
    await create(a, 'A');
    await create(a, '😀' * 64);
    for (final name in [
      '',
      '   ',
      'a\nb',
      'a\t',
      'x\u0000',
      'x\u0085',
      'x\u2028',
      '😀' * 65,
      'A',
    ]) {
      final writes = store.writes;
      expect(await org.create(rootFolder, name), isNotNull, reason: name);
      expect(store.writes, writes);
    }
    expect(await org.rename(a, 'a'), isNotNull);
    expect(await org.rename(a, 'changed'), isNull);
    for (final future in [
      org.rename(rootFolder, 'x'),
      org.moveFolder(rootFolder, a),
      org.deleteEmpty(rootFolder),
    ]) {
      expect(await future, isNotNull);
    }
    expect(await org.create('missing', 'x'), isNotNull);
  });
  test('subtree moves preserve descendants; cycles, leaf targets and name collisions reject', () async {
    final a = await create(rootFolder, 'A'),
        b = await create(a, 'B'),
        c = await create(b, 'C');
    final other = await create(rootFolder, 'Other');
    await create(other, 'A');
    for (final target in [a, b, c, source.items.first.albumKey, other]) {
      final before = org.snapshot;
      expect(await org.moveFolder(a, target), isNotNull);
      expect(org.snapshot, same(before));
    }
    expect(await org.moveFolder(b, other), isNull);
    expect(org.snapshot.path(c), [rootFolder, other, b, c]);
    await org.load();
    expect(org.snapshot.path(c), [rootFolder, other, b, c]);
  });
  test('permission, failed/empty query, path replacement never clear hidden relations', () async {
    final f = await create(rootFolder, 'Trip');
    final key = source.items.first.albumKey;
    await move(key, f);
    source.access = PhotoAccess.denied;
    await browser.refresh();
    expect(await org.deleteEmpty(f), isNotNull);
    expect(org.snapshot.invisibleCount(f, browser.albums), 1);
    expect(await move(key, rootFolder), isNotNull);
    source.access = PhotoAccess.full;
    source.query = (_) => throw StateError('query');
    await browser.refresh();
    expect(browser.phase, BrowsePhase.failed);
    expect(org.snapshot.placements[key], f);
    source.query = null;
    source.items = [];
    await browser.refresh();
    expect(browser.phase, BrowsePhase.ready);
    expect(org.snapshot.placements[key], f);
    source.items = [photo(3, directory: 'Pictures/Moved/')];
    await browser.refresh();
    expect(
      org.snapshot.parentOfAlbum(source.items.single.albumKey),
      rootFolder,
    );
    source.items = [photo(4)];
    await browser.refresh();
    expect(org.snapshot.parentOfAlbum(source.items.single.albumKey), f);
    await move(key, rootFolder);
    expect(await org.deleteEmpty(f), isNull);
  });
  test('queued stale album is rejected, committing private write never repopulates media', () async {
    final f = await create(rootFolder, 'Trip');
    store.pending = Completer<void>();
    final saving = org.rename(f, 'Renamed');
    final queued = move(source.items.first.albumKey, f);
    await Future<void>.delayed(Duration.zero);
    expect(org.snapshot.folders[f]!.name, 'Trip');
    source.access = PhotoAccess.denied;
    await browser.refresh();
    store.pending!.complete();
    expect(await saving, isNull);
    expect(await queued, isNotNull);
    expect(org.snapshot.placements, isEmpty);
    expect(browser.photos, isEmpty);
    source.access = PhotoAccess.full;
    await browser.refresh();
    store.pending = Completer<void>();
    final inFlight = move(source.items.first.albumKey, f);
    await Future<void>.delayed(Duration.zero);
    browser.suspend();
    store.pending!.complete();
    expect(await inFlight, isNull);
    expect(org.snapshot.placements.length, 1);
    expect(browser.photos, isEmpty);
  });
  test('failed commit is unchanged and retry creates once; read failure stays explicit', () async {
    store.failWrite = true;
    expect(await org.create(rootFolder, 'Trip'), isNotNull);
    expect(org.snapshot.folders, isEmpty);
    store.failWrite = false;
    await create(rootFolder, 'Trip');
    expect(await org.create(rootFolder, 'Trip'), isNotNull);
    expect(store.data.folders.length, 1);
    store.failRead = true;
    await org.load();
    expect(org.phase, OrganizationPhase.failed);
    expect(await org.create(rootFolder, 'Other'), isNotNull);
    expect(store.data.folders.length, 1);
    store.failRead = false;
    await org.load();
    expect(org.phase, OrganizationPhase.ready);
  });
  test('invalid persisted graphs rejected and counts deduplicate current accessible keys', () {
    for (final folders in [
      [const AlbumFolder('a', 'b', 'A')],
      [const AlbumFolder('a', 'a', 'A')],
      [const AlbumFolder('a', 'b', 'A'), const AlbumFolder('b', 'a', 'B')],
      [const AlbumFolder(rootFolder, rootFolder, 'Root')],
      [
        const AlbumFolder('a', rootFolder, 'A'),
        const AlbumFolder('a', rootFolder, 'B'),
      ],
    ]) {
      expect(
        () => OrganizationSnapshot(folders, {}),
        throwsA(isA<OrganizationError>()),
      );
    }
    expect(
      () => OrganizationSnapshot([], {'album': 'missing'}),
      throwsA(anything),
    );
    final s = OrganizationSnapshot(
      [
        const AlbumFolder('trip', rootFolder, 'Trip'),
        const AlbumFolder('japan', 'trip', 'Japan'),
      ],
      {'a': 'japan', 'b': 'trip'},
    );
    final albums = [
      Album('a', 'Tokyo', [photo(1), photo(2)]),
      Album('b', 'Iceland', [photo(2), photo(3)]),
    ];
    expect(s.photoCount('trip', albums), 3);
    expect(s.photoCount('japan', albums), 2);
  });
  test('folder drop rejects stale queued tree and retains subtree', () async {
    final a = await create(rootFolder, 'A');
    final b = await create(rootFolder, 'B');
    final child = await create(a, 'Child');
    final base = org.snapshot;
    store.pending = Completer<void>();
    final first = org.rename(b, 'Renamed');
    final moving = org.moveFolder(a, b, base: base, expectedParent: rootFolder);
    await Future<void>.delayed(Duration.zero);
    final writes = store.writes;
    store.pending!.complete();
    expect(await first, isNull);
    expect(await moving, isNotNull);
    expect(store.writes, writes);
    expect(org.snapshot.folders[a]!.parent, rootFolder);
    expect(org.snapshot.folders[child]!.parent, a);
  });

  test('folder drop rechecks shared guard at queued execution', () async {
    final a = await create(rootFolder, 'A');
    final b = await create(rootFolder, 'B');
    final owner = Object();
    org.operationGuard.acquire(owner);
    expect(await org.moveFolder(a, b), isNotNull);
    org.operationGuard.release(owner);
    final writes = store.writes;
    final moving = org.moveFolder(a, b, base: org.snapshot);
    org.operationGuard.acquire(owner);
    expect(await moving, isNotNull);
    org.operationGuard.release(owner);
    expect(store.writes, writes);
    expect(org.snapshot.folders[a]!.parent, rootFolder);
  });

  test(
    'folder drop rejects changed generation, parent and directory revision',
    () async {
      final a = await create(rootFolder, 'A');
      final b = await create(rootFolder, 'B');
      final writes = store.writes;
      expect(await org.moveFolder(a, b, expectedParent: b), isNotNull);
      expect(
        await org.moveFolder(a, b, generation: browser.generation - 1),
        isNotNull,
      );
      expect(
        await org.moveFolder(
          a,
          b,
          directoryRevision: org.directoryRevision - 1,
        ),
        isNotNull,
      );
      expect(store.writes, writes);
      expect(org.snapshot.folders[a]!.parent, rootFolder);
    },
  );
}
