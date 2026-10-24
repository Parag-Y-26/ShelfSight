import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/cache.dart';
import 'package:shelfsight/core/standalone_repository.dart';
import 'ai_provider_router_test.dart' show MemoryCredentials;
import 'runtime_settings_test.dart' show MemorySettings;

class NoServerApi extends ApiClient {
  int networkCalls = 0;
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    networkCalls++;
    throw StateError('Server forbidden');
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) async {
    networkCalls++;
    throw StateError('Server forbidden');
  }

  @override
  Future<dynamic> patch(String path, dynamic body) async {
    networkCalls++;
    throw StateError('Server forbidden');
  }

  @override
  Future<void> clear({bool erase = true}) async {}
  @override
  Future<void> revoke() async {}
}

class LocalTestCache extends OwnerCache {
  final values = <String, dynamic>{};
  @override
  Future<void> open(String uid, {String server = ''}) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> put(String key, dynamic value) async {
    values[key] = value;
  }

  @override
  Future<Map<String, dynamic>?> read(String key) async =>
      values.containsKey(key) ? {'value': values[key]} : null;
  @override
  Future<void> erase() async {
    values.clear();
  }

  @override
  Future<void> recordEvents(
    String storeId,
    List<Map<String, dynamic>> events,
  ) async {}
}

