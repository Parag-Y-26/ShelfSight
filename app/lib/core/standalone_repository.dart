import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_client.dart';
import 'configuration.dart';
import 'food_facts_client.dart';
import '../vision/geometry.dart';
import 'repository.dart';
import 'local_analytics.dart';

/// Durable source of truth for standalone mode, separate from the remote cache.
/// Rows retain the server's JSON record format; explicit tables model each
/// entity. No fixture, sample store, quantity or observation is seeded.
class StandaloneMobileRepository implements ShelfSightRepository {
  StandaloneMobileRepository({
    required this.config,
    DatabaseFactory? factory,
    this.databasePath,
    OpenFoodFactsClient? catalog,
  }) : _factory = factory ?? databaseFactory,
       _catalog = catalog ?? OpenFoodFactsClient();
  final Map<String, dynamic> config;
  final DatabaseFactory _factory;
  final String? databasePath;
  final OpenFoodFactsClient _catalog;
  Database? _db;
  String? _owner;
  int _generation = 0;
  static const tables = [
    'stores',
    'floors',
    'shelves',
    'products',
    'shelf_items',
    'inventory_events',
    'camera_calibrations',
    'monitoring_sessions',
    'visit_events',
    'autonomous_decisions',
  ];
  static const _entities = {
    'stores': 'stores',
    'floors': 'floors',
    'shelves': 'shelves',
    'products': 'products',
    'items': 'shelf_items',
    'calibrations': 'camera_calibrations',
    'monitoring': 'monitoring_sessions',
  };
  @override
  bool get isStandalone => true;
  @override
  bool get ready => _db != null && _owner != null;
  @override
  String get identity => 'standalone_sqlite_v1';
  Database get _database {
    if (!ready) throw const ApiFailure('sessionExpired');
    return _db!;
  }

