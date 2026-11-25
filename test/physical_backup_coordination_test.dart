import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/backup/backup_codec.dart';
import 'package:phototree/backup/backup_export.dart';
import 'package:phototree/backup/backup_restore.dart';
import 'package:phototree/backup/private_snapshot.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/system_favorites.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/storage/directory_access.dart';
import 'package:phototree/storage/operation_guard.dart';

import 'album_creation_test.dart' show CreationStore, PhysicalAccess;
import 'backup_restore_test.dart' show Journal, MatchMedia;
import 'library_views_test.dart' show MemoryFavorites;
import 'media_browser_test.dart' show FakeMedia;
import 'system_favorites_test.dart' show FakeSystem;

class _Gate {
  final entered = Completer<void>(), released = Completer<void>();
  Future<void> hold() async {
    if (!entered.isCompleted) entered.complete();
    await released.future;
  }
}

class _Output implements BackupOutput {
  _Gate? gate;
  int calls = 0;
  @override
  Future<bool> save(Uint8List bytes) async {
    calls++;
    const BackupCodec().decode(bytes);
    await gate?.hold();
    return true;
  }
}

class _Input implements BackupInput {
  _Gate? gate;
  int calls = 0;
  @override
  Future<Uint8List?> open() async {
    calls++;
    await gate?.hold();
    return null;
  }

  @override
  Future<void> cancel() async {
    if (gate != null && !gate!.released.isCompleted) gate!.released.complete();
  }
}

class _Favorites extends MemoryFavorites {
  int replacements = 0;
  @override
  Future<void> replace(FavoriteSnapshot snapshot) async {
    replacements++;
    await super.replace(snapshot);
  }
}

class _Harness {
  final source = FakeMedia()
    ..items = [
      const Photo(id: 10, directory: 'Pictures/A/', systemFavorite: false),
    ];
  final system = FakeSystem();
  late final browser = PhotoBrowser(source);
  final store = CreationStore(), favoriteStore = _Favorites();
  final directories = PhysicalAccess(), guard = BackupOperationGuard();
  final journal = Journal(), media = MatchMedia();
  final input = _Input(), output = _Output();
  _Gate? applyGate;
  late final org = Organization(
    store,
    browser,
    directories: directories,
    operationGuard: guard,
  );
  late final favorites = Favorites(
    favoriteStore,
    browser,
    system: system,
    guard: guard,
  );
  late final exporter = BackupExport(
    org,
    favorites,
    browser,
    media,
    output,
    guard: guard,
  );
  late final restore = BackupRestore(
    org,
    favorites,
    browser,
    media,
    input,
    media,
    journal,
    guard: guard,
    checkpoint: (point) async {
      if (point == 'before-prepare') await applyGate?.hold();
    },
  );

  Future<void> initialize() async {
    await browser.refresh();
    await restore.initialize();
    expect(restore.blocked, false);
    expect(org.physicalCreationAvailable, true);
  }

  Future<String?> create(String name) => org.createAlbum(
    rootFolder,
    const DirectoryIdentity('external_primary', 'Pictures/Coordination/'),
    name,
  );

  BackupDocument get document => BackupDocument(
    organization: OrganizationSnapshot(
      [const AlbumFolder('imported', rootFolder, 'Imported')],
      {},
      folderOrders: {
        rootFolder: ['imported'],
        'imported': [],
      },
    ),
    albums: [],
    favorites: [],
  );

  Future<RestorePreview> preview() => restore.preview(document, {});

  PrivateSnapshot get stored => PrivateSnapshot(
    store.data,
    FavoriteSnapshot(favoriteStore.records, favoriteStore.unresolved),
  );

  List<int> get writes => [
    store.writes,
    favoriteStore.writes,
    favoriteStore.replacements,
    journal.prepares,
    directories.opens,
    directories.writes,
  ];

  void close() {
    restore.dispose();
    org.dispose();
    favorites.dispose();
    browser.dispose();
  }
}

