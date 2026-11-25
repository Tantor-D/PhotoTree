import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../media/browser.dart';
import '../media/media_source.dart';
import '../media/system_favorites.dart';
import '../storage/operation_guard.dart';

// The identity deliberately excludes location. Unknown library versions cannot
// create or match a record, and never cause deletion of previously saved rows.
String? favoriteIdentity(Photo photo, String? libraryVersion) =>
    libraryVersion == null || libraryVersion.isEmpty
    ? null
    : jsonEncode([
        photo.volume,
        photo.id,
        libraryVersion,
        photo.addedSeconds,
        photo.takenMs,
        photo.width,
        photo.height,
        if (photo.kind == MediaKind.video) 'video',
      ]);

// The seven-field image identity remains byte-for-byte compatible. Type is
// intrinsic to the video identity, including unresolved/private recovery rows.
MediaKind favoriteMediaKind(String identity) {
  final tuple = jsonDecode(identity);
  if (tuple is! List ||
      (tuple.length != 7 && tuple.length != 8) ||
      tuple[0] is! String ||
      (tuple[0] as String).isEmpty ||
      tuple[2] is! String ||
      (tuple[2] as String).isEmpty ||
      [1, 3, 4, 5, 6].any((i) => tuple[i] is! int || (tuple[i] as int) < 0) ||
      (tuple.length == 8 && tuple[7] != 'video')) {
    throw const FormatException('Invalid favorite identity');
  }
  return tuple.length == 8 ? MediaKind.video : MediaKind.image;
}

class PendingFavorite {
  const PendingFavorite({
    required this.identity,
    this.albumKey,
    this.filename,
    this.size,
    this.sha256,
    required this.reason,
    this.source = 'legacy',
  });
  final String identity;
  final String? albumKey, filename, sha256;
  final int? size;
  final String reason;
  final String source;
}

class FavoriteSnapshot {
  FavoriteSnapshot(
    Iterable<String> confirmed, [
    Iterable<PendingFavorite> pending = const [],
    Map<String, String> migrationOutcomes = const {},
    Map<String, String> sources = const {},
  ]) : confirmed = Set.unmodifiable(confirmed),
       pending = List.unmodifiable(pending),
       migrationOutcomes = Map.unmodifiable(migrationOutcomes),
       sources = Map.unmodifiable(sources) {
    if (sources.entries.any(
      (e) =>
          !this.confirmed.contains(e.key) ||
          !const {'system', 'both'}.contains(e.value),
    )) {
      throw StateError('Invalid confirmed favorite source');
    }
    if (migrationOutcomes.entries.any(
      (e) =>
          e.key.isEmpty ||
          !SystemFavoriteOutcome.values.any((v) => v.name == e.value),
    )) {
      throw StateError('Invalid favorite migration outcome');
    }
    final identities = <String>{};
    for (final p in this.pending) {
      if (p.identity.isEmpty ||
          p.reason.isEmpty ||
          !const {'legacy', 'system', 'both'}.contains(p.source) ||
          !identities.add(p.identity) ||
          this.confirmed.contains(p.identity) ||
          (p.size == null) != (p.sha256 == null) ||
          (p.size != null &&
              (p.size! < 0 ||
                  !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.sha256!)))) {
        throw StateError('Invalid pending favorite');
      }
    }
  }
  final Set<String> confirmed;
  final List<PendingFavorite> pending;
  final Map<String, String> migrationOutcomes;
  // Only non-default historical origins; absence means application (legacy).
  final Map<String, String> sources;
}

abstract interface class FavoriteStore {
  Future<Set<String>> read();
  Future<FavoriteSnapshot> readSnapshot();
  Future<void> replace(FavoriteSnapshot snapshot);
  Future<void> set(String identity, bool value);
  Future<void> close();
}

enum FavoritePhase { loading, ready, failed }

// Device-local observations stay outside backup and restore documents.
abstract interface class FavoriteSyncStore {
  Future<({bool enabled, Map<String, bool> origins})> readSync();
  Future<void> saveSync({
    bool? enabled,
    required Map<String, bool> observed,
    required Set<String> removed,
    String? addPrivate,
  });
}

