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
import 'qa_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUpAll(loadQaFonts);
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
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      final router = GoRouter.of(tester.element(find.byType(DashboardScreen)));
      final semantics = tester.ensureSemantics();
      expect(find.text('Route test store'), findsWidgets);
      // Auth and pairing routes correctly bypass to home for a local profile.
      for (final path in ['/login', '/connect']) {
        router.go(path);
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(router.routeInformationProvider.value.uri.path, '/home');
      }
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetViewInsets);
      for (final viewport in [
        (const Size(320, 640), 1.0),
        (const Size(568, 320), 2.0),
      ]) {
        tester.view.physicalSize = viewport.$1;
        tester.platformDispatcher.textScaleFactorTestValue = viewport.$2;
        for (final path in [
          '/home',
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
          await tester.pump(const Duration(milliseconds: 350));
          expect(tester.takeException(), isNull, reason: '$path at $viewport');
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          if (viewport.$2 == 1 &&
              ['/home', '/monitor', '/map', '/scan/$shelf'].contains(path)) {
            final frameName =
                path.startsWith('/scan/') ? 'scan' : path.substring(1);
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile('goldens/mobile_$frameName.png'),
            );
          }
          final scroll =
              find
                  .byWidgetPredicate(
                    (w) =>
                        w is Scrollable &&
                        w.axisDirection == AxisDirection.down,
                  )
                  .hitTestable();
          if (scroll.evaluate().isNotEmpty) {
            await tester.drag(scroll.first, const Offset(0, -350));
            await tester.pump(const Duration(milliseconds: 300));
            expect(
              tester.takeException(),
              isNull,
              reason: '$path scrolled at $viewport',
            );
          }
          if (path == '/product/$shelf' ||
              path == '/setup' ||
              path == '/settings') {
            tester.view.viewInsets = const FakeViewPadding(bottom: 120);
            await tester.pump(const Duration(milliseconds: 200));
            expect(
              tester.takeException(),
              isNull,
              reason: '$path keyboard at $viewport',
            );
            tester.view.resetViewInsets();
            await tester.pump(const Duration(milliseconds: 200));
          }
        }
      }
      expect(api.networkCalls, 0);
      expect(app.isStandalone, true);
      expect(app.isOffline, false);
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      await tester.runAsync(() async {
        await repo.close();
        await dir.delete(recursive: true);
      });
    },
  );
}
