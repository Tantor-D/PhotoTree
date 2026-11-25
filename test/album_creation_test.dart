import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/backup/backup_codec.dart';
import 'package:phototree/backup/backup_export.dart';
import 'package:phototree/backup/backup_restore.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/organization/album_creation.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/storage/directory_access.dart';
import 'package:phototree/storage/operation_guard.dart';
import 'package:phototree/ui/physical_album_page.dart';
import 'package:phototree/ui/library_shell.dart';
import 'package:phototree/ui/photo_grid.dart';

import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;
import 'library_views_test.dart' show MemoryFavorites;
import 'backup_export_test.dart' show Output;
import 'backup_restore_test.dart' show Input, MatchMedia, Journal;

class CreationStore extends MemoryOrganization implements AlbumCreationStore {
  final records = <String, AlbumCreationRecord>{};
  bool failIntent = false, failFinal = false, loseResponse = false;
  bool failReadAfterCommit = false, loseOrganizationResponse = false;
  bool failCreationRead = false;
  @override
  Future<void> save(
    OrganizationSnapshot before,
    OrganizationSnapshot after,
  ) async {
    await super.save(before, after);
    if (loseOrganizationResponse) {
      throw const OrganizationError('private response lost');
    }
  }

  Future<void> Function()? intentGate, finalGate;
  @override
  Future<List<AlbumCreationRecord>> readCreations() async {
    if (failCreationRead) throw StateError('creation journal unavailable');
    return records.values.toList();
  }
  @override
  Future<void> recordCreation(AlbumCreationRecord record) async {
    if (failIntent) throw StateError('disk full');
    records[record.id] = record;
    await intentGate?.call();
  }

  @override
  Future<void> commitCreation(
    OrganizationSnapshot before,
    OrganizationSnapshot after,
    AlbumCreationRecord record, {
    Future<bool> Function()? validate,
  }) async {
    await finalGate?.call();
    if (failFinal || (validate != null && !await validate())) {
      throw StateError('transaction rollback');
    }
    expect(records[record.id]!.unresolved, isTrue);
    data = after;
    records[record.id] = record;
    if (failReadAfterCommit) failRead = true;
    if (loseResponse) throw StateError('committed response lost');
  }
}

class PhysicalAccess implements PhysicalDirectoryAccess {
  bool valid = true, authorized = true;
  int writes = 0, opens = 0, closes = 0;
  String? live;
  final existing = <String>{};
  DirectoryCreationResult result = DirectoryCreationResult.created;
  DirectoryReading reading = const DirectoryReading(
    DirectoryContents.empty,
    '真实空目录',
  );
  Future<void> Function()? beforeWrite;
  Completer<DirectoryReading>? readGate;
  @override
  Future<DirectoryCapabilities> inspect(DirectoryIdentity directory) async =>
      const DirectoryCapabilities(
        status: DirectoryStatus.available,
        reason: 'ok',
      );
  @override
  Future<DirectoryRequest> authorize(DirectoryIdentity directory) async =>
      authorized ? DirectoryRequest.granted : DirectoryRequest.cancelled;
  @override
  Future<String?> begin(DirectoryIdentity directory) async {
    if (!authorized || live != null) return null;
    opens++;
    return live = 'live-$opens';
  }

  @override
  Future<DirectoryCreationResult> create(String token, String name) async {
    await beforeWrite?.call();
    expect(token, live);
    writes++;
    if (result == DirectoryCreationResult.created) existing.add(name);
    return result;
  }

  @override
  Future<bool> verify(String token) async =>
      valid && authorized && token == live;
  @override
  Future<void> end(String token) async {
    if (token == live) {
      closes++;
      live = null;
    }
  }

  @override
  Future<DirectoryReading> readDirectory(DirectoryIdentity directory) async =>
      readGate?.future ?? reading;
}

