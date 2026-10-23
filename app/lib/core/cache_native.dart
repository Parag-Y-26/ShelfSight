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
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE cache (owner TEXT NOT NULL, key TEXT NOT NULL, '
          'value TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY(owner,key))',
        );
      },
    );
    if (generation != _generation) {
      await opened.close();
      return;
    }
    _db = opened;
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
    if (_uid != null) {
      await _db?.delete('cache', where: 'owner = ?', whereArgs: [_uid]);
    }
  }

  Future<void> close() async {
    ++_generation;
    final old = _db;
    _db = null;
    _uid = null;
    await old?.close();
  }
}
