import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../media/browser.dart';
import '../media/media_source.dart';
import '../storage/directory_access.dart';
import '../storage/operation_guard.dart';
import 'album_creation.dart';

const rootFolder = 'root';
// Real album keys always contain a volume separator; pending keys never do.
const pendingAlbumPrefix = '@pending/';

class AlbumDescriptor {
  const AlbumDescriptor({
    this.sourceKey,
    this.name,
    this.directory,
    required this.pending,
    this.retainWhenEmpty = false,
  });
  final String? sourceKey, name, directory;
  final bool pending;
  // Local display preference; a successful media observation consumes it.
  final bool retainWhenEmpty;
}

class AlbumFolder {
  const AlbumFolder(this.id, this.parent, this.name);
  final String id, parent, name;
}

class OrganizationError implements Exception {
  const OrganizationError(this.message);
  final String message;
  @override
  String toString() => message;
}

String folderName(String input) {
  if (input.runes.any(
    (c) => c < 32 || (c >= 127 && c <= 159) || c == 0x2028 || c == 0x2029,
  )) {
    throw const OrganizationError('名称必须为单行文本，不能包含控制字符');
  }
  final name = input.trim();
  if (name.isEmpty || name.runes.length > 64) {
    throw const OrganizationError('名称须为 1–64 个字符');
  }
  return name;
}

class OrganizationSnapshot {
  OrganizationSnapshot(
    Iterable<AlbumFolder> folders,
    Map<String, String> placements, {
    Map<String, List<String>> folderOrders = const {},
    Map<String, List<String>> albumOrders = const {},
    Map<String, AlbumDescriptor> descriptors = const {},
  }) : folders = Map.unmodifiable({for (final f in folders) f.id: f}),
       placements = Map.unmodifiable(placements),
       folderOrders = _freeze(folderOrders),
       albumOrders = _freeze(albumOrders),
       descriptors = Map.unmodifiable(descriptors) {
    if (this.folders.length != folders.length) {
      throw const OrganizationError('文件夹标识重复');
    }
    validate();
  }
  final Map<String, AlbumFolder> folders;
  final Map<String, String> placements;
  final Map<String, AlbumDescriptor> descriptors;
  final Map<String, List<String>> folderOrders, albumOrders;
  static Map<String, List<String>> _freeze(Map<String, List<String>> source) =>
      Map.unmodifiable(
        source.map((k, v) => MapEntry(k, List<String>.unmodifiable(v))),
      );

  // Retain hidden slots; append newly observed keys only in customized layers.
  OrganizationSnapshot discover(Iterable<Album> visible) {
    final retained = withoutEmptyRetention(
      visible.where((a) => a.photos.isNotEmpty).map((a) => a.key),
    );
    final orders = Map<String, List<String>>.of(albumOrders);
    var changed = !identical(retained, this);
    for (final parent in orders.keys.toList()) {
      final next = [...orders[parent]!];
      for (final album in visible) {
        if (parentOfAlbum(album.key) == parent && !next.contains(album.key)) {
          next.add(album.key);
          changed = true;
        }
      }
      orders[parent] = next;
    }
    return changed
        ? OrganizationSnapshot(
            folders.values,
            placements,
            folderOrders: folderOrders,
            albumOrders: orders,
            descriptors: retained.descriptors,
          )
        : this;
  }

  OrganizationSnapshot withoutEmptyRetention(Iterable<String> keys) {
    Map<String, AlbumDescriptor>? next;
    for (final key in keys) {
      final d = descriptors[key];
      if (d == null || !d.retainWhenEmpty) continue;
      next ??= Map.of(descriptors);
      next[key] = AlbumDescriptor(
        sourceKey: d.sourceKey,
        name: d.name,
        directory: d.directory,
        pending: d.pending,
      );
    }
    return next == null
        ? this
        : OrganizationSnapshot(
            folders.values,
            placements,
            folderOrders: folderOrders,
            albumOrders: albumOrders,
            descriptors: next,
          );
  }

  List<Album> albums(String parent, Iterable<Album> visible) {
    final local = visible.where((a) => parentOfAlbum(a.key) == parent).toList()
      ..sort((a, b) {
        final name = a.name.compareTo(b.name);
        return name == 0 ? a.key.compareTo(b.key) : name;
      });
    final order = albumOrders[parent];
    if (order == null) return local;
    final byKey = {for (final a in local) a.key: a};
    return [
      for (final key in order)
        if (byKey.containsKey(key)) byKey[key]!,
      ...local.where((a) => !order.contains(a.key)),
    ];
  }

  List<String> albumSlots(String parent, Iterable<Album> visible) => [
    ...?albumOrders[parent],
    for (final a in albums(parent, visible))
      if (!(albumOrders[parent]?.contains(a.key) ?? false)) a.key,
    ...{...placements.keys, ...descriptors.keys}
        .where(
          (key) =>
              parentOfAlbum(key) == parent &&
              !(albumOrders[parent]?.contains(key) ?? false) &&
              !visible.any((a) => a.key == key),
        )
        .toList()
      ..sort(),
  ];

  OrganizationSnapshot withTree(
    Iterable<AlbumFolder> nextFolders,
    Map<String, String> nextPlacements,
  ) {
    final plain = OrganizationSnapshot(
      nextFolders,
      nextPlacements,
      descriptors: descriptors,
    );
    return OrganizationSnapshot(
      nextFolders,
      nextPlacements,
      descriptors: descriptors,
      folderOrders: {
        for (final e in folderOrders.entries)
          if (plain.exists(e.key))
            e.key: [
              ...e.value.where((id) => plain.folders[id]?.parent == e.key),
              ...plain
                  .children(e.key)
                  .map((f) => f.id)
                  .where((id) => !e.value.contains(id)),
            ],
      },
      albumOrders: {
        for (final e in albumOrders.entries)
          if (plain.exists(e.key))
            e.key: [
              ...e.value.where((key) => plain.parentOfAlbum(key) == e.key),
              ...nextPlacements.keys.where(
                (key) => nextPlacements[key] == e.key && !e.value.contains(key),
              ),
            ],
      },
    );
  }

