import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'favorites.dart';

// One application table; no image bytes or full-library metadata stored here.
class SqliteFavoriteStore implements FavoriteStore, FavoriteSyncStore {
  SqliteFavoriteStore({this.path, this.checkpoint});
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

  Future<Database> _open() async {
    final location = path ?? '${await getDatabasesPath()}/favorites.db';
    if (await databaseExists(location)) {
      // sqflite Android's read-only path installs a non-deleting corruption
      // handler. Validate existing files before the ordinary writable open,
      // whose Android default handler can otherwise delete a corrupt database.
      final check = await openDatabase(
        location,
        readOnly: true,
        singleInstance: false,
      );
      try {
        final result = await check.rawQuery('PRAGMA quick_check');
        if (result.length != 1 || result.single.values.single != 'ok') {
          throw StateError('Favorites database integrity check failed');
        }
        final version = await check.getVersion();
        if (version < 1 || version > 5) {
          throw StateError('Unsupported favorites schema');
        }
        await check.query('favorites', columns: ['identity'], limit: 1);
        if (version >= 2) {
          await _readSnapshot(
            check,
            outcomes: version >= 3,
            sources: version >= 4,
          );
        }
      } finally {
        await check.close();
      }
    }
    return openDatabase(
      location,
      version: 5,
      onConfigure: (db) async {
        // Read-only validation must also work after an interrupted write. WAL
        // keeps uncommitted pages outside the database, avoiding a hot rollback
        // journal that would require writes during the validation step.
        final journal = await db.rawQuery('PRAGMA journal_mode = WAL');
        if (journal.single.values.single != 'wal') {
          throw StateError('Favorites WAL journal unavailable');
        }
        await db.execute('PRAGMA synchronous = FULL');
      },
      onCreate: (db, _) async {
        await db.execute(
          "CREATE TABLE favorites (identity TEXT PRIMARY KEY NOT NULL, source TEXT NOT NULL DEFAULT 'legacy' CHECK (source IN ('legacy', 'system', 'both')))",
        );
        await _createPending(db);
        await _createOutcomes(db);
        await _createSync(db);
      },
      onUpgrade: (db, old, next) async {
        if ((old < 1 || old > 4) || next != 5) {
          throw StateError('Unsupported favorites schema upgrade');
        }
        if (old == 1) await _createPending(db);
        if (old < 3) await _createOutcomes(db);
        if (old < 4) {
          await db.execute(
            "ALTER TABLE favorites ADD COLUMN source TEXT NOT NULL DEFAULT 'legacy' CHECK (source IN ('legacy', 'system', 'both'))",
          );
        }
        await _createSync(db);
        await checkpoint?.call('favorites-upgraded');
      },
      onDowngrade: (_, _, _) async {
        throw StateError('Unsupported favorites schema downgrade');
      },
    );
  }

  Future<void> _createSync(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE image_sync_preference (enabled INTEGER NOT NULL)',
    );
    await db.insert('image_sync_preference', {'enabled': 0});
    await db.execute(
      'CREATE TABLE observed_image_favorites (identity TEXT PRIMARY KEY NOT NULL, created_here INTEGER NOT NULL)',
    );
  }

  @override
  Future<({bool enabled, Map<String, bool> origins})> readSync() async {
    final db = await _database();
    return db.transaction(
      (txn) async => (
        enabled:
            (await txn.query('image_sync_preference')).single['enabled'] == 1,
        origins: {
          for (final row in await txn.query('observed_image_favorites'))
            row['identity']! as String: row['created_here'] == 1,
        },
      ),
    );
  }

  @override
  Future<void> saveSync({
    bool? enabled,
    required Map<String, bool> observed,
    required Set<String> removed,
    String? addPrivate,
  }) async {
    final db = await _database();
    await db.transaction((txn) async {
      final batch = txn.batch();
      if (enabled != null) {
        batch.update('image_sync_preference', {'enabled': enabled ? 1 : 0});
      }
      for (final entry in observed.entries) {
        batch.insert('observed_image_favorites', {
          'identity': entry.key,
          'created_here': entry.value ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final id in removed) {
        for (final table in ['observed_image_favorites', 'favorites']) {
          batch.delete(table, where: 'identity = ?', whereArgs: [id]);
        }
      }
      if (addPrivate != null) {
        batch.insert('favorites', {
          'identity': addPrivate,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        batch.delete(
          'pending_favorites',
          where: 'identity = ?',
          whereArgs: [addPrivate],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> _createPending(DatabaseExecutor db) => db.execute(
    'CREATE TABLE pending_favorites (identity TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL)',
  );
  Future<void> _createOutcomes(DatabaseExecutor db) => db.execute(
    'CREATE TABLE migration_outcomes (identity TEXT PRIMARY KEY NOT NULL, result TEXT NOT NULL)',
  );
  Future<FavoriteSnapshot> _readSnapshot(
    DatabaseExecutor db, {
    bool outcomes = true,
    bool sources = true,
  }) async {
    final rows = await db.query('favorites');
    return FavoriteSnapshot(
      rows.map((r) => r['identity']! as String),
      (await db.query('pending_favorites'))
          .map((r) => pendingFrom(jsonDecode(r['data']! as String))),
      outcomes
          ? {
              for (final row in await db.query('migration_outcomes'))
                row['identity']! as String: row['result']! as String,
            }
          : const {},
      sources
          ? {
              for (final row in rows)
                if (row['source'] != 'legacy')
                  row['identity']! as String: row['source']! as String,
            }
          : const {},
    );
  }

  @override
  Future<FavoriteSnapshot> readSnapshot() async =>
      _readSnapshot(await _database());
  @override
  Future<void> replace(FavoriteSnapshot s) async {
    await (await _database()).transaction((txn) async {
      await txn.delete('favorites');
      await txn.delete('pending_favorites');
      await txn.delete('migration_outcomes');
      for (final id in s.confirmed) {
        await txn.insert('favorites', {
          'identity': id,
          'source': s.sources[id] ?? 'legacy',
        });
      }
      for (final p in s.pending) {
        await txn.insert('pending_favorites', {
          'identity': p.identity,
          'data': jsonEncode(pendingData(p)),
        });
      }
      for (final entry in s.migrationOutcomes.entries) {
        await txn.insert('migration_outcomes', {
          'identity': entry.key,
          'result': entry.value,
        });
      }
      await checkpoint?.call('favorites-transaction');
    });
  }

  @override
  Future<Set<String>> read() async => (await (await _database()).query(
    'favorites',
    columns: ['identity'],
  )).map((row) => row['identity']! as String).toSet();
  @override
  Future<void> set(String identity, bool value) async {
    final db = await _database();
    await db.transaction((txn) async {
      await txn.delete(
        'observed_image_favorites',
        where: 'identity = ?',
        whereArgs: [identity],
      );
      if (value) {
        await txn.delete(
          'pending_favorites',
          where: 'identity = ?',
          whereArgs: [identity],
        );
        await txn.insert('favorites', {
          'identity': identity,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        await txn.delete(
          'favorites',
          where: 'identity = ?',
          whereArgs: [identity],
        );
      }
    });
  }

  @override
  Future<void> close() async {
    final opening = _opening;
    if (opening != null) {
      try {
        await (await opening).close();
      } catch (_) {}
    }
    _opening = null;
  }
}
