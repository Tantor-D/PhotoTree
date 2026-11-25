import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/backup/backup_codec.dart';
import 'package:phototree/backup/backup_export.dart';
import 'package:phototree/backup/backup_restore.dart';
import 'package:phototree/backup/private_snapshot.dart';
import 'package:phototree/backup/restore_journal.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/media/media_source.dart';
import 'package:phototree/organization/organization.dart';

import 'library_views_test.dart' show MemoryFavorites;
import 'organization_test.dart' show MemoryOrganization;
import 'media_browser_test.dart' show FakeMedia, photo;
import 'backup_export_test.dart' show Output;
import 'system_favorites_test.dart' show FakeSystem;

class Input implements BackupInput {
  Uint8List? bytes;
  Object? error;
  Completer<Uint8List?>? wait;
  int cancels = 0;
  @override
  Future<Uint8List?> open() async {
    if (error != null) throw error!;
    return wait == null ? bytes : wait!.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (wait?.isCompleted == false) wait!.complete(null);
  }
}

class MatchMedia implements OriginalReader, RestoreMedia {
  @override
  Future<String?> filename(Photo p, String version) async =>
      'file-${p.id}.${p.kind == MediaKind.video ? "mp4" : "jpg"}';
  final hashes = <int, String>{};
  final sizes = <int, int>{};
  final readIds = <int>[];
  Completer<int>? sizeWait;
  Completer<void>? wait;
  void Function()? reading;
  @override
  Future<bool> permission({bool request = false}) async => true;
  @override
  Future<int> size(Photo p, String version) async {
    if (sizeWait != null) return sizeWait!.future;
    return sizes[p.id] ?? 10;
  }

  @override
  Future<OriginalFingerprint> read(Photo p, String version) async {
    readIds.add(p.id);
    await wait?.future;
    reading?.call();
    return OriginalFingerprint(
      BackupFingerprint(
        size: sizes[p.id] ?? 10,
        sha256: hashes[p.id] ?? 'a' * 64,
      ),
      'file.jpg',
    );
  }
}

class Journal implements RestoreJournal {
  RestoreOperation? active;
  PrivateSnapshot? rollback;
  String? fail;
  int prepares = 0;
  @override
  Future<RestoreJournalState> read() async {
    if (fail == 'read') throw StateError('journal corrupt');
    return RestoreJournalState(active, rollback);
  }

  @override
  Future<void> prepare(RestoreOperation operation) async {
    if (fail == 'prepare') throw StateError('journal full');
    prepares++;
    active = operation;
  }

  @override
  Future<void> decide(String id) async {
    if (fail == 'decide') throw StateError('decision full');
    active = RestoreOperation(id, active!.before, active!.target, true);
  }

  @override
  Future<void> finish(String id) async {
    if (fail == 'finish') throw StateError('cleanup full');
    if (active!.committed) rollback = active!.before;
    active = null;
  }

  @override
  Future<void> close() async {}
}

class Harness {
  Harness({this.system});
  final FakeSystem? system;
  final source = FakeMedia()
    ..items = [photo(10), photo(11), photo(12, directory: 'Pictures/B/')];
  late final browser = PhotoBrowser(source);
  final os = MemoryOrganization(), fs = MemoryFavorites();
  late final org = Organization(os, browser);
  late final fav = Favorites(fs, browser, system: system);
  final journal = Journal(),
      media = MatchMedia(),
      input = Input(),
      guard = BackupOperationGuard();
  String? failPoint;
  Completer<void>? checkpointWait;
  String? waitPoint;
  late final restore = BackupRestore(
    org,
    fav,
    browser,
    media,
    input,
    media,
    journal,
    guard: guard,
    checkpoint: (point) async {
      if (point == waitPoint) await checkpointWait!.future;
      if (point == failPoint) {
        failPoint = null;
        throw StateError(point);
      }
    },
  );
  Future<void> init() async {
    await browser.refresh();
    await restore.initialize();
  }

  PrivateSnapshot get state => PrivateSnapshot(org.snapshot, fav.snapshot);
  void close() {
    restore.dispose();
    org.dispose();
    fav.dispose();
    browser.dispose();
  }