  static String newId() =>
      List<int>.generate(
        16,
        (_) => Random.secure().nextInt(256),
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  static String _now() => DateTime.now().toUtc().toIso8601String();
  Future<void> open(String owner) async {
    if (owner.isEmpty) throw const ApiFailure('invalidInput');
    final expected = _generation + 1;
    await close();
    if (expected != _generation) return;
    final generation = expected;
    final path =
        databasePath ??
        p.join(
          await _factory.getDatabasesPath(),
          'shelfsight_standalone_v1.db',
        );
    final db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys=ON');
        },
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE stores(id TEXT PRIMARY KEY, owner TEXT NOT NULL, store_id TEXT NOT NULL, parent_id TEXT, data TEXT NOT NULL, recorded_at TEXT)',
          );
          for (final table in tables.skip(1)) {
            await db.execute(
              'CREATE TABLE $table(id TEXT PRIMARY KEY, owner TEXT NOT NULL, store_id TEXT NOT NULL REFERENCES stores(id) ON DELETE CASCADE, parent_id TEXT, data TEXT NOT NULL, recorded_at TEXT)',
            );
          }
          for (final table in tables) {
            await db.execute(
              'CREATE INDEX ${table}_scope ON $table(owner,store_id)',
            );
          }
          for (final table in ['inventory_events', 'visit_events']) {
            await db.execute(
              "CREATE TRIGGER ${table}_immutable BEFORE UPDATE ON $table BEGIN SELECT RAISE(ABORT,'Observation events are append-only'); END",
            );
          }
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            final stores = {
              for (final row in await db.query('stores'))
                row['id']: jsonDecode(row['data'] as String) as Map,
            };
            for (final row in await db.query('floors')) {
              final floor = Map<String, dynamic>.from(
                jsonDecode(row['data'] as String) as Map,
              );
              final scale =
                  stores[row['store_id']]?['unit'] == 'ft' ? 0.3048 : 1.0;
              floor.addAll({
                'width_m': (floor['width'] as num) * scale,
                'length_m': (floor['length'] as num) * scale,
              });
              await db.update(
                'floors',
                {'data': jsonEncode(floor)},
                where: 'id=?',
                whereArgs: [row['id']],
              );
            }
          }
        },
      ),
    );
    if (generation != _generation) {
      await db.close();
      return;
    }
    _owner = owner;
    _db = db;
    await db.transaction((tx) async {
      for (final session in await _list(tx, 'monitoring_sessions')) {
        if (session['status'] == 'active') {
          // Only durably observed stays and coverage are recovered. Never
          // bridge app termination, background time, or camera downtime.
          await _finishSession(tx, session, incomplete: true, recover: true);
        }
      }
    });
  }

  Future<void> close() async {
    ++_generation;
    final db = _db;
    _db = null;
    _owner = null;
    await db?.close();
  }

  Future<List<Map<String, dynamic>>> _list(
    DatabaseExecutor db,
    String table, [
    String? storeId,
  ]) async {
    final rows = await db.query(
      table,
      where: storeId == null ? 'owner=?' : 'owner=? AND store_id=?',
      whereArgs: storeId == null ? [_owner] : [_owner, storeId],
      orderBy: 'rowid',
    );
    return [
      for (final r in rows)
        Map<String, dynamic>.from(jsonDecode(r['data'] as String) as Map),
    ];
  }

  Future<Map<String, dynamic>> _one(
    DatabaseExecutor db,
    String table,
    String id,
  ) async {
    if (_owner == null) throw const ApiFailure('sessionExpired');
    final rows = await db.query(
      table,
      where: 'id=? AND owner=?',
      whereArgs: [id, _owner],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const ApiFailure('invalidInput', detail: 'Resource not found');
    }
    return Map<String, dynamic>.from(
      jsonDecode(rows.single['data'] as String) as Map,
    );
  }

  Future<Map<String, dynamic>> _create(
    DatabaseExecutor db,
    String table,
    String storeId,
    Map<String, dynamic> values, {
    String? parent,
  }) async {
    if (table == 'floors') {
      final store = await _one(db, 'stores', storeId), scale = 1.0;
      final meters = store['unit'] == 'ft' ? 0.3048 : scale;
      values = {
        ...values,
        'width_m': (values['width'] as num) * meters,
        'length_m': (values['length'] as num) * meters,
      };
    }
    final id = newId();
    if (table == 'stores') storeId = id;
    final data = {
      ...values,
      'id': id,
      'created_at': _now(),
      if (table != 'stores') 'store_id': storeId,
    };
    await db.insert(table, {
      'id': id,
      'owner': _owner,
      'store_id': storeId,
      'parent_id': parent,
      'data': jsonEncode(data),
    });
    return data;
  }

  Future<Map<String, dynamic>> _update(
    DatabaseExecutor db,
    String table,
    String id,
    Map<String, dynamic> changes,
  ) async {
    final previous = await _one(db, table, id);
    final data = {...previous, ...changes, 'updated_at': _now()};
    await db.update(
      table,
      {
        'data': jsonEncode(data),
        if (changes.containsKey('floor_id')) 'parent_id': changes['floor_id'],
      },
      where: 'id=? AND owner=?',
      whereArgs: [id, _owner],
    );
    return data;
  }

  Future<Map<String, dynamic>> _event(
    DatabaseExecutor db,
    String storeId,
    String kind,
    Map<String, dynamic> payload,
  ) async {
    final data = {
      ...payload,
      'id': newId(),
      'type': kind,
      'store_id': storeId,
      'owner_uid': _owner,
      'server_timestamp': _now(),
    };
    await db.insert(
      kind == 'inventory_adjustment' ? 'inventory_events' : 'visit_events',
      {
        'id': data['id'],
        'owner': _owner,
        'store_id': storeId,
        'data': jsonEncode(data),
        'recorded_at': data['server_timestamp'],
      },
    );
    return data;
  }

  List<String> _path(String path) {
    final uri = Uri.tryParse(path);
    if (uri == null ||
        !path.startsWith('/') ||
        path.startsWith('//') ||
        uri.hasScheme ||
        uri.hasQuery ||
        uri.hasFragment ||
        path.contains('..') ||
        path.contains('\\')) {
      throw const ApiFailure('invalidInput');
    }
    return uri.pathSegments.map(Uri.decodeComponent).toList();
  }

  Map<String, dynamic> _body(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  Never _invalid() => throw const ApiFailure('invalidInput');
  String _name(dynamic v, {int max = 200}) {
    if (v is! String || v.trim().isEmpty || v.trim().length > max) _invalid();
    return v.trim();
  }

  num _num(
    dynamic v, {
    num min = 0,
    num max = 1000000,
    bool integer = false,
    bool positive = false,
  }) {
    if (v is! num ||
        !v.isFinite ||
        v < min ||
        v > max ||
        (positive && v <= 0) ||
        (integer && v % 1 != 0)) {
      _invalid();
    }
    return v;
  }

  void _options(Map<String, dynamic> data) {
    for (final entry
        in {
          'type_id': 'store_types',
          'goal_id': 'goals',
          'currency': 'currencies',
          'unit': 'units',
          'shape': 'shapes',
        }.entries) {
      if (data[entry.key] != null &&
          !(config[entry.value] as List).any(
            (v) => (v is Map ? v['id'] : v) == data[entry.key],
          )) {
        _invalid();
      }
    }
    if (data['settings'] != null) {
      data['settings'] = RuntimeConfiguration(
        config,
      ).validate(_body(data['settings']));
    }
  }

  void _floor(Map<String, dynamic> d) {
    _name(d['name']);
    _num(d['width'], positive: true);
    _num(d['length'], positive: true);
  }

  void _geometry(Map<String, dynamic> shelf, Map<String, dynamic> floor) {
    final keys = ['x', 'y', 'width', 'length'];
    if (keys.every((k) => shelf[k] == null)) return;
    if (keys.any((k) => shelf[k] == null)) _invalid();
    final geometry = ShelfGeometry.fromJson(shelf);
    if (geometry == null ||
        !geometry.fits(
          (floor['width'] as num).toDouble(),
          (floor['length'] as num).toDouble(),
        )) {
      _invalid();
    }
  }

  Future<void> _slot(
    DatabaseExecutor db,
    Map<String, dynamic> shelf,
    Map<String, dynamic> item, {
    String? ignore,
  }) async {
    final row = _num(item['row'], min: 1, max: 1000, integer: true),
        slot = _num(item['slot'], min: 1, max: 10000, integer: true);
    _num(item['quantity'], max: 1000000000, integer: true);
    if (shelf['rows'] != null && row > shelf['rows']) _invalid();
    if ((await _list(db, 'shelf_items', shelf['store_id'])).any(
      (i) =>
          i['shelf_id'] == shelf['id'] &&
          i['row'] == row &&
          i['slot'] == slot &&
          i['id'] != ignore,
    )) {
      throw const ApiFailure(
        'invalidInput',
        detail: 'The selected row and slot are already occupied',
      );
    }
  }

  void _product(Map<String, dynamic> d) {
    _name(d['name']);
    if (d['price_minor'] != null) {
      _num(d['price_minor'], max: 1000000000000, integer: true);
    }
    for (final e
        in {
          'barcode': 2048,
          'brand': 300,
          'category': 500,
          'net_weight': 100,
          'ingredients': 20000,
          'allergens': 10000,
          'manufacturer': 1000,
          'shelf_life': 300,
          'source': 100,
          'image_base64': 7000000,
        }.entries) {
      final v = d[e.key];
      if (v != null && (v is! String || v.length > e.value)) _invalid();
    }
    if (d['is_veg'] != null && d['is_veg'] is! bool) _invalid();
    if (d['nutrition'] != null &&
        (d['nutrition'] is! Map ||
            (d['nutrition'] as Map).values.any(
              (v) => v != null && v is! String && v is! num,
            ))) {
      _invalid();
    }
    _options(d);
  }

  Future<void> _inventory(
    DatabaseExecutor db,
    Map<String, dynamic> item,
    int previous,
    String reason,
  ) async {
    final product = await _one(db, 'products', item['product_id']);
    await _event(db, item['store_id'], 'inventory_adjustment', {
      'item_id': item['id'],
      'shelf_id': item['shelf_id'],
      'product_id': product['id'],
      'product_name': product['name'],
      'price_minor': product['price_minor'],
      'currency': product['currency'],
      'quantity': item['quantity'],
      'delta': (item['quantity'] as num) - previous,
      'reason': reason,
      'provenance': 'user_recorded_inventory',
      'event_type':
          reason == 'initial_quantity' ? 'INITIAL_STOCK' : 'STOCK_CORRECTION',
      'row': item['row'],
      'slot': item['slot'],
    });
  }

  Future<List<Map<String, dynamic>>> ledger(
    String storeId, {
    int limit = 10000,
  }) async {
    if (limit <= 0) _invalid();
    final db = _database, generation = _generation, owner = _owner;
    await _one(db, 'stores', storeId);
    _checkIdentity(generation, owner);
    final result = await _ledger(db, storeId, limit: limit);
    _checkIdentity(generation, owner);
    return result;
  }

  Future<List<Map<String, dynamic>>> _ledger(
    DatabaseExecutor db,
    String id, {
    int? limit,
  }) async {
    final rows = await db.rawQuery(
      'SELECT data FROM (SELECT rowid AS sequence,recorded_at,data FROM inventory_events WHERE owner=? AND store_id=? UNION ALL SELECT rowid AS sequence,recorded_at,data FROM visit_events WHERE owner=? AND store_id=?) ORDER BY recorded_at DESC,sequence DESC ${limit == null ? '' : 'LIMIT ?'}',
      [_owner, id, _owner, id, if (limit != null) limit],
    );
    return [
      for (final row in rows.reversed)
        Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
    ];
  }

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    final generation = _generation, owner = _owner;
    final result = await _get(path, query: query);
    _checkIdentity(generation, owner);
    return result;
  }

  void _checkIdentity(int generation, String? owner) {
    if (generation != _generation || owner != _owner || !ready) {
      throw const ApiFailure('sessionExpired');
    }
  }

  Future<dynamic> _get(String path, {Map<String, dynamic>? query}) async {
    final db = _database, parts = _path(path);
    if (parts.length == 1 && parts[0] == 'config') {
      return {
        ...config,
        'capabilities': {
          ..._body(config['capabilities']),
          'visits': true,
          'decisions': true,
        },
        'deployment': {
          'mode': 'standalone_mobile',
          'persistence': 'on_device_sqlite',
        },
        'providers': {
          'detector': {
            'available': true,
            'reason': 'On-device ML Kit, pose-confirmed person',
          },
          'decision_engine': {
            'available': true,
            'reason': 'On-device ledger evidence',
          },
        },
      };
    }
    if (parts.length == 1 && parts[0] == 'stores') {
      return {'items': await _list(db, 'stores')};
    }
    if (parts.length == 2 && parts[0] == 'products' && parts[1] == 'lookup') {
      final barcode = query?['barcode']?.toString().trim() ?? '';
      if (!OpenFoodFactsClient.validBarcode(barcode)) {
        return {'found': false, 'source': 'manual'};
      }
      final generation = _generation;
      final known =
          (await _list(
            db,
            'products',
            query?['store_id']?.toString(),
          )).where((p) => p['barcode'] == barcode).firstOrNull;
      if (known != null) {
        return {'found': true, 'source': 'local_sqlite', 'product': known};
      }
      final result = await _catalog.lookup(barcode);
      if (generation != _generation) throw const ApiFailure('sessionExpired');
      return result;
    }
    if (parts.length == 3 && parts[0] == 'stores') {
      final id = parts[1];
      final store = await _one(db, 'stores', id);
      switch (parts[2]) {
        case 'snapshot':
          return {
            'store': store,
            'floors': await _list(db, 'floors', id),
            'shelves': await _list(db, 'shelves', id),
            'products': await _list(db, 'products', id),
            'items': await _list(db, 'shelf_items', id),
            'calibrations': await _list(db, 'camera_calibrations', id),
          };
        case 'events':
          return {'items': await ledger(id)};
        case 'analytics':
          return summarizeLocal(
            config,
            store,
            await _list(db, 'shelves', id),
            await _ledger(db, id),
            query ?? {},
          );
      }
    }
    _invalid();
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) async {
    final db = _database, parts = _path(path), d = _body(body);
    return db.transaction((tx) async {
      if (parts.length == 1 && parts[0] == 'stores') {
        _name(d['name']);
        _options(d);
        _name(d['timezone'], max: 100);
        final count = _num(d['shelf_count'], max: 1000, integer: true).toInt();
        final floorData = _body(d['floor']);
        _floor(floorData);
        final values =
            {...d}
              ..remove('floor')
              ..remove('shelf_count');
        final store = await _create(tx, 'stores', '', {
          ...values,
          'settings': {},
        });
        final floor = await _create(tx, 'floors', store['id'], floorData);
        for (var i = 0; i < count; i++) {
          await _create(tx, 'shelves', store['id'], {
            'name': (config['shelf_name_template'] as String).replaceAll(
              '{n}',
              '${i + 1}',
            ),
            'floor_id': floor['id'],
            'shape': config['shapes'][0]['id'],
            'x': null,
            'y': null,
            'width': null,
            'length': null,
            'rotation': 0,
            'rows': null,
            'settings': {},
          }, parent: floor['id']);
        }
        return store;
      }
      if (parts.length == 3 && parts[0] == 'stores') {
        final id = parts[1];
        await _one(tx, 'stores', id);
        switch (parts[2]) {
          case 'floors':
            _floor(d);
            return _create(tx, 'floors', id, d);
          case 'shelves':
            _name(d['name']);
            final f = await _one(tx, 'floors', d['floor_id']);
            if (f['store_id'] != id) _invalid();
            return _create(tx, 'shelves', id, {
              ...d,
              'settings': {},
              'shape': config['shapes'][0]['id'],
              'x': null,
              'y': null,
              'width': null,
              'length': null,
              'rotation': 0,
              'rows': null,
            }, parent: f['id']);
          case 'products':
            _product(d);
            return _create(tx, 'products', id, d);
          case 'calibrations':
            if (![
              'portraitUp',
              'portraitDown',
              'landscapeLeft',
              'landscapeRight',
            ].contains(d['orientation'])) {
              _invalid();
            }
            _num(d['frame_width'], min: 1, max: 16384, integer: true);
            _num(d['frame_height'], min: 1, max: 16384, integer: true);
            if (d['zones'] is! List || (d['zones'] as List).length > 1000) {
              _invalid();
            }
            final zones = [
              for (final z in d['zones']) CameraZone.fromJson(_body(z)),
            ];
            if (zones.any((z) => z == null) ||
                !validZones(zones.whereType<CameraZone>().toList())) {
              _invalid();
            }
            for (final z in zones) {
              if ((await _one(tx, 'shelves', z!.shelfId))['store_id'] != id) {
                _invalid();
              }
            }
            return _create(tx, 'camera_calibrations', id, {
              ...d,
              'revision': newId(),
            });
          case 'monitoring':
            final c = await _one(
              tx,
              'camera_calibrations',
              d['calibration_id'],
            );
            if (c['store_id'] != id) _invalid();
            return _create(tx, 'monitoring_sessions', id, {
              'calibration_id': c['id'],
              'calibration_revision': c['revision'],
              'owner_uid': _owner,
              'status': 'active',
              'started_at': _now(),
              'active_tracks': [],
              'coverage': [],
              'provenance': 'live_camera',
              'frames': 0,
              'bytes': 0,
              'zones': c['zones'],
              'thresholds': RuntimeConfiguration(config).resolve(
                device: _body(d['settings']),
                store: {'settings': d['store_settings'] ?? {}},
              ),
              'shelf_thresholds': d['shelf_settings'] ?? {},
            });
        }
      }
      if (parts.length == 3 && parts[0] == 'shelves' && parts[2] == 'items') {
        final s = await _one(tx, 'shelves', parts[1]);
        final p = await _one(tx, 'products', d['product_id']);
        if (s['store_id'] != p['store_id']) _invalid();
        await _slot(tx, s, d);
        final item = await _create(tx, 'shelf_items', s['store_id'], {
          ...d,
          'shelf_id': s['id'],
        }, parent: s['id']);
        await _inventory(tx, item, 0, 'initial_quantity');
        return item;
      }
      if (parts.length == 3 &&
          parts[0] == 'shelves' &&
          parts[2] == 'planogram') {
        final shelf = await _one(tx, 'shelves', parts[1]);
        if (d['items'] is! List) _invalid();
        final rowLimit = d['rows'] ?? shelf['rows'];
        if (d['rows'] != null) {
          _num(d['rows'], min: 1, max: 1000, integer: true);
        }
        final existing =
            (await _list(
              tx,
              'shelf_items',
              shelf['store_id'],
            )).where((i) => i['shelf_id'] == shelf['id']).toList();
        final changes = <String, Map<String, dynamic>>{};
        for (final raw in d['items']) {
          final value = _body(raw), id = value['id'];
          if (id is! String ||
              changes.containsKey(id) ||
              !existing.any((i) => i['id'] == id)) {
            _invalid();
          }
          if (value.keys.any(
            (k) => !['id', 'row', 'slot', 'quantity'].contains(k),
          )) {
            _invalid();
          }
          _num(value['row'], min: 1, max: 1000, integer: true);
          _num(value['slot'], min: 1, max: 10000, integer: true);
          _num(value['quantity'], max: 1000000000, integer: true);
          if (rowLimit != null && value['row'] > rowLimit) _invalid();
          changes[id] = value;
        }
        final occupied = <String>{};
        for (final old in existing) {
          final v = changes[old['id']] ?? old;
          if (rowLimit != null && v['row'] > rowLimit) _invalid();
          if (!occupied.add('${v['row']}:${v['slot']}')) _invalid();
        }
        if (d['rows'] != null) {
          await _update(tx, 'shelves', shelf['id'], {'rows': d['rows']});
        }
        for (final old in existing) {
          final value = changes[old['id']];
          if (value == null) continue;
          if (['row', 'slot', 'quantity'].every((k) => old[k] == value[k])) {
            continue;
          }
          final updated = await _update(tx, 'shelf_items', old['id'], {
            for (final key in ['row', 'slot', 'quantity']) key: value[key],
          });
          await _inventory(tx, updated, old['quantity'], 'user_correction');
        }
        return {'items': await _list(tx, 'shelf_items', shelf['store_id'])};
      }
      if (parts.length == 3 && parts[0] == 'monitoring' && parts[2] == 'stop') {
        final s = await _one(tx, 'monitoring_sessions', parts[1]);
        return _finishSession(tx, s, incomplete: true);
      }
      _invalid();
    });
  }

  @override
  Future<dynamic> patch(String path, dynamic body) async {
    final parts = _path(path), d = _body(body);
    if (parts.length != 2 || !_entities.containsKey(parts[0])) _invalid();
    if (d.keys.any(
      (k) => [
        'id',
        'owner',
        'owner_uid',
        'store_id',
        'created_at',
        'updated_at',
      ].contains(k),
    )) {
      _invalid();
    }
    final allowed = {
      'stores': {'name', 'currency', 'unit', 'settings'},
      'floors': {'name', 'width', 'length'},
      'shelves': {
        'name',
        'floor_id',
        'shape',
        'x',
        'y',
        'width',
        'length',
        'rotation',
        'rows',
        'settings',
      },
      'products': {
        'name',
        'barcode',
        'brand',
        'category',
        'net_weight',
        'price_minor',
        'currency',
        'is_veg',
        'ingredients',
        'allergens',
        'nutrition',
        'manufacturer',
        'shelf_life',
        'image_base64',
        'source',
      },
      'items': {'row', 'slot', 'quantity'},
    };
    if (!allowed.containsKey(parts[0]) ||
        d.keys.any((k) => !allowed[parts[0]]!.contains(k))) {
      _invalid();
    }
    if (parts[0] != 'products' && d.values.any((v) => v == null)) _invalid();
    _options(d);
    return _database.transaction((tx) async {
      final table = _entities[parts[0]]!,
          id = parts[1],
          previous = await _one(tx, table, id),
          merged = {...previous, ...d};
      if (d.containsKey('name')) _name(d['name']);
      if (table == 'stores' &&
          d['unit'] != null &&
          d['unit'] != previous['unit']) {
        const meters = {'m': 1.0, 'ft': .3048};
        final factor = meters[previous['unit']]! / meters[d['unit']]!;
        for (final t in ['floors', 'shelves']) {
          for (final obj in await _list(tx, t, id)) {
            await _update(tx, t, obj['id'], {
              for (final k in ['x', 'y', 'width', 'length'])
                if (obj[k] != null) k: (obj[k] as num) * factor,
            });
          }
        }
      }
      if (table == 'floors') {
        _floor(merged);
        final store = await _one(tx, 'stores', previous['store_id']);
        final scale = store['unit'] == 'ft' ? 0.3048 : 1.0;
        d.addAll({
          'width_m': (merged['width'] as num) * scale,
          'length_m': (merged['length'] as num) * scale,
        });
        for (final s in await _list(tx, 'shelves', previous['store_id'])) {
          if (s['floor_id'] == id) _geometry(s, merged);
        }
      }
      if (table == 'shelves') {
        if (![0, 90, 180, 270].contains(merged['rotation'])) {
          _invalid();
        }
        for (final key in ['x', 'y']) {
          if (merged[key] != null) {
            _num(merged[key]);
          }
        }
        for (final key in ['width', 'length']) {
          if (merged[key] != null) {
            _num(merged[key], positive: true);
          }
        }
        final f = await _one(tx, 'floors', merged['floor_id']);
        if (f['store_id'] != previous['store_id']) _invalid();
        if (merged['rows'] != null) {
          _num(merged['rows'], min: 1, max: 1000, integer: true);
        }
        if (merged['rows'] != null &&
            (await _list(
              tx,
              'shelf_items',
              previous['store_id'],
            )).any((i) => i['shelf_id'] == id && i['row'] > merged['rows'])) {
          _invalid();
        }
        _geometry(merged, f);
      }
      if (table == 'products') _product(merged);
      if (table == 'shelf_items') {
        await _slot(
          tx,
          await _one(tx, 'shelves', previous['shelf_id']),
          merged,
          ignore: id,
        );
      }
      final updated = await _update(tx, table, id, d);
      if (table == 'shelf_items' && d.isNotEmpty) {
        await _inventory(tx, updated, previous['quantity'], 'user_correction');
      }
      if (table == 'products' &&
          d.keys.any((k) => ['name', 'price_minor', 'currency'].contains(k))) {
        for (final i in await _list(tx, 'shelf_items', previous['store_id'])) {
          if (i['product_id'] == id) {
            await _inventory(
              tx,
              i,
              i['quantity'],
              'product_details_correction',
            );
          }
        }
      }
      return updated;
    });
  }

  @override
  Future<dynamic> delete(String path) async {
    final parts = _path(path);
    if (parts.length == 1 && parts[0] == 'stores') {
      final db = _database, owner = _owner, generation = _generation;
      await db.transaction((tx) async {
        _checkIdentity(generation, owner);
        await tx.delete('stores', where: 'owner=?', whereArgs: [owner]);
      });
      return null;
    }
    if (parts.length != 2 || parts[0] != 'stores') _invalid();
    final db = _database, generation = _generation, owner = _owner;
    await db.transaction((tx) async {
      await _one(tx, 'stores', parts[1]);
      _checkIdentity(generation, owner);
      await tx.delete(
        'stores',
        where: 'id=? AND owner=?',
        whereArgs: [parts[1], owner],
      );
    });
    return null;
  }

  Future<Map<String, dynamic>> saveDecision(
    String storeId,
    Map<String, dynamic> plan,
  ) async {
    final db = _database, generation = _generation, owner = _owner;
    return db.transaction((tx) async {
      await _one(tx, 'stores', storeId);
      _checkIdentity(generation, owner);
      return _create(tx, 'autonomous_decisions', storeId, plan);
    });
  }

  Future<List<Map<String, dynamic>>> decisions(String storeId) async {
    final db = _database, generation = _generation, owner = _owner;
    await _one(db, 'stores', storeId);
    _checkIdentity(generation, owner);
    final result = await _list(db, 'autonomous_decisions', storeId);
    _checkIdentity(generation, owner);
    return result;
  }

  Future<Map<String, dynamic>> event(String storeId, String id) async {
    final db = _database, generation = _generation, owner = _owner;
    await _one(db, 'stores', storeId);
    _checkIdentity(generation, owner);
    for (final table in ['inventory_events', 'visit_events']) {
      final rows = await db.query(
        table,
        columns: ['data'],
        where: 'id=? AND owner=? AND store_id=?',
        whereArgs: [id, owner, storeId],
        limit: 1,
      );
      _checkIdentity(generation, owner);
      if (rows.isNotEmpty) {
        return Map<String, dynamic>.from(
          jsonDecode(rows.single['data'] as String) as Map,
        );
      }
    }
    throw const ApiFailure('eventUnavailable');
  }

  Future<List<Map<String, dynamic>>> recordFrame(
    String sessionId, {
    required List<Map<String, dynamic>> visits,
    required List<Map<String, dynamic>> active,
    required double at,
    required double grace,
  }) async {
    return _database.transaction((tx) async {
      final s = await _one(tx, 'monitoring_sessions', sessionId);
      if (s['status'] != 'active') throw const ApiFailure('sessionExpired');
      final last = (s['last_frame_at'] as num?)?.toDouble();
      if (last != null && at < last) _invalid();
      final coverage = [
        for (final c in s['coverage'] as List)
          List<double>.from((c as List).map((v) => (v as num).toDouble())),
      ];
      if (last == null || at - last > grace) {
        coverage.add([at, at]);
      } else {
        coverage.last[1] = at;
      }
      final recorded = <Map<String, dynamic>>[];
      for (final v in visits) {
        recorded.add(await _visit(tx, s, v));
      }
      await _update(tx, 'monitoring_sessions', sessionId, {
        'active_tracks': active,
        'coverage': coverage,
        'last_frame_at': at,
        'frames': (s['frames'] as int) + 1,
      });
      return recorded;
    });
  }

  Future<Map<String, dynamic>> _visit(
    DatabaseExecutor tx,
    Map<String, dynamic> s,
    Map<String, dynamic> v,
  ) async {
    if (!(s['zones'] as List).any((z) => z['shelf_id'] == v['shelf_id'])) {
      _invalid();
    }
    return _event(tx, s['store_id'], 'visit', {
      ...v,
      'session_id': s['id'],
      'calibration_id': s['calibration_id'],
      'calibration_revision': s['calibration_revision'],
      'provenance': s['provenance'],
    });
  }

  Future<Map<String, dynamic>> _finishSession(
    DatabaseExecutor tx,
    Map<String, dynamic> s, {
    required bool incomplete,
    bool recover = false,
  }) async {
    if (s['status'] != 'active') return s;
    for (final track in s['active_tracks'] as List) {
      final thresholds = {
        ..._body(s['thresholds']),
        ..._body((s['shelf_thresholds'] as Map? ?? {})[track['shelf_id']]),
      };
      if ((track['dwell_seconds'] as num) >=
          (thresholds['dwell_cutoff_sec'] as num)) {
        await _visit(tx, s, {
          ..._body(track),
          'incomplete': true,
          'is_incomplete': true,
        });
      }
    }
    for (final interval in s['coverage'] as List) {
      if (interval[1] <= interval[0]) continue;
      String stamp(num seconds) =>
          DateTime.fromMillisecondsSinceEpoch(
            (seconds * 1000).round(),
            isUtc: true,
          ).toIso8601String();
      await _event(tx, s['store_id'], 'coverage', {
        'session_id': s['id'],
        'started_at': stamp(interval[0]),
        'ended_at': stamp(interval[1]),
        'shelf_ids': [for (final z in s['zones']) z['shelf_id']],
        'provenance': s['provenance'],
        'incomplete': incomplete,
      });
    }
    return _update(tx, 'monitoring_sessions', s['id'], {
      'status': recover ? 'interrupted' : 'stopped',
      'ended_at': _now(),
      'incomplete': incomplete,
      'is_incomplete': incomplete,
      'active_tracks': [],
    });
  }

  @override
  Future<String> text(String path, {Map<String, dynamic>? query}) async {
    if (!path.endsWith('/analytics/export')) _invalid();
    final summary = await get(
      path.replaceFirst('/analytics/export', '/analytics'),
      query: query,
    );
    return exportLocalCsv(Map<String, dynamic>.from(summary as Map));
  }

  @override
  Future<dynamic> upload(String path, String filePath) async =>
      throw const ApiFailure('aiUseDirectScan');
  @override
  Future<dynamic> uploadBytes(String path, Uint8List bytes) async =>
      throw const ApiFailure('aiUseDirectScan');
  @override
  Future<WebSocketChannel> openSocket(String path) async =>
      throw const ApiFailure('monitorLocalOnly');
}
