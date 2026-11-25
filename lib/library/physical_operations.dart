import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../media/browser.dart';
import '../media/media_source.dart';
import '../media/physical_media.dart';
import '../organization/organization.dart';
import '../storage/directory_access.dart';
import '../storage/operation_guard.dart';
import 'favorites.dart';

export '../media/physical_media.dart' show PhysicalKind, PhysicalOutcome;

enum PhysicalItemState { queued, inFlight, finished }

class PhysicalItem {
  const PhysicalItem({
    required this.snapshot,
    this.state = PhysicalItemState.queued,
    this.outcome,
    this.after,
    this.privateCommitted = false,
  });
  final PhysicalPhotoSnapshot snapshot;
  final PhysicalItemState state;
  final PhysicalOutcome? outcome;
  final PhysicalPhotoSnapshot? after;
  final bool privateCommitted;
  PhysicalItem copy({
    PhysicalItemState? state,
    PhysicalOutcome? outcome,
    PhysicalPhotoSnapshot? after,
    bool? privateCommitted,
  }) => PhysicalItem(
    snapshot: snapshot,
    state: state ?? this.state,
    outcome: outcome ?? this.outcome,
    after: after ?? this.after,
    privateCommitted: privateCommitted ?? this.privateCommitted,
  );
  Map<String, Object?> toMap() => {
    'snapshot': snapshot.toMap(),
    'state': state.name,
    'outcome': outcome?.name,
    'after': after?.toMap(),
    'privateCommitted': privateCommitted,
  };
}