class Favorites extends ChangeNotifier {
  Favorites(
    this.store,
    this.browser, {
    this.system,
    this.syncStore,
    BackupOperationGuard? guard,
  }) : guard = guard ?? BackupOperationGuard() {
    if (syncStore != null) browser.addListener(_mediaChanged);
  }
  final SystemFavoriteAccess? system;
  final BackupOperationGuard guard;
  final FavoriteSyncStore? syncStore;
  bool get syncAvailable => system?.requestsSupported == true;
  bool _enabled = false;
  bool _loadedSync = false;
  bool _switching = false;
  bool syncFailed = false;
  Map<String, bool> _origins = {};
  List<Photo>? _reconciled;
  String? _reconciledVersion;
  bool _queued = false;
  bool get systemMode => syncAvailable && (syncStore == null || _enabled);
  bool usesSystem(Photo photo) => systemMode && photo.kind == MediaKind.image;
  bool get canSwitch =>
      syncAvailable &&
      syncStore != null &&
      phase == FavoritePhase.ready &&
      !_switching &&
      !_backupHeld &&
      !_systemPending &&
      _busy.isEmpty &&
      !guard.held;

  bool get _readable =>
      browser.phase == BrowsePhase.ready &&
      browser.foreground &&
      !browser.updating &&
      browser.failure == null &&
      browser.libraryVersion?.isNotEmpty == true;

  Future<void> _readSync() async {
    if (_loadedSync || syncStore == null) return;
    final saved = await syncStore!.readSync();
    _enabled = saved.enabled;
    _origins = saved.origins;
    _loadedSync = true;
  }

  void _mediaChanged() {
    if (!syncAvailable ||
        syncStore == null ||
        _disposed ||
        _queued ||
        _backupHeld ||
        _switching ||
        _busy.isNotEmpty ||
        _systemPending ||
        phase != FavoritePhase.ready ||
        (_loadedSync && !_readable) ||
        (_loadedSync && !systemMode) ||
        (identical(_reconciled, browser.photos) &&
            _reconciledVersion == browser.libraryVersion &&
            _loadedSync)) {
      return;
    }
    _queued = true;
    _tail = _tail.then((_) async {
      try {
        await _readSync();
        if (!_disposed && !_backupHeld && systemMode && _readable) {
          await _reconcileImages();
        }
      } catch (_) {
        syncFailed = true;
      } finally {
        _queued = false;
        _publish();
        if (!syncFailed &&
            _loadedSync &&
            systemMode &&
            _readable &&
            !identical(_reconciled, browser.photos)) {
          _mediaChanged();
        }
      }
    });
  }

  Future<void> _reconcileImages({bool? enabled}) async {
    final photos = browser.photos;
    final version = browser.libraryVersion;
    final observed = <String, bool>{};
    final removed = <String>{};
    for (final photo in photos) {
      if (photo.kind != MediaKind.image ||
          photo.systemFavorite == null ||
          _current(photo) == null) {
        continue;
      }
      final id = favoriteIdentity(photo, version)!;
      if (photo.systemFavorite!) {
        if (!_origins.containsKey(id)) {
          observed[id] = false;
        }
      } else if (_origins.containsKey(id)) {
        removed.add(id);
      }
    }
    if (enabled != null || observed.isNotEmpty || removed.isNotEmpty) {
      await syncStore!.saveSync(
        enabled: enabled,
        observed: observed,
        removed: removed,
      );
      _origins.addAll(observed);
      for (final id in removed) {
        _origins.remove(id);
        _confirmed.remove(id);
        _sources.remove(id);
      }
      _revision++;
    }
    _reconciled = photos;
    _reconciledVersion = version;
    syncFailed = false;
  }

  Future<bool> setImageSync(bool enabled) async {
    if (!canSwitch || !_takeSystemGuard()) return false;
    _switching = true;
    _publish();
    try {
      await _tail;
      await _readSync();
      await browser.refresh();
      if (!_readable ||
          browser.permissions.images == PhotoAccess.denied ||
          browser.photos.any(
            (p) => p.kind == MediaKind.image && p.systemFavorite == null,
          )) {
        throw StateError('图片状态待核对');
      }
      await _reconcileImages(enabled: enabled);
      _enabled = enabled;
      return true;
    } catch (_) {
      syncFailed = true;
      return false;
    } finally {
      _switching = false;
      _releaseSystemGuard();
      _publish();
      _mediaChanged();
    }
  }

  final Object _systemOwner = Object();
  bool _systemGuardHeld = false;
  bool _systemPending = false;
  bool _checkingSystemRequest = false;
  bool get systemRequestPending => _systemPending;
  bool get checkingSystemRequest => _checkingSystemRequest;

