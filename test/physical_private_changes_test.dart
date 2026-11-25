import 'package:flutter_test/flutter_test.dart';
import 'package:phototree/library/favorites.dart';
import 'package:phototree/media/browser.dart';
import 'package:phototree/organization/organization.dart';

import 'library_views_test.dart' show MemoryFavorites;
import 'media_browser_test.dart' show FakeMedia;
import 'organization_test.dart' show MemoryOrganization;

class PhysicalFavoritesStore extends MemoryFavorites {
  bool loseResponse = false, corrupt = false;
  @override
  Future<void> replace(FavoriteSnapshot snapshot) async {
    await super.replace(snapshot);
    if (corrupt) records.add('unexpected');
    if (loseResponse) throw StateError('committed response lost');
  }
}

class PhysicalOrganizationStore extends MemoryOrganization {
  bool loseResponse = false, corrupt = false;
  @override
  Future<void> save(
    OrganizationSnapshot before,
    OrganizationSnapshot after,
  ) async {
    await super.save(before, after);
    if (corrupt) data = before;
    if (loseResponse) throw StateError('committed response lost');
  }
}

const album = 'external_primary:Pictures/A/';
const otherAlbum = 'external_primary:Pictures/B/';
const deleted = '["external_primary",7,"old",1,0,32,32]';
const reused = '["external_primary",7,"new",1,0,32,32]';
const moving = '["external_primary",8,"old",1,0,32,32]';

