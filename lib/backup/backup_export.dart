import 'dart:typed_data';

import '../library/favorites.dart';
import '../media/browser.dart';
import '../media/media_source.dart';
import '../organization/organization.dart';
import 'backup_codec.dart';
import 'restore_journal.dart';

class OriginalFingerprint {
  const OriginalFingerprint(this.fingerprint, this.filename);
  final BackupFingerprint fingerprint;
  final String? filename;
}

abstract interface class OriginalReader {
  Future<bool> permission({bool request = false});
  Future<OriginalFingerprint> read(Photo photo, String libraryVersion);
}

abstract interface class BackupOutput {
  // True only after complete output verification; false only for cancellation.
  Future<bool> save(Uint8List bytes);
}

class BackupPreparationCancelled implements Exception {}

class BackupMediaRefreshing extends StateError {
  BackupMediaRefreshing() : super('Photo scope is still refreshing');
}

class ExportResult {
  const ExportResult(this.document, this.saved, {this.pendingFavorites = 0});
  final int pendingFavorites;
  final BackupDocument document;
  final bool saved;
}

// Coordinates immutable inputs. Organization and Favorites remain state owners.
class BackupExport {
  BackupExport(
    this.organization,
    this.favorites,
    this.browser,
    this.originals,
    this.output, {
    BackupOperationGuard? guard,
  }) : guard = guard ?? BackupOperationGuard();
  final BackupOperationGuard guard;
  final Organization organization;
  final Favorites favorites;
  final PhotoBrowser browser;
  final OriginalReader originals;
  final BackupOutput output;
  // The summary and serialized document count the same retained records.
  int? get albumCount {
    if (organization.phase != OrganizationPhase.ready ||
        favorites.phase != FavoritePhase.ready ||
        browser.phase == BrowsePhase.idle ||
        browser.phase == BrowsePhase.checking ||
        browser.phase == BrowsePhase.loading) {
      return null;
    }
    return _albumKeys(
      organization.snapshot,
      browser.phase == BrowsePhase.ready ? browser.photos : [],
      favorites.snapshot.pending,
    ).length;
  }

  List<String> _albumKeys(
    OrganizationSnapshot tree,
    List<Photo> photos,
    List<PendingFavorite> pending,
  ) => <String>{
    ...photos.map((p) => p.albumKey),
    ...tree.placements.keys,
    ...tree.descriptors.keys,
    ...pending.map((p) => p.albumKey).whereType<String>(),
    ...tree.albumOrders.values.expand((keys) => keys),
  }.toList()..sort();

  bool _busy = false;
  bool get busy => _busy;
  bool _preparing = false, _cancelled = false;
  void stopPreparation() {
    if (_preparing) _cancelled = true;
  }

  void _checkCancellation() {
    if (_cancelled) throw BackupPreparationCancelled();
  }