class PhysicalBatch {
  PhysicalBatch({
    required this.id,
    required this.kind,
    required List<PhysicalItem> items,
    this.targetDirectory,
    this.album,
    this.directoryToken,
    this.directoryState = PhysicalItemState.queued,
    this.directoryOutcome,
    this.directoryPrivateCommitted = false,
    this.authorizationPending = false,
  }) : items = List.unmodifiable(items);
  final String id;
  final PhysicalKind kind;
  final List<PhysicalItem> items;
  final String? targetDirectory, directoryToken;
  final DirectoryIdentity? album;
  final PhysicalItemState directoryState;
  final PhysicalOutcome? directoryOutcome;
  final bool directoryPrivateCommitted;
  final bool authorizationPending;
  PhysicalBatch copy({
    List<PhysicalItem>? items,
    PhysicalItemState? directoryState,
    PhysicalOutcome? directoryOutcome,
    bool? directoryPrivateCommitted,
    bool? authorizationPending,
  }) => PhysicalBatch(
    id: id,
    kind: kind,
    authorizationPending: authorizationPending ?? this.authorizationPending,
    items: items ?? this.items,
    targetDirectory: targetDirectory,
    album: album,
    directoryToken: directoryToken,
    directoryState: directoryState ?? this.directoryState,
    directoryOutcome: directoryOutcome ?? this.directoryOutcome,
    directoryPrivateCommitted:
        directoryPrivateCommitted ?? this.directoryPrivateCommitted,
  );
  String encode() => jsonEncode({
    'id': id,
    'kind': kind.name,
    'items': items.map((i) => i.toMap()).toList(),
    'targetDirectory': targetDirectory,
    'album': album == null
        ? null
        : {'volume': album!.volume, 'path': album!.path},
    'directoryToken': directoryToken,
    'directoryState': directoryState.name,
    'directoryOutcome': directoryOutcome?.name,
    'directoryPrivateCommitted': directoryPrivateCommitted,
    if (authorizationPending) 'authorizationPending': true,
  });
  static PhysicalBatch decode(String data) {
    final m = jsonDecode(data) as Map<String, dynamic>;
    PhysicalOutcome? outcome(Object? value) =>
        value == null ? null : PhysicalOutcome.values.byName(value as String);
    final b = PhysicalBatch(
      id: m['id'] as String,
      authorizationPending: m['authorizationPending'] as bool? ?? false,
      kind: PhysicalKind.values.byName(m['kind'] as String),
      items: (m['items'] as List).map((v) {
        final i = v as Map;
        return PhysicalItem(
          snapshot: PhysicalPhotoSnapshot.fromMap(i['snapshot'] as Map),
          state: PhysicalItemState.values.byName(i['state'] as String),
          outcome: outcome(i['outcome']),
          after: i['after'] == null
              ? null
              : PhysicalPhotoSnapshot.fromMap(i['after'] as Map),
          privateCommitted: i['privateCommitted'] as bool,
        );
      }).toList(),
      targetDirectory: m['targetDirectory'] as String?,
      album: m['album'] == null
          ? null
          : DirectoryIdentity(
              m['album']['volume'] as String,
              m['album']['path'] as String,
            ),
      directoryToken: m['directoryToken'] as String?,
      directoryState: PhysicalItemState.values.byName(
        m['directoryState'] as String,
      ),
      directoryOutcome: outcome(m['directoryOutcome']),
      directoryPrivateCommitted: m['directoryPrivateCommitted'] as bool,
    );
    void check(bool ok) {
      if (!ok) {
        throw const FormatException('Invalid physical operation journal');
      }
    }

    void snapshot(PhysicalPhotoSnapshot s) {
      check(
        s.photo.id > 0 &&
            s.libraryVersion.isNotEmpty &&
            DirectoryIdentity(s.photo.volume, s.photo.directory).supported &&
            s.displayName.isNotEmpty &&
            !s.displayName.contains('/') &&
            !s.displayName.contains('\\') &&
            s.size >= 0 &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(s.sha256),
      );
    }

    check(
      !b.authorizationPending ||
          (b.album == null &&
              b.items.every((i) => i.state == PhysicalItemState.queued)),
    );
    check(b.id.isNotEmpty && (b.items.isNotEmpty || b.album != null));
    check(
      b.kind == PhysicalKind.move
          ? b.album == null &&
                b.targetDirectory != null &&
                DirectoryIdentity(
                  'external_primary',
                  b.targetDirectory!,
                ).supported
          : b.targetDirectory == null,
    );
    final identities = <String>{};
    for (final i in b.items) {
      snapshot(i.snapshot);
      check(
        identities.add(
          favoriteIdentity(i.snapshot.photo, i.snapshot.libraryVersion)!,
        ),
      );
      check((i.state == PhysicalItemState.finished) == (i.outcome != null));
      check(!i.privateCommitted || i.outcome == PhysicalOutcome.confirmed);
      check(
        i.outcome != PhysicalOutcome.unchanged ||
            (b.kind == PhysicalKind.move &&
                i.snapshot.photo.directory == b.targetDirectory),
      );
      if (i.after != null) {
        snapshot(i.after!);
        check(
          b.kind == PhysicalKind.move &&
              i.outcome == PhysicalOutcome.confirmed &&
              i.after!.sha256 == i.snapshot.sha256 &&
              i.after!.size == i.snapshot.size &&
              i.after!.photo.directory == b.targetDirectory &&
              favoriteIdentity(i.after!.photo, i.after!.libraryVersion) ==
                  favoriteIdentity(i.snapshot.photo, i.snapshot.libraryVersion),
        );
      }
      check(
        b.kind != PhysicalKind.move ||
            i.outcome != PhysicalOutcome.confirmed ||
            i.after != null,
      );
      if (b.album != null) check(i.snapshot.photo.albumKey == b.album!.key);
    }
    if (b.album != null) {
      check(
        b.album!.supported &&
            b.directoryToken?.isNotEmpty == true &&
            b.kind == PhysicalKind.delete,
      );
      check(
        (b.directoryState == PhysicalItemState.finished) ==
            (b.directoryOutcome != null),
      );
      check(
        !b.directoryPrivateCommitted ||
            b.directoryOutcome == PhysicalOutcome.confirmed,
      );
      if (b.directoryOutcome == PhysicalOutcome.confirmed) {
        check(
          b.items.every(
            (i) => i.outcome == PhysicalOutcome.confirmed && i.privateCommitted,
          ),
        );
      }
    } else {
      check(
        b.directoryToken == null &&
            b.directoryState == PhysicalItemState.queued &&
            b.directoryOutcome == null &&
            !b.directoryPrivateCommitted,
      );
    }
    check(b.encode() == data);
    return b;
  }
}