  bool _takeSystemGuard() {
    if (_systemGuardHeld) return true;
    try {
      guard.acquire(_systemOwner);
      _systemGuardHeld = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  void _releaseSystemGuard() {
    if (!_systemGuardHeld) return;
    guard.release(_systemOwner);
    _systemGuardHeld = false;
  }

  Future<bool?> _readSystemPending() async {
    try {
      return await system!.hasPendingRequest();
    } catch (_) {
      return null;
    }
  }

  /// A read-only retry. A matching favorite field never settles a live request,
  /// and discovering that it ended does not rewrite its unknown history.
  Future<bool> reconcileSystemRequest() async {
    if (!syncAvailable) return true;
    if (_disposed || _switching || _checkingSystemRequest || _busy.isNotEmpty) {
      return false;
    }
    if (!_takeSystemGuard()) return false;
    _checkingSystemRequest = true;
    _systemPending = true;
    _publish();
    try {
      _systemPending = await _readSystemPending() != false;
      if (!_systemPending) _releaseSystemGuard();
      return !_systemPending;
    } finally {
      _checkingSystemRequest = false;
      _publish();
    }
  }

  final Map<String, SystemFavoriteOutcome> _results = {};
  Map<String, String> _migrationOutcomes = {};
  Map<String, String> get migrationOutcomes =>
      Map.unmodifiable(_migrationOutcomes);
  SystemFavoriteOutcome? resultFor(Photo photo) {
    final identity = favoriteIdentity(photo, browser.libraryVersion);
    final recent = _results[identity];
    if (recent != null) return recent;
    final saved = _migrationOutcomes[identity];
    if (saved == null) return null;
    return SystemFavoriteOutcome.values.byName(saved);
  }

  final FavoriteStore store;
  final PhotoBrowser browser;
  Set<String> _confirmed = {};
  Map<String, String> _sources = {};
  List<PendingFavorite> _pending = const [];
  FavoriteSnapshot get snapshot =>
      FavoriteSnapshot(_confirmed, _pending, _migrationOutcomes, _sources);
  int _revision = 0;
  int get revision => _revision;
  bool get held => _backupHeld;
  final Set<String> _busy = {};
  final Set<String> _failures = {};
  FavoritePhase _phase = FavoritePhase.loading;
  FavoritePhase get phase => _phase;
  bool _disposed = false;
  Future<void> _tail = Future.value();
  bool _backupHeld = false;
  Future<void> holdForBackup() {
    if (_disposed || _backupHeld) throw StateError('Favorites unavailable');
    _backupHeld = true;
    return _tail;
  }

  Set<String> get confirmedForBackup {
    if (_disposed || !_backupHeld || phase != FavoritePhase.ready) {
      throw StateError('Favorites unavailable');
    }
    return Set.unmodifiable(_confirmed);
  }

  void installRestored(FavoriteSnapshot value) {
    if (!_backupHeld || _disposed) throw StateError('Favorites not held');
    _confirmed = Set.of(value.confirmed);
    _sources = Map.of(value.sources);
    _pending = value.pending;
    _migrationOutcomes = Map.of(value.migrationOutcomes);
    _results.clear();
    _phase = FavoritePhase.ready;
    _revision++;
    _failures.clear();
  }

  /// Applies only identities whose physical result was independently confirmed.
  /// The coordinator retains both owner barriers until all private writes verify.
  Future<void> commitPhysicalChange({
    Set<String> deletedIdentities = const {},
    Set<String> detachedAlbumKeys = const {},
    Map<String, ({String albumKey, String filename})> movedLocations = const {},
  }) async {
    if (!_backupHeld || _disposed || phase != FavoritePhase.ready) {
      throw StateError('Favorites must be held and ready');
    }
    final deleted = Set<String>.of(deletedIdentities);
    final moved = Map.of(movedLocations);
    final detached = Set<String>.of(detachedAlbumKeys);
    if (deleted.any((id) => id.isEmpty) ||
        detached.any((key) => key.isEmpty) ||
        moved.entries.any(
          (e) =>
              e.key.isEmpty ||
              deleted.contains(e.key) ||
              e.value.albumKey.isEmpty ||
              detached.contains(e.value.albumKey) ||
              e.value.filename.isEmpty,
        )) {
      throw ArgumentError('Invalid physical favorite changes');
    }
    await _tail;
    final next = FavoriteSnapshot(
      _confirmed.where((id) => !deleted.contains(id)),
      _pending.where((p) => !deleted.contains(p.identity)).map((p) {
        final location = moved[p.identity];
        return location == null && !detached.contains(p.albumKey)
            ? p
            : PendingFavorite(
                identity: p.identity,
                albumKey: location?.albumKey,
                filename: location?.filename ?? p.filename,
                size: p.size,
                sha256: p.sha256,
                reason: p.reason,
                source: p.source,
              );
      }),
      Map.fromEntries(
        _migrationOutcomes.entries.where((e) => !deleted.contains(e.key)),
      ),
      Map.fromEntries(_sources.entries.where((e) => !deleted.contains(e.key))),
    );
    try {
      await store.replace(next);
    } catch (_) {
      // A committed transaction can lose its response; verify durable state.
    }
    final actual = await store.readSnapshot();
    Map<String, String> pending(FavoriteSnapshot s) => {
      for (final p in s.pending) p.identity: jsonEncode(pendingData(p)),
    };
    if (!setEquals(next.confirmed, actual.confirmed) ||
        !mapEquals(pending(next), pending(actual)) ||
        !mapEquals(next.migrationOutcomes, actual.migrationOutcomes) ||
        !mapEquals(next.sources, actual.sources)) {
      throw StateError('Physical favorite changes did not verify');
    }
    installRestored(actual);
  }

  void releaseBackup() {
    _backupHeld = false;
    _reconciled = null;
    _mediaChanged();
    _publish();
  }

  int get recordCount => _confirmed.length;
  bool contains(Photo photo) => usesSystem(photo)
      ? _current(photo)?.systemFavorite == true
      : _confirmed.contains(favoriteIdentity(photo, browser.libraryVersion));
  // A derived lookup for the browser's immutable current list, never a second
  // media collection. The browser alone controls membership and permission.
  List<Photo>? _indexedPhotos;
  String? _indexedVersion;
  Map<String, Photo?> _identityIndex = {};
  Photo? _current(Photo photo) {
    final version = browser.libraryVersion;
    final id = favoriteIdentity(photo, version);
    if ((browser.phase != BrowsePhase.ready && !browser.updating) ||
        id == null) {
      _indexedPhotos = null;
      _indexedVersion = null;
      _identityIndex = {};
      return null;
    }
    final photos = browser.photos;
    if (!identical(photos, _indexedPhotos) || version != _indexedVersion) {
      final index = <String, Photo?>{};
      for (final current in photos) {
        final identity = favoriteIdentity(current, version)!;
        // Ambiguous identities must remain unwritable even in a malformed
        // source. A duplicate cannot silently replace the first object.
        index[identity] = index.containsKey(identity) ? null : current;
      }
      _identityIndex = index;
      _indexedPhotos = photos;
      _indexedVersion = version;
    }
    return _identityIndex[id];
  }

  Set<String> get _migrationIdentities => {
    for (final id in {..._confirmed, ..._pending.map((p) => p.identity)})
      if (favoriteMediaKind(id) == MediaKind.image && _origins[id] != true) id,
  };
  List<Photo> get migrationCandidates {
    if (browser.phase != BrowsePhase.ready) return const [];
    final identities = _migrationIdentities;
    return browser.photos
        .where(
          (photo) =>
              photo.kind == MediaKind.image &&
              identities.contains(
                favoriteIdentity(photo, browser.libraryVersion),
              ) &&
              _current(photo) != null,
        )
        .toList();
  }

  int get migrationUnavailableCount =>
      _migrationIdentities.length - migrationCandidates.length;
  bool? state(Photo photo) =>
      usesSystem(photo) ? _current(photo)?.systemFavorite : contains(photo);
  bool get _modeKnown => !syncAvailable || syncStore == null || _loadedSync;
  bool canSet(Photo photo) =>
      _modeKnown &&
      !_disposed &&
      !_backupHeld &&
      !_systemPending &&
      phase == FavoritePhase.ready &&
      browser.phase == BrowsePhase.ready &&
      _current(photo) != null &&
      (!_switching &&
          (!usesSystem(photo) || (_busy.isEmpty && state(photo) != null)));
  bool busy(Photo photo) => _busy.contains(photo.key);
  bool failed(Photo photo) => _failures.contains(photo.key);
  bool get identityAvailable => browser.libraryVersion?.isNotEmpty == true;
  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (_disposed || _backupHeld) return;
    if (!await reconcileSystemRequest()) return;
    if (_disposed || _backupHeld) return;
    _phase = FavoritePhase.loading;
    _publish();
    // All access is serialized, so retrying a read cannot race confirmed writes.
    final task = _tail.then((_) async {
      try {
        final records = await store.readSnapshot();
        if (_disposed) return;
        _confirmed = Set.of(records.confirmed);
        _sources = Map.of(records.sources);
        _pending = records.pending;
        _migrationOutcomes = Map.of(records.migrationOutcomes);
        _results.clear();
        _revision++;
        _phase = FavoritePhase.ready;
      } catch (_) {
        if (!_disposed) _phase = FavoritePhase.failed;
      }
      _publish();
    });
    _tail = task;
    await task;
    _mediaChanged();
  }

  Future<void> set(Photo photo, bool value) async {
    if (_switching || !_modeKnown) return;
    if (usesSystem(photo)) {
      await _systemSet(photo, value);
      return;
    }
    final identity = favoriteIdentity(photo, browser.libraryVersion);
    if (_disposed ||
        _backupHeld ||
        phase != FavoritePhase.ready ||
        identity == null ||
        busy(photo) ||
        browser.phase != BrowsePhase.ready ||
        !browser.photos.any(
          (p) => favoriteIdentity(p, browser.libraryVersion) == identity,
        )) {
      return;
    }
    _busy.add(photo.key);
    _failures.remove(photo.key);
    _publish();
    final task = _tail.then((_) async {
      if (_disposed) return;
      // Authorization can shrink while this write is waiting behind another one.
      if (browser.phase != BrowsePhase.ready ||
          !browser.photos.any(
            (p) => favoriteIdentity(p, browser.libraryVersion) == identity,
          )) {
        _busy.remove(photo.key);
        _publish();
        return;
      }
      try {
        await store.set(identity, value);
        _origins.remove(identity);
        _revision++;
        if (_disposed) return;
        if (value) {
          _confirmed.add(identity);
          _pending = _pending.where((p) => p.identity != identity).toList();
        } else {
          _confirmed.remove(identity);
          _sources.remove(identity);
        }
      } catch (_) {
        if (!_disposed) _failures.add(photo.key);
      }
      _busy.remove(photo.key);
      _publish();
    });
    _tail = task;
    await task;
    _mediaChanged();
  }

  Future<void> migrateSelected(Set<String> identities) async {
    if (!systemMode ||
        _switching ||
        _busy.isNotEmpty ||
        _backupHeld ||
        _disposed ||
        _systemPending) {
      return;
    }
    // Snapshot only explicitly selected, currently uniquely matched records.
    final selectedVersion = browser.libraryVersion;
    final selected = migrationCandidates
        .where(
          (p) =>
              identities.contains(favoriteIdentity(p, browser.libraryVersion)),
        )
        .toList();
    for (final photo in selected) {
      if (_disposed ||
          _backupHeld ||
          !systemMode ||
          browser.libraryVersion != selectedVersion ||
          browser.phase != BrowsePhase.ready) {
        break;
      }
      await _systemSet(photo, true);
      if (resultFor(photo) != SystemFavoriteOutcome.confirmed) break;
    }
  }

  Future<void> _systemSet(Photo photo, bool value) async {
    final version = browser.libraryVersion;
    final identity = favoriteIdentity(photo, version);
    if (_disposed ||
        _backupHeld ||
        phase != FavoritePhase.ready ||
        browser.phase != BrowsePhase.ready ||
        identity == null ||
        _busy.isNotEmpty ||
        _systemPending) {
      return;
    }
    final current = _current(photo);
    if (current == null) {
      _results[identity] = SystemFavoriteOutcome.stale;
      _publish();
      return;
    }
    if (current.systemFavorite == null) {
      _results[identity] = SystemFavoriteOutcome.unknown;
      _publish();
      return;
    }
    if (!_takeSystemGuard()) {
      _results[identity] = SystemFavoriteOutcome.busy;
      _publish();
      return;
    }
    _busy.add(photo.key);
    _failures.remove(photo.key);
    _results.remove(identity);
    _publish();
    final task = _tail.then((_) async {
      var outcome = SystemFavoriteOutcome.unknown;
      var requested = false;
      try {
        if (_disposed ||
            browser.phase != BrowsePhase.ready ||
            browser.libraryVersion != version ||
            _current(photo) == null) {
          return;
        }
        if (syncStore != null && _readable) await _reconcileImages();
        // Persist an interrupted result before the external request. Restarting
        // reads this record, and never replays it.
        _migrationOutcomes[identity] = SystemFavoriteOutcome.unknown.name;
        await store.replace(snapshot);
        if (_disposed ||
            browser.phase != BrowsePhase.ready ||
            browser.libraryVersion != version ||
            _current(photo)?.systemFavorite == null) {
          outcome = SystemFavoriteOutcome.unknown;
        } else if (_current(photo)?.systemFavorite == value) {
          outcome = SystemFavoriteOutcome.confirmed;
        } else {
          requested = true;
          final result = await system!.set(photo, version!, value);
          outcome = result.outcome;
          if (outcome == SystemFavoriteOutcome.confirmed) {
            // Native has re-read this exact identity after user approval. Keep
            // its provenance even if the foreground browser is still resuming.
            if (syncStore != null && result.changed && result.value == value) {
              await syncStore!.saveSync(
                observed: value ? {identity: true} : {},
                removed: value ? {} : {identity},
                addPrivate: value ? identity : null,
              );
              if (value) {
                _origins[identity] = true;
                _confirmed.add(identity);
                _pending = _pending
                    .where((p) => p.identity != identity)
                    .toList();
              } else {
                _origins.remove(identity);
                _confirmed.remove(identity);
                _sources.remove(identity);
              }
              _revision++;
            }
            // System confirmation can suspend the application. Do not restart
            // its browser while backgrounded or claim the late callback failed.
            if (!browser.foreground) {
              outcome = SystemFavoriteOutcome.unknown;
            } else {
              await browser.refresh();
              final reread = _current(photo);
              outcome =
                  browser.failure == null &&
                      browser.libraryVersion == version &&
                      reread?.systemFavorite == value
                  ? SystemFavoriteOutcome.confirmed
                  : SystemFavoriteOutcome.unknown;
            }
          }
        }
        if (syncStore != null &&
            outcome == SystemFavoriteOutcome.confirmed &&
            _readable) {
          await _reconcileImages();
        }
        _migrationOutcomes[identity] = outcome.name;
        await store.replace(snapshot);
        _revision++;
      } catch (_) {
        // An exception may follow a completed external effect; do not call it
        // a proved failure or attempt a compensating write.
        outcome = SystemFavoriteOutcome.unknown;
        _migrationOutcomes[identity] = outcome.name;
      } finally {
        _results[identity] = outcome;
        if (outcome == SystemFavoriteOutcome.failed ||
            outcome == SystemFavoriteOutcome.permission ||
            outcome == SystemFavoriteOutcome.stale) {
          _failures.add(photo.key);
        }
        // A channel reply (including unknown) need not mean the system request
        // ended. Keep the shared lease across UI completion until a read-only
        // native check positively observes no request. Never replay the write.
        _systemPending = requested && await _readSystemPending() != false;
        _busy.remove(photo.key);
        if (!_systemPending) _releaseSystemGuard();
        _publish();
      }
    });
    _tail = task;
    await task;
    _mediaChanged();
  }

  @override
  void dispose() {
    browser.removeListener(_mediaChanged);
    _disposed = true;
    unawaited(_tail.then((_) => store.close()));
    super.dispose();
  }
}

Map<String, Object?> pendingData(PendingFavorite p) => {
  'identity': p.identity,
  'albumKey': p.albumKey,
  'filename': p.filename,
  'size': p.size,
  'sha256': p.sha256,
  'reason': p.reason,
  if (p.source != 'legacy') 'source': p.source,
};
PendingFavorite pendingFrom(dynamic p) {
  if (p is! Map ||
      (p.length != 6 && p.length != 7) ||
      !p.keys.toSet().containsAll(const {
        'identity',
        'albumKey',
        'filename',
        'size',
        'sha256',
        'reason',
      }) ||
      p.keys.any(
        (key) => !const {
          'identity',
          'albumKey',
          'filename',
          'size',
          'sha256',
          'reason',
          'source',
        }.contains(key),
      ) ||
      (p.length == 7 && p['source'] is! String)) {
    throw const FormatException('Invalid pending favorite');
  }
  return PendingFavorite(
    identity: p['identity'] as String,
    albumKey: p['albumKey'] as String?,
    filename: p['filename'] as String?,
    size: p['size'] as int?,
    sha256: p['sha256'] as String?,
    reason: p['reason'] as String,
    source: p['source'] as String? ?? 'legacy',
  );
}