void main() {
  late PhotoBrowser browser;
  setUp(() => browser = PhotoBrowser(FakeMedia()));
  tearDown(() => browser.dispose());

  Future<Favorites> favorites(PhysicalFavoritesStore store) async {
    final owner = Favorites(store, browser);
    addTearDown(owner.dispose);
    await owner.load();
    return owner;
  }

  Future<Organization> organization(PhysicalOrganizationStore store) async {
    final owner = Organization(store, browser);
    addTearDown(owner.dispose);
    await owner.load();
    return owner;
  }

  test('physical methods require ready owners and explicit holds', () async {
    final f = Favorites(PhysicalFavoritesStore(), browser);
    final o = Organization(PhysicalOrganizationStore(), browser);
    addTearDown(f.dispose);
    addTearDown(o.dispose);
    await f.holdForBackup();
    await o.holdForBackup();
    await expectLater(f.commitPhysicalChange(), throwsStateError);
    await expectLater(o.commitPhysicalAlbumDeletion({album}), throwsStateError);
    f.releaseBackup();
    o.releaseBackup();
    await f.load();
    await o.load();
    await expectLater(f.commitPhysicalChange(), throwsStateError);
    await expectLater(o.commitPhysicalAlbumDeletion({album}), throwsStateError);
  });

  test('contradictory deltas fail without changing private state', () async {
    final s = PhysicalFavoritesStore()..records.add(deleted);
    final f = await favorites(s);
    await f.holdForBackup();
    await expectLater(
      f.commitPhysicalChange(
        deletedIdentities: {deleted},
        movedLocations: {deleted: (albumKey: otherAlbum, filename: 'x.jpg')},
      ),
      throwsArgumentError,
    );
    await expectLater(
      f.commitPhysicalChange(
        detachedAlbumKeys: {otherAlbum},
        movedLocations: {moving: (albumKey: otherAlbum, filename: 'x.jpg')},
      ),
      throwsArgumentError,
    );
    expect(await s.read(), {deleted});
  });

  test(
    'confirmed deletion removes exact identity only, retaining reused IDs',
    () async {
      final s = PhysicalFavoritesStore()
        ..records.addAll([deleted, reused])
        ..unresolved = [
          const PendingFavorite(
            identity: moving,
            albumKey: album,
            reason: 'unavailable',
          ),
        ]
        ..migrationOutcomes = {
          deleted: 'confirmed',
          reused: 'unknown',
          moving: 'cancelled',
        };
      final f = await favorites(s);
      await f.holdForBackup();
      await f.commitPhysicalChange(deletedIdentities: {deleted});
      expect(f.snapshot.confirmed, {reused});
      expect(f.snapshot.pending.single.identity, moving);
      expect(f.snapshot.migrationOutcomes, {
        reused: 'unknown',
        moving: 'cancelled',
      });
      await f.commitPhysicalChange(deletedIdentities: {deleted});
      expect(f.snapshot.confirmed, {reused});
      expect(f.held, true);
    },
  );

  test(
    'move changes only matched pending location and retains all provenance',
    () async {
      final hash = 'a' * 64;
      final s = PhysicalFavoritesStore()
        ..records.add(deleted)
        ..unresolved = [
          PendingFavorite(
            identity: moving,
            albumKey: album,
            filename: 'old.jpg',
            size: 12,
            sha256: hash,
            reason: 'awaiting_system_confirmation',
            source: 'both',
          ),
          const PendingFavorite(
            identity: reused,
            albumKey: album,
            reason: 'unknown',
            source: 'system',
          ),
        ]
        ..migrationOutcomes = {moving: 'cancelled', deleted: 'confirmed'};
      final f = await favorites(s);
      await f.holdForBackup();
      for (var i = 0; i < 2; i++) {
        await f.commitPhysicalChange(
          movedLocations: {
            moving: (albumKey: otherAlbum, filename: 'new (1).jpg'),
          },
        );
      }
      final p = f.snapshot.pending.first;
      expect(
        pendingData(p),
        pendingData(
          PendingFavorite(
            identity: moving,
            albumKey: otherAlbum,
            filename: 'new (1).jpg',
            size: 12,
            sha256: hash,
            reason: 'awaiting_system_confirmation',
            source: 'both',
          ),
        ),
      );
      expect(f.snapshot.pending.last.albumKey, album);
      expect(f.snapshot.confirmed, {deleted});
      expect(f.snapshot.migrationOutcomes, {
        moving: 'cancelled',
        deleted: 'confirmed',
      });
    },
  );

  test(
    'deleted album detaches unknown pending location without deleting history',
    () async {
      final s = PhysicalFavoritesStore()
        ..unresolved = [
          const PendingFavorite(
            identity: deleted,
            albumKey: album,
            reason: 'unavailable',
          ),
          const PendingFavorite(
            identity: moving,
            albumKey: album,
            filename: 'keep.jpg',
            reason: 'unknown',
            source: 'both',
          ),
          const PendingFavorite(
            identity: reused,
            albumKey: otherAlbum,
            reason: 'unknown',
            source: 'system',
          ),
        ]
        ..migrationOutcomes = {deleted: 'confirmed', moving: 'unknown'};
      final f = await favorites(s);
      await f.holdForBackup();
      for (var i = 0; i < 2; i++) {
        await f.commitPhysicalChange(
          deletedIdentities: {deleted},
          detachedAlbumKeys: {album},
        );
      }
      expect(f.snapshot.pending.map((p) => p.identity), [moving, reused]);
      expect(f.snapshot.pending.first.albumKey, isNull);
      expect(f.snapshot.pending.first.filename, 'keep.jpg');
      expect(f.snapshot.pending.first.source, 'both');
      expect(f.snapshot.pending.first.reason, 'unknown');
      expect(f.snapshot.pending.last.albumKey, otherAlbum);
      expect(f.snapshot.migrationOutcomes, {moving: 'unknown'});
    },
  );

  for (final kind in ['write', 'read', 'mismatch', 'lost-response']) {
    test(
      'favorites $kind failure keeps barrier and verifies before publishing',
      () async {
        final s = PhysicalFavoritesStore()..records.addAll([deleted, reused]);
        final f = await favorites(s);
        await f.holdForBackup();
        s.failWrite = kind == 'write';
        s.failRead = kind == 'read';
        s.corrupt = kind == 'mismatch';
        s.loseResponse = kind == 'lost-response';
        if (kind == 'lost-response') {
          await f.commitPhysicalChange(deletedIdentities: {deleted});
          expect(f.snapshot.confirmed, {reused});
        } else {
          await expectLater(
            f.commitPhysicalChange(deletedIdentities: {deleted}),
            throwsStateError,
          );
          expect(f.snapshot.confirmed, {deleted, reused});
          s.failWrite = s.failRead = s.corrupt = false;
          await f.commitPhysicalChange(deletedIdentities: {deleted});
          expect(f.snapshot.confirmed, {reused});
        }
        expect(f.held, true);
      },
    );
  }

  OrganizationSnapshot tree() => OrganizationSnapshot(
    [const AlbumFolder('folder', rootFolder, 'Folder')],
    {
      album: 'folder',
      otherAlbum: 'folder',
      'external_primary:Pictures/Hidden/': 'folder',
    },
    folderOrders: {
      rootFolder: ['folder'],
    },
    albumOrders: {
      'folder': [album, otherAlbum, 'external_primary:Pictures/Hidden/'],
      rootFolder: [],
    },
    descriptors: {
      album: const AlbumDescriptor(directory: 'Pictures/A/', pending: false),
      otherAlbum: const AlbumDescriptor(
        directory: 'Pictures/B/',
        pending: false,
      ),
    },
  );

  test(
    'remember real albums only adds missing descriptors without reorganizing',
    () async {
      final s = PhysicalOrganizationStore()..data = tree();
      final o = await organization(s);
      await expectLater(o.rememberPhysicalAlbums([]), throwsStateError);
      await o.holdForBackup();
      const freshKey = 'external_primary:Pictures/New/';
      const fresh = AlbumDescriptor(
        sourceKey: freshKey,
        directory: 'Pictures/New/',
        name: 'New',
        pending: false,
      );
      const existing = AlbumDescriptor(
        sourceKey: album,
        directory: 'Pictures/A/',
        name: 'Must not replace',
        pending: false,
      );
      final original = o.snapshot;
      for (var i = 0; i < 2; i++) {
        await o.rememberPhysicalAlbums([fresh, existing]);
      }
      expect(o.snapshot.descriptors.length, original.descriptors.length + 1);
      expect(o.snapshot.descriptors[freshKey], same(fresh));
      expect(o.snapshot.descriptors[album], same(original.descriptors[album]));
      expect(o.snapshot.placements, original.placements);
      expect(o.snapshot.albumOrders, original.albumOrders);
      expect(o.snapshot.folderOrders, original.folderOrders);
      await expectLater(
        o.rememberPhysicalAlbums([
          const AlbumDescriptor(
            sourceKey: freshKey,
            directory: 'Pictures/Wrong/',
            pending: false,
          ),
        ]),
        throwsArgumentError,
      );
      expect(o.snapshot.descriptors[freshKey], same(fresh));
    },
  );

  test(
    'remember write failure cannot publish an unpersisted source directory',
    () async {
      final s = PhysicalOrganizationStore();
      final o = await organization(s);
      await o.holdForBackup();
      s.failWrite = true;
      const descriptor = AlbumDescriptor(
        sourceKey: album,
        directory: 'Pictures/A/',
        pending: false,
      );
      await expectLater(
        o.rememberPhysicalAlbums([descriptor]),
        throwsStateError,
      );
      expect(o.snapshot.descriptors, isEmpty);
      expect(o.busy, true);
      s.failWrite = false;
      s.loseResponse = true;
      await o.rememberPhysicalAlbums([descriptor]);
      expect(o.snapshot.descriptors[album], same(descriptor));
    },
  );

  test(
    'album deletion preserves containers, empty orders and hidden other slots',
    () async {
      final s = PhysicalOrganizationStore()..data = tree();
      final o = await organization(s);
      await o.holdForBackup();
      for (var i = 0; i < 2; i++) {
        await o.commitPhysicalAlbumDeletion({album});
      }
      expect(o.snapshot.placements, {
        otherAlbum: 'folder',
        'external_primary:Pictures/Hidden/': 'folder',
      });
      expect(o.snapshot.descriptors.keys, [otherAlbum]);
      expect(o.snapshot.albumOrders, {
        'folder': [otherAlbum, 'external_primary:Pictures/Hidden/'],
        rootFolder: [],
      });
      expect(o.snapshot.folderOrders, {
        rootFolder: ['folder'],
      });
      expect(o.snapshot.folders['folder']!.name, 'Folder');
      expect(o.busy, true);
    },
  );

  for (final kind in ['write', 'read', 'mismatch', 'lost-response']) {
    test(
      'organization $kind failure keeps barrier and verifies before publishing',
      () async {
        final s = PhysicalOrganizationStore()..data = tree();
        final o = await organization(s);
        await o.holdForBackup();
        s.failWrite = kind == 'write';
        s.failRead = kind == 'read';
        s.corrupt = kind == 'mismatch';
        s.loseResponse = kind == 'lost-response';
        if (kind == 'lost-response') {
          await o.commitPhysicalAlbumDeletion({album});
          expect(o.snapshot.placements.containsKey(album), false);
        } else {
          await expectLater(
            o.commitPhysicalAlbumDeletion({album}),
            throwsStateError,
          );
          expect(o.snapshot.placements.containsKey(album), true);
          s.failWrite = s.failRead = s.corrupt = false;
          await o.commitPhysicalAlbumDeletion({album});
          expect(o.snapshot.placements.containsKey(album), false);
        }
        expect(o.busy, true);
      },
    );
  }
}