abstract interface class PhysicalJournal {
  Future<List<PhysicalBatch>> read();
  Future<void> save(PhysicalBatch batch);
  Future<void> close();
}

class PhysicalOperations extends ChangeNotifier {
  PhysicalOperations(
    this.organization,
    this.favorites,
    this.browser,
    this.access,
    this.journal, {
    required this.guard,
  });
  final Organization organization;
  final Favorites favorites;
  final PhotoBrowser browser;
  final PhysicalMediaAccess access;
  final PhysicalJournal journal;
  final BackupOperationGuard guard;
  bool initialized = false, busy = false, blocked = false;
  String? issue;
  PhysicalBatch? preview;
  List<PhysicalBatch> _records = [];
  List<PhysicalBatch> get records => List.unmodifiable(_records);
  bool _held = false, _owned = false, _cancel = false, _disposed = false;
  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _take({bool recovery = false}) async {
    if (_held) return;
    guard.acquire(this);
    _owned = true;
    Future<void> a;
    try {
      a = organization.holdForBackup(allowCreationRecovery: recovery);
    } catch (_) {
      _release();
      rethrow;
    }
    try {
      final b = favorites.holdForBackup();
      _held = true;
      await a;
      await b;
    } catch (_) {
      if (!_held) organization.releaseBackup();
      rethrow;
    }
  }

  void _release() {
    if (_held) {
      _held = false;
      favorites.releaseBackup();
      organization.releaseBackup();
    }
    if (_owned) {
      _owned = false;
      guard.release(this);
    }
  }

  void _ready() {
    if (!initialized || blocked || busy || preview != null) {
      throw StateError('真实操作尚未就绪');
    }
  }

  void _fail(Object e) {
    debugPrint('Physical operation verification failed: $e');
    issue = '上次操作尚未核对完成，已暂停写入。请重新核对后再继续。';
    blocked = true;
  }

  Future<void> _persist(PhysicalBatch b) async {
    PhysicalBatch.decode(b.encode());
    try {
      await journal.save(b);
    } catch (_) {
      final saved = (await journal.read())
          .where((v) => v.id == b.id)
          .firstOrNull;
      if (saved?.encode() != b.encode()) rethrow;
    }
    _records = [..._records.where((v) => v.id != b.id), b];
    _publish();
  }