  bool exists(String id) => id == rootFolder || folders.containsKey(id);
  String parentOfAlbum(String key) => placements[key] ?? rootFolder;
  List<String> path(String id) {
    final path = <String>[];
    while (id != rootFolder) {
      final folder = folders[id];
      if (folder == null || path.contains(id)) {
        throw const OrganizationError('组织关系无效');
      }
      path.add(id);
      id = folder.parent;
    }
    return [rootFolder, ...path.reversed];
  }

  void validate() {
    for (final e in descriptors.entries) {
      if (e.key.isEmpty ||
          e.value.pending != e.key.startsWith(pendingAlbumPrefix) ||
          (e.value.pending && e.key.contains(':'))) {
        throw const OrganizationError('待关联相册描述无效');
      }
    }
    final names = <(String, String)>{};
    final childrenByParent = <String, Set<String>>{};
    for (final f in folders.values) {
      if (f.id.isEmpty ||
          f.id == rootFolder ||
          !exists(f.parent) ||
          folderName(f.name) != f.name) {
        throw const OrganizationError('组织关系无效');
      }
      if (!names.add((f.parent, f.name))) {
        throw const OrganizationError('目标下已有同名相册文件夹');
      }
      (childrenByParent[f.parent] ??= {}).add(f.id);
    }
    // Each node is visited at most once, including long imported chains.
    final checked = <String>{rootFolder};
    for (final id in folders.keys) {
      final chain = <String>{};
      var at = id;
      while (!checked.contains(at)) {
        if (!chain.add(at)) {
          throw const OrganizationError('组织关系无效');
        }
        at = folders[at]!.parent;
      }
      checked.addAll(chain);
    }
    final placementsByParent = <String, Set<String>>{};
    for (final entry in placements.entries) {
      if (entry.key.isEmpty ||
          entry.value == rootFolder ||
          !folders.containsKey(entry.value)) {
        throw const OrganizationError('相册归类关系无效');
      }
      (placementsByParent[entry.value] ??= {}).add(entry.key);
    }
    for (final orders in [folderOrders, albumOrders]) {
      for (final e in orders.entries) {
        if (!exists(e.key) ||
            e.value.toSet().length != e.value.length ||
            e.value.any((key) => key.isEmpty)) {
          throw const OrganizationError('排序记录无效');
        }
      }
    }
    for (final e in folderOrders.entries) {
      if (!setEquals(childrenByParent[e.key] ?? <String>{}, e.value.toSet())) {
        throw const OrganizationError('文件夹排序关系无效');
      }
    }
    for (final e in albumOrders.entries) {
      final slots = e.value.toSet();
      if (e.value.any((key) => parentOfAlbum(key) != e.key) ||
          !(placementsByParent[e.key] ?? <String>{}).every(slots.contains)) {
        throw const OrganizationError('相册排序关系无效');
      }
    }
  }

  List<AlbumFolder> children(String parent) {
    final order = folderOrders[parent];
    if (order != null) return order.map((id) => folders[id]!).toList();
    return folders.values.where((f) => f.parent == parent).toList()
      ..sort((a, b) {
        final n = a.name.compareTo(b.name);
        return n == 0 ? a.id.compareTo(b.id) : n;
      });
  }

  bool includes(String ancestor, String folder) =>
      path(folder).contains(ancestor);
  int invisibleCount(String folder, Iterable<Album> visible) {
    final keys = visible.map((a) => a.key).toSet();
    return placements.entries
        .where((e) => !keys.contains(e.key) && includes(folder, e.value))
        .length;
  }

  int photoCount(String folder, Iterable<Album> visible) => {
    for (final album in visible)
      if (includes(folder, parentOfAlbum(album.key)))
        for (final p in album.photos) p.key,
  }.length;
}

// The adapter atomically persists only changed private rows. No media APIs.
abstract interface class OrganizationStore {
  Future<OrganizationSnapshot> read();
  Future<void> save(OrganizationSnapshot before, OrganizationSnapshot after);
  Future<void> replace(OrganizationSnapshot snapshot);
  Future<void> close();
}

// A confirmation is bound to exactly the private tree and media scope shown.
class FolderDissolution {
  FolderDissolution._({
    required this.base,
    required this.generation,
    required this.mediaPhase,
    required this.folder,
    required this.childFolders,
    required this.albums,
    required this.hiddenAlbums,
    required this.next,
  });
  final OrganizationSnapshot base, next;
  final int generation, childFolders, albums, hiddenAlbums;
  final BrowsePhase mediaPhase;
  final AlbumFolder folder;
  String get target => folder.parent;
}

enum OrganizationPhase { loading, ready, failed }

class Organization extends ChangeNotifier {
  Organization(
    this.store,
    this.browser, {
    this.directories,
    BackupOperationGuard? operationGuard,
  }) : operationGuard = operationGuard ?? BackupOperationGuard() {
    browser.addListener(_mediaChanged);
  }
  void _mediaChanged() {
    if (phase == OrganizationPhase.ready &&
        browser.phase == BrowsePhase.ready) {
      unawaited(refreshDirectories());
    }
    if (!_backupHeld &&
        phase == OrganizationPhase.ready &&
        browser.phase == BrowsePhase.ready &&
        (_observedRetainedAlbums.isNotEmpty ||
            !identical(_snapshot.discover(albums), _snapshot))) {
      unawaited(retryDiscovery());
    }
  }

