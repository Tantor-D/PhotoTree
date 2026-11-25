import 'dart:async';

import 'package:flutter/foundation.dart';

import '../organization/organization.dart';
import '../library/favorites.dart';
import '../media/browser.dart';
import '../media/media_source.dart';
import 'backup_codec.dart';
import 'backup_export.dart';
import 'private_snapshot.dart';
import 'restore_journal.dart';

/// Application messages safe to show without platform/storage exception details.
class RestoreProblem extends StateError {
  RestoreProblem(super.message);
}

enum BackupInputFailureKind { tooLarge, unavailable }

class BackupInputFailure implements Exception {
  const BackupInputFailure(this.kind);
  final BackupInputFailureKind kind;
  String get message => switch (kind) {
    BackupInputFailureKind.tooLarge =>
      '备份文件超过 32 MiB，无法读取。请选择不超过 32 MiB 的备份文件。',
    BackupInputFailureKind.unavailable => '无法读取备份文件。请检查文件是否可访问，然后重新选择。',
  };
}

abstract interface class BackupInput {
  Future<Uint8List?> open();
  Future<void> cancel();
}

abstract interface class RestoreMedia {
  // Exact identity/freshness validation, without requesting any permissions.
  Future<int> size(Photo photo, String version);
  Future<String?> filename(Photo photo, String version);
}

class RestorePreview {
  RestorePreview._(
    this.before,
    this.target,
    this.generation,
    this.version,
    this.collectionRevision,
    this.access,
    this.phase,
    this.document,
    this.mappings,
    this.manualPhotos,
    this.readOriginals,
    this.reassociation,
    this.rollback,
  );
  final PrivateSnapshot before, target;
  final int generation;
  final String? version;
  final int? collectionRevision;
  final MediaPermissions access;
  final BrowsePhase phase;
  final BackupDocument? document;
  final Map<String, String?> mappings;
  final Map<String, String> manualPhotos;
  final bool readOriginals, reassociation, rollback;
  int get pendingAlbums =>
      target.organization.descriptors.values.where((d) => d.pending).length;
  int get resolvedFavorites => target.favorites.confirmed.length;
  int get pendingFavorites => target.favorites.pending.length;
}

class BackupRestore extends ChangeNotifier {
  BackupRestore(
    this.organization,
    this.favorites,
    this.browser,
    this.originals,
    this.input,
    this.media,
    this.journal, {
    BackupOperationGuard? guard,
    this.checkpoint,
  }) : guard = guard ?? BackupOperationGuard();
  final Organization organization;
  final Favorites favorites;
  final PhotoBrowser browser;
  final OriginalReader originals;
  final BackupInput input;
  final RestoreMedia media;
  final RestoreJournal journal;
  final BackupOperationGuard guard;
  final Future<void> Function(String)? checkpoint;
  bool busy = false, blocked = false, initialized = false, hasRollback = false;
  bool _held = false, _guardHeld = false, _disposed = false;
  String? status;
  int _readEpoch = 0;
  bool _reading = false;
  void cancelPreview() {
    if (!_reading) return;
    _readEpoch++;
    _reading = false;
    busy = false;
    _releaseGuard();
    unawaited(input.cancel().catchError((Object _) {}));
    _publish();
  }

  int _startRead() {
    _reading = true;
    return ++_readEpoch;
  }

  void _currentRead(int epoch) {
    if (epoch != _readEpoch) throw RestoreProblem('已取消预览');
  }

