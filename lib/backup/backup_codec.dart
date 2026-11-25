import 'dart:convert';
import 'dart:typed_data';

import '../organization/organization.dart';
import '../media/media_source.dart';
import '../library/favorites.dart';

/// These IDs belong to the backup. A source key is descriptive provenance only,
/// never permission to associate a directory on another device automatically.
class BackupAlbum {
  const BackupAlbum({
    required this.id,
    this.sourceKey,
    this.name,
    this.directory,
    this.pending = false,
  });
  final String id;
  final String? sourceKey, name, directory;
  final bool pending;
}

class BackupFingerprint {
  const BackupFingerprint({required this.size, required this.sha256});
  final int size;
  final String sha256;
}

class BackupFavorite {
  const BackupFavorite({
    required this.identity,
    this.albumId,
    this.filename,
    this.fingerprint,
    this.unresolvedReason,
    this.source = 'legacy',
    this.systemFavorite,
    this.pending = false,
    this.mediaKind = MediaKind.image,
  });
  final MediaKind mediaKind;
  final String identity;
  final String source;
  // Captured public state; null means unknown/unavailable, never false.
  final bool? systemFavorite;
  // Independent of source: imported system provenance can still await action.
  final bool pending;
  final String? albumId, filename, unresolvedReason;
  final BackupFingerprint? fingerprint;
}

class BackupDocument {
  BackupDocument({
    required this.organization,
    required Iterable<BackupAlbum> albums,
    required Iterable<BackupFavorite> favorites,
    this.systemSnapshotComplete = false,
  }) : albums = List.unmodifiable(albums),
       favorites = List.unmodifiable(favorites);
  final bool systemSnapshotComplete;
  final OrganizationSnapshot organization;
  final List<BackupAlbum> albums;
  final List<BackupFavorite> favorites;
  int get unresolvedCount =>
      favorites.where((f) => f.fingerprint == null).length;
}

/// Version 3 is a strict, self-contained UTF-8 JSON document. Missing order
/// records mean default order; an order record with [] means explicit empty.
/// There are no image payload fields. Decode never touches private state.
class BackupCodec {
  const BackupCodec();
  static const format = 'phototree-organization-backup';
  static const version = 3;
  static const maxBytes = 32 * 1024 * 1024;
  static const maxRecords = 100000;
  static const maxJsonDepth = 32;