  Future<void> initialize() => reconcile();
  Future<void> reconcile() async {
    if (busy || preview != null) return;
    busy = true;
    _publish();
    try {
      await _take(recovery: true);
      await journal.close();
      final read = await journal.read();
      final ids = <String>{};
      for (final b in read) {
        PhysicalBatch.decode(b.encode());
        if (!ids.add(b.id)) throw StateError('重复操作记录');
      }
      _records = read;
      for (var b in List<PhysicalBatch>.of(_records)) {
        if (b.authorizationPending) {
          final status = await access.authorizationState();
          if (status != PhysicalOutcome.confirmed) {
            throw StateError('Media authorization may still be active');
          }
          b = b.copy(authorizationPending: false);
          await _persist(b);
        }
        for (var n = 0; n < b.items.length; n++) {
          var i = b.items[n];
          if (i.privateCommitted) continue;
          if (i.state == PhysicalItemState.queued) {
            i = i.copy(
              state: PhysicalItemState.finished,
              outcome: PhysicalOutcome.cancelled,
            );
          } else if (i.state == PhysicalItemState.inFlight ||
              i.outcome == PhysicalOutcome.unknown) {
            final r = await access.reconcilePhoto(
              b.kind,
              i.snapshot,
              targetDirectory: b.targetDirectory,
            );
            if (r.outcome == PhysicalOutcome.busy) {
              b = _withItem(b, n, _result(b, i, r));
              await _persist(b);
              throw StateError('Platform operation is still active');
            }
            i = _result(
              b,
              i,
              r.outcome == PhysicalOutcome.confirmed ||
                      r.outcome == PhysicalOutcome.failed ||
                      (r.outcome == PhysicalOutcome.unchanged &&
                          b.kind == PhysicalKind.move &&
                          i.snapshot.photo.directory == b.targetDirectory)
                  ? r
                  : const PhysicalResult(PhysicalOutcome.unknown),
            );
          }
          if (!identical(i, b.items[n])) {
            b = _withItem(b, n, i);
            await _persist(b);
          }
          b = await _commitItem(b, n);
        }
        if (b.album != null && !b.directoryPrivateCommitted) {
          if (b.directoryState == PhysicalItemState.queued) {
            b = b.copy(
              directoryState: PhysicalItemState.finished,
              directoryOutcome: PhysicalOutcome.cancelled,
            );
          } else if (b.directoryState == PhysicalItemState.inFlight ||
              b.directoryOutcome == PhysicalOutcome.unknown) {
            final r = await access.reconcileEmptyAlbum(
              b.album!.volume,
              b.album!.path,
              directoryToken: b.directoryToken!,
            );
            if (r.outcome == PhysicalOutcome.busy) {
              b = b.copy(
                directoryState: PhysicalItemState.finished,
                directoryOutcome: PhysicalOutcome.unknown,
              );
              await _persist(b);
              throw StateError('Platform directory operation is still active');
            }
            final valid = b.items.every(
              (i) =>
                  i.outcome == PhysicalOutcome.confirmed && i.privateCommitted,
            );
            b = b.copy(
              directoryState: PhysicalItemState.finished,
              directoryOutcome: r.outcome == PhysicalOutcome.confirmed && valid
                  ? PhysicalOutcome.confirmed
                  : r.outcome == PhysicalOutcome.failed
                  ? PhysicalOutcome.failed
                  : PhysicalOutcome.unknown,
            );
          }
          await _persist(b);
          await _commitDirectory(b);
        }
      }
      await browser.refresh();
      initialized = true;
      blocked = false;
      issue = null;
      _release();
    } catch (e) {
      _fail(e);
    } finally {
      busy = false;
      _publish();
    }
  }