  String? _discoveryError;
  final Set<String> _observedRetainedAlbums = {};
  String? get discoveryError => _discoveryError;
  Future<void> retryDiscovery() async {
    if (_disposed || _backupHeld) return;
    // Capture positive evidence before the serial queue: a later refresh may
    // already have removed these media, but cannot undo that they were seen.
    if (browser.phase == BrowsePhase.ready) {
      _observedRetainedAlbums.addAll(
        browser.photos
            .map((p) => p.albumKey)
            .where(
              (key) => _snapshot.descriptors[key]?.retainWhenEmpty == true,
            ),
      );
    }
    final seen = Set<String>.of(_observedRetainedAlbums);
    final error = await _change((s) {
      s = s.withoutEmptyRetention(seen);
      return browser.phase == BrowsePhase.ready ? s.discover(albums) : s;
    });
    _discoveryError = error == null ? null : '相册显示或顺序尚未保存，请重试';
    if (error == null) {
      _observedRetainedAlbums.removeWhere(
        (key) => _snapshot.descriptors[key]?.retainWhenEmpty != true,
      );
    }
    _publish();
  }

  final OrganizationStore store;
  final PhotoBrowser browser;
  final PhysicalDirectoryAccess? directories;
  final BackupOperationGuard operationGuard;
  List<AlbumCreationRecord> _creations = [];
  List<AlbumCreationRecord> get creations => List.unmodifiable(_creations);
  final Map<String, String> _liveTokens = {};
  final Map<String, DirectoryReading> _directoryReadings = {};
  bool _creationLoaded = false, _cancelCreation = false;
  int _directoryEpoch = 0, _directoryRevision = 0;
  int get directoryRevision => _directoryRevision;
  bool get physicalCreationAvailable =>
      directories != null && store is AlbumCreationStore;
  String? get creationIssue => !physicalCreationAvailable
      ? null
      : !_creationLoaded
      ? '正在核对相册创建记录'
      : _creations.any((r) => r.unresolved)
      ? '请先处理未完成的相册创建记录，再备份或恢复'
      : null;
  bool canRetryCreation(String id) => _liveTokens.containsKey(id);

  /// One derived read-only view; PhotoBrowser still exclusively owns photos.
  List<Album> get albums => _albumsWithDirectories(_snapshot.descriptors.keys);

  bool isHiddenEmptyAlbum(Album album) =>
      phase == OrganizationPhase.ready &&
      browser.phase == BrowsePhase.ready &&
      browser.access == PhotoAccess.full &&
      album.photos.isEmpty &&
      album.availability == AlbumAvailability.empty &&
      _snapshot.descriptors[album.key]?.retainWhenEmpty != true;

  bool canHideEmptyAlbum(Album album) =>
      phase == OrganizationPhase.ready &&
      browser.phase == BrowsePhase.ready &&
      browser.access == PhotoAccess.full &&
      album.photos.isEmpty &&
      album.availability == AlbumAvailability.empty &&
      _snapshot.descriptors[album.key]?.retainWhenEmpty == true;

  Future<String?> hideEmptyAlbum(String key) async {
    if (_disposed || operationGuard.held || busy) return '另一项操作正在进行，请稍后重试';
    final album = albums.where((a) => a.key == key).firstOrNull;
    if (album == null || !canHideEmptyAlbum(album) || directories == null) {
      return '相册状态已变化，请重新核对';
    }
    final base = _snapshot;
    final generation = browser.generation;
    final revision = directoryRevision;
    final split = key.indexOf(':');
    final reading = await directories!.readDirectory(
      DirectoryIdentity(key.substring(0, split), key.substring(split + 1)),
    );
    if (reading.contents != DirectoryContents.empty) return reading.reason;
    return _change((s) {
      if (operationGuard.held ||
          !identical(base, s) ||
          generation != browser.generation ||
          revision != directoryRevision ||
          browser.phase != BrowsePhase.ready ||
          browser.access != PhotoAccess.full) {
        throw const OrganizationError('相册状态已变化，请重新核对');
      }
      return s.withoutEmptyRetention([key]);
    });
  }

  List<Album> _albumsWithDirectories(Iterable<String> directoryKeys) {
    final result = {
      for (final a
          in (browser.phase == BrowsePhase.ready || browser.updating)
              ? browser.albums
              : <Album>[])
        a.key: a,
    };
    for (final key in directoryKeys) {
      if (result.containsKey(key) || key.startsWith(pendingAlbumPrefix)) {
        continue;
      }
      final split = key.indexOf(':');
      if (split < 0) continue;
      final directory = DirectoryIdentity(
        key.substring(0, split),
        key.substring(split + 1),
      );
      if (!directory.supported) continue;
      final reading = _directoryReadings[key];
      final availability = switch (reading?.contents) {
        DirectoryContents.empty => AlbumAvailability.empty,
        DirectoryContents.content => AlbumAvailability.unindexed,
        DirectoryContents.missing => AlbumAvailability.missing,
        _ => AlbumAvailability.unverified,
      };
      result[key] = Album(
        key,
        directory.path,
        [],
        availability: availability,
        status: reading?.reason ?? '目录状态待核对',
      );
    }
    return List.unmodifiable(result.values);
  }

  // A checked restore target is only a candidate until a private transaction
  // associates it. Read caches never define ordinary library membership.
  List<Album> get restoreAlbums =>
      _albumsWithDirectories({
            ..._snapshot.descriptors.keys,
            ..._directoryReadings.keys,
          })
          .where(
            (a) =>
                a.availability == AlbumAvailability.indexed ||
                a.availability == AlbumAvailability.empty ||
                a.availability == AlbumAvailability.unindexed,
          )
          .toList();

  Future<void> refreshDirectories() async {
    final access = directories;
    if (access == null || _disposed) return;
    final epoch = ++_directoryEpoch;
    final keys = {..._snapshot.descriptors.keys, ..._directoryReadings.keys};
    for (final key in keys) {
      _directoryReadings[key] = const DirectoryReading(
        DirectoryContents.failed,
        '目录状态正在核对',
      );
    }
    _directoryRevision++;
    _publish();
    for (final key in keys) {
      if (key.startsWith(pendingAlbumPrefix) ||
          browser.albums.any((a) => a.key == key)) {
        continue;
      }
      final split = key.indexOf(':');
      if (split < 0) continue;
      final d = DirectoryIdentity(
        key.substring(0, split),
        key.substring(split + 1),
      );
      if (!d.supported) continue;
      final reading = await access.readDirectory(d);
      if (_disposed || epoch != _directoryEpoch) return;
      _directoryReadings[key] = reading;
    }
    _directoryRevision++;
    _publish();
  }

