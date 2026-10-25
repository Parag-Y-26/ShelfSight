import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Each authenticated owner gets a different file and row namespace. The cache
/// never authorizes writes or supplies synthetic business records.
class OwnerCache {
  Database? _db;
  String? _uid;
  int _generation = 0;
  Future<void> open(String uid, {String server = ''}) async {
    final expected = _generation + 1;
    await close();
    if (expected != _generation) return;
    final generation = expected;
    _uid = uid;
    final suffix = sha256.convert(utf8.encode('$uid|$server')).toString();
    final opened = await openDatabase(
      p.join(await getDatabasesPath(), 'cache_$suffix.db'),
      version: 2,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE cache (owner TEXT NOT NULL, key TEXT NOT NULL, '
          'value TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(owner,key))',
        );
        await _createLedger(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createLedger(db);
      },
    );
    if (generation != _generation) {
      await opened.close();
      return;
    }
    _db = opened;
  }

  static Future<void> _createLedger(Database db) async {
    await db.execute(
      'CREATE TABLE ledger_events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, '
      'owner TEXT NOT NULL, store_id TEXT NOT NULL, event_id TEXT NOT NULL, '
      'data TEXT NOT NULL, UNIQUE(owner,store_id,event_id))',
    );
    await db.execute(
      'CREATE TRIGGER ledger_events_immutable BEFORE UPDATE ON ledger_events '
      "BEGIN SELECT RAISE(ABORT,'Ledger events are immutable'); END",
    );
  }

  Future<void> recordEvents(
    String storeId,
    List<Map<String, dynamic>> events,
  ) async {
    final db = _db, uid = _uid;
    if (db == null || uid == null) return;
    await db.transaction((transaction) async {
      for (final event in events) {
        final id = event['id'];
        if (id is! String ||
            id.isEmpty ||
            id.length > 128 ||
            event['store_id'] != storeId) {
          continue;
        }
        await transaction.insert('ledger_events', {
          'owner': uid,
          'store_id': storeId,
          'event_id': id,
          'data': jsonEncode(event),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  Future<List<Map<String, dynamic>>> readEvents(
    String storeId, {
    int limit = 10000,
  }) async {
    if (limit <= 0) throw const FormatException('Invalid ledger limit');
    final rows = await _db?.query(
      'ledger_events',
      columns: ['data'],
      where: 'owner = ? AND store_id = ?',
      whereArgs: [_uid, storeId],
      orderBy: 'sequence DESC',
      limit: limit,
    );
    return [
      for (final row in (rows ?? []).reversed)
        Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
    ];
  }

  Future<void> put(String key, dynamic value) async {
    await _db?.insert('cache', {
      'owner': _uid,
      'key': key,
      'value': jsonEncode(value),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> read(String key) async {
    final rows = await _db?.query(
      'cache',
      where: 'owner = ? AND key = ?',
      whereArgs: [_uid, key],
      limit: 1,
    );
    if (rows == null || rows.isEmpty) return null;
    return {
      'value': jsonDecode(rows.first['value'] as String),
      'updated_at': rows.first['updated_at'],
    };
  }

  Future<void> erase() async {
    final db = _db, uid = _uid;
    if (db == null || uid == null) return;
    await db.transaction((tx) async {
      await tx.delete('cache', where: 'owner = ?', whereArgs: [uid]);
      await tx.delete('ledger_events', where: 'owner = ?', whereArgs: [uid]);
    });
  }

  Future<void> close() async {
    ++_generation;
    final old = _db;
    _db = null;
    _uid = null;
    await old?.close();
  }
}
