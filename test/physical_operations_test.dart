import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/backup/backup_codec.dart';
import 'package:phototree/backup/backup_export.dart';
import 'package:phototree/backup/backup_restore.dart';
import 'package:phototree/backup/private_snapshot.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/library/physical_operations.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/media/physical_media.dart';
import 'package:phototree/organization/organization.dart';
import 'package:phototree/storage/directory_access.dart';
import 'package:phototree/storage/operation_guard.dart';

import 'backup_export_test.dart' show Output;
import 'backup_restore_test.dart' as restore_fakes;
import 'library_views_test.dart' show MemoryFavorites;
import 'media_browser_test.dart' show FakeMedia, photo;
import 'organization_test.dart' show MemoryOrganization;

PhysicalPhotoSnapshot snap(Photo p) => PhysicalPhotoSnapshot(
  photo: p,
  libraryVersion: 'test-library',
  displayName: '${p.id}.${p.kind == MediaKind.video ? 'mp4' : 'jpg'}',
  size: 32,
  mimeType: p.kind == MediaKind.video ? 'video/mp4' : 'image/jpeg',
  modifiedSeconds: 1,
  generationModified: 1,
  sha256: 'a' * 64,
);

class Journal implements PhysicalJournal {
  final data = <String, PhysicalBatch>{};
  int writes = 0;
  int? failAt;
  bool failRead = false, loseResponse = false;
  @override
  Future<List<PhysicalBatch>> read() async {
    if (failRead) throw StateError('read');
    return data.values.toList();
  }

  @override
  Future<void> save(PhysicalBatch b) async {
    writes++;
    if (writes == failAt) throw StateError('write');
    data[b.id] = PhysicalBatch.decode(b.encode());
    if (loseResponse) throw StateError('response');
  }

  @override
  Future<void> close() async {}
}

class Access implements PhysicalMediaAccess {
  final authorizationGroups = <List<PhysicalPhotoSnapshot>>[];
  Future<PhysicalResult> Function()? authorizing;
  PhysicalOutcome authorizationOutcome = PhysicalOutcome.confirmed;
  PhysicalOutcome pendingAuthorization = PhysicalOutcome.confirmed;
  @override
  Future<PhysicalResult> authorizePhotos(
    List<PhysicalPhotoSnapshot> photos,
  ) async {
    authorizationGroups.add(List.of(photos));
    return await authorizing?.call() ?? PhysicalResult(authorizationOutcome);
  }

  @override
  Future<PhysicalOutcome> authorizationState() async => pendingAuthorization;
  int writes = 0, reconciles = 0, directoryWrites = 0, directoryReads = 0;
  List<Photo> photos = [];
  Future<PhysicalResult> Function()? action;
  PhysicalOutcome reconcileOutcome = PhysicalOutcome.confirmed;
  PhysicalOutcome directoryOutcome = PhysicalOutcome.confirmed;
  PhysicalResult? reconcileResult;
  Future<void> Function()? inspecting;
  Future<void> Function()? preparing;
  final preparationSizes = <int>[];
  final preparationTargets = <String?>[];
  PhysicalOutcome preparationOutcome = PhysicalOutcome.confirmed;
  @override
  Future<PhysicalPreparation> prepare(
    List<Photo> photos,
    String version, {
    String? targetDirectory,
  }) async {
    preparationSizes.add(photos.length);
    preparationTargets.add(targetDirectory);
    await preparing?.call();
    return PhysicalPreparation(
      preparationOutcome,
      photos: photos.map(snap).toList(),
    );
  }

  @override
  Future<PhysicalAlbumInspection> inspectAlbum(
    String volume,
    String path,
  ) async {
    await inspecting?.call();
    return PhysicalAlbumInspection(
      PhysicalOutcome.confirmed,
      photos: photos.map(snap).toList(),
      empty: photos.isEmpty,
      directoryToken: 'token',
    );
  }