  /// Explicit read discovery for an existing empty-directory restore target.
  Future<String?> inspectRestoreDirectory(DirectoryIdentity directory) async {
    if (directories == null || !directory.supported) return '不支持此目录';
    final reading = await directories!.readDirectory(directory);
    if (_disposed) return '操作已结束';
    _directoryReadings[directory.key] = reading;
    _directoryRevision++;
    _publish();
    return reading.verified ? null : reading.reason;
  }

  Future<void> loadCreationHistory({OrganizationSnapshot? organization}) async {
    if (!physicalCreationAvailable) return;
    final persistence = store as AlbumCreationStore;
    final authoritative = organization ?? _snapshot;
    Future<void> releaseMissingParent(AlbumCreationRecord record) async {
      final token = _liveTokens[record.id];
      if (token != null &&
          record.treeParent != rootFolder &&
          !authoritative.folders.containsKey(record.treeParent)) {
        await _endCreationSession(record.id, token);
      }
    }

    // A committed removal already makes these credentials unusable, even if
    // the journal cannot be read or updated afterwards.
    for (final record in _creations) {
      await releaseMissingParent(record);
    }
    final records = await persistence.readCreations();
    // A disk stamp cannot recreate a live credential. No filesystem writes.
    final next = <AlbumCreationRecord>[];
    for (final record in records) {
      await releaseMissingParent(record);
      if (record.unresolved &&
          !_liveTokens.containsKey(record.id) &&
          record.outcome != CreationOutcome.unknown) {
        final unknown = record.update(outcome: CreationOutcome.unknown);
        await persistence.recordCreation(unknown);
        next.add(unknown);
      } else {
        next.add(record);
      }
    }
    _creations = next;
    _creationLoaded = true;
  }

  String _newId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  void cancelCreation() {
    _cancelCreation = true;
  }

  Future<void> _remember(AlbumCreationRecord record) async {
    await (store as AlbumCreationStore).recordCreation(record);
    _creations = [..._creations.where((r) => r.id != record.id), record];
    _publish();
  }

  /// Reconcile uncertain private write responses before releasing the serial
  /// owner to another mutation. If the authoritative read fails, stale state
  /// must remain read-only until an explicit successful load.
  Future<void> _refreshPrivateState() async {
    try {
      final loaded = await store.read();
      loaded.validate();
      await loadCreationHistory(organization: loaded);
      _snapshot = loaded;
      for (final id in _liveTokens.keys.toList()) {
        if (!_creations.any((r) => r.id == id && r.unresolved)) {
          await directories!.end(_liveTokens.remove(id)!);
        }
      }
    } catch (_) {
      _creationLoaded = false;
      _phase = OrganizationPhase.failed;
      rethrow;
    }
  }

