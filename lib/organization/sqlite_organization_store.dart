import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'organization.dart';
import 'album_creation.dart';

class SqliteOrganizationStore implements OrganizationStore, AlbumCreationStore {
  SqliteOrganizationStore({this.path, this.checkpoint});
  final Future<void> Function(String)? checkpoint;
  final String? path;
  Future<Database>? _opening;
  Future<Database> _database() async {
    try {
      return await (_opening ??= _open());
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<OrganizationSnapshot> _read(
    DatabaseExecutor db, {
    int version = 4,
  }) async {
    final orders = version == 1
        ? <Map<String, Object?>>[]
        : await db.query('folder_orders');
    if (orders.map((r) => r['parent']).toSet().length != orders.length) {
      throw const OrganizationError('排序父节点重复');
    }
    final folders = await db.query('folders');
    final placements = await db.query('album_placements');
    if (placements.map((row) => row['album_key']).toSet().length !=
        placements.length) {
      throw const OrganizationError('相册归类标识重复');
    }
    return OrganizationSnapshot(
      folders.map(
        (r) => AlbumFolder(
          r['id']! as String,
          r['parent']! as String,
          r['name']! as String,
        ),
      ),
      {
        for (final r in placements)
          r['album_key']! as String: r['parent']! as String,
      },
      folderOrders: {
        for (final r in orders)
          if (r['folder_ids'] != null)
            r['parent']! as String:
                (jsonDecode(r['folder_ids']! as String) as List).cast<String>(),
      },
      descriptors: version < 3
          ? {}
          : {
              for (final row in await db.query('album_descriptors'))
                row['album_key']! as String: descriptorFrom(
                  jsonDecode(row['data']! as String),
                ),
            },
      albumOrders: {
        for (final r in orders)
          if (r['album_keys'] != null)
            r['parent']! as String:
                (jsonDecode(r['album_keys']! as String) as List).cast<String>(),
      },
    );
  }

  Future<Database> _open() async {
    final location = path ?? '${await getDatabasesPath()}/organization.db';
    if (await databaseExists(location)) {
      // Android sqflite read-only open uses a non-deleting corruption handler.
      final check = await openDatabase(
        location,
        readOnly: true,
        singleInstance: false,
      );
      try {
        final version = await check.getVersion();
        final result = await check.rawQuery('PRAGMA quick_check');
        if (result.length != 1 ||
            result.single.values.single != 'ok' ||
            (version < 1 || version > 4)) {
          throw StateError('Unsupported or corrupt organization database');
        }
        if (version >= 4) await _readCreations(check);
        await _read(
          check,
          version: version,
        ); // Reject cycles/dangling relationships before any write.
      } finally {
        await check.close();
      }
    }
    return openDatabase(
      location,
      version: 4,
      onConfigure: (db) async {
        final mode = await db.rawQuery('PRAGMA journal_mode = WAL');
        if (mode.single.values.single != 'wal') {
          throw StateError('WAL unavailable');
        }
        await db.execute('PRAGMA synchronous = FULL');
      },
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE folders (id TEXT PRIMARY KEY NOT NULL, parent TEXT NOT NULL, name TEXT NOT NULL, UNIQUE(parent, name))',
        );
        await db.execute(
          'CREATE TABLE album_placements (album_key TEXT PRIMARY KEY NOT NULL, parent TEXT NOT NULL)',
        );
        await _createOrders(db);
        await _createDescriptors(db);
        await _createCreations(db);
      },
      onUpgrade: (db, old, next) async {
        if (old < 1 || old > 3 || next != 4) {
          throw StateError('Unsupported organization schema');
        }
        await _read(db, version: old);
        if (old == 1) await _createOrders(db);
        if (old < 3) await _createDescriptors(db);
        await _createCreations(db);
      },
      onDowngrade: (_, _, _) async {
        throw StateError('Unsupported organization schema');
      },
    );
  }

  Future<void> _createDescriptors(DatabaseExecutor db) => db.execute(
    'CREATE TABLE album_descriptors (album_key TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL)',
  );

  Future<void> _writeDescriptors(
    DatabaseExecutor db,
    OrganizationSnapshot s,
  ) async {
    await db.delete('album_descriptors');
    for (final e in s.descriptors.entries) {
      await db.insert('album_descriptors', {
        'album_key': e.key,
        'data': jsonEncode(descriptorData(e.value)),
      });
    }
  }

  @override
  Future<void> replace(OrganizationSnapshot s) async {
    s.validate();
    await (await _database()).transaction((txn) async {
      for (final table in ['folders', 'album_placements', 'folder_orders']) {
        await txn.delete(table);
      }
      for (final f in s.folders.values) {
        await txn.insert('folders', {
          'id': f.id,
          'parent': f.parent,
          'name': f.name,
        });
      }
      for (final e in s.placements.entries) {
        await txn.insert('album_placements', {
          'album_key': e.key,
          'parent': e.value,
        });
      }
      for (final parent in {...s.folderOrders.keys, ...s.albumOrders.keys}) {
        await txn.insert('folder_orders', {
          'parent': parent,
          'folder_ids': s.folderOrders[parent] == null
              ? null
              : jsonEncode(s.folderOrders[parent]),
          'album_keys': s.albumOrders[parent] == null
              ? null
              : jsonEncode(s.albumOrders[parent]),
        });
      }
      await _writeDescriptors(txn, s);
      await checkpoint?.call('organization-transaction');
    });
  }