  @override
  Future<PhysicalResult> executePhoto(
    PhysicalKind kind,
    PhysicalPhotoSnapshot snapshot, {
    String? targetDirectory,
    bool authorized = false,
  }) async {
    writes++;
    return action == null
        ? const PhysicalResult(PhysicalOutcome.confirmed)
        : await action!();
  }

  @override
  Future<PhysicalResult> reconcilePhoto(
    PhysicalKind kind,
    PhysicalPhotoSnapshot snapshot, {
    String? targetDirectory,
  }) async {
    reconciles++;
    return reconcileResult ?? PhysicalResult(reconcileOutcome);
  }

  @override
  Future<PhysicalResult> deleteEmptyAlbum(
    String volume,
    String path, {
    required String directoryToken,
  }) async {
    directoryWrites++;
    return PhysicalResult(directoryOutcome);
  }

  @override
  Future<PhysicalResult> reconcileEmptyAlbum(
    String volume,
    String path, {
    required String directoryToken,
  }) async {
    directoryReads++;
    return PhysicalResult(reconcileOutcome);
  }
}

class Harness {
  Harness({this.directories});
  final PhysicalDirectoryAccess? directories;
  final media = FakeMedia()..items = [photo(1), photo(2)];
  late final browser = PhotoBrowser(media);
  final fs = MemoryFavorites();
  final os = MemoryOrganization();
  final journal = Journal();
  final access = Access();
  final guard = BackupOperationGuard();
  late final favorites = Favorites(fs, browser, guard: guard);
  late final organization = Organization(
    os,
    browser,
    directories: directories,
    operationGuard: guard,
  );
  late final ops = PhysicalOperations(
    organization,
    favorites,
    browser,
    access,
    journal,
    guard: guard,
  );
  Future<void> init() async {
    await browser.refresh();
    fs.records.addAll(
      media.items.map((p) => favoriteIdentity(p, media.version)!),
    );
    await favorites.load();
    await organization.load();
    await ops.initialize();
  }

  void dispose() {
    ops.dispose();
    organization.dispose();
    favorites.dispose();
    browser.dispose();
  }
}

