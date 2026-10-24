import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:shelfsight/app.dart';
import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/ai_credentials.dart';
import 'package:shelfsight/core/standalone_repository.dart';
import 'package:shelfsight/core/configuration.dart';

class _NoServer extends ApiClient {
  int calls = 0;
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    calls++;
    throw StateError('Server forbidden');
  }

  @override
  Future<dynamic> post(String path, [dynamic body]) async {
    calls++;
    throw StateError('Server forbidden');
  }

  @override
  Future<void> clear({bool erase = true}) async {}
  @override
  Future<void> revoke() async {}
}

class _OfflineKeys extends AiCredentials {
  // Test-only key satisfies onboarding without spending any provider tokens.
  @override
  Future<String> key(String provider) async =>
      provider == 'gemini' ? 'device-test-only' : '';
}

class _TestSettings extends DeviceSettingsStore {
  Map<String, dynamic> values = {};
  @override
  Future<Map<String, dynamic>> read() async =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(values)) as Map);
  @override
  Future<void> write(Map<String, dynamic> value) async {
    values = Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'standalone uses native SQLite, persists after reopen and opens home without server pairing',
    (tester) async {
      final config = Map<String, dynamic>.from(
        jsonDecode(await rootBundle.loadString('assets/defaults.json')) as Map,
      );
      final path = p.join(
        await getDatabasesPath(),
        'standalone_integration_${StandaloneMobileRepository.newId()}.db',
      );
      final repo = StandaloneMobileRepository(
            config: config,
            databasePath: path,
          ),
          api = _NoServer();
      final app = AppController.forTesting(
        api: api,
        config: config,
        localRepository: repo,
        aiCredentials: _OfflineKeys(),
        settingsStore: _TestSettings(),
        signedIn: false,
      );
      String? storeId;
      var attached = false;
      try {
        await app.enterStandalone();
        final s = await repo.post('/stores', {
          'name': 'Integration test store',
          'type_id': config['store_types'][0]['id'],
          'goal_id': config['goals'][0]['id'],
          'currency': config['currencies'][0],
          'unit': 'm',
          'timezone': 'UTC',
          'shelf_count': 1,
          'floor': {'name': 'Integration floor', 'width': 10, 'length': 10},
        });
        storeId = s['id'];
        await app.refresh();
        final shelf = app.shelves.single['id'];
        final product = await repo.post('/stores/$storeId/products', {
          'name': 'Integration product',
          'barcode': '12345678',
        });
        await repo.post('/shelves/$shelf/items', {
          'product_id': product['id'],
          'row': 1,
          'slot': 1,
          'quantity': 7,
        });
        await app.logout();
        await app.enterStandalone(requireApiKey: false);
        expect(app.items.single['quantity'], 7);
        expect(
          (await repo.get(
            '/products/lookup',
            query: {'barcode': '12345678', 'store_id': storeId},
          ))['source'],
          'local_sqlite',
        );
        attached = true;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appControllerProvider.overrideWith((ref) => app)],
            child: const ShelfSightApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Integration test store'), findsWidgets);
        expect(app.ready, true);
        expect(api.calls, 0);
        expect(api.hasApiAddress, false);
        // This smoke checks native persistence/navigation. Real-camera timing and
        // visible-person visits must be measured with the separate device checklist.
      } finally {
        if (storeId != null && repo.ready) {
          await repo.delete('/stores/$storeId');
        }
        await app.cache.erase();
        if (attached) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          app.dispose();
        }
        await repo.close();
        await deleteDatabase(path);
      }
    },
  );
}