  BackupDocument document({bool fingerprint = true, bool rootOnly = false}) =>
      BackupDocument(
        organization: OrganizationSnapshot(
          rootOnly ? [] : [const AlbumFolder('f', rootFolder, 'Imported')],
          rootOnly ? {} : {'a': 'f'},
          folderOrders: rootOnly
              ? {}
              : {
                  rootFolder: ['f'],
                  'f': [],
                },
          albumOrders: rootOnly
              ? {}
              : {
                  'f': ['a'],
                },
        ),
        albums: [
          const BackupAlbum(
            id: 'a',
            sourceKey: 'external_primary:Old/',
            name: 'Old',
            directory: 'Old/',
          ),
        ],
        favorites: [
          BackupFavorite(
            identity: favoriteIdentity(photo(1), 'old-library')!,
            albumId: 'a',
            filename: 'old.jpg',
            fingerprint: fingerprint
                ? BackupFingerprint(size: 10, sha256: 'a' * 64)
                : null,
            unresolvedReason: fingerprint
                ? null
                : 'original_permission_declined',
          ),
        ],
      );
}

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.init();
  });
  tearDown(() => h.close());

  test('choosing a backup rejects the legacy identifier before restore', () async {
    await h.org.create(rootFolder, 'Existing folder');
    await h.fav.set(photo(10), true);
    final before = h.state;
    final current = const BackupCodec().encode(h.document());
    final legacy = jsonDecode(utf8.decode(current)) as Map<String, dynamic>;
    legacy['format'] = 'hashphoto-organization-backup';
    h.input.bytes = utf8.encode(jsonEncode(legacy));

    await expectLater(h.restore.choose(), throwsFormatException);
    expect(h.state.same(before), isTrue);
    expect(h.journal.prepares, 0);

    h.input.bytes = current;
    final document = await h.restore.choose();
    expect(document!.organization.folders['f']!.name, 'Imported');
    expect(h.state.same(before), isTrue);
  });

  test(
    'source metadata survives reload export exact rollback and removal',
    () async {
      final id = favoriteIdentity(photo(10), h.browser.libraryVersion)!;
      await h.fs.replace(FavoriteSnapshot([id], [], {}, {id: 'system'}));
      await h.fav.load();
      final before = h.state;
      expect(PrivateSnapshot.decode(before.encode()).same(before), true);
      final out = await BackupExport(
        h.org,
        h.fav,
        h.browser,
        h.media,
        Output(),
      ).export(readOriginals: false);
      expect(out.document.favorites.single.source, 'system');
      expect(out.document.favorites.single.systemFavorite, isNull);
      await h.fav.set(photo(10), false);
      expect(h.fav.snapshot.sources, isEmpty);
      await h.fav.set(photo(10), true);
      expect(h.fav.snapshot.sources, isEmpty);
      await h.fs.replace(before.favorites);
      await h.fav.load();
      await h.fav.holdForBackup();
      await h.fav.commitPhysicalChange(deletedIdentities: {id});
      h.fav.releaseBackup();
      expect(h.fav.snapshot.sources, isEmpty);
      expect(h.fav.snapshot.confirmed, isEmpty);
    },
  );
  test(
    'two records matching one target remain pending in both orders',
    () async {
      h.source.items = [photo(10)];
      await h.browser.refresh();
      final base = h.document();
      final records = [
        base.favorites.single,
        BackupFavorite(
          identity: favoriteIdentity(photo(2), 'old-library')!,
          albumId: 'a',
          source: 'system',
          fingerprint: BackupFingerprint(size: 10, sha256: 'a' * 64),
        ),
      ];
      for (final list in [records, records.reversed.toList()]) {
        final doc = BackupDocument(
          organization: base.organization,
          albums: base.albums,
          favorites: list,
        );
        final p = await h.restore.preview(doc, {'a': photo(10).albumKey});
        expect(p.resolvedFavorites, 0);
        expect(
          p.target.favorites.pending.map((f) => f.reason),
          everyElement('target_conflict'),
        );
        expect(
          p.target.favorites.pending.map((f) => f.identity).toSet(),
          records.map((f) => f.identity).toSet(),
        );
        await expectLater(
          h.restore.preview(
            doc,
            {'a': photo(10).albumKey},
            manualPhotos: {
              records.first.identity: favoriteIdentity(
                photo(10),
                h.browser.libraryVersion,
              )!,
            },
          ),
          throwsStateError,
        );
        expect(h.journal.prepares, 0);
      }
    },
  );
  test(
    'unresolved identity is reserved against another record resolving to it',
    () async {
      final target = h.source.items.first;
      final identity = favoriteIdentity(target, h.browser.libraryVersion)!;
      final other = favoriteIdentity(h.source.items.last, 'older')!;
      final doc = BackupDocument(
        organization: OrganizationSnapshot([], {}),
        albums: [const BackupAlbum(id: 'wrong', name: 'Wrong directory')],
        favorites: [
          BackupFavorite(
            identity: identity,
            albumId: 'wrong',
            filename: 'reserved.jpg',
            unresolvedReason: 'missing_fingerprint',
            source: 'system',
          ),
          BackupFavorite(
            identity: other,
            filename: 'manual.jpg',
            unresolvedReason: 'missing_fingerprint',
          ),
        ],
      );
      await expectLater(
        h.restore.preview(
          doc,
          {'wrong': h.source.items.last.albumKey},
          manualPhotos: {other: identity},
        ),
        throwsA(isA<RestoreProblem>()),
      );
      expect(h.journal.prepares, 0);
    },
  );

  test(
    'unchanged reassociation leaves previous rollback and journal untouched',
    () async {
      final before = h.state;
      final preview = await h.restore.pendingPreview({});
      expect(preview.target.same(before), true);
      await h.restore.apply(preview);
      expect(h.journal.prepares, 0);
      expect(h.journal.rollback, isNull);
      expect(h.restore.status, contains('暂无可提交'));
      expect(h.restore.busy, false);
    },
  );
  test(
    'private source validation rejects orphan unknown and redundant defaults',
    () {
      for (final sources in [
        {'orphan': 'system'},
        {'id': 'unknown'},
        {'id': 'legacy'},
      ]) {
        expect(
          () => FavoriteSnapshot(['id'], [], {}, sources),
          throwsStateError,
        );
      }
      final old = PrivateSnapshot(
        OrganizationSnapshot([], {}),
        FavoriteSnapshot(['id']),
      );
      expect(old.encode(), isNot(contains('sources')));
      expect(PrivateSnapshot.decode(old.encode()).same(old), true);
    },
  );
  test(
    'video restore never matches an image with the same size and hash',
    () async {
      const video = Photo(id: 1, directory: 'Old/', kind: MediaKind.video);
      final base = h.document();
      final document = BackupDocument(
        organization: base.organization,
        albums: base.albums,
        favorites: [
          BackupFavorite(
            identity: favoriteIdentity(video, 'old-library')!,
            mediaKind: MediaKind.video,
            albumId: 'a',
            fingerprint: BackupFingerprint(size: 10, sha256: 'a' * 64),
          ),
        ],
      );
      final before = h.state;
      final preview = await h.restore.preview(document, {
        'a': photo(10).albumKey,
      });
      expect(preview.resolvedFavorites, 0);
      expect(h.media.readIds, isEmpty);
      expect(h.state.same(before), true);
      await expectLater(
        h.restore.preview(
          document,
          {'a': photo(10).albumKey},
          manualPhotos: {
            document.favorites.single.identity: favoriteIdentity(
              photo(10),
              h.browser.libraryVersion,
            )!,
          },
        ),
        throwsA(isA<RestoreProblem>()),
      );
      expect(h.journal.prepares, 0);
      expect(h.state.same(before), true);
    },
  );
  test(
    'preview never writes; whole replacement and exact confirmed rollback',
    () async {
      await h.org.create(rootFolder, 'before');
      await h.fav.set(photo(10), true);
      final before = h.state;
      h.media.hashes[11] = 'b' * 64;
      final p = await h.restore.preview(h.document(), {
        'a': photo(10).albumKey,
      });
      expect(h.state.same(before), true);
      expect(h.journal.prepares, 0);
      expect(p.resolvedFavorites, 1);
      expect(p.target.favorites.pending, isEmpty);
      expect(p.pendingFavorites, 0);
      await h.restore.apply(p);
      expect(h.org.snapshot.folders.keys, ['f']);
      expect(h.fav.contains(photo(10)), true);
      expect(h.journal.rollback!.same(before), true);
      final rollback = await h.restore.rollbackPreview();
      await h.restore.apply(rollback);
      expect(h.state.same(before), true);
    },
  );
  test('size filters hashing; duplicate or partial subset never silently resolves changed identity', () async {
    h.media.sizes[11] = 20;
    var p = await h.restore.preview(h.document(), {'a': photo(10).albumKey});
    expect(h.media.readIds, [10]);
    expect(p.resolvedFavorites, 1);
    expect(p.target.favorites.pending, isEmpty);
    h.media.sizes[11] = 10;
    h.media.readIds.clear();
    p = await h.restore.preview(h.document(), {'a': photo(10).albumKey});
    expect(p.target.favorites.pending.single.reason, 'duplicate_content');
    h.source.access = PhotoAccess.limited;
    h.source.items = [photo(10)];
    await h.browser.refresh();
    h.media.readIds.clear();
    p = await h.restore.preview(h.document(), {'a': photo(10).albumKey});
    expect(
      p.target.favorites.pending.single.reason,
      'partial_access_requires_choice',
    );
    expect(h.media.readIds, isEmpty);
    p = await h.restore.preview(
      h.document(),
      {'a': photo(10).albumKey},
      manualPhotos: {
        h.document().favorites.single.identity: favoriteIdentity(
          photo(10),
          h.browser.libraryVersion,
        )!,
      },
    );
    expect(p.resolvedFavorites, 1);
    expect(p.target.favorites.pending, isEmpty);
  });
  test('missing root descriptors and pending fingerprints survive restart-like reload and export', () async {
    final p = await h.restore.preview(h.document(rootOnly: true), {'a': null});
    await h.restore.apply(p);
    expect(h.org.snapshot.placements, isEmpty);
    expect(h.org.snapshot.descriptors.length, 1);
    await h.org.load();
    await h.fav.load();
    final output = Output();
    final export = BackupExport(
      h.org,
      h.fav,
      h.browser,
      h.media,
      output,
      guard: h.guard,
    );
    final result = await export.export(readOriginals: false);
    expect(result.document.albums.where((a) => a.pending).length, 1);
    expect(result.document.favorites.single.fingerprint!.sha256, 'a' * 64);
    expect(result.pendingFavorites, 1);
    expect(result.document.unresolvedCount, 0);
  });
  test('reassociation uses current dissolved tree and removes only automatic root discovery slot', () async {
    final p = await h.restore.preview(h.document(), {'a': null});
    await h.restore.apply(p);
    final pending = h.org.snapshot.descriptors.keys.single;
    await h.org.dissolve(h.org.previewDissolution('f'));
    expect(h.org.snapshot.albumOrders[rootFolder], contains(pending));
    h.media.hashes[11] = 'b' * 64;
    final next = await h.restore.pendingPreview({pending: photo(10).albumKey});
    await h.restore.apply(next);
    expect(h.org.snapshot.folders, isEmpty);
    expect(h.org.snapshot.placements, isEmpty);
    expect(
      h.org.snapshot.albumOrders[rootFolder]!
          .where((k) => k == photo(10).albumKey)
          .length,
      1,
    );
    expect(h.fav.snapshot.pending, isEmpty);
    expect(h.fav.contains(photo(10)), true);
  });
  test('explicit placement conflict and duplicate album choices reject without writes', () async {
    final d = h.document();
    final two = BackupDocument(
      organization: OrganizationSnapshot([], {}),
      albums: [
        ...d.albums,
        const BackupAlbum(id: 'b'),
      ],
      favorites: [],
    );
    await expectLater(
      h.restore.preview(two, {
        'a': photo(10).albumKey,
        'b': photo(10).albumKey,
      }),
      throwsStateError,
    );
    expect(h.journal.prepares, 0);
  });
  test(
    'private edit or queued write after preview rejects before prepare',
    () async {
      final p = await h.restore.preview(h.document(), {'a': null});
      await h.org.create(rootFolder, 'new edit');
      await expectLater(h.restore.apply(p), throwsStateError);
      expect(h.journal.prepares, 0);
      final q = await h.restore.preview(h.document(), {'a': null});
      h.fs.pending = Completer<void>();
      final write = h.fav.set(photo(10), true);
      final apply = h.restore.apply(q);
      final failure = expectLater(apply, throwsStateError);
      h.fs.pending!.complete();
      await write;
      await failure;
      expect(h.fav.contains(photo(10)), true);
      expect(h.journal.prepares, 0);
    },
  );
  test('unnotified permission change, hashing invalidation and native rematch changes reject', () async {
    h.media.hashes[11] = 'b' * 64;
    var p = await h.restore.preview(h.document(), {'a': photo(10).albumKey});
    h.source.access = PhotoAccess.limited;
    await expectLater(h.restore.apply(p), throwsStateError);
    expect(h.journal.prepares, 0);
    h.source.access = PhotoAccess.full;
    p = await h.restore.preview(h.document(), {'a': photo(10).albumKey});
    h.media.hashes[10] = 'c' * 64;
    await expectLater(h.restore.apply(p), throwsStateError);
    expect(h.journal.prepares, 0);
    h.media.reading = h.browser.suspend;
    await expectLater(
      h.restore.preview(h.document(), {'a': photo(10).albumKey}),
      throwsStateError,
    );
  });
  for (final boundary in [
    'before-prepare',
    'prepared',
    'organization-written',
    'favorites-written',
    'targets-verified',
    'decision-written',
    'published',
  ]) {
    test('deterministic rollback or target after $boundary failure', () async {
      await h.org.create(rootFolder, 'before');
      final id = favoriteIdentity(
        h.source.items.first,
        h.browser.libraryVersion,
      )!;
      await h.fs.replace(FavoriteSnapshot([id], [], {}, {id: 'both'}));
      await h.fav.load();
      final before = h.state;
      final p = await h.restore.preview(h.document(), {'a': null});
      h.failPoint = boundary;
      if (['decision-written', 'published'].contains(boundary)) {
        await h.restore.apply(p);
        expect(h.state.same(p.target), true);
      } else {
        await expectLater(h.restore.apply(p), throwsStateError);
        expect(h.state.same(before), true);
      }
      expect(h.restore.blocked, false);
      expect(h.org.busy, false);
      expect(h.journal.active, isNull);
    });
  }
  test('failed second replacement retains previous rollback; committed cleanup failure gates until retry', () async {
    await h.org.create(rootFolder, 'original');
    final old = h.state;
    var p = await h.restore.preview(h.document(), {'a': null});
    await h.restore.apply(p);
    h.journal.fail = 'decide';
    p = await h.restore.preview(h.document(rootOnly: true), {'a': null});
    await expectLater(h.restore.apply(p), throwsStateError);
    expect(h.journal.rollback!.same(old), true);
    h.journal.fail = 'finish';
    p = await h.restore.preview(h.document(rootOnly: true), {'a': null});
    await expectLater(h.restore.apply(p), throwsStateError);
    expect(h.restore.blocked, true);
    final export = BackupExport(
      h.org,
      h.fav,
      h.browser,
      h.media,
      Output(),
      guard: h.guard,
    );
    await expectLater(export.export(readOriginals: false), throwsStateError);
    expect(await h.org.create(rootFolder, 'blocked'), isNotNull);
    h.journal.fail = null;
    await h.restore.retryRecovery();
    expect(h.restore.blocked, false);
    expect(h.state.same(p.target), true);
  });
  test('startup corrupt journal blocks owners before any load/discovery; replay decision selects both stores', () async {
    final fresh = Harness();
    fresh.journal.fail = 'read';
    await fresh.init();
    expect(fresh.restore.blocked, true);
    expect(fresh.org.phase, OrganizationPhase.loading);
    expect(fresh.fav.phase, FavoritePhase.loading);
    expect(fresh.os.writes, 0);
    fresh.journal.fail = null;
    await fresh.restore.retryRecovery();
    expect(fresh.restore.initialized, true);
    fresh.close();
    final before = h.state;
    final p = await h.restore.preview(h.document(), {'a': null});
    await h.os.replace(p.target.organization);
    h.journal.active = RestoreOperation('crash', before, p.target, false);
    await h.restore.retryRecovery();
    expect(h.state.same(before), true);
    h.journal.active = RestoreOperation('committed', before, p.target, true);
    await h.restore.retryRecovery();
    expect(h.state.same(p.target), true);
  });
  test('cancel choose/preview releases guard and old completion cannot publish or release a new operation', () async {
    h.input.wait = Completer<Uint8List?>();
    final choosing = h.restore.choose();
    final cancelled = expectLater(choosing, throwsStateError);
    h.restore.cancelPreview();
    await cancelled;
    expect(h.restore.busy, false);
    expect(h.input.cancels, 1);
    h.media.wait = Completer<void>();
    final preview = h.restore.preview(h.document(), {'a': photo(10).albumKey});
    await Future<void>.delayed(Duration.zero);
    h.restore.cancelPreview();
    final failed = expectLater(preview, throwsStateError);
    final output = Output()..delay = Completer<void>();
    final export = BackupExport(
      h.org,
      h.fav,
      h.browser,
      h.media,
      output,
      guard: h.guard,
    );
    final exporting = export.export(readOriginals: false);
    h.media.wait!.complete();
    await failed;
    await expectLater(
      h.restore.preview(h.document(), {'a': null}),
      throwsStateError,
    );
    output.delay!.complete();
    await exporting;
    expect(h.journal.prepares, 0);
  });
  test('double apply rejected and leaving page cannot cancel confirmed prepared operation', () async {
    final p = await h.restore.preview(h.document(), {'a': null});
    h.waitPoint = 'prepared';
    h.checkpointWait = Completer<void>();
    final applying = h.restore.apply(p);
    await Future<void>.delayed(Duration.zero);
    h.restore.cancelPreview();
    expect(h.restore.busy, true);
    await expectLater(h.restore.apply(p), throwsStateError);
    h.checkpointWait!.complete();
    await applying;
    expect(h.journal.prepares, 1);
  });
  test('unnotified added duplicate rejects cached candidates before preview and confirmation', () async {
    h.source.items = [photo(10)];
    h.source.revision = 2;
    await h.browser.refresh();
    final p = await h.restore.preview(h.document(), {'a': photo(10).albumKey});
    expect(p.resolvedFavorites, 1);
    expect(p.target.favorites.pending, isEmpty);
    h.source.items.add(photo(11));
    h.source.revision = 3;
    await expectLater(h.restore.apply(p), throwsStateError);
    await expectLater(
      h.restore.preview(h.document(), {'a': photo(10).albumKey}),
      throwsStateError,
    );
    expect(h.journal.prepares, 0);
    await h.browser.refresh();
    final next = await h.restore.preview(h.document(), {
      'a': photo(10).albumKey,
    });
    expect(next.target.favorites.pending.single.reason, 'duplicate_content');
  });
  test(
    'browser refuses a collection changed during both full enumerations',
    () async {
      var reads = 0;
      h.source.query = (after) async {
        if (after == 0) {
          reads++;
          return [photo(10)];
        }
        h.source.revision = h.source.revision! + 1;
        return [];
      };
      await h.browser.refresh();
      expect(reads, 2);
      expect(h.browser.phase, BrowsePhase.failed);
      expect(h.browser.photos, isEmpty);
      expect(h.browser.collectionRevision, isNull);
    },
  );

  test('re-export describes resolved current directory and proposes it while old directory still exists', () async {
    h.source.items.add(photo(20, directory: 'Old/'));
    h.source.revision = 2;
    await h.browser.refresh();
    h.media.hashes[11] = 'b' * 64;
    final p = await h.restore.preview(h.document(), {'a': photo(10).albumKey});
    await h.restore.apply(p);
    final export = BackupExport(
      h.org,
      h.fav,
      h.browser,
      h.media,
      Output(),
      guard: h.guard,
    );
    final d = (await export.export(readOriginals: false)).document;
    final placed = d.albums.singleWhere(
      (a) => d.organization.placements[a.id] == 'f',
    );
    expect(placed.sourceKey, photo(10).albumKey);
    expect(placed.directory, photo(10).directory);
    expect(h.restore.proposals(d)[placed.id], photo(10).albumKey);
    final pending = await h.restore.preview(h.document(), {'a': null});
    await h.restore.apply(pending);
    final unresolved = (await export.export(readOriginals: false))
        .document
        .albums
        .singleWhere((a) => a.pending);
    expect(unresolved.sourceKey, 'external_primary:Old/');
  });

  test(
    'cancel during size await never starts a subsequent original hash',
    () async {
      h.media.sizeWait = Completer<int>();
      final pending = h.restore.preview(h.document(), {
        'a': photo(10).albumKey,
      });
      await Future<void>.delayed(Duration.zero);
      h.restore.cancelPreview();
      final rejected = expectLater(pending, throwsStateError);
      h.media.sizeWait!.complete(10);
      await rejected;
      expect(h.media.readIds, isEmpty);
      expect(h.restore.busy, false);
      expect(h.journal.prepares, 0);
    },
  );

  test('imported historical sources become private favorites and rollback without system writes', () async {
    h.close();
    final system = FakeSystem();
    h = Harness(system: system);
    await h.init();
    h.fs.migrationOutcomes['historical-record'] = 'unknown';
    await h.fav.load();
    final original = h.document();
    final d = BackupDocument(
      organization: original.organization,
      albums: original.albums,
      favorites: [
        BackupFavorite(
          identity: favoriteIdentity(photo(10), h.browser.libraryVersion)!,
          source: 'both',
          unresolvedReason: 'missing_fingerprint',
          albumId: 'a',
        ),
      ],
    );
    final before = h.state;
    final preview = await h.restore.preview(d, {'a': photo(10).albumKey});
    expect(preview.resolvedFavorites, 1);
    expect(preview.target.favorites.pending, isEmpty);
    expect(preview.target.favorites.sources.values, ['both']);
    await h.restore.apply(preview);
    expect(h.fav.snapshot.sources.values, ['both']);
    await h.fav.load();
    expect(h.fav.snapshot.sources.values, ['both']);
    expect(h.fav.snapshot.migrationOutcomes, {'historical-record': 'unknown'});
    expect(system.calls, 0);
    expect(h.restore.status, contains('收藏仅保存在 PhotoTree 内'));
    await h.restore.apply(await h.restore.rollbackPreview());
    expect(h.state.same(before), true);
    expect(system.calls, 0);
  });

  test(
    'private journal round trips migration outcomes and system pending sources',
    () {
      final snapshot = PrivateSnapshot(
        OrganizationSnapshot([], {}),
        FavoriteSnapshot(
          [],
          [
            const PendingFavorite(
              identity: 'opaque',
              reason: 'awaiting_system_confirmation',
              source: 'system',
            ),
          ],
          {'opaque': 'unknown'},
        ),
      );
      final restored = PrivateSnapshot.decode(snapshot.encode());
      expect(restored.same(snapshot), true);
      expect(restored.favorites.migrationOutcomes, {'opaque': 'unknown'});
      expect(restored.favorites.pending.single.source, 'system');
    },
  );

  test('local recovery decoder preserves optional empty order and rejects ambiguous/corrupt state', () {
    final snapshot = PrivateSnapshot(
      OrganizationSnapshot([], {}, albumOrders: {rootFolder: []}),
      FavoriteSnapshot(['legacy-opaque']),
    );
    expect(PrivateSnapshot.decode(snapshot.encode()).same(snapshot), true);
    expect(
      () => PrivateSnapshot.decode(
        snapshot.encode().replaceFirst(
          '"placements":{}',
          '"placements":{},"placements":{}',
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => FavoriteSnapshot(
        ['same'],
        [const PendingFavorite(identity: 'same', reason: 'pending')],
      ),
      throwsStateError,
    );
  });
}