  bool _browsable() =>
      browser.phase == BrowsePhase.ready &&
      browser.libraryVersion?.isNotEmpty == true;
  // Return the exact preview this request produced, so a disappearing UI can
  // release only its own result after asynchronous preparation finishes.
  Future<PhysicalBatch?> preparePhotos(
    List<Photo> photos, {
    required PhysicalKind kind,
    String? targetDirectory,
  }) async {
    try {
      _ready();
    } catch (e) {
      issue = '$e';
      _publish();
      return null;
    }
    photos = List.unmodifiable(photos);
    if (photos.any(
      (p) => !DirectoryIdentity(p.volume, p.directory).supported,
    )) {
      issue = '当前仅支持主存储 Pictures 或 DCIM 中的媒体';
      _publish();
      return null;
    }
    if (kind == PhysicalKind.move &&
        (targetDirectory == null ||
            !DirectoryIdentity(
              'external_primary',
              targetDirectory,
            ).supported)) {
      issue = '请选择主存储 Pictures 或 DCIM 中的真实目标相册';
      _publish();
      return null;
    }
    busy = true;
    _cancel = false;
    issue = null;
    _publish();
    try {
      await _take();
      if (!_browsable() || photos.isEmpty) throw StateError('媒体或访问权限已变化');
      final version = browser.libraryVersion!;
      final selected = {
        for (final p in photos) favoriteIdentity(p, version): p,
      };
      bool stillSelected() {
        final current = {
          for (final p in browser.photos)
            favoriteIdentity(p, browser.libraryVersion): p.directory,
        };
        return photos.every(
          (p) => current[favoriteIdentity(p, version)] == p.directory,
        );
      }

      if (selected.length != photos.length || !stillSelected()) {
        throw StateError('媒体选择已过期');
      }
      final prepared = <PhysicalPhotoSnapshot>[];
      // Freeze small read-only chunks; native execution still validates each
      // complete snapshot again immediately before its system request.
      for (var offset = 0; offset < photos.length; offset += 50) {
        if (_cancel) {
          _release();
          return null;
        }
        if (!_browsable() || browser.libraryVersion != version) {
          throw StateError('媒体权限或媒体库已变化，请重新核对');
        }
        final chunk = photos.skip(offset).take(50).toList();
        final result = await access.prepare(
          List.unmodifiable(chunk),
          version,
          targetDirectory: kind == PhysicalKind.move ? targetDirectory : null,
        );
        if (result.outcome != PhysicalOutcome.confirmed) {
          throw StateError(result.reason ?? result.outcome.name);
        }
        if (!_browsable() ||
            browser.libraryVersion != version ||
            result.photos.length != chunk.length ||
            !setEquals(
              result.photos
                  .map((p) => favoriteIdentity(p.photo, p.libraryVersion))
                  .toSet(),
              chunk.map((p) => favoriteIdentity(p, version)).toSet(),
            ) ||
            result.photos.any(
              (p) =>
                  selected[favoriteIdentity(p.photo, p.libraryVersion)]
                      ?.directory !=
                  p.photo.directory,
            )) {
          throw StateError('媒体核对结果已变化');
        }
        prepared.addAll(result.photos);
      }
      if (!stillSelected() ||
          prepared.length != photos.length ||
          !setEquals(
            prepared
                .map((p) => favoriteIdentity(p.photo, p.libraryVersion))
                .toSet(),
            selected.keys.toSet(),
          )) {
        throw StateError('媒体核对结果不完整');
      }
      final b = PhysicalBatch(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        kind: kind,
        targetDirectory: kind == PhysicalKind.move ? targetDirectory : null,
        items: prepared.map((s) => PhysicalItem(snapshot: s)).toList(),
      );
      PhysicalBatch.decode(b.encode());
      if (!_cancel) {
        preview = b;
        return b;
      } else {
        _release();
      }
    } catch (e) {
      issue = '$e';
      _release();
    } finally {
      busy = false;
      _publish();
    }
    return null;
  }

  Future<PhysicalBatch?> prepareAlbum(DirectoryIdentity directory) async {
    try {
      _ready();
    } catch (e) {
      issue = '$e';
      _publish();
      return null;
    }
    busy = true;
    _cancel = false;
    issue = null;
    _publish();
    try {
      await _take();
      if (!_browsable() ||
          browser.access != PhotoAccess.full ||
          !directory.supported) {
        throw StateError('需要完整媒体权限和可核对目录');
      }
      final version = browser.libraryVersion;
      final r = await access.inspectAlbum(directory.volume, directory.path);
      if (!_browsable() ||
          browser.access != PhotoAccess.full ||
          browser.libraryVersion != version ||
          r.photos.any((p) => p.libraryVersion != version)) {
        throw StateError('媒体权限或媒体库已变化，请重新核对');
      }
      if (r.outcome != PhysicalOutcome.confirmed ||
          r.directoryToken == null ||
          r.empty != r.photos.isEmpty) {
        throw StateError(r.reason ?? '相册包含不可安全处理的内容');
      }
      final b = PhysicalBatch(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        kind: PhysicalKind.delete,
        items: r.photos.map((s) => PhysicalItem(snapshot: s)).toList(),
        album: directory,
        directoryToken: r.directoryToken,
      );
      PhysicalBatch.decode(b.encode());
      if (!_cancel) {
        preview = b;
        return b;
      } else {
        _release();
      }
    } catch (e) {
      issue = '$e';
      _release();
    } finally {
      busy = false;
      _publish();
    }
    return null;
  }

