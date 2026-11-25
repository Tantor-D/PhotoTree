export '../storage/operation_guard.dart';

import 'package:sqflite/sqflite.dart';

import 'private_snapshot.dart';

class RestoreOperation {
  const RestoreOperation(this.id, this.before, this.target, this.committed);
  final String id;
  final PrivateSnapshot before, target;
  final bool committed;
}

class RestoreJournalState {
  const RestoreJournalState(this.active, this.rollback);
  final RestoreOperation? active;
  final PrivateSnapshot? rollback;
}

abstract interface class RestoreJournal {
  Future<RestoreJournalState> read();
  Future<void> prepare(RestoreOperation operation);
  Future<void> decide(String id);
  Future<void> finish(String id);
  Future<void> close();
}

/// Only this feature's write-ahead recovery record, never a media/task database.
class SqliteRestoreJournal implements RestoreJournal {
  SqliteRestoreJournal({this.path, this.checkpoint});
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

  Future<RestoreJournalState> _read(DatabaseExecutor db) async {
    final rows = await db.query('recovery');
    if (rows.length > 2) throw StateError('Invalid recovery journal');
    RestoreOperation? active;
    PrivateSnapshot? rollback;
    for (final r in rows) {
      if (r['slot'] == 'active') {
        if (r['decision'] != 0 && r['decision'] != 1 ||
            r['operation'] is! String ||
            (r['operation'] as String).isEmpty) {
          throw StateError('Invalid recovery decision');
        }
        active = RestoreOperation(
          r['operation']! as String,
          PrivateSnapshot.decode(r['before_state']! as String),
          PrivateSnapshot.decode(r['target_state']! as String),
          r['decision'] == 1,
        );
      } else if (r['slot'] == 'rollback') {
        if (r['target_state'] != null || r['decision'] != null) {
          throw StateError('Invalid rollback');
        }
        rollback = PrivateSnapshot.decode(r['before_state']! as String);
      } else {
        throw StateError('Unknown recovery slot');
      }
    }
    return RestoreJournalState(active, rollback);
  }

  Future<Database> _open() async {
    final location = path ?? '${await getDatabasesPath()}/restore.db';
    if (await databaseExists(location)) {
      final check = await openDatabase(
        location,
        readOnly: true,
        singleInstance: false,
      );
      try {
        final result = await check.rawQuery('PRAGMA quick_check');
        if (await check.getVersion() != 1 ||
            result.length != 1 ||
            result.single.values.single != 'ok') {
          throw StateError('Unsupported or corrupt recovery journal');
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
          throw StateError('Recovery WAL unavailable');
        }
        await db.execute('PRAGMA synchronous = FULL');
      },
      onCreate: (db, _) => db.execute(
        'CREATE TABLE recovery (slot TEXT PRIMARY KEY NOT NULL, operation TEXT, before_state TEXT NOT NULL, target_state TEXT, decision INTEGER)',
      ),
      onUpgrade: (_, _, _) async {
        throw StateError('Unsupported recovery schema');
      },
      onDowngrade: (_, _, _) async {
        throw StateError('Unsupported recovery schema');
      },
    );
  }

  @override
  Future<RestoreJournalState> read() async => _read(await _database());
  @override
  Future<void> prepare(RestoreOperation op) async {
    // Decode before touching the journal, even for caller-constructed snapshots.
    final before = PrivateSnapshot.decode(op.before.encode()).encode();
    final target = PrivateSnapshot.decode(op.target.encode()).encode();
    await (await _database()).transaction((txn) async {
      if ((await _read(txn)).active != null) {
        throw StateError('Recovery already pending');
      }
      await txn.insert('recovery', {
        'slot': 'active',
        'operation': op.id,
        'before_state': before,
        'target_state': target,
        'decision': 0,
      });
      await checkpoint?.call('prepare-transaction');
    });
  }

  @override
  Future<void> decide(String id) async {
    await (await _database()).transaction((txn) async {
      if (await txn.update(
            'recovery',
            {'decision': 1},
            where: 'slot = ? AND operation = ?',
            whereArgs: ['active', id],
          ) !=
          1) {
        throw StateError('Recovery operation missing');
      }
      await checkpoint?.call('decision-transaction');
    });
  }

  @override
  Future<void> finish(String id) async {
    await (await _database()).transaction((txn) async {
      final active = (await _read(txn)).active;
      if (active == null || active.id != id) {
        throw StateError('Recovery operation missing');
      }
      if (active.committed) {
        await checkpoint?.call('rollback-promotion-before');
        await txn.insert('recovery', {
          'slot': 'rollback',
          'operation': id,
          'before_state': active.before.encode(),
          'target_state': null,
          'decision': null,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await checkpoint?.call('rollback-promotion-after');
      }
      await txn.delete('recovery', where: 'slot = ?', whereArgs: ['active']);
      await checkpoint?.call('finish-transaction');
    });
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