  void _endRead(int epoch) {
    if (epoch == _readEpoch) {
      _reading = false;
      busy = false;
      _releaseGuard();
      _publish();
    }
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  void _acquire() {
    guard.acquire(this);
    _guardHeld = true;
  }

  void _releaseGuard() {
    if (_guardHeld) {
      guard.release(this);
      _guardHeld = false;
    }
  }

  Future<void> _hold({bool recovery = false}) async {
    if (_held) return;
    final a = organization.holdForBackup(allowCreationRecovery: recovery);
    try {
      final b = favorites.holdForBackup();
      _held = true;
      await a;
      await b;
    } catch (_) {
      organization.releaseBackup();
      rethrow;
    }
  }

  void _install(PrivateSnapshot state) {
    organization.installRestored(state.organization);
    favorites.installRestored(state.favorites);
  }

  void _release() {
    if (_held) {
      _held = false;
      // Both snapshots were installed before either notification/discovery.
      favorites.releaseBackup();
      organization.releaseBackup();
    }
    _releaseGuard();
  }

  PrivateSnapshot _snapshot() =>
      PrivateSnapshot(organization.snapshot, favorites.snapshot);
  Future<PrivateSnapshot> _readStores() async {
    final o = await organization.store.read();
    await organization.loadCreationHistory();
    final f = await favorites.store.readSnapshot();
    return PrivateSnapshot(o, f);
  }

  Future<void> _verify(PrivateSnapshot expected) async {
    if (!(await _readStores()).same(expected)) {
      throw RestoreProblem('两份私有数据核对失败');
    }
  }

  Future<void> initialize() => retryRecovery();
  Future<void> retryRecovery() async {
    if (busy) return;
    busy = true;
    status = '正在检查私有数据恢复记录…';
    _publish();
    try {
      if (!_guardHeld) _acquire();
      await _hold(recovery: true);
      await journal.close();
      // Nothing may load/discover before this record has been validated.
      final state = await journal.read();
      if (state.active != null) {
        await _recover(state.active!);
      } else {
        _install(await _readStores());
        hasRollback = state.rollback != null;
      }
      blocked = false;
      initialized = true;
      status = '私有数据已就绪';
      _release();
    } catch (_) {
      blocked = true;
      status = '私有数据恢复未完成，已保留数据库与回滚材料。分类、收藏编辑和导出已暂停，请重试。';
      // The guard/barriers survive errors. Do not publish an editable mixed state.
    } finally {
      busy = false;
      _publish();
    }
  }

  Future<void> _recover(RestoreOperation op) async {
    final desired = op.committed ? op.target : op.before;
    await organization.store.replace(desired.organization);
    await checkpoint?.call('recovery-organization');
    await favorites.store.replace(desired.favorites);
    await checkpoint?.call('recovery-favorites');
    await _verify(desired);
    await journal.finish(op.id);
    hasRollback = (await journal.read()).rollback != null;
    _install(desired);
  }

  void _ready() {
    if (organization.creationIssue != null) {
      throw RestoreProblem(organization.creationIssue!);
    }
    if (!initialized ||
        blocked ||
        busy ||
        organization.phase != OrganizationPhase.ready ||
        favorites.phase != FavoritePhase.ready) {
      throw RestoreProblem('私有数据尚不可用');
    }
    if ([
      BrowsePhase.idle,
      BrowsePhase.checking,
      BrowsePhase.loading,
    ].contains(browser.phase)) {
      throw BackupMediaRefreshing();
    }
  }

  Future<BackupDocument?> choose() async {
    _ready();
    _acquire();
    busy = true;
    final epoch = _startRead();
    _publish();
    try {
      final bytes = await input.open();
      _currentRead(epoch);
      if (bytes == null) return null;
      return const BackupCodec().decode(bytes);
    } finally {
      _endRead(epoch);
    }
  }

  Map<String, String?> proposals(BackupDocument document) => {
    for (final a in document.albums)
      a.id: organization.restoreAlbums.any((now) => now.key == a.sourceKey)
          ? a.sourceKey
          : null,
  };
  BackupDocument pendingDocument() {
    final tree = organization.snapshot;
    final keys = {
      ...tree.descriptors.entries
          .where((e) => e.value.pending)
          .map((e) => e.key),
      ...favorites.snapshot.pending.map((f) => f.albumKey).whereType<String>(),
    };
    return BackupDocument(
      organization: OrganizationSnapshot([], {}),
      albums: [
        for (final k in keys)
          BackupAlbum(
            id: k,
            sourceKey: tree.descriptors[k]?.sourceKey ?? k,
            name: tree.descriptors[k]?.name,
            directory: tree.descriptors[k]?.directory,
            pending: tree.descriptors[k]?.pending ?? false,
          ),
      ],
      favorites: [
        for (final p in favorites.snapshot.pending)
          BackupFavorite(
            identity: p.identity,
            mediaKind: favoriteMediaKind(p.identity),
            source: p.source,
            pending: true,
            albumId: p.albumKey,
            filename: p.filename,
            fingerprint: p.size == null
                ? null
                : BackupFingerprint(size: p.size!, sha256: p.sha256!),
            unresolvedReason: p.size == null ? p.reason : null,
          ),
      ],
    );
  }

  Future<RestorePreview> pendingPreview(
    Map<String, String?> mappings, {
    Map<String, String> manualPhotos = const {},
    bool readOriginals = true,
  }) =>
      _preview(pendingDocument(), mappings, manualPhotos, readOriginals, true);
  Future<RestorePreview> preview(
    BackupDocument document,
    Map<String, String?> mappings, {
    Map<String, String> manualPhotos = const {},
    bool readOriginals = true,
  }) => _preview(document, mappings, manualPhotos, readOriginals, false);
  Future<RestorePreview> _preview(
    BackupDocument document,
    Map<String, String?> mappings,
    Map<String, String> manual,
    bool readOriginals,
    bool reassociation,
  ) async {
    _ready();
    _acquire();
    busy = true;
    final epoch = _startRead();
    _publish();
    final before = _snapshot(), generation = browser.generation;
    final version = browser.libraryVersion,
        access = browser.permissions,
        phase = browser.phase;
    try {
      if (!reassociation) const BackupCodec().encode(document);
      final confirmedMappings = Map<String, String?>.unmodifiable(mappings);
      final choices = Map<String, String>.unmodifiable(manual);
      final target = await _target(
        before,
        document,
        confirmedMappings,
        choices,
        readOriginals,
        reassociation,
        epoch: epoch,
      );
      final result = RestorePreview._(
        before,
        target,
        generation,
        version,
        browser.collectionRevision,
        access,
        phase,
        document,
        confirmedMappings,
        choices,
        readOriginals,
        reassociation,
        false,
      );
      _currentRead(epoch);
      _check(result);
      return result;
    } finally {
      _endRead(epoch);
    }
  }

  void _check(RestorePreview p) {
    if (!_snapshot().same(p.before) ||
        browser.generation != p.generation ||
        browser.libraryVersion != p.version ||
        browser.collectionRevision != p.collectionRevision ||
        browser.permissions != p.access ||
        browser.phase != p.phase) {
      throw RestoreProblem('预览已过期：分类、收藏或媒体访问范围已变化，请重新预览');
    }
  }

  Future<PrivateSnapshot> _target(
    PrivateSnapshot before,
    BackupDocument d,
    Map<String, String?> mappings,
    Map<String, String> manual,
    bool readOriginals,
    bool reassociation, {
    int? epoch,
  }) async {
    if (epoch != null) _currentRead(epoch);
    if (await browser.source.permission() != browser.permissions ||
        (browser.phase == BrowsePhase.ready &&
            (browser.collectionRevision == null ||
                await browser.source.collectionRevision() !=
                    browser.collectionRevision)) ||
        (browser.phase == BrowsePhase.ready &&
            await browser.source.libraryVersion() != browser.libraryVersion)) {
      throw RestoreProblem('媒体访问范围已变化，请刷新后重新预览');
    }
    final photos = browser.phase == BrowsePhase.ready
        ? List<Photo>.of(browser.photos)
        : <Photo>[];
    await organization.refreshDirectories();
    final visible = organization.restoreAlbums.map((a) => a.key).toSet();
    if (mappings.length != d.albums.length ||
        !d.albums.every((a) => mappings.containsKey(a.id))) {
      throw RestoreProblem('请逐项确认所有相册映射');
    }
    final used = <String>{};
    for (final selected in mappings.values.whereType<String>()) {
      if (!visible.contains(selected) || !used.add(selected)) {
        throw RestoreProblem('相册不可访问或两个相册选择了同一目标');
      }
    }
    if (manual.keys.any((id) => !d.favorites.any((f) => f.identity == id))) {
      throw RestoreProblem('手动收藏选择已过期');
    }
    final keys = <String, String>{};
    final descriptors = reassociation
        ? Map<String, AlbumDescriptor>.of(before.organization.descriptors)
        : <String, AlbumDescriptor>{};
    for (var i = 0; i < d.albums.length; i++) {
      final a = d.albums[i];
      final selected = mappings[a.id];
      final oldKey = reassociation ? a.id : null;
      // An association must not steal another existing tree position.
      if (reassociation &&
          selected != null &&
          selected != oldKey &&
          (before.organization.placements.containsKey(selected) ||
              before.organization.descriptors.containsKey(selected))) {
        throw RestoreProblem('目标相册已有分类位置，无法合并两个位置');
      }
      final key = selected ?? oldKey ?? '$pendingAlbumPrefix$i';
      keys[a.id] = key;
      if (oldKey != null && key != oldKey) descriptors.remove(oldKey);
      descriptors[key] = AlbumDescriptor(
        sourceKey: a.sourceKey,
        name: a.name,
        directory: a.directory,
        retainWhenEmpty: reassociation && key == oldKey
            ? before.organization.descriptors[key]?.retainWhenEmpty ?? false
            : false,
        pending:
            selected == null &&
            (oldKey == null || oldKey.startsWith(pendingAlbumPrefix)),
      );
    }
    final source = reassociation ? before.organization : d.organization;
    final rootDiscoveries = reassociation
        ? keys.entries
              .where((e) => e.key != e.value)
              .map((e) => e.value)
              .toSet()
        : <String>{};
    String remap(String key) => keys[key] ?? key;
    final tree = OrganizationSnapshot(
      source.folders.values,
      source.placements.map((k, v) => MapEntry(remap(k), v)),
      folderOrders: source.folderOrders,
      albumOrders: source.albumOrders.map(
        (k, v) => MapEntry(
          k,
          v.where((old) => !rootDiscoveries.contains(old)).map(remap).toList(),
        ),
      ),
      descriptors: descriptors,
    );
    final confirmed = reassociation
        ? Set<String>.of(before.favorites.confirmed)
        : <String>{};
    final pending = <PendingFavorite>[];
    final sources = reassociation
        ? Map<String, String>.of(before.favorites.sources)
        : <String, String>{};
    final matchesByRecord = <String, String>{};
    final reasons = <String, String>{};
    final targetCounts = <String, int>{};
    final version = browser.libraryVersion;
    final byIdentity = {
      for (final p in photos) favoriteIdentity(p, version): p,
    };
    final sizes = <String, int?>{};
    final hashes = <String, OriginalFingerprint?>{};
    for (final f in d.favorites) {
      if (epoch != null) _currentRead(epoch);
      String reason = 'not_accessible';
      String? resolved;
      final album = f.albumId == null ? null : mappings[f.albumId];
      final chosen = manual[f.identity];
      if (chosen != null) {
        final photo = byIdentity[chosen];
        if (photo == null ||
            photo.kind != f.mediaKind ||
            version == null ||
            (album != null && photo.albumKey != album)) {
          throw RestoreProblem('所选媒体已不可访问或不在确认相册中');
        }
        await media.size(
          photo,
          version,
        ); // Native check also catches unnotified edits.
        resolved = chosen;
      } else {
        final exact = byIdentity[f.identity];
        if (exact != null &&
            exact.kind == f.mediaKind &&
            version != null &&
            (album == null || exact.albumKey == album)) {
          try {
            await media.size(exact, version);
            resolved = f.identity;
          } catch (_) {
            reason = 'original_unavailable';
          }
        } else if (album == null) {
          reason = 'album_not_associated';
        } else if (f.fingerprint == null) {
          reason = 'missing_fingerprint';
        } else if (version == null) {
          reason = 'unknown_library_version';
        } else if (browser.access != PhotoAccess.full) {
          reason = 'partial_access_requires_choice';
        } else if (!readOriginals) {
          reason = 'original_permission_declined';
        } else {
          final matches = <Photo>[];
          var unavailable = false;
          for (final photo in photos.where(
            (p) => p.albumKey == album && p.kind == f.mediaKind,
          )) {
            if (epoch != null) _currentRead(epoch);
            if (!sizes.containsKey(photo.key)) {
              try {
                sizes[photo.key] = await media.size(photo, version);
              } catch (_) {
                sizes[photo.key] = null;
              }
            }
            if (epoch != null) _currentRead(epoch);
            if (sizes[photo.key] == null) {
              unavailable = true;
              continue;
            }
            if (sizes[photo.key] != f.fingerprint!.size) continue;
            if (!hashes.containsKey(photo.key)) {
              try {
                hashes[photo.key] = await originals.read(photo, version);
              } catch (_) {
                hashes[photo.key] = null;
              }
            }
            if (epoch != null) _currentRead(epoch);
            final hash = hashes[photo.key];
            if (hash == null) {
              unavailable = true;
              continue;
            }
            if (hash.fingerprint.size == f.fingerprint!.size &&
                hash.fingerprint.sha256 == f.fingerprint!.sha256) {
              matches.add(photo);
            }
          }
          if (matches.length == 1 && !unavailable) {
            resolved = favoriteIdentity(matches.single, version);
          } else {
            reason = matches.length > 1
                ? 'duplicate_content'
                : unavailable
                ? 'original_unavailable'
                : 'no_match';
          }
        }
      }
      if (resolved != null) {
        matchesByRecord[f.identity] = resolved;
        targetCounts[resolved] = (targetCounts[resolved] ?? 0) + 1;
      }
      reasons[f.identity] = reason;
    }
    // A pending record reserves its original identity. Propagate collisions so
    // another record cannot consume it and make the pending record disappear.
    final conflicts = <String>{};
    final reserving = <String>[];
    final byTarget = <String, List<String>>{};
    for (final f in d.favorites) {
      final resolved = matchesByRecord[f.identity];
      if (resolved != null) (byTarget[resolved] ??= []).add(f.identity);
      if (resolved == null ||
          (targetCounts[resolved] ?? 0) > 1 ||
          confirmed.contains(resolved)) {
        if (resolved != null) conflicts.add(f.identity);
        reserving.add(f.identity);
      }
    }
    for (var i = 0; i < reserving.length; i++) {
      for (final record in byTarget[reserving[i]] ?? <String>[]) {
        if (conflicts.add(record)) reserving.add(record);
      }
    }
    for (final f in d.favorites) {
      final resolved = matchesByRecord[f.identity];
      final conflict = conflicts.contains(f.identity);
      if (conflict && manual.containsKey(f.identity)) {
        throw RestoreProblem('所选媒体已被其他收藏记录使用，请选择其他媒体或暂不关联');
      }
      if (resolved != null && !conflict) {
        confirmed.add(resolved);
        if (f.source != 'legacy') sources[resolved] = f.source;
      } else {
        pending.add(
          PendingFavorite(
            identity: f.identity,
            source: f.source,
            albumKey: keys[f.albumId],
            filename: f.filename,
            size: f.fingerprint?.size,
            sha256: f.fingerprint?.sha256,
            reason: conflict ? 'target_conflict' : reasons[f.identity]!,
          ),
        );
      }
    }
    if (epoch != null) _currentRead(epoch);
    if (await browser.source.permission() != browser.permissions ||
        (browser.phase == BrowsePhase.ready &&
            (browser.collectionRevision == null ||
                await browser.source.collectionRevision() !=
                    browser.collectionRevision)) ||
        (browser.phase == BrowsePhase.ready &&
            await browser.source.libraryVersion() != browser.libraryVersion)) {
      throw RestoreProblem('媒体访问范围已变化，请刷新后重新预览');
    }
    return PrivateSnapshot(
      tree,
      FavoriteSnapshot(
        confirmed,
        pending,
        before.favorites.migrationOutcomes,
        sources,
      ),
    );
  }

  Future<RestorePreview> rollbackPreview() async {
    _ready();
    _acquire();
    busy = true;
    _publish();
    try {
      final target = (await journal.read()).rollback;
      if (target == null) throw RestoreProblem('没有可用的回滚副本');
      return RestorePreview._(
        _snapshot(),
        target,
        browser.generation,
        browser.libraryVersion,
        browser.collectionRevision,
        browser.permissions,
        browser.phase,
        null,
        const {},
        const {},
        false,
        false,
        true,
      );
    } finally {
      busy = false;
      _releaseGuard();
      _publish();
    }
  }

  Future<bool> apply(RestorePreview p) async {
    _ready();
    _acquire();
    busy = true;
    status = '正在核对确认内容…';
    _publish();
    var prepared = false;
    try {
      await _hold();
      _check(p);
      // Re-run native identity and content checks before any journal mutation.
      if (!p.rollback) {
        final checked = await _target(
          p.before,
          p.document!,
          p.mappings,
          p.manualPhotos,
          p.readOriginals,
          p.reassociation,
        );
        _check(p);
        if (!checked.same(p.target)) throw RestoreProblem('匹配结果已变化，请重新预览');
      }
      if (p.reassociation && p.before.same(p.target)) {
        status = '暂无可提交的关联变化，当前数据与回滚副本未改变。';
        _release();
        return false;
      }
      await checkpoint?.call('before-prepare');
      final op = RestoreOperation(
        DateTime.now().microsecondsSinceEpoch.toString(),
        p.before,
        p.target,
        false,
      );
      await journal.prepare(op);
      prepared = true;
      await checkpoint?.call('prepared');
      await organization.store.replace(p.target.organization);
      await checkpoint?.call('organization-written');
      await favorites.store.replace(p.target.favorites);
      await checkpoint?.call('favorites-written');
      await _verify(p.target);
      await checkpoint?.call('targets-verified');
      await journal.decide(op.id);
      await checkpoint?.call('decision-written');
      await journal.finish(op.id);
      hasRollback = true;
      _install(p.target);
      await checkpoint?.call('published');
      status =
          '私有恢复已完成；待关联相册 ${p.pendingAlbums} 个，待处理收藏 ${p.pendingFavorites} 条。收藏仅保存在 PhotoTree 内。';
      _release();
    } catch (error) {
      var completed = false;
      // A failed prepare/decision may have committed before returning an error.
      // Read the durable decision, never infer it from an in-memory flag.
      try {
        final active = (await journal.read()).active;
        if (active != null) {
          await _recover(active);
          completed = active.committed;
          status = active.committed ? '恢复提交已完成' : '恢复未完成，已还原原有私有数据';
          _release();
        } else if (!prepared) {
          status = error is RestoreProblem
              ? error.message
              : '恢复未开始，当前私有数据未替换。请检查数据后重试。';
          _release();
        } else {
          // finish may already have committed: verify the desired complete state.
          await _verify(p.target);
          _install(p.target);
          hasRollback = true;
          completed = true;
          status = '恢复提交已完成';
          _release();
        }
      } catch (_) {
        blocked = true;
        status = '恢复中断，已保留数据库与恢复材料。私有编辑和导出已暂停，请重试恢复。';
      }
      if (!completed) throw RestoreProblem(status ?? '恢复未完成，请重试。');
    } finally {
      busy = false;
      _publish();
    }
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