void main() {
  const busy = '另一项媒体、备份或恢复操作正在进行';
  final guardError = throwsA(
    isA<StateError>().having((error) => error.message, 'reason', busy),
  );
  late _Harness h;
  setUp(() async {
    h = _Harness();
    await h.initialize();
  });
  tearDown(() => h.close());

  test('system confirmation excludes real backup coordinators and creation without releasing its guard', () async {
    final preview = await h.preview();
    final gate = _Gate();
    h.system.action = (_, _) async {
      await gate.hold();
      return const SystemFavoriteResult(SystemFavoriteOutcome.cancelled);
    };
    final saving = h.favorites.set(h.source.items.single, true);
    await gate.entered.future;
    final counts = h.writes;
    await expectLater(h.exporter.export(readOriginals: false), guardError);
    await expectLater(h.restore.choose(), guardError);
    await expectLater(h.restore.apply(preview), guardError);
    expect(await h.create('Rejected'), busy);
    expect(h.writes, counts);
    expect(h.system.calls, 1);
    expect(h.input.calls, 0);
    expect(h.output.calls, 0);
    gate.released.complete();
    await saving;
    expect(
      h.favorites.resultFor(h.source.items.single),
      SystemFavoriteOutcome.cancelled,
    );
    expect((await h.exporter.export(readOriginals: false)).saved, true);
    await h.restore.apply(await h.preview());
    expect(await h.create('After'), isNull);
    expect(h.directories.writes, 1);
    expect(h.system.calls, 1);
  });

  test('unknown live favorite blocks coordinators until read-only completion check', () async {
    final preview = await h.preview();
    h.system.action = (_, _) async {
      h.system.pendingRequest = true;
      return const SystemFavoriteResult(
        SystemFavoriteOutcome.unknown,
        pending: true,
      );
    };
    await h.favorites.set(h.source.items.single, true);
    final counts = h.writes;
    await expectLater(h.exporter.export(readOriginals: false), guardError);
    await expectLater(h.restore.choose(), guardError);
    await expectLater(h.restore.apply(preview), guardError);
    expect(await h.create('Blocked'), busy);
    expect(h.writes, counts);
    h.system.pendingRequest = null;
    expect(await h.favorites.reconcileSystemRequest(), false);
    await expectLater(h.exporter.export(readOriginals: false), guardError);
    h.system.pendingRequest = false;
    expect(await h.favorites.reconcileSystemRequest(), true);
    expect(
      h.favorites.resultFor(h.source.items.single),
      SystemFavoriteOutcome.unknown,
    );
    expect((await h.exporter.export(readOriginals: false)).saved, true);
    await h.restore.apply(await h.preview());
    expect(await h.create('Available'), isNull);
    expect(h.system.calls, 1);
  });

  test('startup pending check defers real private recovery until system completion', () async {
    final restarted = _Harness();
    try {
      await restarted.browser.refresh();
      final identity = favoriteIdentity(
        restarted.source.items.single,
        restarted.browser.libraryVersion,
      )!;
      restarted.favoriteStore.migrationOutcomes[identity] = 'unknown';
      restarted.system.pendingRequest = true;
      final counts = restarted.writes;
      // This is the same explicit composition order as app startup; the
      // coordinators and private installation are real, the stores are fixtures.
      Future<void> initializeWhenClear() async {
        if (await restarted.favorites.reconcileSystemRequest()) {
          await restarted.restore.initialize();
        }
      }

      await initializeWhenClear();
      expect(restarted.restore.initialized, false);
      expect(restarted.restore.blocked, false);
      expect(restarted.guard.held, true);
      expect(restarted.writes, counts);
      restarted.system.pendingRequest = null;
      await initializeWhenClear();
      expect(restarted.restore.initialized, false);
      expect(restarted.guard.held, true);
      restarted.system.pendingRequest = false;
      await initializeWhenClear();
      expect(restarted.restore.initialized, true);
      expect(restarted.restore.blocked, false);
      expect(restarted.org.physicalCreationAvailable, true);
      expect(restarted.favorites.phase, FavoritePhase.ready);
      expect(
        restarted.favorites.resultFor(restarted.source.items.single),
        SystemFavoriteOutcome.unknown,
      );
      expect(restarted.guard.held, false);
      expect(restarted.system.calls, 0);
      expect(await restarted.create('AfterPending'), isNull);
    } finally {
      restarted.close();
    }
  });

  test('physical creation excludes actual export, input, restore and rollback calls', () async {
    await h.org.create(rootFolder, 'Before');
    await h.restore.apply(await h.preview());
    final rollback = await h.restore.rollbackPreview();
    final preview = await h.preview();
    final gate = _Gate();
    h.store.intentGate = gate.hold;
    final creation = h.create('Held');
    await gate.entered.future;
    final before = h.stored, counts = h.writes;
    final records = Map.of(h.store.records);

    await h.favorites.set(h.source.items.single, true);
    expect(h.system.calls, 0);
    expect(
      h.favorites.resultFor(h.source.items.single),
      SystemFavoriteOutcome.busy,
    );
    await expectLater(h.exporter.export(readOriginals: false), guardError);
    await expectLater(h.restore.choose(), guardError);
    await expectLater(h.preview(), guardError);
    await expectLater(h.restore.apply(preview), guardError);
    await expectLater(h.restore.rollbackPreview(), guardError);
    await expectLater(h.restore.apply(rollback), guardError);
    expect(h.writes, counts);
    expect(h.stored.same(before), true);
    expect(h.store.records, records);
    expect(h.input.calls, 0);
    expect(h.output.calls, 0);

    gate.released.complete();
    expect(await creation, isNull);
    expect(h.directories.writes, 1);
    expect((await h.exporter.export(readOriginals: false)).saved, true);
    expect(await h.restore.choose(), isNull);
    await h.restore.apply(await h.preview());
    await h.restore.apply(await h.restore.rollbackPreview());
    expect(h.directories.writes, 1);
  });

  for (final owner in ['export', 'input']) {
    test('$owner holds the shared guard against physical creation until it ends', () async {
      final gate = _Gate();
      if (owner == 'export') {
        h.output.gate = gate;
      } else {
        h.input.gate = gate;
      }
      final operation = owner == 'export'
          ? h.exporter.export(readOriginals: false)
          : h.restore.choose();
      await gate.entered.future;
      final before = h.stored, counts = h.writes;
      await h.favorites.set(h.source.items.single, true);
      expect(h.system.calls, 0);
      expect(
        h.favorites.resultFor(h.source.items.single),
        SystemFavoriteOutcome.busy,
      );
      expect(await h.create('Rejected'), busy);
      expect(h.writes, counts);
      expect(h.store.records, isEmpty);
      expect(h.stored.same(before), true);
      // Rejection must not accidentally release the other coordinator's owner.
      if (owner == 'export') {
        await expectLater(h.restore.choose(), guardError);
      } else {
        await expectLater(h.exporter.export(readOriginals: false), guardError);
      }
      gate.released.complete();
      await operation;
      await h.favorites.set(h.source.items.single, true);
      expect(h.system.calls, 1);
      expect(await h.create('After'), isNull);
      expect(h.directories.writes, 1);
    });
  }

  for (final rollback in [false, true]) {
    test(
      '${rollback ? 'rollback' : 'restore'} apply excludes creation and releases its own guard',
      () async {
        await h.org.create(rootFolder, 'Before');
        if (rollback) await h.restore.apply(await h.preview());
        final preview = rollback
            ? await h.restore.rollbackPreview()
            : await h.preview();
        final gate = _Gate();
        h.applyGate = gate;
        final applying = h.restore.apply(preview);
        await gate.entered.future;
        final before = h.stored, counts = h.writes;
        await h.favorites.set(h.source.items.single, true);
        expect(h.system.calls, 0);
        expect(await h.create('Rejected'), '组织数据或目录能力尚不可用');
        await expectLater(h.exporter.export(readOriginals: false), guardError);
        expect(h.writes, counts);
        expect(h.store.records, isEmpty);
        expect(h.stored.same(before), true);
        gate.released.complete();
        await applying;
        expect(h.stored.same(preview.target), true);
        await h.favorites.set(h.source.items.single, true);
        expect(h.system.calls, 1);
        expect(await h.create('After'), isNull);
        expect(h.directories.writes, 1);
        expect((await h.exporter.export(readOriginals: false)).saved, true);
      },
    );
  }
}