  Future<void> _createOrders(DatabaseExecutor db) => db.execute(
    'CREATE TABLE folder_orders (parent TEXT PRIMARY KEY NOT NULL, folder_ids TEXT, album_keys TEXT)',
  );

  @override
  Future<OrganizationSnapshot> read() async => _read(await _database());
  @override
  Future<void> save(
    OrganizationSnapshot before,
    OrganizationSnapshot after,
  ) async {
    after.validate();
    await (await _database()).transaction((txn) => _save(txn, before, after));
  }

  Future<void> _save(
    DatabaseExecutor txn,
    OrganizationSnapshot before,
    OrganizationSnapshot after,
  ) async {
    await _writeDescriptors(txn, after);
    for (final id in before.folders.keys) {
      if (!after.folders.containsKey(id)) {
        await txn.delete('folders', where: 'id = ?', whereArgs: [id]);
      }
    }
    for (final f in after.folders.values) {
      final old = before.folders[f.id];
      final row = {'id': f.id, 'parent': f.parent, 'name': f.name};
      if (old == null) {
        await txn.insert('folders', row);
      } else if (old.parent != f.parent || old.name != f.name) {
        await txn.update('folders', row, where: 'id = ?', whereArgs: [f.id]);
      }
    }
    for (final key in before.placements.keys) {
      if (!after.placements.containsKey(key)) {
        await txn.delete(
          'album_placements',
          where: 'album_key = ?',
          whereArgs: [key],
        );
      }
    }
    for (final entry in after.placements.entries) {
      if (before.placements[entry.key] != entry.value) {
        await txn.insert('album_placements', {
          'album_key': entry.key,
          'parent': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    final parents = {
      ...before.folderOrders.keys,
      ...before.albumOrders.keys,
      ...after.folderOrders.keys,
      ...after.albumOrders.keys,
    };
    for (final parent in parents) {
      final folders = after.folderOrders[parent],
          albums = after.albumOrders[parent];
      if (jsonEncode(folders) == jsonEncode(before.folderOrders[parent]) &&
          jsonEncode(albums) == jsonEncode(before.albumOrders[parent])) {
        continue;
      }
      if (folders == null && albums == null) {
        await txn.delete(
          'folder_orders',
          where: 'parent = ?',
          whereArgs: [parent],
        );
      } else {
        await txn.insert('folder_orders', {
          'parent': parent,
          'folder_ids': folders == null ? null : jsonEncode(folders),
          'album_keys': albums == null ? null : jsonEncode(albums),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  Future<void> _createCreations(DatabaseExecutor db) => db.execute(
    'CREATE TABLE album_creations (id TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL)',
  );
  Future<List<AlbumCreationRecord>> _readCreations(DatabaseExecutor db) async {
    final records = <AlbumCreationRecord>[];
    for (final row in await db.query('album_creations')) {
      final record = AlbumCreationRecord.fromData(
        (jsonDecode(row['data']! as String) as Map).cast<String, dynamic>(),
      );
      if (record.id != row['id']) {
        throw const FormatException('Invalid journal identity');
      }
      records.add(record);
    }
    return records;
  }

  @override
  Future<List<AlbumCreationRecord>> readCreations() async =>
      _readCreations(await _database());
  Future<void> _writeCreation(
    DatabaseExecutor db,
    AlbumCreationRecord record,
  ) async {
    AlbumCreationRecord.fromData(record.toData());
    final previous = (await _readCreations(db))
        .where((r) => r.id == record.id)
        .firstOrNull;
    if (previous != null &&
        (!previous.unresolved ||
            previous.parentDirectory != record.parentDirectory ||
            previous.name != record.name ||
            previous.treeParent != record.treeParent)) {
      throw const OrganizationError('创建记录已处理或身份已改变，请重新核对');
    }
    await db.insert('album_creations', {
      'id': record.id,
      'data': jsonEncode(record.toData()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> recordCreation(AlbumCreationRecord record) async {
    await (await _database()).transaction((txn) async {
      await _writeCreation(txn, record);
      await checkpoint?.call('creation-intent-transaction');
    });
  }

  @override
  Future<void> commitCreation(
    OrganizationSnapshot before,
    OrganizationSnapshot after,
    AlbumCreationRecord record, {
    Future<bool> Function()? validate,
  }) async {
    after.validate();
    await (await _database()).transaction((txn) async {
      final old = (await _readCreations(txn))
          .where((r) => r.id == record.id)
          .firstOrNull;
      if (old == null || !old.unresolved) {
        throw const OrganizationError('此创建记录已处理，请重新核对');
      }
      await _save(txn, before, after);
      await _writeCreation(txn, record);
      await checkpoint?.call('creation-final-transaction');
      if (validate != null && !await validate()) {
        throw const OrganizationError('目录会话已失效，归类事务未提交');
      }
    });
    await checkpoint?.call('creation-after-commit');
  }

  @override
  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) {
      try {
        await (await opening).close();
      } catch (_) {}
    }
  }
}