  Uint8List encode(BackupDocument document) {
    final data = _data(document);
    _decodeData(data); // Export and import accept exactly the same domain.
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));
    if (bytes.length > maxBytes) _fail('备份超过 32 MiB');
    return bytes;
  }

  BackupDocument decode(List<int> bytes) {
    if (bytes.length > maxBytes) _fail('备份超过 32 MiB');
    final text = utf8.decode(bytes, allowMalformed: false);
    _JsonGuard(text).check();
    return _decodeData(jsonDecode(text));
  }

  Map<String, Object?> _data(BackupDocument document) => {
    'format': format,
    'version': version,
    'systemSnapshotComplete': document.systemSnapshotComplete,
    'folders': [
      for (final f in document.organization.folders.values)
        {'id': f.id, 'parent': f.parent, 'name': f.name},
    ],
    'albums': [
      for (final a in document.albums)
        {
          'id': a.id,
          'sourceKey': a.sourceKey,
          'name': a.name,
          'directory': a.directory,
          'pending': a.pending,
        },
    ],
    'placements': [
      for (final p in document.organization.placements.entries)
        {'albumId': p.key, 'parent': p.value},
    ],
    'folderOrders': _orders(document.organization.folderOrders),
    'albumOrders': _orders(document.organization.albumOrders),
    'favorites': [
      for (final f in document.favorites)
        {
          'identity': f.identity,
          'mediaKind': f.mediaKind.name,
          'source': f.source,
          'systemFavorite': f.systemFavorite,
          'pending': f.pending,
          'albumId': f.albumId,
          'filename': f.filename,
          'fingerprint': f.fingerprint == null
              ? null
              : {'size': f.fingerprint!.size, 'sha256': f.fingerprint!.sha256},
          'unresolvedReason': f.unresolvedReason,
        },
    ],
  };

  List<Object?> _orders(Map<String, List<String>> orders) => [
    for (final e in orders.entries) {'parent': e.key, 'ids': e.value},
  ];

  BackupDocument _decodeData(Object? value) {
    final isV3 = value is Map && value['version'] == 3;
    final isV2 = value is Map && (value['version'] == 2 || isV3);
    final root = _object(value, {
      'format',
      'version',
      'folders',
      'albums',
      'placements',
      'folderOrders',
      'albumOrders',
      'favorites',
      if (isV2) 'systemSnapshotComplete',
    });
    if (root['format'] != format ||
        root['version'] is! int ||
        !const [1, 2, 3].contains(root['version'])) {
      _fail('不支持的备份格式或版本');
    }
    if (isV2 && root['systemSnapshotComplete'] is! bool) {
      _fail('系统收藏快照完整性标记无效');
    }
    var records = 0;
    void count(int n) {
      records += n;
      if (records > maxRecords) _fail('备份条目超过 100000');
    }

    List<dynamic> list(String key) {
      final items = _list(root[key]);
      count(items.length);
      return items;
    }

    final folderItems = list('folders');
    final albumItems = list('albums');
    final placementItems = list('placements');
    final favoriteItems = list('favorites');
    final folderOrderItems = list('folderOrders');
    final albumOrderItems = list('albumOrders');
    final folders = <String, AlbumFolder>{};
    for (final item in folderItems) {
      final f = _object(item, const {'id', 'parent', 'name'});
      final id = _string(f['id']);
      if (id == rootFolder || folders.containsKey(id)) _fail('文件夹标识重复或无效');
      folders[id] = AlbumFolder(id, _string(f['parent']), _string(f['name']));
    }
    // The format is flat: legal tree depth is bounded only by record count.
    // Memoized ancestor walks reject cycles/orphans without recursion or
    // repeatedly walking every ancestor of a deep tree.
    final checked = <String>{rootFolder};
    for (final id in folders.keys) {
      final path = <String>{};
      var at = id;
      while (!checked.contains(at)) {
        if (!path.add(at)) _fail('文件夹关系循环');
        final f = folders[at];
        if (f == null) _fail('文件夹父节点不存在');
        at = f.parent;
      }
      checked.addAll(path);
    }
    final albums = <String, BackupAlbum>{};
    for (final item in albumItems) {
      final a = _object(item, const {
        'id',
        'sourceKey',
        'name',
        'directory',
        'pending',
      });
      final id = _string(a['id']);
      if (albums.containsKey(id)) _fail('相册标识重复');
      if (a['pending'] is! bool) _fail('待关联状态无效');
      albums[id] = BackupAlbum(
        id: id,
        sourceKey: _optional(a['sourceKey']),
        name: _optional(a['name']),
        directory: _optional(a['directory']),
        pending: a['pending'] as bool,
      );
    }
    final placements = <String, String>{};
    for (final item in placementItems) {
      final p = _object(item, const {'albumId', 'parent'});
      final id = _string(p['albumId']);
      if (!albums.containsKey(id) || placements.containsKey(id)) {
        _fail('相册归类引用无效');
      }
      placements[id] = _string(p['parent']);
    }
    Map<String, List<String>> orders(List<dynamic> items, bool album) {
      final result = <String, List<String>>{};
      for (final item in items) {
        final order = _object(item, const {'parent', 'ids'});
        final parent = _string(order['parent']);
        if (result.containsKey(parent)) _fail('排序父节点重复');
        final ids = _list(order['ids']);
        count(ids.length);
        result[parent] = [for (final id in ids) _string(id)];
        if (album && result[parent]!.any((id) => !albums.containsKey(id))) {
          _fail('排序引用缺少相册描述');
        }
      }
      return result;
    }

    final folderOrders = orders(folderOrderItems, false);
    final albumOrders = orders(albumOrderItems, true);
    final favorites = <BackupFavorite>[];
    final identities = <String>{};
    for (final item in favoriteItems) {
      final f = _object(item, {
        'identity',
        if (isV3) 'mediaKind',
        if (isV2) ...['source', 'systemFavorite', 'pending'],
        'albumId',
        'filename',
        'fingerprint',
        'unresolvedReason',
      });
      final source = isV2 ? _string(f['source']) : 'legacy';
      if (!const ['legacy', 'system', 'both'].contains(source)) {
        _fail('收藏来源无效');
      }
      if (isV2 &&
          (f['pending'] is! bool ||
              (f['systemFavorite'] != null && f['systemFavorite'] is! bool))) {
        _fail('收藏当前状态或待处理标记无效');
      }
      final identity = _string(f['identity']);
      // The identity is nested JSON inside a string: bound its parser before
      // inspecting its type, just as for the outer document.
      if (!identities.add(_identity(identity))) _fail('收藏身份重复');
      final kind = isV3
          ? mediaKindFrom(_string(f['mediaKind']))
          : MediaKind.image;
      if (favoriteMediaKind(identity) != kind) _fail('收藏媒体类型不匹配');
      final albumId = _optional(f['albumId']);
      if (albumId != null && !albums.containsKey(albumId)) _fail('收藏相册引用无效');
      final reason = _optional(f['unresolvedReason']);
      BackupFingerprint? fingerprint;
      if (f['fingerprint'] != null) {
        final fp = _object(f['fingerprint'], const {'size', 'sha256'});
        final hash = _string(fp['sha256']);
        if (fp['size'] is! int ||
            (fp['size'] as int) < 0 ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
          _fail('收藏指纹无效');
        }
        fingerprint = BackupFingerprint(size: fp['size'] as int, sha256: hash);
      }
      if ((fingerprint == null) == (reason == null)) _fail('收藏必须包含指纹或未解析原因');
      favorites.add(
        BackupFavorite(
          identity: identity,
          mediaKind: kind,
          source: source,
          systemFavorite: isV2 ? f['systemFavorite'] as bool? : null,
          pending: isV2 && f['pending'] == true,
          albumId: albumId,
          filename: _optional(f['filename']),
          fingerprint: fingerprint,
          unresolvedReason: reason,
        ),
      );
    }
    try {
      return BackupDocument(
        organization: OrganizationSnapshot(
          folders.values,
          placements,
          folderOrders: folderOrders,
          albumOrders: albumOrders,
        ),
        systemSnapshotComplete: isV2 && root['systemSnapshotComplete'] == true,
        albums: albums.values,
        favorites: favorites,
      );
    } on OrganizationError catch (e) {
      _fail(e.message);
    }
  }
}