  Future<ExportResult> export({
    required bool readOriginals,
    void Function()? onOutput,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (_busy) throw StateError('Backup already active');
    guard.acquire(this);
    _busy = true;
    _preparing = true;
    _cancelled = false;
    try {
      final snapshot = await _snapshot(readOriginals, onProgress);
      _checkCancellation();
      final document = snapshot.$1;
      final bytes = const BackupCodec().encode(document);
      _preparing = false;
      onOutput?.call();
      return ExportResult(
        document,
        await output.save(bytes),
        pendingFavorites: snapshot.$2,
      );
    } finally {
      _preparing = false;
      _busy = false;
      guard.release(this);
    }
  }

  Future<(BackupDocument, int)> _snapshot(
    bool readOriginals,
    void Function(int completed, int total)? onProgress,
  ) async {
    var organizationHeld = false, favoritesHeld = false;
    late OrganizationSnapshot tree;
    late Set<String> identities;
    late List<PendingFavorite> pending;
    late List<Photo> photos;
    late int generation;
    int? collectionRevision;
    late Map<String, String> origins;
    String? version;
    try {
      final organizationDrain = organization.holdForBackup();
      organizationHeld = true;
      final favoritesDrain = favorites.holdForBackup();
      favoritesHeld = true;
      await Future.wait([organizationDrain, favoritesDrain]);
      tree = organization.confirmedForBackup;
      identities = favorites.confirmedForBackup;
      origins = favorites.snapshot.sources;
      pending = favorites.snapshot.pending;
      if (browser.phase == BrowsePhase.idle ||
          browser.phase == BrowsePhase.checking ||
          browser.phase == BrowsePhase.loading) {
        throw BackupMediaRefreshing();
      }
      generation = browser.generation;
      version = browser.libraryVersion;
      collectionRevision = browser.collectionRevision;
      photos = browser.phase == BrowsePhase.ready
          ? List.of(browser.photos)
          : [];
    } finally {
      if (favoritesHeld) favorites.releaseBackup();
      if (organizationHeld) organization.releaseBackup();
    }
    _checkCancellation();
    final visible = albumsOf(photos);
    final visibleByKey = {for (final album in visible) album.key: album};
    final keys = _albumKeys(tree, photos, pending);
    final albumIds = {
      for (var i = 0; i < keys.length; i++) keys[i]: 'album-$i',
    };
    final albums = keys.map((key) {
      final retained = tree.descriptors[key];
      final separator = key.indexOf(':');
      final directory = separator >= 0 ? key.substring(separator + 1) : null;
      final matching = visibleByKey[key];
      return BackupAlbum(
        id: albumIds[key]!,
        sourceKey: retained?.pending == true ? retained?.sourceKey : key,
        name: matching?.name ?? retained?.name,
        directory: retained?.pending == true
            ? retained?.directory
            : matching?.directory ?? directory,
        pending: retained?.pending ?? false,
      );
    }).toList();
    final backupTree = OrganizationSnapshot(
      tree.folders.values,
      tree.placements.map((key, value) => MapEntry(albumIds[key]!, value)),
      folderOrders: tree.folderOrders,
      albumOrders: tree.albumOrders.map(
        (key, value) =>
            MapEntry(key, value.map((id) => albumIds[id]!).toList()),
      ),
    );
    final byIdentity = {
      for (final photo in photos) favoriteIdentity(photo, version): photo,
    };
    bool current() =>
        browser.current(generation) && browser.libraryVersion == version;
    final sources = {for (final id in identities) id: origins[id] ?? 'legacy'};
    final records = <BackupFavorite>[];
    onProgress?.call(0, sources.length);
    for (final identity in sources.keys.toList()..sort()) {
      _checkCancellation();
      final photo = byIdentity[identity];
      OriginalFingerprint? original;
      String? reason;
      if (photo == null || version == null) {
        reason = 'not_accessible';
      } else if (!readOriginals) {
        reason = 'original_permission_declined';
      } else if (!current()) {
        reason = 'media_scope_changed';
      } else {
        try {
          original = await originals.read(photo, version);
          if (!current()) {
            original = null;
            reason = 'media_scope_changed';
          }
        } catch (_) {
          reason = current() ? 'original_unavailable' : 'media_scope_changed';
        }
      }
      _checkCancellation();
      records.add(
        BackupFavorite(
          identity: identity,
          mediaKind: favoriteMediaKind(identity),
          source: sources[identity]!,
          systemFavorite: null,
          albumId: photo == null ? null : albumIds[photo.albumKey],
          filename: original?.filename,
          fingerprint: original?.fingerprint,
          unresolvedReason: reason,
        ),
      );
      onProgress?.call(records.length, sources.length);
    }
    _checkCancellation();
    // Recheck identity/permission tickets independently of system favorite fields.
    var scopeCurrent = current();
    if (browser.phase == BrowsePhase.ready) {
      try {
        scopeCurrent =
            await browser.source.permission() == browser.permissions &&
            await browser.source.libraryVersion() == version &&
            await browser.source.collectionRevision() == collectionRevision &&
            current();
      } catch (_) {
        scopeCurrent = false;
      }
    }
    _checkCancellation();
    final merged = <String, BackupFavorite>{};
    for (final p in pending) {
      merged[p.identity] = BackupFavorite(
        identity: p.identity,
        mediaKind: favoriteMediaKind(p.identity),
        source: p.source,
        pending: true,
        systemFavorite: null,
        albumId: albumIds[p.albumKey],
        filename: p.filename,
        fingerprint: p.size == null
            ? null
            : BackupFingerprint(size: p.size!, sha256: p.sha256!),
        unresolvedReason: p.size == null ? p.reason : null,
      );
    }
    for (final record in records) {
      final previous = merged[record.identity];
      final source = previous == null || previous.source == record.source
          ? record.source
          : 'both';
      final valid = scopeCurrent && current();
      merged[record.identity] = BackupFavorite(
        identity: record.identity,
        mediaKind: favoriteMediaKind(record.identity),
        source: source,
        pending: previous?.pending ?? false,
        systemFavorite: valid ? record.systemFavorite : null,
        albumId: record.albumId ?? previous?.albumId,
        filename: record.filename ?? previous?.filename,
        fingerprint: valid
            ? record.fingerprint ?? previous?.fingerprint
            : previous?.fingerprint,
        unresolvedReason:
            (valid
                    ? record.fingerprint ?? previous?.fingerprint
                    : previous?.fingerprint) !=
                null
            ? null
            : valid
            ? record.unresolvedReason
            : 'media_scope_changed',
      );
    }
    return (
      BackupDocument(
        organization: backupTree,
        albums: albums,
        favorites: merged.values,
        systemSnapshotComplete: false,
      ),
      pending.length,
    );
  }
}
