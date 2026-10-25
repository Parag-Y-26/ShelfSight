import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/ai_provider_router.dart';
import 'package:shelfsight/core/autonomous_decision_engine.dart';
import 'package:shelfsight/core/strings.dart';
import 'package:shelfsight/core/theme.dart';
import 'package:shelfsight/screens/recommendations.dart';
import 'package:shelfsight/widgets/ai_keys_panel.dart';
import 'package:shelfsight/widgets/provider_badge.dart';

import 'ai_provider_router_test.dart' show MemoryCredentials, FakeAiTransport;
import 'runtime_settings_test.dart' show MemorySettings, OfflineApi;

final _translations = <String, String>{};

class AiTestStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const AiTestStringsDelegate();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<AppStrings> load(Locale locale) =>
      SynchronousFuture(AppStrings(_translations));
  @override
  bool shouldReload(covariant LocalizationsDelegate<AppStrings> old) => false;
}

Map<String, dynamic> configuration() =>
    jsonDecode(File('assets/defaults.json').readAsStringSync())
        as Map<String, dynamic>;

class GoldenProbeRouter extends AiProviderRouter {
  GoldenProbeRouter(
    super.config, {
    required super.credentials,
    required super.transport,
  });
  @override
  Future<AiResult> testConnection(String provider) async {
    final result = await super.testConnection(provider);
    return AiResult(
      data: result.data,
      provider: result.provider,
      model: result.model,
      latencyMs: 123,
      attempts: result.attempts,
    );
  }
}

class PlanApp extends AppController {
  PlanApp()
    : super.forTesting(
        api: OfflineApi(),
        config: configuration(),
        store: {'id': 'first'},
      );
  @override
  Future<AutonomousActionPlan> recommendations() async => AutonomousActionPlan({
    'actions': [
      {
        'type': 'RESTOCK_ALERT',
        'shelf_id': 'owned-shelf',
        'event_ids': ['owned-event'],
      },
    ],
    'disclaimer': config['ai']['disclaimer'],
    'requires_review': true,
  });
}

Future<void> pump(WidgetTester tester, AppController app, Widget child) async {
  tester.view.physicalSize = const Size(430, 920);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      key: ValueKey(app),
      overrides: [appControllerProvider.overrideWith((ref) => app)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        locale: const Locale('en'),
        localizationsDelegates: const [
          AiTestStringsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final module in ['core', 'retail', 'monitoring']) {
      final data =
          jsonDecode(File('assets/l10n/${module}_en.arb').readAsStringSync())
              as Map;
      for (final entry in data.entries) {
        if (!entry.key.toString().startsWith('@') && entry.value is String) {
          _translations[entry.key.toString()] = entry.value as String;
        }
      }
    }
    await (FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
    final packagesFile = File('.dart_tool/package_config.json').absolute;
    final packages = jsonDecode(await packagesFile.readAsString()) as Map;
    final flutter = (packages['packages'] as List).whereType<Map>().firstWhere(
      (p) => p['name'] == 'flutter',
    );
    final root =
        Directory.fromUri(
          packagesFile.uri.resolve(flutter['rootUri'] as String),
        ).parent.parent;
    final icons =
        await File(
          '${root.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes();
    await (FontLoader('MaterialIcons')
      ..addFont(SynchronousFuture(ByteData.sublistView(icons)))).load();
  });
  testWidgets(
    'key save, single-provider test latency and removal need no backend',
    (tester) async {
      final keys = MemoryCredentials();
      final transport =
          FakeAiTransport()
            ..result = {
              'candidates': [
                {
                  'finishReason': 'STOP',
                  'content': {
                    'parts': [
                      {'text': '{"ok":true}'},
                    ],
                  },
                },
              ],
            };
      final config = configuration();
      final app = AppController.forTesting(
        api: OfflineApi(),
        signedIn: false,
        config: config,
        aiCredentials: keys,
        aiRouter: GoldenProbeRouter(
          config,
          credentials: keys,
          transport: transport,
        ),
        settingsStore: MemorySettings(),
      );
      await pump(
        tester,
        app,
        const Scaffold(body: SingleChildScrollView(child: AiKeysPanel())),
      );
      final tile = find.byKey(const ValueKey('ai-provider-gemini'));
      await tester.tap(
        find.descendant(of: tile, matching: find.text('Gemini')),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('ai-key-gemini'));
      await tester.enterText(field, 'unit-test-secret');
      final button = find.byKey(const ValueKey('ai-test-gemini'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(await keys.key('gemini'), 'unit-test-secret');
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(transport.calls.length, 1);
      expect(find.textContaining('Live model response:'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/ai_key_connection.png'),
      );
      await tester.tap(
        find.descendant(of: tile, matching: find.text('Remove key')),
      );
      await tester.pumpAndSettle();
      expect(await keys.key('gemini'), isEmpty);
    },
  );

  testWidgets(
    'provider badge distinguishes preferred route, actual fallback and server credentials',
    (tester) async {
      final keys = MemoryCredentials();
      await keys.setKey('gemini', 'test-gemini');
      await keys.setKey('nvidia_nim', 'test-nim');
      final transport = FakeAiTransport()..failures = 1;
      final config = configuration();
      final router = AiProviderRouter(
        config,
        credentials: keys,
        transport: transport,
      );
      final app = AppController.forTesting(
        api: OfflineApi(),
        config: config,
        store: {'id': 'owned'},
        aiRouter: router,
        aiCredentials: keys,
        settingsStore: MemorySettings(),
      );
      await pump(
        tester,
        app,
        const Scaffold(body: ProviderBadge(direct: true)),
      );
      expect(find.textContaining('Next scan route:'), findsOneWidget);
      final result = await router.generate(
        'shelf_scan',
        'unit test',
        preferred: 'gemini',
      );
      expect(result.provider, 'nvidia_nim');
      app.recordShelfScan(provider: result.provider, model: result.model);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Last scan served by: NVIDIA NIM'),
        findsOneWidget,
      );
      expect(app.aiRoutingRevision, 2);
      final remoteConfig = configuration();
      remoteConfig['settings']['execution_mode'] = 'remote_server';
      final remote = AppController.forTesting(
        api: OfflineApi(),
        config: remoteConfig,
        store: {'id': 'server'},
        aiCredentials: MemoryCredentials(),
        settingsStore: MemorySettings(),
      );
      await remote.saveSettings({
        'execution_mode': 'remote_server',
      }, global: true);
      await pump(tester, remote, const Scaffold(body: ProviderBadge()));
      expect(find.textContaining('Server AI routing'), findsOneWidget);
      expect(find.textContaining('No AI key configured'), findsNothing);
      remote.recordShelfScan(provider: 'openrouter', model: 'server-model');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Last scan served by: OpenRouter · server-model'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'a completed recommendation disappears after store context changes',
    (tester) async {
      final app = PlanApp();
      await pump(tester, app, const RecommendationsScreen());
      await tester.tap(find.text('Review recommendations'));
      await tester.pumpAndSettle();
      expect(find.textContaining('owned-event'), findsOneWidget);
      app.store = {'id': 'other'};
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.textContaining('owned-event'), findsNothing);
    },
  );
}