void main() {
  const parent = DirectoryIdentity('external_primary', 'Pictures/Tests/');
  late CreationStore store;
  late PhysicalAccess access;
  late FakeMedia media;
  late PhotoBrowser browser;
  late Organization org;
  late BackupOperationGuard guard;
  setUp(() async {
    store = CreationStore();
    access = PhysicalAccess();
    media = FakeMedia();
    browser = PhotoBrowser(media);
    await browser.refresh();
    guard = BackupOperationGuard();
    org = Organization(
      store,
      browser,
      directories: access,
      operationGuard: guard,
    );
    await org.load();
  });
  tearDown(() {
    org.dispose();
    browser.dispose();
  });

  test(
    'physical names count Unicode code points and reject unsafe components',
    () {
      expect(physicalAlbumName('  相册🦋  '), '相册🦋');
      expect(physicalAlbumName('🦋' * 64), '🦋' * 64);
      for (final name in [
        '',
        ' ',
        '.hidden',
        '.',
        '..',
        'a/b',
        'a\\b',
        'a\n',
        'a\u0000',
        '🦋' * 65,
      ]) {
        expect(
          () => physicalAlbumName(name),
          throwsA(isA<OrganizationError>()),
        );
      }
    },
  );

  test('intent precedes the only shared write; one atomic tree, descriptor, order and completion', () async {
    access.beforeWrite = () async {
      expect(store.records.values.single.outcome, CreationOutcome.prepared);
      expect(store.data.descriptors, isEmpty);
    };
    var target = rootFolder;
    for (var i = 0; i < 5; i++) {
      expect(await org.create(target, 'L$i'), isNull);
      target = org.snapshot.children(target).single.id;
    }
    expect(await org.createAlbum(target, parent, ' 相册🦋 '), isNull);
    const key = 'external_primary:Pictures/Tests/相册🦋/';
    expect(store.data.placements[key], target);
    expect(store.data.descriptors[key]!.directory, 'Pictures/Tests/相册🦋/');
    expect(store.data.albumOrders[target], [key]);
    expect(store.records.values.single.outcome, CreationOutcome.completed);
    expect(access.writes, 1);
    expect(access.live, isNull);
    expect(org.albums.single.availability, AlbumAvailability.empty);
    expect(browser.photos, isEmpty);
  });

  test(
    'intent failure, invalid parent and cancellation imply zero shared calls',
    () async {
      store.failIntent = true;
      expect(await org.createAlbum(rootFolder, parent, 'NoWrite'), isNotNull);
      expect(access.writes, 0);
      expect(access.live, isNull);
      store.failIntent = false;
      expect(
        await org.createAlbum('vanished', parent, 'NoRootFallback'),
        isNotNull,
      );
      expect(access.writes, 0);
      store.intentGate = () async {
        org.cancelCreation();
      };
      expect(
        await org.createAlbum(rootFolder, parent, 'Cancelled'),
        contains('取消'),
      );
      expect(store.records.values.single.outcome, CreationOutcome.cancelled);
      expect(access.writes, 0);
      expect(access.opens, access.closes);
    },
  );

  test('EEXIST never merges, renames, associates or retries', () async {
    access.result = DirectoryCreationResult.conflict;
    expect(
      await org.createAlbum(rootFolder, parent, 'Existing'),
      contains('同名'),
    );
    expect(store.records.values.single.outcome, CreationOutcome.conflict);
    expect(org.snapshot.descriptors, isEmpty);
    expect(access.writes, 1);
    expect(access.live, isNull);
    expect(org.creationIssue, isNull);
  });

  test(
    'private failure retries with a live credential, never another mkdir',
    () async {
      store.failFinal = true;
      expect(await org.createAlbum(rootFolder, parent, 'Retry'), isNotNull);
      final id = org.creations.single.id;
      expect(org.canRetryCreation(id), isTrue);
      expect(await org.create(rootFolder, 'Unrelated folder'), isNull);
      expect(org.canRetryCreation(id), isTrue);
      expect(access.live, isNotNull);
      expect(store.data.descriptors, isEmpty);
      expect(() => org.holdForBackup(), throwsA(isA<OrganizationError>()));
      store.failFinal = false;
      expect(await org.retryAlbumCreation(id), isNull);
      expect(access.writes, 1);
      expect(access.opens, access.closes);
      expect(store.data.descriptors, hasLength(1));
      expect(org.creationIssue, isNull);
    },
  );

  for (final point in ['before association', 'inside final transaction']) {
    test('invalid credential $point releases immediately without another write', () async {
      if (point == 'before association') {
        store.intentGate = () async {
          if (store.records.values.single.outcome == CreationOutcome.created) {
            access.valid = false;
          }
        };
      } else {
        store.finalGate = () async { access.valid = false; };
      }
      expect(await org.createAlbum(rootFolder, parent, 'Changed'), isNotNull);
      final record = org.creations.single;
      expect(access.live, isNull);
      expect(access.closes, access.opens);
      expect(org.canRetryCreation(record.id), isFalse);
      expect(record.outcome, CreationOutcome.unknown);
      expect(access.writes, 1);
      expect(access.existing, {'Changed'});
      expect(store.data.descriptors, isEmpty);
      expect(store.data.albumOrders, isEmpty);
    });
  }

  test('vanished virtual parent ends a no-longer-usable retry credential', () async {
    await org.create(rootFolder, 'Destination');
    final target = org.snapshot.children(rootFolder).single.id;
    store.failFinal = true;
    expect(await org.createAlbum(target, parent, 'Retained'), isNotNull);
    final id = org.creations.single.id;
    expect(org.canRetryCreation(id), isTrue);
    await org.dissolve(org.previewDissolution(target));
    expect(access.live, isNull);
    expect(org.canRetryCreation(id), isFalse);
    expect(org.creations.single.outcome, CreationOutcome.unknown);
    store.failFinal = false;
    expect(await org.retryAlbumCreation(id), contains('无法确认上次'));
    expect(access.live, isNull);
    expect(access.closes, access.opens);
    expect(org.canRetryCreation(id), isFalse);
    expect(org.creations.single.outcome, CreationOutcome.unknown);
    expect(access.writes, 1);
    expect(access.existing, {'Retained'});
    expect(store.data.descriptors, isEmpty);
  });

  test('committed parent removal releases even when journal reread fails', () async {
    await org.create(rootFolder, 'Destination');
    final target = org.snapshot.children(rootFolder).single.id;
    store.failFinal = true;
    await org.createAlbum(target, parent, 'Retained');
    final id = org.creations.single.id;
    store.failCreationRead = true;
    expect(await org.dissolve(org.previewDissolution(target)), isNotNull);
    expect(store.data.folders, isEmpty);
    expect(access.live, isNull);
    expect(access.closes, access.opens);
    expect(org.canRetryCreation(id), isFalse);
    expect(org.phase, OrganizationPhase.failed);
    expect(access.writes, 1);
    store.failCreationRead = false;
    await org.load();
    expect(org.creations.single.outcome, CreationOutcome.unknown);
  });

  test('lost commit response reads authoritative completion without duplicating association', () async {
    store.loseResponse = true;
    expect(await org.createAlbum(rootFolder, parent, 'Committed'), isNotNull);
    final id = org.creations.single.id;
    expect(store.records[id]!.outcome, CreationOutcome.completed);
    expect(await org.retryAlbumCreation(id), isNull);
    expect(access.writes, 1);
    expect(org.snapshot.descriptors, hasLength(1));
    expect(org.snapshot.albumOrders[rootFolder], hasLength(1));
    expect(access.live, isNull);
  });

  for (final action in ['dismiss', 'associate', 'ordinary edit']) {
    test(
      'lost commit response followed by $action preserves durable completion',
      () async {
        await org.create(rootFolder, 'Destination');
        final target = org.snapshot.children(rootFolder).single.id;
        store.loseResponse = true;
        expect(await org.createAlbum(target, parent, 'Committed'), isNotNull);
        final id = store.records.keys.single;
        const key = 'external_primary:Pictures/Tests/Committed/';
        store.loseResponse = false;
        switch (action) {
          case 'dismiss':
            await org.resolveAlbumCreation(id);
          case 'associate':
            await org.resolveAlbumCreation(
              id,
              existing: const DirectoryIdentity(
                'external_primary',
                'Pictures/Other/',
              ),
              parent: rootFolder,
            );
          case 'ordinary edit':
            expect(await org.create(rootFolder, 'Later edit'), isNull);
        }
        expect(store.records[id]!.outcome, CreationOutcome.completed);
        expect(store.records[id]!.resolution, CreationResolution.none);
        expect(store.data.descriptors.keys, [key]);
        expect(store.data.placements[key], target);
        expect(store.data.albumOrders[target], [key]);
        expect(org.snapshot.descriptors.keys, [key]);
        expect(access.writes, 1);
        expect(access.live, isNull);
      },
    );
  }

  test('uncertain commit and failed reconciliation block queued edits until reload', () async {
    store.loseResponse = true;
    store.failReadAfterCommit = true;
    final creating = org.createAlbum(rootFolder, parent, 'Committed');
    final editing = org.create(rootFolder, 'Must not overwrite');
    expect(await creating, isNotNull);
    expect(await editing, isNotNull);
    expect(org.phase, OrganizationPhase.failed);
    expect(store.data.descriptors, hasLength(1));
    expect(store.data.folders, isEmpty);
    expect(await org.create(rootFolder, 'Still blocked'), isNotNull);
    store.failRead = false;
    await org.load();
    expect(org.phase, OrganizationPhase.ready);
    expect(org.creations.single.outcome, CreationOutcome.completed);
    expect(await org.create(rootFolder, 'After reload'), isNull);
    expect(store.data.descriptors, hasLength(1));
    expect(access.writes, 1);
    expect(access.live, isNull);
  });

  test('ordinary mutation response loss also refreshes authority before another edit', () async {
    await org.createAlbum(rootFolder, parent, 'Retained');
    store.loseOrganizationResponse = true;
    expect(
      await org.create(rootFolder, 'Saved before lost response'),
      isNotNull,
    );
    expect(org.snapshot.folders, hasLength(1));
    store.loseOrganizationResponse = false;
    expect(await org.create(rootFolder, 'Second'), isNull);
    expect(store.data.folders, hasLength(2));
    expect(store.data.descriptors, hasLength(1));
    expect(access.writes, 1);
  });

  test(
    'lost association response preserves one disposition and never replaces it',
    () async {
      access.result = DirectoryCreationResult.unknown;
      await org.createAlbum(rootFolder, parent, 'Unknown');
      final id = org.creations.single.id;
      const existing = DirectoryIdentity(
        'external_primary',
        'Pictures/Selected/',
      );
      store.loseResponse = true;
      await org.resolveAlbumCreation(
        id,
        existing: existing,
        parent: rootFolder,
      );
      store.loseResponse = false;
      await org.resolveAlbumCreation(id);
      expect(store.records[id]!.outcome, CreationOutcome.unknown);
      expect(store.records[id]!.resolution, CreationResolution.associated);
      expect(store.data.descriptors.keys, [existing.key]);
      expect(org.snapshot.descriptors.keys, [existing.key]);
      expect(access.writes, 1);
    },
  );

  test('read-only restore inspection does not create a visible album or discovery order', () async {
    const inspected = DirectoryIdentity(
      'external_primary',
      'Pictures/Inspected/',
    );
    await org.inspectRestoreDirectory(inspected);
    expect(org.restoreAlbums.map((a) => a.key), contains(inspected.key));
    expect(org.albums, isEmpty);
    await org.retryDiscovery();
    expect(store.data.descriptors, isEmpty);
    expect(store.data.albumOrders, isEmpty);
  });

  test('replacing organization removes old empty albums even when a reading is cached', () async {
    await org.createAlbum(rootFolder, parent, 'RemovedByRestore');
    expect(org.albums, hasLength(1));
    await org.holdForBackup();
    final replacement = OrganizationSnapshot(
      [],
      {},
      albumOrders: {rootFolder: []},
    );
    await store.replace(replacement);
    org.installRestored(replacement);
    org.releaseBackup();
    await org.refreshDirectories();
    await org.retryDiscovery();
    expect(org.albums, isEmpty);
    expect(store.data.albumOrders[rootFolder], isEmpty);
  });

  test(
    'revoked or replaced live credential refuses private completion',
    () async {
      store.failFinal = true;
      await org.createAlbum(rootFolder, parent, 'Changed');
      final id = org.creations.single.id;
      store.failFinal = false;
      access.valid = false;
      expect(await org.retryAlbumCreation(id), contains('无法确认'));
      expect(org.creations.single.outcome, CreationOutcome.unknown);
      expect(org.snapshot.descriptors, isEmpty);
      expect(access.writes, 1);
      expect(access.live, isNull);
    },
  );

  test('three process reopens retain unknown without claiming the same path or issuing writes', () async {
    store.failFinal = true;
    await org.createAlbum(rootFolder, parent, 'Reused');
    final id = org.creations.single.id;
    org.dispose();
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 3; i++) {
      access = PhysicalAccess()..existing.add('Reused');
      org = Organization(store, browser, directories: access);
      await org.load();
      expect(org.creations.single.outcome, CreationOutcome.unknown);
      expect(org.canRetryCreation(id), isFalse);
      expect(await org.retryAlbumCreation(id), contains('无法确认'));
      expect(access.writes, 0);
      expect(org.snapshot.descriptors, isEmpty);
      if (i < 2) org.dispose();
    }
  });

  test('explicit new association plus unknown disposition is atomic and performs zero writes', () async {
    access.result = DirectoryCreationResult.unknown;
    await org.createAlbum(rootFolder, parent, 'Uncertain');
    final id = org.creations.single.id;
    final writes = access.writes;
    const selected = DirectoryIdentity(
      'external_primary',
      'Pictures/Selected/',
    );
    store.failFinal = true;
    expect(
      await org.resolveAlbumCreation(
        id,
        existing: selected,
        parent: rootFolder,
      ),
      isNotNull,
    );
    expect(store.data.descriptors, isEmpty);
    expect(store.records[id]!.resolution, CreationResolution.none);
    store.failFinal = false;
    expect(
      await org.resolveAlbumCreation(
        id,
        existing: selected,
        parent: rootFolder,
      ),
      isNull,
    );
    expect(store.records[id]!.outcome, CreationOutcome.unknown);
    expect(store.records[id]!.resolution, CreationResolution.associated);
    expect(store.records[id]!.associatedKey, selected.key);
    expect(store.data.descriptors.keys, [selected.key]);
    expect(access.writes, writes);
    expect(org.creationIssue, isNull);
    await org.holdForBackup();
    expect(org.confirmedForBackup.descriptors.keys, [selected.key]);
    org.releaseBackup();
    await store.replace(OrganizationSnapshot([], {}));
    expect(store.records[id]!.resolution, CreationResolution.associated);
  });

  test('dismissal retains unknown history, releases backup and never modifies shared storage', () async {
    access.result = DirectoryCreationResult.unknown;
    await org.createAlbum(rootFolder, parent, 'Uncertain');
    final writes = access.writes;
    expect(await org.resolveAlbumCreation(org.creations.single.id), isNull);
    expect(org.creations.single.outcome, CreationOutcome.unknown);
    expect(org.creations.single.resolution, CreationResolution.dismissed);
    expect(org.creationIssue, isNull);
    expect(access.writes, writes);
    expect(org.snapshot.descriptors, isEmpty);
  });

  test(
    'guard excludes backup and duplicate create while intent is pending',
    () async {
      final gate = Completer<void>();
      store.intentGate = () => gate.future;
      final creating = org.createAlbum(rootFolder, parent, 'One');
      await Future<void>.delayed(Duration.zero);
      expect(await org.createAlbum(rootFolder, parent, 'Two'), isNotNull);
      final backup = Object();
      expect(() => guard.acquire(backup), throwsStateError);
      gate.complete();
      expect(await creating, isNull);
      guard.acquire(backup);
      guard.release(backup);
      expect(access.writes, 1);
    },
  );

  test('empty view survives reload, becomes one indexed node and never mislabels denied or content as empty', () async {
    await org.createAlbum(rootFolder, parent, 'Photos');
    const directory = 'Pictures/Tests/Photos/';
    await org.load();
    await org.refreshDirectories();
    expect(org.albums.single.availability, AlbumAvailability.empty);
    media.items = [photo(9, directory: directory)];
    await browser.refresh();
    expect(org.albums, hasLength(1));
    expect(org.albums.single.photos, hasLength(1));
    expect(org.albums.single.availability, AlbumAvailability.indexed);
    media.items = [];
    access.reading = const DirectoryReading(DirectoryContents.content, '待索引');
    await browser.refresh();
    await org.refreshDirectories();
    expect(org.albums.single.availability, AlbumAvailability.unindexed);
    access.reading = const DirectoryReading(
      DirectoryContents.needsAuthorization,
      '待授权',
    );
    await org.refreshDirectories();
    expect(org.albums.single.availability, AlbumAvailability.unverified);
    expect(org.restoreAlbums, isEmpty);
    access.reading = const DirectoryReading(DirectoryContents.missing, '已缺失');
    await org.refreshDirectories();
    expect(org.albums.single.availability, AlbumAvailability.missing);
    expect(org.snapshot.descriptors, hasLength(1));
  });

  test(
    'refresh immediately invalidates a formerly verified empty result',
    () async {
      await org.createAlbum(rootFolder, parent, 'Refresh');
      access.readGate = Completer<DirectoryReading>();
      final refresh = org.refreshDirectories();
      expect(org.albums.single.availability, AlbumAvailability.unverified);
      access.readGate!.complete(
        const DirectoryReading(DirectoryContents.failed, '查询失败'),
      );
      await refresh;
      expect(org.albums.single.availability, AlbumAvailability.unverified);
    },
  );

  test('v1 export and restore round-trip empty albums, order and historical disposition with no shared writes', () async {
    await org.create(rootFolder, 'Trip');
    final folder = org.snapshot.children(rootFolder).single.id;
    await org.createAlbum(folder, parent, 'Empty');
    final key = org.albums.single.key;
    final history = org.creations.single.id;
    final fs = MemoryFavorites();
    final favorites = Favorites(fs, browser);
    await favorites.load();
    final originals = MatchMedia(), output = Output();
    final exporter = BackupExport(
      org,
      favorites,
      browser,
      originals,
      output,
      guard: guard,
    );
    final exported = await exporter.export(readOriginals: false);
    expect(exported.saved, isTrue);
    final decoded = const BackupCodec().decode(
      const BackupCodec().encode(output.captured!),
    );
    expect(decoded.albums, hasLength(1));
    expect(decoded.albums.single.sourceKey, key);
    expect(decoded.organization.albumOrders[folder], [
      decoded.albums.single.id,
    ]);
    expect(decoded.favorites, isEmpty);
    final restore = BackupRestore(
      org,
      favorites,
      browser,
      originals,
      Input(),
      originals,
      Journal(),
      guard: guard,
    );
    await restore.initialize();
    final preview = await restore.preview(decoded, {
      decoded.albums.single.id: key,
    }, readOriginals: false);
    await restore.apply(preview);
    await org.refreshDirectories();
    expect(org.snapshot.parentOfAlbum(key), folder);
    expect(org.albums.single.availability, AlbumAvailability.empty);
    expect(org.creations.single.id, history);
    expect(access.writes, 1);
    // Missing target stays private pending; restore must never create it.
    final pending = await restore.preview(decoded, {
      decoded.albums.single.id: null,
    }, readOriginals: false);
    await restore.apply(pending);
    expect(org.snapshot.descriptors.values.single.pending, isTrue);
    expect(access.writes, 1);
    expect(org.creations.single.id, history);
    restore.dispose();
    favorites.dispose();
  });

  testWidgets(
    'empty album detail follows current directory state and becomes the photo grid without reopening',
    (tester) async {
      await tester.runAsync(
        () => org.createAlbum(rootFolder, parent, 'Detail'),
      );
      final key = org.albums.single.key;
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryShell(
            organization: org,
            browser: browser,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('album-panel-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(find.text('已核对真实空目录 · 0 项'), findsOneWidget);
      expect(find.text('相册当前不可访问'), findsNothing);
      access.readGate = Completer<DirectoryReading>();
      final refreshing = org.refreshDirectories();
      await tester.pump();
      expect(find.textContaining('0 项'), findsNothing);
      expect(find.text('目录状态正在核对'), findsOneWidget);
      access.readGate!.complete(
        const DirectoryReading(DirectoryContents.failed, '查询失败'),
      );
      await refreshing;
      access.readGate = null;
      for (final reading in [
        const DirectoryReading(
          DirectoryContents.needsAuthorization,
          '目录授权已失效，状态待核对',
        ),
        const DirectoryReading(DirectoryContents.failed, '目录查询失败，状态待核对'),
        const DirectoryReading(DirectoryContents.missing, '已确认目录缺失；私有归类保留'),
        const DirectoryReading(
          DirectoryContents.content,
          '目录含内容，尚无可访问照片；可刷新媒体索引',
        ),
      ]) {
        access.reading = reading;
        await tester.runAsync(org.refreshDirectories);
        await tester.pumpAndSettle();
        expect(find.text(reading.reason), findsOneWidget);
        expect(find.textContaining('0 项'), findsNothing);
      }
      access.reading = const DirectoryReading(DirectoryContents.empty, '真实空目录');
      await tester.runAsync(org.refreshDirectories);
      await tester.pumpAndSettle();
      expect(find.text('已核对真实空目录 · 0 项'), findsOneWidget);
      media.image = () async => base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
      );
      media.items = [photo(19, directory: 'Pictures/Tests/Detail/')];
      await tester.runAsync(browser.refresh);
      await tester.pumpAndSettle();
      expect(find.byType(PhotoTile), findsOneWidget);
      expect(find.textContaining('0 项'), findsNothing);
      expect(org.albums, hasLength(1));
      expect(org.albums.single.key, key);
      expect(access.writes, 1);
    },
  );

  for (final control in {'LF': '\n', 'CR': '\r', 'TAB': '\t'}.entries) {
    testWidgets(
      'physical form preserves IME ${control.key} and rejects it before any write',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: PhysicalAlbumPage(organization: org, parent: rootFolder),
          ),
        );
        await tester.tap(find.text('选择真实父目录'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), parent.path);
        await tester.tap(find.text('打开系统选择器并授权'));
        await tester.pumpAndSettle();
        final field = find.byType(TextField);
        await tester.showKeyboard(field);
        final raw = 'Bad${control.value}Name';
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: raw,
            selection: TextSelection.collapsed(offset: raw.length),
          ),
        );
        await tester.pump();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          raw,
        );
        await tester.tap(find.text('确认建立真实相册'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('不能包含控制字符'), findsOneWidget);
        expect(access.writes, 0);
        expect(access.opens, 0);
        expect(store.records, isEmpty);
        expect(org.snapshot.descriptors, isEmpty);
      },
    );
  }

  testWidgets(
    'unknown record has direct private-only disposition and retains historical label',
    (tester) async {
      access.result = DirectoryCreationResult.unknown;
      await tester.runAsync(
        () => org.createAlbum(rootFolder, parent, 'Unknown'),
      );
      await tester.pumpWidget(
        MaterialApp(home: CreationReviewPage(organization: org)),
      );
      expect(find.textContaining('无法确认上次创建结果'), findsWidgets);
      await tester.tap(find.text('不再处理'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不删除'), findsWidgets);
      await tester.tap(find.text('结束跟进'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
      expect(org.creations.single.outcome, CreationOutcome.unknown);
      expect(org.creations.single.resolution, CreationResolution.dismissed);
      expect(access.writes, 1);
    },
  );
}