  void cancelRemaining() {
    _cancel = true;
    _publish();
  }

  void cancelPreview() {
    if (busy) {
      cancelRemaining();
      return;
    }
    if (preview == null || blocked) return;
    preview = null;
    _release();
    _publish();
  }

  PhysicalBatch _withItem(PhysicalBatch b, int n, PhysicalItem i) =>
      b.copy(items: [...b.items.take(n), i, ...b.items.skip(n + 1)]);
  PhysicalItem _result(PhysicalBatch b, PhysicalItem i, PhysicalResult r) {
    if (b.kind == PhysicalKind.move &&
        r.outcome == PhysicalOutcome.confirmed &&
        (r.after == null ||
            r.after!.sha256 != i.snapshot.sha256 ||
            r.after!.size != i.snapshot.size ||
            r.after!.photo.directory != b.targetDirectory ||
            favoriteIdentity(r.after!.photo, r.after!.libraryVersion) !=
                favoriteIdentity(
                  i.snapshot.photo,
                  i.snapshot.libraryVersion,
                ))) {
      return i.copy(
        state: PhysicalItemState.finished,
        outcome: PhysicalOutcome.unknown,
      );
    }
    return i.copy(
      state: PhysicalItemState.finished,
      outcome: r.outcome == PhysicalOutcome.busy
          ? PhysicalOutcome.unknown
          : r.outcome,
      after:
          b.kind == PhysicalKind.move && r.outcome == PhysicalOutcome.confirmed
          ? r.after
          : null,
    );
  }

  AlbumDescriptor _descriptor(DirectoryIdentity d) => AlbumDescriptor(
    sourceKey: d.key,
    directory: d.path,
    name: d.path.split('/').where((p) => p.isNotEmpty).last,
    pending: false,
  );
  Future<PhysicalBatch> _commitItem(PhysicalBatch b, int n) async {
    final i = b.items[n];
    if (i.outcome != PhysicalOutcome.confirmed || i.privateCommitted) return b;
    final identity = favoriteIdentity(
      i.snapshot.photo,
      i.snapshot.libraryVersion,
    )!;
    if (b.kind == PhysicalKind.delete) {
      await favorites.commitPhysicalChange(deletedIdentities: {identity});
    } else {
      final after = i.after!;
      await organization.rememberPhysicalAlbums([
        _descriptor(
          DirectoryIdentity(after.photo.volume, after.photo.directory),
        ),
      ]);
      await favorites.commitPhysicalChange(
        movedLocations: {
          identity: (
            albumKey: after.photo.albumKey,
            filename: after.displayName,
          ),
        },
      );
    }
    b = _withItem(b, n, i.copy(privateCommitted: true));
    await _persist(b);
    return b;
  }

  Future<PhysicalBatch> _commitDirectory(PhysicalBatch b) async {
    if (b.directoryOutcome != PhysicalOutcome.confirmed ||
        b.directoryPrivateCommitted) {
      return b;
    }
    await favorites.commitPhysicalChange(detachedAlbumKeys: {b.album!.key});
    await organization.commitPhysicalAlbumDeletion({b.album!.key});
    b = b.copy(directoryPrivateCommitted: true);
    await _persist(b);
    return b;
  }