class PendingCreationOrganization extends Organization {
  PendingCreationOrganization(
    super.store,
    super.browser, {
    super.operationGuard,
  });
  @override
  String? get creationIssue => 'Unresolved creation';
}

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.init();
  });
  tearDown(() => h.dispose());
  test('preview holds all writers, cancellation creates no journal or native effects', () async {
    await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
    expect(h.ops.preview, isNotNull);
    expect(h.guard.held, true);
    expect(h.favorites.held, true);
    expect(h.organization.busy, true);
    expect(() => h.guard.acquire(Object()), throwsStateError);
    h.ops.cancelPreview();
    expect(h.guard.held, false);
    expect(h.journal.writes, 0);
    expect(h.access.writes, 0);
    await h.ops.preparePhotos(
      h.media.items,
      kind: PhysicalKind.move,
      targetDirectory: 'Pictures/B/',
    );
    expect(h.ops.preview, isNotNull);
    expect(h.guard.held, true);
    h.ops.cancelPreview();
    expect(h.access.writes, 0);
    expect(h.guard.held, false);
  });
  test(
    'intent is durable before native and confirmed private cleanup is precise',
    () async {
      await h.ops.preparePhotos([
        h.media.items.first,
      ], kind: PhysicalKind.delete);
      h.access.action = () async {
        expect(
          h.journal.data.values.single.items.single.state,
          PhysicalItemState.inFlight,
        );
        expect(
          h.organization.snapshot.descriptors.containsKey(
            h.media.items.first.albumKey,
          ),
          true,
        );
        return const PhysicalResult(PhysicalOutcome.confirmed);
      };
      await h.ops.execute();
      expect(h.access.writes, 1);
      expect(h.fs.records, {
        favoriteIdentity(h.media.items.last, h.media.version),
      });
      expect(h.ops.records.single.items.single.privateCommitted, true);
      expect(h.guard.held, false);
    },
  );
  test('cancel during current request finishes it and cancels only remaining items', () async {
    final wait = Completer<PhysicalResult>();
    h.access.action = () => wait.future;
    await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
    final execution = h.ops.execute();
    while (h.access.writes == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    h.ops.cancelRemaining();
    wait.complete(const PhysicalResult(PhysicalOutcome.confirmed));
    await execution;
    expect(h.access.writes, 1);
    expect(h.ops.records.single.items.map((i) => i.outcome), [
      PhysicalOutcome.confirmed,
      PhysicalOutcome.cancelled,
    ]);
    expect(h.fs.records, {
      favoriteIdentity(h.media.items.last, h.media.version),
    });
  });
  test('album never removes directory after partial failure', () async {
    h.access.photos = h.media.items;
    h.access.action = () async => PhysicalResult(
      h.access.writes == 1
          ? PhysicalOutcome.confirmed
          : PhysicalOutcome.permission,
    );
    await h.ops.prepareAlbum(
      const DirectoryIdentity('external_primary', 'Pictures/A/'),
    );
    await h.ops.execute();
    expect(h.access.directoryWrites, 0);
    expect(h.ops.records.single.directoryOutcome, PhysicalOutcome.cancelled);
    expect(h.ops.records.single.items.map((i) => i.outcome), [
      PhysicalOutcome.confirmed,
      PhysicalOutcome.permission,
    ]);
    expect(h.ops.blocked, false);
  });
  test(
    'album removes directory only after each confirmed private commit',
    () async {
      h.access.photos = h.media.items;
      await h.ops.prepareAlbum(
        const DirectoryIdentity('external_primary', 'Pictures/A/'),
      );
      await h.ops.execute();
      expect(h.access.directoryWrites, 1);
      expect(h.ops.records.single.directoryPrivateCommitted, true);
      expect(h.fs.records, isEmpty);
      expect(h.organization.snapshot.descriptors, isEmpty);
    },
  );
  test(
    'empty album has journaled directory execution and no photo request',
    () async {
      await h.ops.prepareAlbum(
        const DirectoryIdentity('external_primary', 'Pictures/Empty/'),
      );
      await h.ops.execute();
      expect(h.access.writes, 0);
      expect(h.access.directoryWrites, 1);
      expect(h.ops.records.single.directoryPrivateCommitted, true);
    },
  );
  test('failed intent save blocks before any native; reconcile cancels durable queued item', () async {
    h.journal.failAt = 2;
    await h.ops.preparePhotos([h.media.items.first], kind: PhysicalKind.delete);
    await h.ops.execute();
    expect(h.access.writes, 0);
    expect(h.ops.blocked, true);
    expect(h.guard.held, true);
    h.journal.failAt = null;
    await h.ops.reconcile();
    expect(h.ops.blocked, false);
    expect(h.access.writes, 0);
    expect(
      h.ops.records.single.items.single.outcome,
      PhysicalOutcome.cancelled,
    );
  });
  test('lost result persistence reconciles once without replaying destructive request', () async {
    h.access.action = () async {
      h.journal.failAt = h.journal.writes + 1;
      return const PhysicalResult(PhysicalOutcome.confirmed);
    };
    await h.ops.preparePhotos([h.media.items.first], kind: PhysicalKind.delete);
    await h.ops.execute();
    expect(h.access.writes, 1);
    expect(h.ops.blocked, true);
    expect(h.fs.records.length, 2);
    h.journal.failAt = null;
    await h.ops.reconcile();
    expect(h.access.writes, 1);
    expect(h.access.reconciles, 1);
    expect(h.ops.records.single.items.single.privateCommitted, true);
    expect(h.fs.records.length, 1);
    expect(h.guard.held, false);
  });
  test(
    'private failure blocks and reconcile applies private delta only',
    () async {
      h.access.action = () async {
        h.fs.failWrite = true;
        return const PhysicalResult(PhysicalOutcome.confirmed);
      };
      await h.ops.preparePhotos([
        h.media.items.first,
      ], kind: PhysicalKind.delete);
      await h.ops.execute();
      expect(h.ops.blocked, true);
      expect(h.guard.held, true);
      h.ops.cancelPreview();
      expect(h.guard.held, true);
      expect(h.favorites.held, true);
      expect(h.organization.busy, true);
      expect(
        h.ops.records.single.items.single.outcome,
        PhysicalOutcome.confirmed,
      );
      h.fs.failWrite = false;
      await h.ops.reconcile();
      expect(h.access.writes, 1);
      expect(h.access.reconciles, 0);
      expect(h.fs.records.length, 1);
    },
  );
  test(
    'source descriptor write failure causes zero native execution',
    () async {
      h.os.failWrite = true;
      await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
      await h.ops.execute();
      expect(h.access.writes, 0);
      expect(h.ops.blocked, true);
      h.os.failWrite = false;
      await h.ops.reconcile();
      expect(h.access.writes, 0);
      expect(h.ops.blocked, false);
    },
  );
  test('restart only observes in-flight and unknown, cancels queued, keeps committed history', () async {
    final a = snap(h.media.items.first), b = snap(h.media.items.last);
    h.journal.data['one'] = PhysicalBatch(
      id: 'one',
      kind: PhysicalKind.delete,
      items: [
        PhysicalItem(snapshot: a, state: PhysicalItemState.inFlight),
        PhysicalItem(snapshot: b),
      ],
    );
    await h.ops.initialize();
    expect(h.access.writes, 0);
    expect(h.access.reconciles, 1);
    expect(h.ops.records.single.items.last.outcome, PhysicalOutcome.cancelled);
    // A later restored private record must not be deleted by historical cleanup.
    h.fs.records.add(favoriteIdentity(a.photo, a.libraryVersion)!);
    await h.favorites.load();
    await h.ops.initialize();
    expect(
      h.fs.records.contains(favoriteIdentity(a.photo, a.libraryVersion)),
      true,
    );
    expect(h.access.reconciles, 1);
  });
  test(
    'unknown is persisted and releases guard without inventing confirmation',
    () async {
      h.access.action = () async =>
          const PhysicalResult(PhysicalOutcome.unknown);
      h.access.reconcileOutcome = PhysicalOutcome.unknown;
      await h.ops.preparePhotos([
        h.media.items.first,
      ], kind: PhysicalKind.delete);
      await h.ops.execute();
      await h.ops.reconcile();
      expect(h.guard.held, false);
      expect(h.ops.blocked, false);
      expect(h.fs.records.length, 2);
      expect(h.access.writes, 1);
      expect(h.access.reconciles, 1);
    },
  );
  test(
    'unknown retains retryability across temporary permission loss',
    () async {
      h.access.action = () async =>
          const PhysicalResult(PhysicalOutcome.unknown);
      await h.ops.preparePhotos([
        h.media.items.first,
      ], kind: PhysicalKind.delete);
      await h.ops.execute();
      h.access.reconcileOutcome = PhysicalOutcome.permission;
      await h.ops.reconcile();
      expect(
        h.ops.records.single.items.single.outcome,
        PhysicalOutcome.unknown,
      );
      expect(h.ops.blocked, false);
      h.access.reconcileOutcome = PhysicalOutcome.confirmed;
      await h.ops.reconcile();
      expect(h.ops.records.single.items.single.privateCommitted, true);
      expect(h.access.writes, 1);
      expect(h.access.reconciles, 2);
    },
  );

  test(
    'corrupt or unreadable journal retains owners until successful recovery',
    () async {
      h.journal.failRead = true;
      await h.ops.reconcile();
      expect(h.ops.blocked, true);
      expect(h.guard.held, true);
      expect(h.favorites.held, true);
      h.journal.failRead = false;
      await h.ops.reconcile();
      expect(h.ops.blocked, false);
      expect(h.guard.held, false);
    },
  );
  for (final outcome in [PhysicalOutcome.cancelled, PhysicalOutcome.unknown]) {
    test(
      '$outcome stops subsequent system requests and publishes progress',
      () async {
        h.access.action = () async => PhysicalResult(outcome);
        var sawInFlight = false;
        h.ops.addListener(() {
          if (h.ops.records.any(
            (b) => b.items.any((i) => i.state == PhysicalItemState.inFlight),
          )) {
            sawInFlight = true;
          }
        });
        await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
        await h.ops.execute();
        expect(sawInFlight, true);
        expect(h.access.writes, 1);
        expect(
          h.ops.records.single.items.last.outcome,
          PhysicalOutcome.cancelled,
        );
        expect(h.fs.records.length, 2);
      },
    );
  }

  test(
    'album permission shrink during inspection cannot publish a preview',
    () async {
      h.access.photos = h.media.items;
      h.access.inspecting = () async {
        h.media.access = PhotoAccess.limited;
        await h.browser.refresh();
      };
      await h.ops.prepareAlbum(
        const DirectoryIdentity('external_primary', 'Pictures/A/'),
      );
      expect(h.ops.preview, isNull);
      expect(h.guard.held, false);
      expect(h.access.writes, 0);
    },
  );

  test(
    'creation recovery issue does not deadlock physical journal startup',
    () async {
      final org = PendingCreationOrganization(
        MemoryOrganization(),
        h.browser,
        operationGuard: h.guard,
      );
      await org.load();
      final ops = PhysicalOperations(
        org,
        h.favorites,
        h.browser,
        h.access,
        Journal(),
        guard: h.guard,
      );
      addTearDown(ops.dispose);
      addTearDown(org.dispose);
      await ops.initialize();
      expect(ops.initialized, true);
      expect(ops.blocked, false);
      await ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
      expect(ops.preview, isNull);
      expect(h.guard.held, false);
    },
  );

  test(
    'actual backup and restore reject physical preview and retain its barrier',
    () async {
      final media = restore_fakes.MatchMedia();
      final output = Output();
      final exporter = BackupExport(
        h.organization,
        h.favorites,
        h.browser,
        media,
        output,
        guard: h.guard,
      );
      final restore = BackupRestore(
        h.organization,
        h.favorites,
        h.browser,
        media,
        restore_fakes.Input(),
        media,
        restore_fakes.Journal(),
        guard: h.guard,
      );
      addTearDown(restore.dispose);
      await restore.initialize();
      final document = BackupDocument(
        organization: OrganizationSnapshot([], {}),
        albums: [],
        favorites: [],
      );
      final preview = await restore.preview(document, {});
      await h.ops.preparePhotos([
        h.media.items.first,
      ], kind: PhysicalKind.delete);
      await expectLater(
        exporter.export(readOriginals: false),
        throwsStateError,
      );
      await expectLater(restore.apply(preview), throwsStateError);
      expect(output.captured, isNull);
      expect(h.guard.held, true);
      expect(h.favorites.held, true);
      h.ops.cancelPreview();
      await restore.apply(preview);
      expect(restore.blocked, false);
    },
  );

  test('actual private rollback restores historical favorite without cleanup replay', () async {
    final before = PrivateSnapshot(
      h.organization.snapshot,
      h.favorites.snapshot,
    );
    await h.ops.preparePhotos([h.media.items.first], kind: PhysicalKind.delete);
    await h.ops.execute();
    final media = restore_fakes.MatchMedia();
    final journal = restore_fakes.Journal()..rollback = before;
    final restore = BackupRestore(
      h.organization,
      h.favorites,
      h.browser,
      media,
      restore_fakes.Input(),
      media,
      journal,
      guard: h.guard,
    );
    addTearDown(restore.dispose);
    await restore.initialize();
    await restore.apply(await restore.rollbackPreview());
    expect(h.fs.records.length, 2);
    await h.ops.reconcile();
    expect(h.fs.records.length, 2);
    expect(h.access.writes, 1);
    expect(h.access.reconciles, 0);
  });

  test('actual restore write phase prevents physical preparation', () async {
    final media = restore_fakes.MatchMedia();
    final entered = Completer<void>(), release = Completer<void>();
    final restore = BackupRestore(
      h.organization,
      h.favorites,
      h.browser,
      media,
      restore_fakes.Input(),
      media,
      restore_fakes.Journal(),
      guard: h.guard,
      checkpoint: (point) async {
        if (point == 'before-prepare') {
          entered.complete();
          await release.future;
        }
      },
    );
    addTearDown(restore.dispose);
    await restore.initialize();
    final document = BackupDocument(
      organization: OrganizationSnapshot([], {}),
      albums: [],
      favorites: [],
    );
    final preview = await restore.preview(document, {});
    final apply = restore.apply(preview);
    await entered.future;
    await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
    expect(h.ops.preview, isNull);
    expect(h.access.writes, 0);
    expect(h.guard.held, true);
    release.complete();
    await apply;
    expect(h.guard.held, false);
  });

  PhysicalPhotoSnapshot moved(
    Photo p, {
    String target = 'Pictures/B/',
    String name = 'collision (1).jpg',
  }) {
    final old = snap(p);
    return PhysicalPhotoSnapshot(
      photo: Photo(
        id: p.id,
        directory: target,
        volume: p.volume,
        takenMs: p.takenMs,
        addedSeconds: p.addedSeconds,
        width: p.width,
        height: p.height,
      ),
      libraryVersion: old.libraryVersion,
      displayName: name,
      size: old.size,
      mimeType: old.mimeType,
      modifiedSeconds: 2,
      generationModified: 2,
      sha256: old.sha256,
    );
  }

  test('large batch prepares bounded chunks and cancellation stops subsequent chunks', () async {
    h.media.items = [for (var n = 1; n <= 501; n++) photo(n)];
    await h.browser.refresh();
    await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
    expect(h.access.preparationSizes.length, 11);
    expect(h.access.preparationSizes.every((n) => n <= 50), true);
    expect(h.ops.preview!.items.length, 501);
    h.ops.cancelPreview();
    h.access.preparationSizes.clear();
    h.access.preparing = () async {
      h.ops.cancelRemaining();
    };
    await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
    expect(h.access.preparationSizes, [50]);
    expect(h.ops.preview, isNull);
    expect(h.journal.writes, 0);
    expect(h.access.writes, 0);
    expect(h.guard.held, false);
  });

  test(
    'unsupported source fails before journal or native preparation',
    () async {
      h.media.items = [photo(7, directory: 'Download/Photos/')];
      await h.browser.refresh();
      await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
      expect(h.ops.preview, isNull);
      expect(h.journal.writes, 0);
      expect(h.access.writes, 0);
      expect(h.ops.issue, contains('Pictures'));
      expect(h.ops.blocked, false);
    },
  );

  test('move target permission failure prevents preview and all durable or native writes', () async {
    h.access.preparationOutcome = PhysicalOutcome.permission;
    await h.ops.preparePhotos(
      h.media.items,
      kind: PhysicalKind.move,
      targetDirectory: 'Pictures/B/',
    );
    expect(h.access.preparationTargets, ['Pictures/B/']);
    expect(h.ops.preview, isNull);
    expect(h.journal.writes, 0);
    expect(h.access.writes, 0);
    expect(h.guard.held, false);
    expect(h.ops.blocked, false);
  });

  test('move records actual conflict suffix and preserves private favorite provenance', () async {
    final p = h.media.items.first;
    final identity = favoriteIdentity(p, h.media.version)!;
    h.fs.records.remove(identity);
    h.fs.unresolved = [
      PendingFavorite(
        identity: identity,
        albumKey: p.albumKey,
        filename: 'old.jpg',
        size: 32,
        sha256: 'a' * 64,
        reason: 'awaiting_system_confirmation',
        source: 'both',
      ),
    ];
    h.fs.migrationOutcomes = {identity: 'cancelled'};
    await h.favorites.load();
    final after = moved(p);
    h.access.action = () async =>
        PhysicalResult(PhysicalOutcome.confirmed, after: after);
    await h.ops.preparePhotos(
      [p],
      kind: PhysicalKind.move,
      targetDirectory: 'Pictures/B/',
    );
    expect(h.ops.preview!.targetDirectory, 'Pictures/B/');
    await h.ops.execute();
    expect(
      h.ops.records.single.items.single.after!.displayName,
      'collision (1).jpg',
    );
    final pending = h.favorites.snapshot.pending.single;
    expect(pending.albumKey, after.photo.albumKey);
    expect(pending.filename, after.displayName);
    expect(pending.source, 'both');
    expect(pending.sha256, 'a' * 64);
    expect(pending.size, 32);
    expect(h.favorites.snapshot.migrationOutcomes[identity], 'cancelled');
    expect(h.favorites.snapshot.confirmed, {
      favoriteIdentity(h.media.items.last, h.media.version),
    });
    expect(
      h.organization.snapshot.descriptors.keys,
      containsAll([p.albumKey, after.photo.albumKey]),
    );
  });

  test(
    'same album is finally validated as unchanged without favorite cleanup',
    () async {
      final before = Set<String>.of(h.fs.records);
      h.access.action = () async =>
          const PhysicalResult(PhysicalOutcome.unchanged);
      await h.ops.preparePhotos(
        h.media.items,
        kind: PhysicalKind.move,
        targetDirectory: 'Pictures/A/',
      );
      await h.ops.execute();
      expect(h.access.writes, 2); // Read-only final-validation channel calls.
      expect(h.fs.records, before);
      expect(
        h.ops.records.single.items.every(
          (i) => i.outcome == PhysicalOutcome.unchanged && !i.privateCommitted,
        ),
        true,
      );
      await h.ops.reconcile();
      expect(h.access.reconciles, 0);
      expect(h.fs.records, before);
    },
  );

  test(
    'move partial cancellation retains first success and stops later requests',
    () async {
      h.media.items.add(photo(3));
      await h.browser.refresh();
      h.access.action = () async => h.access.writes == 1
          ? PhysicalResult(
              PhysicalOutcome.confirmed,
              after: moved(h.media.items.first),
            )
          : const PhysicalResult(PhysicalOutcome.cancelled);
      await h.ops.preparePhotos(
        h.media.items,
        kind: PhysicalKind.move,
        targetDirectory: 'Pictures/B/',
      );
      await h.ops.execute();
      expect(h.access.writes, 2);
      expect(h.ops.records.single.items.map((i) => i.outcome), [
        PhysicalOutcome.confirmed,
        PhysicalOutcome.cancelled,
        PhysicalOutcome.cancelled,
      ]);
      expect(h.fs.records.length, 2);
    },
  );

  test('interrupted same album validation reconciles unchanged without private edits', () async {
    final p = h.media.items.first;
    h.journal.data['same'] = PhysicalBatch(
      id: 'same',
      kind: PhysicalKind.move,
      targetDirectory: p.directory,
      items: [
        PhysicalItem(snapshot: snap(p), state: PhysicalItemState.inFlight),
      ],
    );
    h.access.reconcileResult = const PhysicalResult(PhysicalOutcome.unchanged);
    await h.ops.reconcile();
    expect(
      h.ops.records.single.items.single.outcome,
      PhysicalOutcome.unchanged,
    );
    expect(h.ops.records.single.items.single.privateCommitted, false);
    expect(h.access.writes, 0);
    expect(h.access.reconciles, 1);
    expect(h.fs.records.length, 2);
    await h.ops.reconcile();
    expect(h.access.reconciles, 1);
  });

  test(
    'interrupted move only reconciles matching after without repeating write',
    () async {
      final p = h.media.items.first;
      h.journal.data['move'] = PhysicalBatch(
        id: 'move',
        kind: PhysicalKind.move,
        targetDirectory: 'Pictures/B/',
        items: [
          PhysicalItem(snapshot: snap(p), state: PhysicalItemState.inFlight),
        ],
      );
      h.access.reconcileResult = PhysicalResult(
        PhysicalOutcome.confirmed,
        after: moved(p),
      );
      await h.ops.reconcile();
      expect(h.access.writes, 0);
      expect(h.access.reconciles, 1);
      expect(h.ops.records.single.items.single.privateCommitted, true);
      expect(h.fs.records.length, 2);
    },
  );

  test('move confirmation with wrong target remains unknown and stops remaining items', () async {
    h.access.action = () async => PhysicalResult(
      PhysicalOutcome.confirmed,
      after: moved(h.media.items.first, target: 'Pictures/Wrong/'),
    );
    await h.ops.preparePhotos(
      h.media.items,
      kind: PhysicalKind.move,
      targetDirectory: 'Pictures/B/',
    );
    await h.ops.execute();
    expect(h.access.writes, 1);
    expect(h.ops.records.single.items.first.outcome, PhysicalOutcome.unknown);
    expect(h.ops.records.single.items.first.privateCommitted, false);
    expect(h.fs.records.length, 2);
  });

  test(
    'active platform photo keeps all barriers until observation is idle',
    () async {
      h.access.action = () async => const PhysicalResult(PhysicalOutcome.busy);
      await h.ops.preparePhotos(h.media.items, kind: PhysicalKind.delete);
      await h.ops.execute();
      expect(h.ops.blocked, true);
      expect(h.guard.held, true);
      expect(h.favorites.held, true);
      expect(h.organization.busy, true);
      expect(h.access.writes, 1);
      expect(h.fs.records.length, 2);
      expect(h.ops.records.single.items.first.outcome, PhysicalOutcome.unknown);
      expect(h.ops.records.single.items.last.state, PhysicalItemState.queued);
      h.ops.cancelPreview();
      expect(h.guard.held, true);
      h.access.reconcileOutcome = PhysicalOutcome.busy;
      await h.ops.reconcile();
      expect(h.ops.blocked, true);
      expect(h.guard.held, true);
      expect(h.access.writes, 1);
      h.access.reconcileOutcome = PhysicalOutcome.confirmed;
      await h.ops.reconcile();
      expect(h.ops.blocked, false);
      expect(h.guard.held, false);
      expect(h.access.writes, 1);
      expect(h.fs.records.length, 1);
      expect(h.ops.records.single.items.first.privateCommitted, true);
      expect(
        h.ops.records.single.items.last.outcome,
        PhysicalOutcome.cancelled,
      );
    },
  );

  test('active directory retains guard; idle unknown releases without cleanup or replay', () async {
    h.access.directoryOutcome = PhysicalOutcome.busy;
    await h.ops.prepareAlbum(
      const DirectoryIdentity('external_primary', 'Pictures/Empty/'),
    );
    await h.ops.execute();
    expect(h.ops.blocked, true);
    expect(h.guard.held, true);
    expect(h.ops.records.single.directoryOutcome, PhysicalOutcome.unknown);
    expect(h.ops.records.single.directoryPrivateCommitted, false);
    h.access.reconcileOutcome = PhysicalOutcome.busy;
    await h.ops.reconcile();
    expect(h.ops.blocked, true);
    expect(h.favorites.held, true);
    expect(h.organization.busy, true);
    h.access.reconcileOutcome = PhysicalOutcome.unknown;
    await h.ops.reconcile();
    expect(h.ops.blocked, false);
    expect(h.guard.held, false);
    expect(h.access.directoryWrites, 1);
    expect(h.ops.records.single.directoryPrivateCommitted, false);
    expect(
      h.organization.snapshot.descriptors.containsKey(
        'external_primary:Pictures/Empty/',
      ),
      true,
    );
  });

  test(
    'codec rejects impossible phases, private completion and extra fields',
    () {
      final b = PhysicalBatch(
        id: 'x',
        kind: PhysicalKind.delete,
        items: [PhysicalItem(snapshot: snap(h.media.items.first))],
      );
      expect(PhysicalBatch.decode(b.encode()).encode(), b.encode());
      final data = jsonDecode(b.encode()) as Map<String, dynamic>;
      data['items'][0]['privateCommitted'] = true;
      expect(
        () => PhysicalBatch.decode(jsonEncode(data)),
        throwsFormatException,
      );
      data['items'][0]['privateCommitted'] = false;
      data['extra'] = true;
      expect(
        () => PhysicalBatch.decode(jsonEncode(data)),
        throwsFormatException,
      );
    },
  );
}
