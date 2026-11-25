import 'package:sqflite/sqflite.dart';

import 'physical_operations.dart';

/// Durable intent and observed outcomes, not a second media library.
class SqlitePhysicalJournal implements PhysicalJournal {
  SqlitePhysicalJournal({this.path, this.checkpoint});

  final String? path;
  final Future<void> Function(String)? checkpoint;
  Future<Database>? _opening;

  Future<Database> _database() async {
    try {
      return await (_opening ??= _open());
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<List<PhysicalBatch>> _read(DatabaseExecutor db) async {
    final rows = await db.query('operations', orderBy: 'id');
    return List.unmodifiable(
      rows.map((row) {
        final batch = PhysicalBatch.decode(row['data']! as String);
        if (batch.id != row['id']) {
          throw StateError('Physical operation journal identity mismatch');
        }
        return batch;
      }),
    );
  }

  Future<Database> _open() async {
    final location =
        path ?? '${await getDatabasesPath()}/physical_operations.db';
    if (await databaseExists(location)) {
      final check = await openDatabase(
        location,
        readOnly: true,
        singleInstance: false,
      );
      try {
        final integrity = await check.rawQuery('PRAGMA quick_check');
        if (await check.getVersion() != 1 ||
            integrity.length != 1 ||
            integrity.single.values.single != 'ok') {
          throw StateError('Unsupported or corrupt physical operation journal');
        }
        await _read(check);
      } finally {
        await check.close();
      }
    }
    return openDatabase(
      location,
      version: 1,
      onConfigure: (db) async {
        final mode = await db.rawQuery('PRAGMA journal_mode = WAL');
        if (mode.single.values.single != 'wal') {
          throw StateError('Physical operation WAL unavailable');
        }
        await db.execute('PRAGMA synchronous = FULL');
      },
      onCreate: (db, _) => db.execute(
        'CREATE TABLE operations (id TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL)',
      ),
      onUpgrade: (_, _, _) async {
        throw StateError('Unsupported physical operation schema');
      },
      onDowngrade: (_, _, _) async {
        throw StateError('Unsupported physical operation schema');
      },
    );
  }

  @override
  Future<List<PhysicalBatch>> read() async => _read(await _database());

  @override
  Future<void> save(PhysicalBatch batch) async {
    final encoded = PhysicalBatch.decode(batch.encode()).encode();
    try {
      await (await _database()).transaction((txn) async {
        await txn.insert('operations', {
          'id': batch.id,
          'data': encoded,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await checkpoint?.call('save-transaction');
        final rows = await txn.query(
          'operations',
          where: 'id = ?',
          whereArgs: [batch.id],
        );
        if (rows.length != 1 || rows.single['data'] != encoded) {
          throw StateError('Physical operation journal verification failed');
        }
      });
    } catch (_) {
      // A failed SQLite rollback can leave the plugin connection waiting for
      // a transaction that SQLite already ended. Discard it before recovery
      // reads; never replay this write after an uncertain transaction result.
      await close();
      rethrow;
    }
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