  Future<void> execute() async {
    if (busy || blocked || preview == null) return;
    var b = preview!;
    preview = null;
    busy = true;
    _cancel = false;
    _publish();
    try {
      await _persist(b);
      if (b.album == null) {
        final requested = b.items
            .where(
              (i) =>
                  b.kind != PhysicalKind.move ||
                  i.snapshot.photo.directory != b.targetDirectory,
            )
            .map((i) => i.snapshot)
            .toList();
        PhysicalOutcome? failure;
        for (
          var offset = 0;
          offset < requested.length && !_cancel;
          offset += 500
        ) {
          b = b.copy(authorizationPending: true);
          await _persist(b); // Before launching any external authorization UI.
          final result = await access.authorizePhotos(
            requested.skip(offset).take(500).toList(),
          );
          if (result.outcome == PhysicalOutcome.busy ||
              result.outcome == PhysicalOutcome.unknown) {
            throw StateError('Media authorization outcome is not known');
          }
          b = b.copy(authorizationPending: false);
          await _persist(b);
          if (result.outcome != PhysicalOutcome.confirmed) {
            failure = result.outcome;
            break;
          }
        }
        if (failure != null || _cancel) {
          b = b.copy(
            items: b.items
                .map(
                  (i) => i.copy(
                    state: PhysicalItemState.finished,
                    outcome: failure ?? PhysicalOutcome.cancelled,
                  ),
                )
                .toList(),
          );
          await _persist(b);
          issue = '未开始处理媒体';
          _release();
          return;
        }
      }
      final dirs = {
        for (final i in b.items)
          i.snapshot.photo.albumKey: DirectoryIdentity(
            i.snapshot.photo.volume,
            i.snapshot.photo.directory,
          ),
      };
      if (b.album != null) dirs[b.album!.key] = b.album!;
      if (b.targetDirectory != null) {
        final d = DirectoryIdentity('external_primary', b.targetDirectory!);
        dirs[d.key] = d;
      }
      await organization.rememberPhysicalAlbums(dirs.values.map(_descriptor));
      for (var n = 0; n < b.items.length; n++) {
        var i = b.items[n];
        if (_cancel) {
          i = i.copy(
            state: PhysicalItemState.finished,
            outcome: PhysicalOutcome.cancelled,
          );
          b = _withItem(b, n, i);
          await _persist(b);
          continue;
        }
        i = i.copy(state: PhysicalItemState.inFlight);
        b = _withItem(b, n, i);
        await _persist(b);
        PhysicalResult r;
        try {
          r = await access.executePhoto(
            b.kind,
            i.snapshot,
            targetDirectory: b.targetDirectory,
            authorized: b.album == null,
          );
        } catch (_) {
          r = const PhysicalResult(PhysicalOutcome.unknown);
        }
        b = _withItem(b, n, _result(b, i, r));
        if (b.items[n].outcome == PhysicalOutcome.cancelled ||
            b.items[n].outcome == PhysicalOutcome.unknown ||
            b.items[n].outcome == PhysicalOutcome.permission ||
            b.items[n].outcome == PhysicalOutcome.stale) {
          _cancel = true;
        }
        await _persist(b);
        if (r.outcome == PhysicalOutcome.busy) {
          throw StateError('Platform operation is still active');
        }
        b = await _commitItem(b, n);
      }
      if (b.album != null) {
        if (_cancel ||
            !b.items.every(
              (i) =>
                  i.outcome == PhysicalOutcome.confirmed && i.privateCommitted,
            )) {
          b = b.copy(
            directoryState: PhysicalItemState.finished,
            directoryOutcome: PhysicalOutcome.cancelled,
          );
          await _persist(b);
        } else {
          b = b.copy(directoryState: PhysicalItemState.inFlight);
          await _persist(b);
          PhysicalResult r;
          try {
            r = await access.deleteEmptyAlbum(
              b.album!.volume,
              b.album!.path,
              directoryToken: b.directoryToken!,
            );
          } catch (_) {
            r = const PhysicalResult(PhysicalOutcome.unknown);
          }
          b = b.copy(
            directoryState: PhysicalItemState.finished,
            directoryOutcome: r.outcome == PhysicalOutcome.busy
                ? PhysicalOutcome.unknown
                : r.outcome,
          );
          await _persist(b);
          if (r.outcome == PhysicalOutcome.busy) {
            throw StateError('Platform directory operation is still active');
          }
          await _commitDirectory(b);
        }
      }
      await browser.refresh();
      issue = '本次处理已结束，请核对逐项结果';
      _release();
    } catch (e) {
      _fail(e);
    } finally {
      busy = false;
      _publish();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
