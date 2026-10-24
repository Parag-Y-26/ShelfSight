import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shelfsight/app.dart';
import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/standalone_repository.dart';
import 'package:shelfsight/screens/dashboard.dart';
import 'standalone_controller_test.dart' show NoServerApi, LocalTestCache;
import 'runtime_settings_test.dart' show MemorySettings;
import 'ai_provider_router_test.dart' show MemoryCredentials;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  testWidgets(
    'all business routes use real local SQLite without a server URL or pairing',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory dir;
      late StandaloneMobileRepository repo;
      late AppController app;
      final api = NoServerApi();
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('shelfsight_routes_test');
        final config =
            jsonDecode(await File('assets/defaults.json').readAsString())
                as Map<String, dynamic>;
        repo = StandaloneMobileRepository(
          config: config,
          factory: databaseFactoryFfi,
          databasePath: '${dir.path}/ledger.db',
        );
        final keys = MemoryCredentials();
        await keys.setKey('gemini', 'dummy-navigation-key');
        app = AppController.forTesting(
          api: api,
          config: config,
          localRepository: repo,
          cache: LocalTestCache(),
          settingsStore: MemorySettings(),
          aiCredentials: keys,
          signedIn: false,
        );
        await app.enterStandalone();
        await repo.post('/stores', {
          'name': 'Route test store',
          'type_id': 'grocery',
          'goal_id': 'demand',
          'currency': 'INR',
          'unit': 'm',
          'timezone': 'UTC',
          'shelf_count': 1,
          'floor': {'name': 'Route test floor', 'width': 10, 'length': 10},
        });
        await app.refresh();
      });
      final shelf = app.shelves.single['id'];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => app)],
          child: const ShelfSightApp(),
        ),
      );
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(DashboardScreen)));
      expect(find.text('Route test store'), findsWidgets);
      // Auth and pairing routes correctly bypass to home for a local profile.
      for (final path in ['/login', '/connect']) {
        router.go(path);
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/home');
      }
      for (final path in [
        '/setup',
        '/shelf/$shelf',
        '/product/$shelf',
        '/map',
        '/analytics',
        '/monitor',
        '/scan/$shelf',
        '/settings',
        '/recommendations',
      ]) {
        router.go(path);
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(router.routeInformationProvider.value.uri.path, path);
        expect(tester.takeException(), isNull, reason: path);
      }
      expect(api.networkCalls, 0);
      expect(app.isStandalone, true);
      expect(app.isOffline, false);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await repo.close();
        await dir.delete(recursive: true);
      });
    },
  );
}
