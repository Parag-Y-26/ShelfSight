import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shelfsight/core/standalone_repository.dart';
import 'package:shelfsight/vision/local_tracker.dart';
import 'package:shelfsight/vision/geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late StandaloneMobileRepository repo;
  late Map<String, dynamic> config;
  setUpAll(() {
    sqfliteFfiInit();
  });
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('shelfsight_sql_test');
    config = jsonDecode(await File('assets/defaults.json').readAsString());
    repo = StandaloneMobileRepository(
      config: config,
      factory: databaseFactoryFfi,
      databasePath: '${dir.path}/ledger.db',
    );
    await repo.open('owner-a');
  });
  tearDown(() async {
    await repo.close();
    await dir.delete(recursive: true);
  });
  Future<Map<String, dynamic>> create() async => Map<String, dynamic>.from(
    await repo.post('/stores', {
      'name': 'User entered store',
      'type_id': config['store_types'][0]['id'],
      'goal_id': config['goals'][0]['id'],
      'currency': config['currencies'][0],
      'unit': 'm',
      'timezone': 'UTC',
      'shelf_count': 1,
      'floor': {'name': 'User floor', 'width': 10.0, 'length': 10.0},
    }),
  );
  test(
    'version one floor migration preserves feet and creates canonical metres',
    () async {
      final store = await create();
      await repo.patch('/stores/${store['id']}', {'unit': 'ft'});
      final before =
          (await repo.get('/stores/${store['id']}/snapshot'))['floors'].single
              as Map;
      await repo.close();
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/ledger.db');
      final legacy =
          Map<String, dynamic>.from(before)
            ..remove('width_m')
            ..remove('length_m');
      await db.update(
        'floors',
        {'data': jsonEncode(legacy)},
        where: 'id=?',
        whereArgs: [before['id']],
      );
      await db.setVersion(1);
      await db.close();
      await repo.open('owner-a');
      final after =
          (await repo.get('/stores/${store['id']}/snapshot'))['floors'].single;
      expect(after['width'], before['width']);
      expect(after['width_m'], closeTo(10, 0.000001));
      expect(await repo.ledger(store['id']), isEmpty);
    },
  );
  test(
    'real SQLite persists setup, product, stock, calibration and decisions across restart',
    () async {
      final store = await create();
      final id = store['id'];
      final snap = await repo.get('/stores/$id/snapshot');
      expect(snap['floors'].single['width_m'], 10.0);
      expect(snap['floors'].single['length_m'], 10.0);
      final shelf = snap['shelves'].single;
      final product = await repo.post('/stores/$id/products', {
        'name': 'User product',
        'barcode': '12345678',
      });
      final item = await repo.post('/shelves/${shelf['id']}/items', {
        'product_id': product['id'],
        'row': 1,
        'slot': 1,
        'quantity': 4,
      });
      await repo.patch('/items/${item['id']}', {'quantity': 2});
      await repo.post('/stores/$id/calibrations', {
        'orientation': 'portraitUp',
        'frame_width': 480,
        'frame_height': 640,
        'zones': [
          {
            'shelf_id': shelf['id'],
            'x': 0.0,
            'y': 0.0,
            'width': 1.0,
            'height': 1.0,
          },
        ],
      });
      await repo.saveDecision(id, {'actions': [], 'review_required': true});
      await repo.close();
      await repo.open('owner-a');
      final restored = await repo.get('/stores/$id/snapshot');
      expect(restored['items'].single['quantity'], 2);
      expect(restored['calibrations'], hasLength(1));
      expect((await repo.get('/stores/$id/events'))['items'], hasLength(2));
      expect(await repo.decisions(id), hasLength(1));
      final lookup = await repo.get(
        '/products/lookup',
        query: {'barcode': '12345678', 'store_id': id},
      );
      expect(lookup['source'], 'local_sqlite');
      expect(lookup['product']['price_minor'], isNull);
      final analytics = await repo.get(
        '/stores/$id/analytics',
        query: {'start': '2020-01-01T00:00:00Z', 'end': '2099-01-01T00:00:00Z'},
      );
      expect(analytics['visits'], 0);
      expect(analytics['inventory'].single['quantity'], 2);
      await repo.close();
      await repo.open('owner-b');
      expect((await repo.get('/stores'))['items'], isEmpty);
      await expectLater(repo.get('/stores/$id/snapshot'), throwsException);
    },
  );
  test(
    'atomic slot conflicts, ledger immutability and owner-scoped deletion',
    () async {
      final s = await create();
      final id = s['id'];
      final shelf = (await repo.get('/stores/$id/snapshot'))['shelves'].single;
      await expectLater(
        repo.patch('/shelves/${shelf['id']}', {'rotation': 45}),
        throwsException,
      );
      final p = await repo.post('/stores/$id/products', {'name': 'Entered'});
      final data = {'product_id': p['id'], 'row': 1, 'slot': 1, 'quantity': 0};
      await repo.post('/shelves/${shelf['id']}/items', data);
      await expectLater(
        repo.post('/shelves/${shelf['id']}/items', data),
        throwsException,
      );
      expect((await repo.get('/stores/$id/events'))['items'], hasLength(1));
      expect(
        (await repo.get('/stores/$id/events'))['items'].single['event_type'],
        'INITIAL_STOCK',
      );
      await expectLater(
        repo.patch('/items/missing', {'quantity': 1}),
        throwsException,
      );
      await repo.delete('/stores/$id');
      expect((await repo.get('/stores'))['items'], isEmpty);
    },
  );
  test(
    'an owner change cannot publish stale snapshots or write another owners decision',
    () async {
      final store = await create(), id = store['id'];
      final decision = repo
          .saveDecision(id, {'actions': []})
          .then<bool>((_) => true, onError: (Object _) => false);
      final snapshot = repo
          .get('/stores/$id/snapshot')
          .then<bool>((_) => true, onError: (Object _) => false);
      await repo.open('owner-b');
      await decision;
      await snapshot;
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/ledger.db');
      expect(
        await db.query(
          'autonomous_decisions',
          where: 'owner=?',
          whereArgs: ['owner-b'],
        ),
        isEmpty,
      );
      expect((await repo.get('/stores'))['items'], isEmpty);
      await expectLater(repo.decisions(id), throwsException);
    },
  );
  test(
    'crash recovery finalizes observed dwell and coverage incomplete exactly once',
    () async {
      final store = await create(), id = store['id'];
      final shelf = (await repo.get('/stores/$id/snapshot'))['shelves'].single;
      final c = await repo.post('/stores/$id/calibrations', {
        'orientation': 'portraitUp',
        'frame_width': 480,
        'frame_height': 640,
        'zones': [
          {
            'shelf_id': shelf['id'],
            'x': 0.0,
            'y': 0.0,
            'width': 1.0,
            'height': 1.0,
          },
        ],
      });
      final s = await repo.post('/stores/$id/monitoring', {
        'calibration_id': c['id'],
      });
      final tracker = BottomCenterIoUTracker(
        zones: [
          CameraZone(
            shelfId: shelf['id'],
            rect: const Rect.fromLTWH(0, 0, 1, 1),
          ),
        ],
        defaults: Map<String, dynamic>.from(config['settings']),
      );
      final start = DateTime.now().toUtc().millisecondsSinceEpoch / 1000 - 20;
      for (var i = 0; i < 5; i++) {
        final at = start + i;
        await repo.recordFrame(
          s['id'],
          visits: tracker.update([
            const PersonDetection(Rect.fromLTRB(.2, .1, .4, .8), .9),
          ], at),
          active: tracker.active(),
          at: at,
          grace: 1.5,
        );
      }
      await repo.close();
      await repo.open('owner-a');
      final events = await repo.ledger(id);
      expect(events.where((e) => e['type'] == 'visit'), hasLength(1));
      final visit = events.firstWhere((e) => e['type'] == 'visit');
      expect(visit['provenance'], 'live_camera');
      expect(visit['dwell_seconds'], 4);
      expect(visit['is_incomplete'], true);
      expect(events.where((e) => e['type'] == 'coverage'), hasLength(1));
      await repo.post('/monitoring/${s['id']}/stop');
      expect(await repo.ledger(id), hasLength(2));
      final analytics = await repo.get(
        '/stores/$id/analytics',
        query: {'start': '2020-01-01T00:00:00Z', 'end': '2099-01-01T00:00:00Z'},
      );
      expect(analytics['visits'], 1);
      expect(analytics['coverage_seconds'], 4);
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/ledger.db');
      await expectLater(
        db.execute("UPDATE visit_events SET data='{}'"),
        throwsException,
      );
      final names = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).map((r) => r['name']);
      expect(names, containsAll(StandaloneMobileRepository.tables));
    },
  );
  test(
    'planogram swaps are atomic, stock is typed, and event citations are store scoped',
    () async {
      final store = await create(), id = store['id'];
      final shelf = (await repo.get('/stores/$id/snapshot'))['shelves'].single;
      final p = await repo.post('/stores/$id/products', {
        'name': 'Verified test product',
      });
      final first = await repo.post('/shelves/${shelf['id']}/items', {
        'product_id': p['id'],
        'row': 1,
        'slot': 1,
        'quantity': 2,
      });
      final second = await repo.post('/shelves/${shelf['id']}/items', {
        'product_id': p['id'],
        'row': 1,
        'slot': 2,
        'quantity': 3,
      });
      await repo.post('/shelves/${shelf['id']}/planogram', {
        'items': [
          {'id': first['id'], 'row': 1, 'slot': 2, 'quantity': 2},
          {'id': second['id'], 'row': 1, 'slot': 1, 'quantity': 3},
        ],
      });
      final items = (await repo.get('/stores/$id/snapshot'))['items'] as List;
      expect(items.firstWhere((i) => i['id'] == first['id'])['slot'], 2);
      final ledger = await repo.ledger(id);
      expect(ledger, hasLength(4));
      expect(ledger.first['event_type'], 'INITIAL_STOCK');
      expect(ledger.last['slot'], 1);
      expect(
        (await repo.event(id, ledger.first['id']))['id'],
        ledger.first['id'],
      );
      final other = await create();
      await expectLater(
        repo.event(other['id'], ledger.first['id']),
        throwsException,
      );
      await expectLater(
        repo.post('/shelves/${shelf['id']}/planogram', {
          'items': [
            {'id': first['id'], 'row': 1, 'slot': 1, 'quantity': 2},
          ],
        }),
        throwsException,
      );
      expect(await repo.ledger(id), hasLength(4));
      await repo.patch('/stores/$id', {'unit': 'ft'});
      expect(
        (await repo.get('/stores/$id/snapshot'))['floors'].single['width_m'],
        10.0,
      );
    },
  );
  test(
    'full data wipe removes every store for this owner and preserves other owners',
    () async {
      await create();
      await create();
      await repo.open('owner-b');
      final other = await create();
      await repo.open('owner-a');
      await repo.delete('/stores');
      expect((await repo.get('/stores'))['items'], isEmpty);
      await repo.open('owner-b');
      expect((await repo.get('/stores'))['items'].single['id'], other['id']);
    },
  );
}