Never _fail(String message) => throw FormatException(message);

Map<String, dynamic> _object(Object? input, Set<String> keys) {
  if (input is! Map<String, dynamic> ||
      input.length != keys.length ||
      !input.keys.every(keys.contains)) {
    _fail('备份字段无效');
  }
  return input;
}

List<dynamic> _list(Object? value) {
  if (value is! List) _fail('备份列表无效');
  return value;
}

String _string(Object? value) {
  if (value is! String || value.isEmpty) _fail('备份文本无效');
  return value;
}

String? _optional(Object? value) => value == null ? null : _string(value);

String _identity(String value) {
  // Identity is an opaque original seven-field tuple, preserved byte-for-byte.
  // Parsing only checks integrity; it never authorizes cross-device matching.
  _JsonGuard(value).check();
  favoriteMediaKind(value);
  final tuple = jsonDecode(value);
  return jsonEncode(tuple);
}

/// Preflight before dart:convert allocation: bounded nesting and duplicate keys
/// (including escaped equivalent spellings). dart:convert checks JSON syntax.
class _JsonGuard {
  _JsonGuard(this.text);
  final String text;
  int at = 0;
  void check() {
    _value(0);
    _space();
    if (at != text.length) _fail('备份 JSON 尾部无效');
  }

  void _space() {
    while (at < text.length &&
        const [9, 10, 13, 32].contains(text.codeUnitAt(at))) {
      at++;
    }
  }

  void _value(int depth) {
    _space();
    if (depth > BackupCodec.maxJsonDepth) _fail('备份 JSON 嵌套过深');
    if (at >= text.length) _fail('备份不完整');
    final c = text[at];
    if (c == '"') {
      _text();
      return;
    }
    if (c == '{' || c == '[') {
      at++;
      final object = c == '{';
      final close = object ? '}' : ']';
      final keys = <String>{};
      _space();
      if (at < text.length && text[at] == close) {
        at++;
        return;
      }
      while (true) {
        if (object) {
          _space();
          if (at >= text.length || text[at] != '"') _fail('备份 JSON 键无效');
          final key = _text();
          if (!keys.add(key)) _fail('备份 JSON 键重复');
          _space();
          if (at >= text.length || text[at++] != ':') _fail('备份 JSON 无效');
        }
        _value(depth + 1);
        _space();
        if (at >= text.length) _fail('备份不完整');
        final next = text[at++];
        if (next == close) return;
        if (next != ',') _fail('备份 JSON 无效');
      }
    }
    final start = at;
    while (at < text.length &&
        !const [',', '}', ']', ' ', '\t', '\r', '\n'].contains(text[at])) {
      at++;
    }
    if (start == at) _fail('备份 JSON 无效');
  }

  String _text() {
    final start = at++;
    while (at < text.length) {
      final c = text[at++];
      if (c == '"') return jsonDecode(text.substring(start, at)) as String;
      if (c == '\\') at++;
    }
    _fail('备份文本不完整');
  }
}