class PausedSettings extends MemorySettings {
  final began = Completer<void>(), release = Completer<void>();
  bool first = true;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (first) {
      first = false;
      began.complete();
      await release.future;
    }
    await super.write(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
    'local profile, stock and evidence-grounded decisions work with every server call forbidden',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'shelfsight_controller_test',
      );
      final config =
          jsonDecode(await File('assets/defaults.json').readAsString())
              as Map<String, dynamic>;
      final repo = StandaloneMobileRepository(
        config: config,
        factory: databaseFactoryFfi,
        databasePath: '${dir.path}/ledger.db',
      );
      final api = NoServerApi(),
          credentials = MemoryCredentials(),
          settings = MemorySettings();
      final app = AppController.forTesting(
        api: api,
        localRepository: repo,
        config: config,
        cache: LocalTestCache(),
        aiCredentials: credentials,
        settingsStore: settings,
        signedIn: false,
      );
      try {
        await expectLater(
          app.enterStandalone(),
          throwsA(
            isA<ApiFailure>().having((e) => e.key, 'key', 'localNeedsKey'),
          ),
        );
        await credentials.setKey('gemini', 'dummy-local-test-key');
        app.passwordRecoveryPending = true;
        await expectLater(
          app.enterStandalone(),
          throwsA(
            isA<ApiFailure>().having((e) => e.key, 'key', 'chooseNewPassword'),
          ),
        );
        app.passwordRecoveryPending = false;
        await app.enterStandalone();
        expect(app.authenticated, true);
        expect(app.ready, true);
        expect(api.hasApiAddress, false);
        final s = await app.repository.post('/stores', {
          'name': 'Locally entered',
          'type_id': 'grocery',
          'goal_id': 'demand',
          'currency': 'INR',
          'unit': 'm',
          'timezone': 'UTC',
          'shelf_count': 1,
          'floor': {'name': 'Entered floor', 'width': 10, 'length': 10},
        });
        await app.refresh();
        expect(app.store!['id'], s['id']);
        final shelf = app.shelves.single['id'];
        final p = await app.repository.post('/stores/${s['id']}/products', {
          'name': 'Entered product',
        });
        await app.repository.post('/shelves/$shelf/items', {
          'product_id': p['id'],
          'row': 1,
          'slot': 1,
          'quantity': 2,
        });
        await app.refresh();
        // No key available means deterministic, evidence-gated decisions. This
        // confirms actual SQLite event IDs rather than mocked model citations.
        await credentials.clear('gemini');
        final plan = await app.recommendations();
        expect(plan.actions.single['type'], 'RESTOCK_ALERT');
        final ids = (await repo.ledger(s['id'])).map((e) => e['id']).toSet();
        expect(plan.actions.single['event_ids'].every(ids.contains), true);
        expect(await repo.decisions(s['id']), hasLength(1));
        await app.saveSettings({'low_stock_threshold': 3}, shelfId: shelf);
        expect(
          app.effectiveSettings(app.shelves.single)['low_stock_threshold'],
          3,
        );
        await app.logout();
        expect(app.authenticated, false);
        await app.enterStandalone(requireApiKey: false);
        expect(app.items.single['quantity'], 2);
        expect(
          (await app.latestLocalDecision())!.actions.single['type'],
          'RESTOCK_ALERT',
        );
        expect(settings.values['local_profile']['active'], true);
        expect(api.networkCalls, 0);
        await app.deleteSelectedStore();
        expect(app.stores, isEmpty);
        await app.useRemoteMode();
        expect(app.isStandalone, false);
        expect(app.authenticated, false);
      } finally {
        app.dispose();
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'cached cloud-origin standalone identity resumes offline and explicit logout deactivates it',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'shelfsight_resume_test',
      );
      final config =
          jsonDecode(await File('assets/defaults.json').readAsString())
              as Map<String, dynamic>;
      final repo = StandaloneMobileRepository(
        config: config,
        factory: databaseFactoryFfi,
        databasePath: '${dir.path}/ledger.db',
      );
      final settings =
          MemorySettings()
            ..values = {
              'global': {'execution_mode': 'standalone_mobile'},
              'standalone_identity': {
                'id': 'previously-authenticated-owner',
                'name': 'Cached profile',
                'active': true,
                'source': 'cloud_cached',
              },
            };
      final api = NoServerApi();
      final app = AppController(
        api: api,
        localRepository: repo,
        cache: LocalTestCache(),
        settingsStore: settings,
      );
      try {
        for (var i = 0; i < 100 && !app.initialized; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(app.initialized, true);
        expect(app.authenticated, true);
        expect(app.ready, true);
        expect(app.displayName, 'Cached profile');
        expect(api.networkCalls, 0);
        await app.logout();
        expect(settings.values['standalone_identity']['active'], false);
      } finally {
        app.dispose();
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'a delayed standalone launch cannot reopen an identity after logout',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'shelfsight_entry_race_test',
      );
      final config =
          jsonDecode(await File('assets/defaults.json').readAsString())
              as Map<String, dynamic>;
      final repo = StandaloneMobileRepository(
        config: config,
        factory: databaseFactoryFfi,
        databasePath: '${dir.path}/ledger.db',
      );
      final keys = MemoryCredentials();
      await keys.setKey('gemini', 'dummy-entry-key');
      final settings = PausedSettings();
      final app = AppController.forTesting(
        api: NoServerApi(),
        localRepository: repo,
        config: config,
        cache: LocalTestCache(),
        settingsStore: settings,
        aiCredentials: keys,
        signedIn: false,
      );
      try {
        final entry = app.enterStandalone().then<bool>(
          (_) => true,
          onError: (Object _) => false,
        );
        await settings.began.future;
        final exit = app.logout();
        await Future<void>.delayed(Duration.zero);
        settings.release.complete();
        await exit;
        expect(await entry, false);
        expect(app.authenticated, false);
        expect(app.ready, false);
        expect(settings.values['local_profile']['active'], false);
      } finally {
        app.dispose();
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'resetting a remote device override switches the backend to the mobile default',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'shelfsight_reset_test',
      );
      final config =
          jsonDecode(await File('assets/defaults.json').readAsString())
              as Map<String, dynamic>;
      final repo = StandaloneMobileRepository(
        config: config,
        factory: databaseFactoryFfi,
        databasePath: '${dir.path}/ledger.db',
      );
      final keys = MemoryCredentials();
      await keys.setKey('gemini', 'dummy-reset-key');
      final app = AppController.forTesting(
        api: NoServerApi(),
        localRepository: repo,
        config: config,
        cache: LocalTestCache(),
        settingsStore: MemorySettings(),
        aiCredentials: keys,
      );
      try {
        await app.useRemoteMode();
        expect(app.isStandalone, false);
        await app.saveSettings({}, global: true);
        expect(app.globalSettings['execution_mode'], 'standalone_mobile');
        expect(app.isStandalone, true);
        expect(app.ready, true);
        await app.logout();
      } finally {
        app.dispose();
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