  Future<bool> _recoverPrivateResponse() async {
    try {
      await _refreshPrivateState();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _physical(Future<String?> Function() work) {
    if (!physicalCreationAvailable ||
        !_creationLoaded ||
        _disposed ||
        _backupHeld ||
        phase != OrganizationPhase.ready) {
      return Future.value('组织数据或目录能力尚不可用');
    }
    try {
      operationGuard.acquire(this);
    } catch (_) {
      return Future.value('另一项媒体、备份或恢复操作正在进行');
    }
    _pending++;
    _cancelCreation = false;
    _publish();
    final result = Completer<String?>();
    _tail = _tail.then((_) async {
      try {
        if (_disposed || phase != OrganizationPhase.ready) {
          throw const OrganizationError('组织数据尚不可用，请重试加载');
        }
        // Queued requests must not use a pre-commit UI snapshot or journal.
        await _refreshPrivateState();
        result.complete(await work());
      } on OrganizationError catch (e) {
        final readable = await _recoverPrivateResponse();
        result.complete(readable ? e.message : '无法核对私有提交结果，请重试加载');
      } catch (_) {
        final readable = await _recoverPrivateResponse();
        result.complete(
          readable ? '操作响应异常，已重新读取创建记录，请查看实际结果' : '无法核对私有提交结果，请重试加载',
        );
      } finally {
        _pending--;
        operationGuard.release(this);
        _publish();
      }
    });
    return result.future;
  }

  OrganizationSnapshot _associated(
    String key,
    String directory,
    String parent,
  ) {
    _target(_snapshot, parent);
    if (_snapshot.descriptors.containsKey(key) ||
        _snapshot.placements.containsKey(key) ||
        browser.albums.any((a) => a.key == key)) {
      throw const OrganizationError('此目录已有相册节点，原有归属未改变；可结束跟进后管理原节点');
    }
    final s = _orderedTarget(_snapshot, parent, folders: false);
    return OrganizationSnapshot(
      s.folders.values,
      {...s.placements, if (parent != rootFolder) key: parent},
      descriptors: {
        ...s.descriptors,
        key: AlbumDescriptor(
          sourceKey: key,
          name: directory.split('/').where((p) => p.isNotEmpty).last,
          directory: directory,
          pending: false,
          retainWhenEmpty: true,
        ),
      },
      folderOrders: s.folderOrders,
      albumOrders: {
        ...s.albumOrders,
        parent: [
          ...s.albumOrders[parent]!,
          if (!s.albumOrders[parent]!.contains(key)) key,
        ],
      },
    );
  }

  Future<void> _endCreationSession(String id, String token) async {
    if (_liveTokens[id] == token) _liveTokens.remove(id);
    await directories!.end(token);
  }

  Future<bool> _verifyCreationSession(String id, String token) async {
    if (await directories!.verify(token)) return true;
    await _endCreationSession(id, token);
    return false;
  }

  Future<void> _commitAssociation(
    AlbumCreationRecord record,
    String directory,
    String parent,
    String token,
  ) async {
    final key = 'external_primary:$directory';
    if (!await _verifyCreationSession(record.id, token)) {
      throw const OrganizationError('目录会话已失效，结果待核对');
    }
    try {
      _target(_snapshot, parent);
    } on OrganizationError {
      await _endCreationSession(record.id, token);
      rethrow;
    }
    final next = _associated(key, directory, parent);
    await (store as AlbumCreationStore).commitCreation(
      _snapshot,
      next,
      record,
      validate: () => _verifyCreationSession(record.id, token),
    );
    // A completed transaction is authoritative even if its response is lost.
    _snapshot = next;
    _creations = [..._creations.where((r) => r.id != record.id), record];
    final reading = await directories!.readDirectory(
      DirectoryIdentity('external_primary', directory),
    );
    _directoryReadings[key] = reading;
    _directoryRevision++;
  }

  Future<String?> createAlbum(
    String parent,
    DirectoryIdentity physicalParent,
    String input,
  ) => _physical(() async {
    if (_creations.any((r) => r.unresolved)) return '请先处理上次未完成的创建';
    _target(_snapshot, parent);
    final name = physicalAlbumName(input);
    if (!physicalParent.supported) return '仅支持主共享存储 Pictures/ 或 DCIM/ 内目录';
    final token = await directories!.begin(physicalParent);
    if (token == null) return '目录授权或身份无法确认，请重新选择并授权';
    var keep = false;
    var record = AlbumCreationRecord(
      id: _newId(),
      parentDirectory: physicalParent.path,
      name: name,
      treeParent: parent,
      outcome: CreationOutcome.prepared,
    );
    try {
      _target(_snapshot, parent);
      await _remember(record); // Failure here must imply zero shared writes.
      if (_cancelCreation || _disposed) {
        await _remember(record.update(outcome: CreationOutcome.cancelled));
        return '已取消，未建立目录';
      }
      _target(_snapshot, parent);
      final outcome = await directories!.create(token, name);
      if (outcome != DirectoryCreationResult.created) {
        await _remember(
          record.update(
            outcome: switch (outcome) {
              DirectoryCreationResult.conflict => CreationOutcome.conflict,
              DirectoryCreationResult.failed => CreationOutcome.failed,
              _ => CreationOutcome.unknown,
            },
          ),
        );
        return outcome == DirectoryCreationResult.conflict
            ? '已有同名文件或目录，未合并或改名'
            : outcome == DirectoryCreationResult.failed
            ? '未能建立目录，请重新核对'
            : '无法确认创建结果，请处理待核对记录';
      }
      _liveTokens[record.id] = token;
      keep = true;
      record = record.update(outcome: CreationOutcome.created);
      await _remember(record);
      await _commitAssociation(
        record.update(outcome: CreationOutcome.completed),
        record.directory,
        parent,
        token,
      );
      keep = false;
      _liveTokens.remove(record.id);
      return null;
    } finally {
      if (!keep) await directories!.end(token);
    }
  });

  Future<String?> retryAlbumCreation(String id) => _physical(() async {
    final current = (await (store as AlbumCreationStore).readCreations())
        .where((r) => r.id == id)
        .firstOrNull;
    if (current == null) return '创建记录已不存在';
    if (!current.unresolved) {
      _snapshot = await store.read();
      await loadCreationHistory();
      final token = _liveTokens.remove(id);
      if (token != null) await directories!.end(token);
      return null;
    }
    final token = _liveTokens[id];
    if (token == null || !await directories!.verify(token)) {
      if (token != null) await directories!.end(token);
      _liveTokens.remove(id);
      await _remember(current.update(outcome: CreationOutcome.unknown));
      return '无法确认上次创建结果，请重新选择目录或结束跟进';
    }
    await _commitAssociation(
      current.update(outcome: CreationOutcome.completed),
      current.directory,
      current.treeParent,
      token,
    );
    _liveTokens.remove(id);
    await directories!.end(token);
    return null;
  });

  Future<String?> resolveAlbumCreation(
    String id, {
    DirectoryIdentity? existing,
    String? parent,
  }) => _physical(() async {
    final record = _creations
        .where((r) => r.id == id && r.unresolved)
        .firstOrNull;
    if (record == null) return '此记录已处理';
    final oldToken = _liveTokens.remove(id);
    if (oldToken != null) await directories!.end(oldToken);
    // A resolution never promotes uncertain historical execution to success.
    final unknown = record.update(outcome: CreationOutcome.unknown);
    await _remember(unknown);
    if (existing == null) {
      final resolved = unknown.update(resolution: CreationResolution.dismissed);
      await (store as AlbumCreationStore).commitCreation(
        _snapshot,
        _snapshot,
        resolved,
      );
      _creations = [..._creations.where((r) => r.id != id), resolved];
      return null;
    }
    if (parent == null || !existing.supported) return '请选择仍存在的虚拟归属和支持的真实目录';
    _target(_snapshot, parent);
    final token = await directories!.begin(existing);
    if (token == null) return '目录身份或授权无法核对';
    try {
      final reading = await directories!.readDirectory(existing);
      if (!reading.verified) return reading.reason;
      await _commitAssociation(
        unknown.update(
          resolution: CreationResolution.associated,
          associatedKey: existing.key,
        ),
        existing.path,
        parent,
        token,
      );
      return null;
    } finally {
      await directories!.end(token);
    }
  });
  OrganizationSnapshot _snapshot = OrganizationSnapshot([], {});
  OrganizationSnapshot get snapshot => _snapshot;
  OrganizationPhase _phase = OrganizationPhase.loading;
  OrganizationPhase get phase => _phase;
  int _pending = 0;
  bool get busy => _pending > 0 || _backupHeld;
  bool _backupHeld = false;
  // Synchronously closes this owner to new work, then drains accepted writes.
  Future<void> holdForBackup({bool allowCreationRecovery = false}) {
    if (!allowCreationRecovery && creationIssue != null) {
      throw OrganizationError(creationIssue!);
    }
    if (_disposed || _backupHeld) throw StateError('Organization unavailable');
    _backupHeld = true;
    return _tail;
  }

  OrganizationSnapshot get confirmedForBackup {
    if (_disposed || !_backupHeld || phase != OrganizationPhase.ready) {
      throw StateError('Organization unavailable');
    }
    if (creationIssue != null) throw OrganizationError(creationIssue!);
    return _snapshot;
  }

  void installRestored(OrganizationSnapshot value) {
    if (!_backupHeld || _disposed) throw StateError('Organization not held');
    value.validate();
    _snapshot = value;
    _observedRetainedAlbums.clear();
    _phase = OrganizationPhase.ready;
    _discoveryError = null;
    unawaited(refreshDirectories());
  }

  /// Removes only directories confirmed deleted, never an album merely emptied
  /// by moving its photos. Unrelated and permission-hidden slots are retained.
  Future<void> commitPhysicalAlbumDeletion(Set<String> keys) async {
    if (!_backupHeld || _disposed || phase != OrganizationPhase.ready) {
      throw StateError('Organization must be held and ready');
    }
    final deleted = Set<String>.of(keys);
    if (deleted.any((key) => key.isEmpty || !key.contains(':'))) {
      throw ArgumentError('Physical album keys required');
    }
    await _tail;
    final before = _snapshot;
    final next = OrganizationSnapshot(
      before.folders.values,
      Map.fromEntries(
        before.placements.entries.where((e) => !deleted.contains(e.key)),
      ),
      folderOrders: before.folderOrders,
      albumOrders: {
        for (final e in before.albumOrders.entries)
          e.key: e.value.where((key) => !deleted.contains(key)).toList(),
      },
      descriptors: Map.fromEntries(
        before.descriptors.entries.where((e) => !deleted.contains(e.key)),
      ),
    );
    await _commitPhysicalSnapshot(before, next);
  }

  /// Retains a real directory before its last indexed photo can disappear.
  /// Existing metadata and private ordering always win over this observation.
  Future<void> rememberPhysicalAlbums(
    Iterable<AlbumDescriptor> descriptors,
  ) async {
    if (!_backupHeld || _disposed || phase != OrganizationPhase.ready) {
      throw StateError('Organization must be held and ready');
    }
    final additions = descriptors.toList();
    for (final d in additions) {
      final key = d.sourceKey;
      final split = key?.indexOf(':') ?? -1;
      if (d.pending ||
          split <= 0 ||
          d.directory == null ||
          key!.substring(split + 1) != d.directory ||
          !DirectoryIdentity(key.substring(0, split), d.directory!).supported) {
        throw ArgumentError('A real supported album descriptor is required');
      }
    }
    await _tail;
    final before = _snapshot;
    final nextDescriptors = Map<String, AlbumDescriptor>.of(before.descriptors);
    for (final d in additions) {
      nextDescriptors.putIfAbsent(d.sourceKey!, () => d);
    }
    final next = OrganizationSnapshot(
      before.folders.values,
      before.placements,
      folderOrders: before.folderOrders,
      albumOrders: before.albumOrders,
      descriptors: nextDescriptors,
    );
    await _commitPhysicalSnapshot(before, next);
  }

  Future<void> _commitPhysicalSnapshot(
    OrganizationSnapshot before,
    OrganizationSnapshot next,
  ) async {
    try {
      await store.save(before, next);
    } catch (_) {
      // Resolve a lost commit response by reading the durable result.
    }
    final actual = await store.read();
    bool ordersEqual(
      Map<String, List<String>> a,
      Map<String, List<String>> b,
    ) =>
        setEquals(a.keys.toSet(), b.keys.toSet()) &&
        a.entries.every((e) => listEquals(e.value, b[e.key]));
    if (!mapEquals(
          {for (final f in next.folders.values) f.id: (f.parent, f.name)},
          {for (final f in actual.folders.values) f.id: (f.parent, f.name)},
        ) ||
        !mapEquals(next.placements, actual.placements) ||
        !ordersEqual(next.folderOrders, actual.folderOrders) ||
        !ordersEqual(next.albumOrders, actual.albumOrders) ||
        !setEquals(
          next.descriptors.keys.toSet(),
          actual.descriptors.keys.toSet(),
        ) ||
        !next.descriptors.entries.every(
          (e) => mapEquals(
            descriptorData(e.value),
            descriptorData(actual.descriptors[e.key]!),
          ),
        )) {
      throw StateError('Physical album deletion did not verify');
    }
    installRestored(actual);
  }

  void releaseBackup() {
    _backupHeld = false;
    _publish();
    if (!_disposed) _mediaChanged();
  }

  bool _disposed = false;
  Future<void> _tail = Future.value();
  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() {
    if (_disposed || _backupHeld) return Future.value();
    _phase = OrganizationPhase.loading;
    _publish();
    final task = _tail.then((_) async {
      if (_disposed) return;
      try {
        // A retry must reopen a failed adapter, never replace its file.
        await store.close();
        await _refreshPrivateState();
        if (_disposed) return;
        _phase = OrganizationPhase.ready;
      } catch (_) {
        if (!_disposed) _phase = OrganizationPhase.failed;
      }
      _publish();
    });
    _tail = task;
    unawaited(task.then((_) => _mediaChanged()));
    return task;
  }

  Future<String?> _change(
    OrganizationSnapshot Function(OrganizationSnapshot) edit,
  ) {
    if (_disposed || _backupHeld || phase != OrganizationPhase.ready) {
      return Future.value('组织数据尚不可用，请重试加载');
    }
    _pending++;
    _publish();
    final result = Completer<String?>();
    _tail = _tail.then((_) async {
      var saving = false;
      try {
        if (_disposed || phase != OrganizationPhase.ready) {
          throw const OrganizationError('操作已过期，请重新打开');
        }
        final next = edit(_snapshot);
        if (!identical(next, _snapshot)) {
          saving = true;
          await store.save(_snapshot, next);
          if (!_disposed) {
            _snapshot = next;
            // A committed folder removal makes its old target unusable now.
            if (_liveTokens.isNotEmpty) {
              await loadCreationHistory(organization: next);
            }
          }
        }
        result.complete(null);
      } on OrganizationError catch (e) {
        final readable = !saving || await _recoverPrivateResponse();
        result.complete(readable ? e.message : '无法核对保存结果，请重试加载');
      } catch (_) {
        final readable = await _recoverPrivateResponse();
        result.complete(
          readable ? '保存失败或响应丢失，已重新读取分类，请核对后重试' : '无法核对保存结果，请重试加载',
        );
      } finally {
        _pending--;
        _publish();
      }
    });
    return result.future;
  }

  AlbumFolder _editable(OrganizationSnapshot s, String id) {
    final folder = s.folders[id];
    if (folder == null) throw const OrganizationError('根不能修改，或文件夹已不存在');
    return folder;
  }

  void _target(OrganizationSnapshot s, String id) {
    if (!s.exists(id)) throw const OrganizationError('目标必须是仍存在的相册文件夹');
  }

  Future<String?> create(String parent, String input) => _change((s) {
    _target(s, parent);
    s = _orderedTarget(s, parent, folders: true);
    final id = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return s.withTree([
      ...s.folders.values,
      AlbumFolder(id, parent, folderName(input)),
    ], s.placements);
  });
  Future<String?> rename(String id, String input) => _change((s) {
    final f = _editable(s, id);
    final name = folderName(input);
    if (name == f.name) return s;
    return s.withTree([
      for (final item in s.folders.values)
        if (item.id == id) AlbumFolder(id, f.parent, name) else item,
    ], s.placements);
  });
  Future<String?> moveFolder(
    String id,
    String parent, {
    OrganizationSnapshot? base,
    String? expectedParent,
    int? generation,
    int? directoryRevision,
  }) {
    if (operationGuard.held) {
      return Future.value('另一项媒体、备份或恢复操作正在进行');
    }
    return _change((s) {
      if (operationGuard.held) {
        throw const OrganizationError('另一项媒体、备份或恢复操作正在进行');
      }
      final f = _editable(s, id);
      if ((base != null && !identical(base, s)) ||
          (expectedParent != null && f.parent != expectedParent) ||
          (generation != null && generation != browser.generation) ||
          (directoryRevision != null &&
              directoryRevision != this.directoryRevision)) {
        throw const OrganizationError('归类目标或来源已变化，请重新调整');
      }
      _target(s, parent);
      if (s.includes(id, parent)) {
        throw const OrganizationError('不能移动到自身或后代文件夹');
      }
      if (f.parent == parent) return s;
      s = _orderedTarget(s, parent, folders: true);
      return s.withTree([
        for (final item in s.folders.values)
          if (item.id == id) AlbumFolder(id, parent, f.name) else item,
      ], s.placements);
    });
  }

  Future<String?> deleteEmpty(String id) => _change((s) {
    _editable(s, id);
    if (s.folders.values.any((f) => f.parent == id) ||
        s.placements.containsValue(id)) {
      throw const OrganizationError('文件夹非空（包括暂不可见的相册），请先移出内容');
    }
    return s.withTree(s.folders.values.where((f) => f.id != id), s.placements);
  });
  FolderDissolution previewDissolution(String id) {
    if (_disposed || phase != OrganizationPhase.ready) {
      throw const OrganizationError('组织数据尚不可用，请重试加载');
    }
    if (browser.phase == BrowsePhase.idle ||
        browser.phase == BrowsePhase.checking ||
        browser.phase == BrowsePhase.loading) {
      throw const OrganizationError('正在核对照片范围，请稍后重新预检');
    }
    final s = snapshot;
    final folder = _editable(s, id);
    final children = s.children(id);
    final existing = s.children(folder.parent).where((f) => f.id != id);
    final conflicts = children
        .where((child) => existing.any((f) => f.name == child.name))
        .map((f) => f.name)
        .toList();
    if (conflicts.isNotEmpty) {
      throw OrganizationError('无法解散，父层已有同名相册文件夹：${conflicts.join('、')}');
    }
    final visible = albums;
    final promoted = s.albumSlots(id, visible);
    final placements = Map<String, String>.of(s.placements);
    for (final key in promoted) {
      if (folder.parent == rootFolder) {
        placements.remove(key);
      } else {
        placements[key] = folder.parent;
      }
    }
    final folderOrders = Map<String, List<String>>.of(s.folderOrders)
      ..remove(id);
    folderOrders[folder.parent] = [
      ...existing.map((f) => f.id),
      ...children.map((f) => f.id),
    ];
    final albumOrders = Map<String, List<String>>.of(s.albumOrders)..remove(id);
    albumOrders[folder.parent] = [
      ...s.albumSlots(folder.parent, visible),
      ...promoted,
    ];
    return FolderDissolution._(
      base: s,
      generation: browser.generation,
      mediaPhase: browser.phase,
      folder: folder,
      childFolders: children.length,
      albums: promoted.length,
      hiddenAlbums: promoted
          .where((key) => !visible.any((a) => a.key == key))
          .length,
      next: OrganizationSnapshot(
        [
          for (final f in s.folders.values)
            if (f.id != id)
              if (f.parent == id)
                AlbumFolder(f.id, folder.parent, f.name)
              else
                f,
        ],
        placements,
        descriptors: s.descriptors,
        folderOrders: folderOrders,
        albumOrders: albumOrders,
      ),
    );
  }

  Future<String?> dissolve(FolderDissolution preview) => _change((s) {
    if (!identical(preview.base, s) ||
        browser.generation != preview.generation ||
        browser.phase != preview.mediaPhase) {
      throw const OrganizationError('解散预检已过期，请重新打开并确认');
    }
    // Recheck inside the serialized queue; never trust a dialog's old targets.
    return previewDissolution(preview.folder.id).next;
  });

  Future<String?> moveAlbum(
    String key,
    String parent, {
    required int generation,
    OrganizationSnapshot? base,
    String? expectedParent,
    int? directoryRevision,
  }) {
    if (operationGuard.held) {
      return Future.value('另一项媒体、备份或恢复操作正在进行');
    }
    return _change((s) {
      if (operationGuard.held) {
        throw const OrganizationError('另一项媒体、备份或恢复操作正在进行');
      }
      // Validate the gesture's view inside the serial queue, not just on drop.
      // A preceding edit can change either source or target while this waits.
      if ((base != null && !identical(base, s)) ||
          (expectedParent != null && s.parentOfAlbum(key) != expectedParent) ||
          (directoryRevision != null &&
              directoryRevision != this.directoryRevision)) {
        throw const OrganizationError('归类目标或来源已变化，请重新调整');
      }
      _target(s, parent);
      if (browser.phase != BrowsePhase.ready ||
          browser.generation != generation ||
          !albums.any((a) => a.key == key)) {
        throw const OrganizationError('相册访问范围已变化，请刷新后重试');
      }
      if (s.parentOfAlbum(key) == parent) return s;
      s = _orderedTarget(s, parent, folders: false);
      final placements = Map<String, String>.of(s.placements);
      if (parent == rootFolder) {
        placements.remove(key);
      } else {
        placements[key] = parent;
      }
      final next = s.withTree(s.folders.values, placements);
      return OrganizationSnapshot(
        next.folders.values,
        next.placements,
        descriptors: next.descriptors,
        folderOrders: next.folderOrders,
        albumOrders: {
          ...next.albumOrders,
          parent: [
            ...next.albumOrders[parent]!,
            if (!next.albumOrders[parent]!.contains(key)) key,
          ],
        },
      );
    });
  }

  OrganizationSnapshot _orderedTarget(
    OrganizationSnapshot s,
    String parent, {
    required bool folders,
  }) => OrganizationSnapshot(
    s.folders.values,
    s.placements,
    descriptors: s.descriptors,
    folderOrders: folders
        ? {
            ...s.folderOrders,
            parent: s.children(parent).map((f) => f.id).toList(),
          }
        : s.folderOrders,
    albumOrders: folders
        ? s.albumOrders
        : {...s.albumOrders, parent: s.albumSlots(parent, albums)},
  );

  Future<String?> saveOrder({
    required String parent,
    required OrganizationSnapshot base,
    required int generation,
    required List<String> folders,
    required List<String> albums,
    int? directoryRevision,
  }) {
    if (operationGuard.held) {
      return Future.value('另一项媒体、备份或恢复操作正在进行');
    }
    // Copy page-owned mutable lists before entering the serial write queue.
    final folderIds = List<String>.of(folders),
        albumKeys = List<String>.of(albums);
    return _change((s) {
      if (operationGuard.held) {
        throw const OrganizationError('另一项媒体、备份或恢复操作正在进行');
      }
      // A settled denial/failure still permits private folder ordering, but
      // never authorizes rearranging albums from a previously visible scope.
      final privateOnly =
          (browser.phase == BrowsePhase.denied ||
              browser.phase == BrowsePhase.failed) &&
          albumKeys.isEmpty;
      if (!identical(base, s) ||
          (browser.phase != BrowsePhase.ready && !privateOnly) ||
          browser.generation != generation ||
          !s.exists(parent) ||
          directoryRevision != null &&
              directoryRevision != this.directoryRevision) {
        throw const OrganizationError('排序来源已过期，请重新调整');
      }
      final visible = privateOnly ? <Album>[] : this.albums;
      final expected = s.albums(parent, visible).map((a) => a.key).toSet();
      if (albumKeys.length != expected.length ||
          !setEquals(albumKeys.toSet(), expected) ||
          folderIds.length != s.children(parent).length ||
          !setEquals(
            folderIds.toSet(),
            s.children(parent).map((f) => f.id).toSet(),
          )) {
        throw const OrganizationError('节点已变化，请取消并重新调整');
      }
      final slots = s.albumSlots(parent, visible);
      var index = 0;
      return OrganizationSnapshot(
        s.folders.values,
        s.placements,
        descriptors: s.descriptors,
        folderOrders: {...s.folderOrders, parent: folderIds},
        albumOrders: {
          ...s.albumOrders,
          parent: [
            for (final key in slots)
              expected.contains(key) ? albumKeys[index++] : key,
          ],
        },
      );
    });
  }

  @override
  void dispose() {
    browser.removeListener(_mediaChanged);
    _disposed = true;
    _directoryEpoch++;
    for (final token in _liveTokens.values) {
      unawaited(directories!.end(token));
    }
    _liveTokens.clear();
    unawaited(_tail.then((_) => store.close()));
    super.dispose();
  }
}

Map<String, Object?> descriptorData(AlbumDescriptor d) => {
  'sourceKey': d.sourceKey,
  'name': d.name,
  'directory': d.directory,
  'pending': d.pending,
  if (d.retainWhenEmpty) 'retainWhenEmpty': true,
};
AlbumDescriptor descriptorFrom(dynamic d) {
  if (d is! Map ||
      !setEquals(d.keys.toSet(), {
        'sourceKey',
        'name',
        'directory',
        'pending',
        if (d.containsKey('retainWhenEmpty')) 'retainWhenEmpty',
      }) ||
      (d.containsKey('retainWhenEmpty') && d['retainWhenEmpty'] != true)) {
    throw const FormatException('Invalid album description');
  }
  return AlbumDescriptor(
    sourceKey: d['sourceKey'] as String?,
    name: d['name'] as String?,
    directory: d['directory'] as String?,
    pending: d['pending'] as bool,
    retainWhenEmpty: d['retainWhenEmpty'] == true,
  );
}
