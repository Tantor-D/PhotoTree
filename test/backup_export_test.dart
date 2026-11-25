import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/backup/backup_codec.dart';
import 'package:phototree/backup/backup_export.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/organization/organization.dart';

import 'library_views_test.dart' show MemoryFavorites;
import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;

class Originals implements OriginalReader {
  final calls = <int>[];
  Completer<void>? delay;
  bool fail = false;
  void Function()? duringRead;
  @override
  Future<bool> permission({bool request = false}) async => true;
  @override
  Future<OriginalFingerprint> read(Photo photo, String libraryVersion) async {
    calls.add(photo.id);
    await delay?.future;
    duringRead?.call();
    if (fail) throw StateError('read failed');
    return OriginalFingerprint(
      BackupFingerprint(size: 10, sha256: 'a' * 64),
      'photo.jpg',
    );
  }
}

class Output implements BackupOutput {
  BackupDocument? captured;
  bool result = true, fail = false;
  Completer<void>? delay;
  @override
  Future<bool> save(Uint8List bytes) async {
    captured = const BackupCodec().decode(bytes);
    await delay?.future;
    if (fail) throw StateError('ENOSPC');
    return result;
  }
}

void main() {
  late PhotoBrowser browser;
  late FakeMedia media;
  late MemoryFavorites favoriteStore;
  late MemoryOrganization organizationStore;
  late Favorites favorites;
  late Organization organization;
  late Originals reader;
  late Output output;
  late BackupExport backup;
  setUp(() async {
    media = FakeMedia()..items = [photo(1), photo(2)];
    browser = PhotoBrowser(media);
    await browser.refresh();
    favoriteStore = MemoryFavorites();
    organizationStore = MemoryOrganization();
    favorites = Favorites(favoriteStore, browser);
    organization = Organization(organizationStore, browser);
    await favorites.load();
    await organization.load();
    reader = Originals();
    output = Output();
    backup = BackupExport(organization, favorites, browser, reader, output);
  });
  tearDown(() {
    organization.dispose();
    favorites.dispose();
    browser.dispose();
  });

  test('stopping an in-flight read keeps guard until settlement and never saves late results', () async {
    await favorites.set(photo(1), true);
    await favorites.set(photo(2), true);
    reader.delay = Completer<void>();
    final progress = <(int, int)>[];
    final task = backup.export(
      readOriginals: true,
      onProgress: (done, total) => progress.add((done, total)),
    );
    final outcome = expectLater(
      task,
      throwsA(isA<BackupPreparationCancelled>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(reader.calls, [1]);
    backup.stopPreparation();
    expect(backup.busy, true);
    reader.delay!.complete();
    await outcome;
    expect(reader.calls, [1]);
    expect(output.captured, isNull);
    expect(progress, [(0, 2)]);
    expect(backup.busy, false);
    reader.delay = null;
    final retry = await backup.export(readOriginals: true);
    expect(retry.saved, true);
    expect(retry.document.unresolvedCount, 0);
  });

  test('drains accepted writes together, rejects new edits/load/discovery, unlocks before IO', () async {
    favoriteStore.pending = Completer<void>();
    organizationStore.pending = Completer<void>();
    final favoriteWrite = favorites.set(photo(1), true);
    final folderWrite = organization.create(rootFolder, 'accepted');
    final exporting = backup.export(readOriginals: true);
    await favorites.set(photo(2), true);
    expect(await organization.create(rootFolder, 'rejected'), isNotNull);
    await favorites.load();
    await organization.load();
    expect(favorites.phase, FavoritePhase.ready);
    expect(organization.phase, OrganizationPhase.ready);
    await organization.retryDiscovery();
    reader.delay = Completer<void>();
    favoriteStore.pending!.complete();
    organizationStore.pending!.complete();
    await favoriteWrite;
    await folderWrite;
    await Future<void>.delayed(Duration.zero);
    expect(organization.busy, false);
    expect(await organization.create(rootFolder, 'later'), isNull);
    await favorites.set(photo(2), true);
    reader.delay!.complete();
    final result = await exporting;
    expect(result.document.organization.folders.values.single.name, 'accepted');
    expect(result.document.favorites.length, 1);
    expect(reader.calls, [1]);
    expect(favorites.recordCount, 2);
  });
  test(
    'failed queued writes preserve confirmed snapshot and release barrier',
    () async {
      await favorites.set(photo(1), true);
      organizationStore.failWrite = true;
      final changing = organization.create(rootFolder, 'failed');
      final exported = await backup.export(readOriginals: false);
      expect(await changing, isNotNull);
      expect(exported.document.organization.folders, isEmpty);
      expect(exported.document.unresolvedCount, 1);
      expect(reader.calls, isEmpty);
      organizationStore.failWrite = false;
      expect(await organization.create(rootFolder, 'after'), isNull);
    },
  );
  test(
    'hidden placements/root slots and inaccessible identities are preserved',
    () async {
      organizationStore.data = OrganizationSnapshot(
        [const AlbumFolder('f', rootFolder, 'folder')],
        {'external_primary:Hidden/': 'f'},
        albumOrders: {
          rootFolder: ['external_primary:RootHidden/'],
          'f': ['external_primary:Hidden/'],
        },
        folderOrders: {
          rootFolder: ['f'],
          'f': [],
        },
      );
      favoriteStore.records.add(
        favoriteIdentity(photo(99), browser.libraryVersion)!,
      );
      await organization.load();
      await favorites.load();
      final summaryCount = backup.albumCount;
      final result = await backup.export(readOriginals: true);
      expect(summaryCount, result.document.albums.length);
      browser.suspend();
      expect(backup.albumCount, isNull);
      expect(
        result.document.albums.map((a) => a.sourceKey),
        containsAll([
          'external_primary:Hidden/',
          'external_primary:RootHidden/',
        ]),
      );
      expect(
        result.document.favorites.single.unresolvedReason,
        'not_accessible',
      );
      expect(result.document.organization.folderOrders['f'], isEmpty);
      expect(reader.calls, isEmpty);
    },
  );
  test(
    'read failure retains favorite and invalidation discards every fingerprint',
    () async {
      await favorites.set(photo(1), true);
      await favorites.set(photo(2), true);
      reader.fail = true;
      final failed = await backup.export(readOriginals: true);
      expect(failed.document.unresolvedCount, 2);
      reader.fail = false;
      reader.duringRead = () {
        if (reader.calls.length == 4) browser.suspend();
      };
      final stale = await backup.export(readOriginals: true);
      expect(stale.document.unresolvedCount, 2);
      expect(
        stale.document.favorites.every(
          (f) => f.unresolvedReason == 'media_scope_changed',
        ),
        true,
      );
    },
  );
  test('picker invalidation is after snapshot; cancellation and IO faults never mutate private state', () async {
    await favorites.set(photo(1), true);
    final original = organization.snapshot;
    output.result = false;
    final cancelled = await backup.export(
      readOriginals: true,
      onOutput: browser.suspend,
    );
    expect(cancelled.saved, false);
    expect(cancelled.document.unresolvedCount, 0);
    expect(organization.snapshot, same(original));
    expect(favorites.recordCount, 1);
    await browser.refresh();
    output.fail = true;
    await expectLater(backup.export(readOriginals: false), throwsStateError);
    expect(backup.busy, false);
    expect(favorites.recordCount, 1);
  });
  test(
    'failed owner prevents empty fallback and releases the other owner',
    () async {
      favoriteStore.failRead = true;
      await favorites.load();
      await expectLater(backup.export(readOriginals: false), throwsStateError);
      expect(output.captured, isNull);
      expect(await organization.create(rootFolder, 'still editable'), isNull);
    },
  );
  test(
    'disposal while draining fails export and releases surviving owner',
    () async {
      organizationStore.pending = Completer<void>();
      final write = organization.create(rootFolder, 'queued');
      final exporting = backup.export(readOriginals: false);
      final rejected = expectLater(exporting, throwsStateError);
      favorites.dispose();
      organizationStore.pending!.complete();
      await write;
      await rejected;
      expect(await organization.create(rootFolder, 'after'), isNull);
      // replace disposed reference so teardown owns a live object only.
      favorites = Favorites(MemoryFavorites(), browser);
    },
  );
  test('permission refresh superseded by resume cannot export a loading empty media snapshot', () async {
    await favorites.set(photo(1), true);
    final firstPage = Completer<List<Photo>>();
    final resumePage = Completer<List<Photo>>();
    var calls = 0;
    media.query = (after) async {
      if (after != 0) return [];
      return (++calls == 1 ? firstPage : resumePage).future;
    };
    // Same ordering as BackupPage's post-permission refresh and app resume.
    final permissionRefresh = browser.refresh();
    await Future<void>.delayed(Duration.zero);
    final resumedRefresh = browser.refresh();
    await Future<void>.delayed(Duration.zero);
    firstPage.complete([photo(1), photo(2)]);
    await permissionRefresh;
    expect(browser.phase, BrowsePhase.loading);
    try {
      await expectLater(
        backup.export(readOriginals: true),
        throwsA(isA<BackupMediaRefreshing>()),
      );
      expect(output.captured, isNull);
      expect(reader.calls, isEmpty);
    } finally {
      resumePage.complete([photo(1), photo(2)]);
      await resumedRefresh;
    }
    final retried = await backup.export(readOriginals: true);
    expect(retried.document.unresolvedCount, 0);
    expect(retried.document.favorites.single.albumId, isNotNull);
  });

  test(
    'confirmed denied access still exports all private records unresolved',
    () async {
      await favorites.set(photo(1), true);
      media.access = PhotoAccess.denied;
      await browser.refresh();
      expect(browser.phase, BrowsePhase.denied);
      final result = await backup.export(readOriginals: false);
      expect(result.document.favorites.length, 1);
      expect(
        result.document.favorites.single.unresolvedReason,
        'not_accessible',
      );
      expect(result.saved, true);
      media.access = PhotoAccess.full;
      media.query = (_) => Future.error(StateError('query failed'));
      await browser.refresh();
      expect(browser.phase, BrowsePhase.failed);
      final failedScope = await backup.export(readOriginals: false);
      expect(failedScope.document.favorites.length, 1);
      expect(
        failedScope.document.favorites.single.unresolvedReason,
        'not_accessible',
      );
    },
  );

  test(
    'export includes only private favorites regardless of live system fields',
    () async {
      await favorites.set(photo(1), true);
      media.items = [
        Photo(
          id: photo(1).id,
          directory: photo(1).directory,
          takenMs: photo(1).takenMs,
          addedSeconds: photo(1).addedSeconds,
          width: photo(1).width,
          height: photo(1).height,
          systemFavorite: true,
        ),
        Photo(
          id: photo(2).id,
          directory: photo(2).directory,
          takenMs: photo(2).takenMs,
          addedSeconds: photo(2).addedSeconds,
          width: photo(2).width,
          height: photo(2).height,
          systemFavorite: true,
        ),
      ];
      await browser.refresh();
      var result = await backup.export(readOriginals: true);
      expect(result.document.favorites.single.source, 'legacy');
      expect(result.document.systemSnapshotComplete, false);
      media.access = PhotoAccess.limited;
      await browser.refresh();
      result = await backup.export(readOriginals: true);
      expect(result.document.systemSnapshotComplete, false);
      expect(result.document.favorites.single.source, 'legacy');
      media.access = PhotoAccess.full;
      media.items = [media.items.first, photo(2)];
      await browser.refresh();
      result = await backup.export(readOriginals: true);
      expect(result.document.systemSnapshotComplete, false);
    },
  );

  test(
    'pending application origin is not changed by a live system field',
    () async {
      media.items = [
        const Photo(id: 42, directory: 'Pictures/A/', systemFavorite: true),
      ];
      await browser.refresh();
      final id = favoriteIdentity(media.items.single, browser.libraryVersion)!;
      await favorites.holdForBackup();
      favorites.installRestored(
        FavoriteSnapshot([], [
          PendingFavorite(identity: id, reason: 'missing_fingerprint'),
        ]),
      );
      favorites.releaseBackup();
      final result = await backup.export(readOriginals: false);
      expect(result.document.favorites.single.source, 'legacy');
      expect(result.pendingFavorites, 1);
      expect(result.document.favorites.single.pending, true);
      expect(result.document.favorites.single.systemFavorite, isNull);
    },
  );

  test(
    'unnotified source token changes cannot claim complete system snapshot',
    () async {
      media.items = [
        const Photo(id: 42, directory: 'Pictures/A/', systemFavorite: true),
      ];
      await browser.refresh();
      await favorites.set(media.items.single, true);
      reader.duringRead = () => media.access = PhotoAccess.limited;
      final result = await backup.export(readOriginals: true);
      expect(result.document.systemSnapshotComplete, false);
      expect(result.document.favorites.single.systemFavorite, isNull);
    },
  );

  test('system provenance pending records never masquerade as current system favorites', () async {
    media.items = [
      const Photo(id: 42, directory: 'Pictures/A/', systemFavorite: false),
    ];
    await browser.refresh();
    final identity = favoriteIdentity(
      media.items.single,
      browser.libraryVersion,
    )!;
    await favorites.holdForBackup();
    favorites.installRestored(
      FavoriteSnapshot([], [
        PendingFavorite(
          identity: identity,
          source: 'system',
          reason: 'awaiting_system_confirmation',
        ),
      ]),
    );
    favorites.releaseBackup();
    var result = await backup.export(readOriginals: false);
    expect(result.document.systemSnapshotComplete, false);
    expect(result.document.favorites.single.source, 'system');
    expect(result.document.favorites.single.pending, true);
    expect(result.document.favorites.single.systemFavorite, isNull);
    media.items = [const Photo(id: 42, directory: 'Pictures/A/')];
    await browser.refresh();
    result = await backup.export(readOriginals: false);
    expect(result.document.systemSnapshotComplete, false);
    expect(result.document.favorites.single.systemFavorite, isNull);
    expect(result.document.favorites.single.pending, true);
    media.access = PhotoAccess.denied;
    await browser.refresh();
    result = await backup.export(readOriginals: false);
    expect(result.document.favorites.single.identity, identity);
    expect(result.document.favorites.single.source, 'system');
    expect(result.document.favorites.single.systemFavorite, isNull);
  });

  test('duplicate export rejected until output has completed', () async {
    output.delay = Completer<void>();
    final first = backup.export(readOriginals: false);
    await expectLater(backup.export(readOriginals: false), throwsStateError);
    output.delay!.complete();
    await first;
    expect(backup.busy, false);
  });
}
