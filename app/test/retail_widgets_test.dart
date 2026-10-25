import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/strings.dart';
import 'package:shelfsight/core/theme.dart';
import 'package:shelfsight/screens/analytics.dart';
import 'package:shelfsight/screens/dashboard.dart';
import 'package:shelfsight/screens/connection.dart';
import 'package:shelfsight/screens/product.dart';
import 'package:shelfsight/screens/shelf_results.dart';
import 'package:shelfsight/screens/store_setup.dart';
import 'package:shelfsight/widgets/shared.dart';
import 'runtime_settings_test.dart' show MemorySettings;

const _config = <String, dynamic>{
  'store_types': [
    {'id': 'independent', 'label_key': 'other'},
  ],
  'goals': [
    {'id': 'footfall', 'label_key': 'trackDemand'},
  ],
  'currencies': ['EUR'],
  'units': ['m'],
  'periods': [
    {'id': 'day', 'label_key': 'today', 'days': 1},
    {'id': 'custom', 'label_key': 'custom', 'days': null},
  ],
};
const _store = <String, dynamic>{
  'id': 'owned-store',
  'name': 'Lantern Pantry',
  'currency': 'EUR',
};
const _shelf = <String, dynamic>{'id': 'owned-shelf', 'name': 'Wall display'};
const _product = <String, dynamic>{
  'id': 'owned-product',
  'name': 'Cedar spice jar',
  'price_minor': null,
};
const _item = <String, dynamic>{
  'id': 'owned-item',
  'shelf_id': 'owned-shelf',
  'product_id': 'owned-product',
  'row': 3,
  'slot': 2,
  'quantity': 7,
};

final _translations = <String, String>{};

DateTime _fixedNow() => DateTime(2026, 10, 23, 15, 30);

class _TestStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _TestStringsDelegate();
  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';
  @override
  Future<AppStrings> load(Locale locale) =>
      SynchronousFuture(AppStrings(_translations));
  @override
  bool shouldReload(covariant LocalizationsDelegate<AppStrings> old) => false;
}

class _Api extends ApiClient {
  final posts = <Map<String, dynamic>>[];
  final patches = <Map<String, dynamic>>[];
  final queries = <Map<String, dynamic>>[];
  final exports = <String>[];
  final lookupQueries = <String>[];
  final lookups = <String, Map<String, dynamic>>{};
  VoidCallback? afterProductPost;
  Map<String, dynamic> analytics = {
    'coverage_seconds': 0,
    'visits': 0,
    'total_dwell_seconds': 0,
    'shelves': <dynamic>[],
    'inventory': <dynamic>[],
    'generated_at': _fixedNow().toUtc().toIso8601String(),
  };

  @override
  bool get paired => true;

  @override
  Future<dynamic> post(String path, [dynamic body]) async {
    posts.add({'path': path, 'body': body});
    if (path.endsWith('/products')) afterProductPost?.call();
    return {'id': 'created-id'};
  }

  @override
  Future<dynamic> patch(String path, dynamic body) async {
    patches.add({'path': path, 'body': body});
    return {'id': 'owned-item'};
  }

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    if (path == '/products/lookup') {
      lookupQueries.add(query?['barcode']?.toString() ?? '');
      return lookups[query?['barcode']] ?? {'found': false, 'product': null};
    }
    if (path.endsWith('/analytics')) {
      queries.add(query ?? {});
      return analytics;
    }
    if (path == '/config') return _config;
    if (path == '/stores') {
      return {
        'items': [_store],
      };
    }
    if (path.endsWith('/snapshot')) {
      return {
        'store': _store,
        'floors': <dynamic>[],
        'shelves': [_shelf],
        'products': [_product],
        'items': [_item],
        'calibrations': <dynamic>[],
      };
    }
    throw StateError('Unexpected test request: $path');
  }

  @override
  Future<String> text(String path, {Map<String, dynamic>? query}) async {
    exports.add(path);
    return 'shelf,visits\nWall display,0\n';
  }
}

class _SwitchableApp extends AppController {
  _SwitchableApp(ApiClient api)
    : super.forTesting(
        api: api,
        config: _config,
        store: _store,
        shelves: [_shelf],
      );
  int revision = 0;
  @override
  int get identityGeneration => revision;
}

class _DisconnectedApi extends _Api {
  @override
  bool get paired => false;
  @override
  String? get serverAddress => null;
}

Future<void> _pump(
  WidgetTester tester,
  Widget child,
  AppController app, {
  bool routing = false,
}) async {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final delegates = <LocalizationsDelegate<dynamic>>[
    const _TestStringsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];
  final router =
      routing
          ? GoRouter(
            routes: [
              GoRoute(path: '/', builder: (_, _) => child),
              GoRoute(
                path: '/map',
                builder:
                    (_, _) => const Scaffold(body: Icon(Icons.map_outlined)),
              ),
              GoRoute(
                path: '/shelf/:id',
                builder: (_, _) => const Scaffold(body: Icon(Icons.shelves)),
              ),
            ],
          )
          : null;
  if (router != null) addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => app)],
      child:
          router == null
              ? MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(),
                localizationsDelegates: delegates,
                supportedLocales: const [Locale('en')],
                home: child,
              )
              : MaterialApp.router(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(),
                localizationsDelegates: delegates,
                supportedLocales: const [Locale('en')],
                routerConfig: router,
              ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);
Finder get _vertical =>
    find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .first;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final textFont = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await textFont.load();
    final packagesFile = File('.dart_tool/package_config.json').absolute;
    final packages =
        jsonDecode(await packagesFile.readAsString()) as Map<String, dynamic>;
    final flutterPackage = (packages['packages'] as List)
        .whereType<Map>()
        .firstWhere((p) => p['name'] == 'flutter');
    final flutterRoot =
        Directory.fromUri(
          packagesFile.uri.resolve(flutterPackage['rootUri'] as String),
        ).parent.parent;
    final iconsBytes =
        await File(
          '${flutterRoot.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes();
    final iconFont = FontLoader('MaterialIcons')
      ..addFont(SynchronousFuture(ByteData.sublistView(iconsBytes)));
    await iconFont.load();
    for (final name in ['core', 'retail', 'monitoring']) {
      final file = File('assets/l10n/${name}_en.arb');
      if (!await file.exists()) continue;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final entry in data.entries) {
        if (!entry.key.startsWith('@') && entry.value is String) {
          _translations[entry.key] = entry.value as String;
        }
      }
    }
  });
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/camera'),
          (call) async {
            if (call.method == 'availableCameras') {
              return <Map<String, Object>>[];
            }
            return null;
          },
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/camera'),
          null,
        );
  });

  testWidgets(
    'setup requires user data and accepts configuration-owned options',
    (tester) async {
      final api = _Api();
      final app = AppController.forTesting(api: api, config: _config);
      await _pump(tester, const StoreSetupScreen(), app);
      expect(find.text('Other'), findsOneWidget);
      expect(find.text('Track demand'), findsOneWidget);
      await tester.tap(find.text('Continue to Shelf Scan'));
      await tester.pumpAndSettle();
      expect(api.posts, isEmpty);
      expect(find.text('This field is required.'), findsWidgets);
      expect(find.text('Lantern Pantry'), findsNothing);
    },
  );

  testWidgets('scan suggestions cannot persist without a user-counted quantity', (
    tester,
  ) async {
    final api = _Api();
    final app = AppController.forTesting(
      api: api,
      config: _config,
      store: _store,
      shelves: [_shelf],
    );
    await _pump(
      tester,
      const ShelfResultsScreen(
        shelfId: 'owned-shelf',
        candidates: [
          {'name': 'Cedar spice jar', 'row': 3, 'slot': 2, 'confidence': null},
        ],
      ),
      app,
    );
    await tester.tap(find.text('Save shelf'));
    await tester.pumpAndSettle();
    expect(api.posts, isEmpty);
    expect(
      find.text(
        'Review every product name, row, slot and counted quantity before saving.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('98%'), findsNothing);
  });

  testWidgets('rescanning an existing named product does not duplicate it', (
    tester,
  ) async {
    final api = _Api();
    final app = AppController.forTesting(
      api: api,
      config: _config,
      store: _store,
      shelves: [_shelf],
      products: [_product],
      items: [_item],
    );
    await _pump(
      tester,
      const ShelfResultsScreen(
        shelfId: 'owned-shelf',
        candidates: [
          {'name': 'Cedar spice jar', 'row': 3, 'slot': 2, 'confidence': null},
        ],
      ),
      app,
    );
    expect(find.text('1 product'), findsOneWidget);
    expect(find.text('2 products'), findsNothing);
  });

  testWidgets('quantity correction is sent to the inventory endpoint', (
    tester,
  ) async {
    final api = _Api();
    final app = AppController.forTesting(
      api: api,
      config: _config,
      store: _store,
      shelves: [_shelf],
      products: [_product],
      items: [_item],
    );
    await _pump(
      tester,
      const ShelfResultsScreen(shelfId: 'owned-shelf'),
      app,
      routing: true,
    );
    final increase = find.byTooltip('Increase quantity');
    await tester.scrollUntilVisible(increase, 200, scrollable: _vertical);
    await tester.tap(increase);
    await tester.pump();
    await tester.tap(find.text('Save shelf'));
    await tester.pumpAndSettle();
    final correction =
        api.posts
            .where((p) => p['path'] == '/shelves/owned-shelf/planogram')
            .single;
    expect(correction['body'], {
      'items': [
        {'id': 'owned-item', 'row': 3, 'slot': 2, 'quantity': 8},
      ],
    });
    expect(find.byIcon(Icons.map_outlined), findsOneWidget);
  });

  testWidgets(
    'product editor preserves unknown price and requires counted quantity',
    (tester) async {
      final api = _Api();
      final incomplete = {..._item, 'quantity': null};
      final app = AppController.forTesting(
        api: api,
        config: _config,
        store: _store,
        shelves: [_shelf],
        products: [_product],
        items: [_item],
      );
      await _pump(
        tester,
        ProductScreen(shelfId: 'owned-shelf', item: incomplete),
        app,
      );
      await tester.tap(find.text('Save to Wall display'));
      await tester.pumpAndSettle();
      expect(api.posts, isEmpty);
      expect(api.patches, isEmpty);
      final price = tester
          .widgetList<TextField>(find.byType(TextField))
          .where((field) => field.decoration?.labelText == 'Unit price');
      if (price.isNotEmpty) expect(price.single.controller?.text, isEmpty);
    },
  );

  testWidgets(
    'changing a cached barcode to an unknown product cannot patch the cached catalog entry',
    (tester) async {
      final api = _Api();
      const cachedProduct = {..._product, 'barcode': 'catalog-a'};
      api.lookups['catalog-a'] = {
        'found': true,
        'product': cachedProduct,
        'source': 'cache',
      };
      final app = AppController.forTesting(
        api: api,
        config: _config,
        store: _store,
        shelves: [_shelf],
        products: [cachedProduct],
      );
      await _pump(
        tester,
        const ProductScreen(shelfId: 'owned-shelf'),
        app,
        routing: true,
      );
      await tester.enterText(_field('Barcode or QR contents'), 'catalog-a');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Look up product'));
      await tester.tap(find.byTooltip('Look up product'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        _field('Product name'),
        200,
        scrollable: _vertical,
      );
      expect(
        tester.widget<TextField>(_field('Product name')).controller?.text,
        'Cedar spice jar',
      );
      await tester.scrollUntilVisible(
        _field('Barcode or QR contents'),
        -200,
        scrollable: _vertical,
      );
      await tester.enterText(_field('Barcode or QR contents'), 'catalog-b');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Look up product'));
      await tester.tap(find.byTooltip('Look up product'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        _field('Product name'),
        200,
        scrollable: _vertical,
      );
      expect(
        tester.widget<TextField>(_field('Product name')).controller?.text,
        isEmpty,
      );
      await tester.enterText(_field('Product name'), 'Juniper jar');
      await tester.scrollUntilVisible(
        _field('Row'),
        300,
        scrollable: _vertical,
      );
      await tester.enterText(_field('Row'), '6');
      await tester.enterText(_field('Slot'), '8');
      await tester.scrollUntilVisible(
        _field('Units on shelf'),
        200,
        scrollable: _vertical,
      );
      await tester.enterText(_field('Units on shelf'), '11');
      await tester.tap(find.text('Save to Wall display'));
      await tester.pumpAndSettle();
      expect(
        api.patches.where((p) => p['path'] == '/products/owned-product'),
        isEmpty,
      );
      final newProduct =
          api.posts
              .where((p) => p['path'] == '/stores/owned-store/products')
              .single;
      expect((newProduct['body'] as Map)['name'], 'Juniper jar');
      expect((newProduct['body'] as Map)['barcode'], 'catalog-b');
      expect(api.lookupQueries, ['catalog-a', 'catalog-b']);
    },
  );

  testWidgets(
    'pending product camera initialization recovers after pause and resume',
    (tester) async {
      const channel = MethodChannel('plugins.flutter.io/camera');
      final pending = Completer<List<Map<String, Object>>>();
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'availableCameras') {
              calls++;
              return calls == 1 ? pending.future : <Map<String, Object>>[];
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final api = _Api();
      final app = AppController.forTesting(
        api: api,
        config: _config,
        store: _store,
        shelves: [_shelf],
      );
      final delegates = <LocalizationsDelegate<dynamic>>[
        const _TestStringsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => app)],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: delegates,
            supportedLocales: const [Locale('en')],
            home: const ProductScreen(shelfId: 'owned-shelf'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      pending.complete(<Map<String, Object>>[]);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final retake = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'Retake',
        ),
      );
      expect(retake.onPressed, isNotNull);
    },
  );

  testWidgets(
    'editing a product keeps its recorded currency after the store currency changes',
    (tester) async {
      final api = _Api();
      final priced = {..._product, 'price_minor': 123, 'currency': 'USD'};
      final app = AppController.forTesting(
        api: api,
        config: _config,
        store: _store,
        shelves: [_shelf],
        products: [priced],
        items: [_item],
      );
      await _pump(
        tester,
        const ProductScreen(shelfId: 'owned-shelf', item: _item),
        app,
        routing: true,
      );
      await tester.tap(find.text('Save to Wall display'));
      await tester.pumpAndSettle();
      final productPatch =
          api.patches
              .where((p) => p['path'] == '/products/owned-product')
              .single;
      expect((productPatch['body'] as Map)['currency'], 'USD');
      expect((productPatch['body'] as Map)['price_minor'], 123);
    },
  );

  testWidgets(
    'legacy price without currency is not labelled using the store currency',
    (tester) async {
      final api = _Api();
      final priced = {..._product, 'price_minor': 123, 'currency': null};
      final app = AppController.forTesting(
        api: api,
        config: _config,
        store: _store,
        shelves: [_shelf],
        products: [priced],
        items: [_item],
      );
      await _pump(
        tester,
        const ProductScreen(shelfId: 'owned-shelf', item: _item),
        app,
        routing: true,
      );
      await tester.tap(find.text('Save to Wall display'));
      await tester.pumpAndSettle();
      final productPatch =
          api.patches
              .where((p) => p['path'] == '/products/owned-product')
              .single;
      expect((productPatch['body'] as Map)['currency'], isNull);
      expect((productPatch['body'] as Map)['price_minor'], 123);
    },
  );

  testWidgets(
    'a product save cannot continue inventory writes after identity changes',
    (tester) async {
      final api = _Api();
      final app = _SwitchableApp(api);
      api.afterProductPost = () => app.revision++;
      await _pump(
        tester,
        const ProductScreen(
          shelfId: 'owned-shelf',
          item: {
            'row': 3,
            'slot': 2,
            'quantity': 7,
            'product': {'name': 'Cedar spice jar'},
          },
        ),
        app,
      );
      await tester.tap(find.text('Save to Wall display'));
      await tester.pumpAndSettle();
      expect(api.posts, hasLength(1));
      expect(api.posts.single['path'], '/stores/owned-store/products');
      expect(api.patches, isEmpty);
    },
  );

  testWidgets('analytics uses real empty aggregates and UTC range queries', (
    tester,
  ) async {
    final api = _Api();
    final app = AppController.forTesting(
      api: api,
      config: _config,
      store: _store,
    );
    await _pump(tester, const AnalyticsScreen(now: _fixedNow), app);
    expect(api.queries, hasLength(1));
    final start = DateTime.parse(api.queries.single['start'] as String);
    final end = DateTime.parse(api.queries.single['end'] as String);
    expect(start.isUtc, isTrue);
    expect(end.isUtc, isTrue);
    expect(start.toLocal().hour, 0);
    expect(end.toLocal().hour, 0);
    expect(start.toLocal(), DateTime(2026, 10, 23));
    expect(end.toLocal(), DateTime(2026, 10, 24));
    expect(find.text('Shelf visits'), findsOneWidget);
    expect(find.text('No recorded events yet'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Estimated items sold and sales value'),
      300,
      scrollable: _vertical,
    );
    expect(find.text('Not measured in this build'), findsWidgets);
    expect(find.textContaining('₹'), findsNothing);
    expect(find.textContaining('+9%'), findsNothing);
    await tester.tap(find.byTooltip('Copy CSV export'));
    await tester.pumpAndSettle();
    expect(api.exports, ['/stores/owned-store/analytics/export']);
  });

  testWidgets('local low-stock settings drive analytics classification', (
    tester,
  ) async {
    final api = _Api();
    api.analytics['inventory'] = [
      {
        'item_id': 'local-item',
        'shelf_id': _shelf['id'],
        'product_id': 'p',
        'name': 'User-counted test inventory',
        'quantity': 6,
        'price_minor': null,
        'last_corrected_at': _fixedNow().toUtc().toIso8601String(),
        'low_stock_threshold': 5,
      },
    ];
    final config = Map<String, dynamic>.from(
      jsonDecode(File('assets/defaults.json').readAsStringSync()) as Map,
    );
    final app = AppController.forTesting(
      api: api,
      config: config,
      settingsStore: MemorySettings(),
      store: _store,
      shelves: [_shelf],
    );
    await app.saveSettings({'low_stock_threshold': 10}, global: true);
    await _pump(tester, AnalyticsScreen(now: _fixedNow), app);
    await tester.scrollUntilVisible(
      find.text('Running low'),
      250,
      scrollable: _vertical,
    );
    expect(find.text('Running low'), findsOneWidget);
    expect(find.text('User-counted test inventory'), findsWidgets);
  });

  testWidgets('setup reference frame uses blank user input fields', (
    tester,
  ) async {
    final app = AppController.forTesting(api: _Api(), config: _config);
    await _pump(tester, const StoreSetupScreen(), app);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/retail_setup.png'),
    );
  });

  testWidgets(
    'shelf reference frame uses an explicitly labelled test fixture',
    (tester) async {
      final app = AppController.forTesting(
        api: _Api(),
        config: _config,
        store: _store,
        shelves: [_shelf],
        products: [_product],
        items: [_item],
      );
      await _pump(
        tester,
        const ShelfResultsScreen(shelfId: 'owned-shelf'),
        app,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/retail_shelf.png'),
      );
    },
  );

  testWidgets('product reference frame preserves unknown product metadata', (
    tester,
  ) async {
    final app = AppController.forTesting(
      api: _Api(),
      config: _config,
      store: _store,
      shelves: [_shelf],
      products: [_product],
      items: [_item],
    );
    await _pump(
      tester,
      const ProductScreen(shelfId: 'owned-shelf', item: _item),
      app,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/retail_product.png'),
    );
  });

  testWidgets('analytics reference frame displays empty event aggregates', (
    tester,
  ) async {
    final app = AppController.forTesting(
      api: _Api(),
      config: _config,
      store: _store,
    );
    await _pump(tester, const AnalyticsScreen(now: _fixedNow), app);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/retail_analytics.png'),
    );
  });

  testWidgets('dashboard reopens shelf inventory after initial setup', (
    tester,
  ) async {
    final api = _Api();
    final app = AppController.forTesting(
      api: api,
      config: _config,
      store: _store,
      shelves: [_shelf],
    );
    await _pump(tester, const DashboardScreen(), app, routing: true);
    final manage = find.text('Manage shelves and products');
    expect(manage, findsOneWidget);
    await tester.ensureVisible(manage);
    await tester.tap(manage);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.shelves), findsOneWidget);
    expect(api.posts, isEmpty);
  });

  testWidgets('Android connection offers local pairing and optional hosted API', (
    tester,
  ) async {
    final api = _DisconnectedApi();
    final app = AppController.forTesting(api: api, config: _config);
    await _pump(tester, const CloudConnectionScreen(), app);
    expect(find.text('API connection'), findsOneWidget);
    expect(find.text('Pair your laptop'), findsOneWidget);
    expect(_field('Local server HTTPS address'), findsOneWidget);
    expect(_field('Certificate SHA-256 fingerprint'), findsOneWidget);
    expect(_field('One-use pairing code'), findsOneWidget);
    expect(find.text('HTTPS API address'), findsNothing);
    await tester.tap(find.text('Hosted API'));
    await tester.pumpAndSettle();
    expect(_field('API HTTPS address'), findsOneWidget);
    expect(find.text('Certificate SHA-256 fingerprint'), findsNothing);
    expect(find.text('One-use pairing code'), findsNothing);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/android_connection.png'),
    );
    await tester.enterText(_field('API HTTPS address'), 'http://example.com');
    await tester.tap(find.text('Connect to API'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Enter an HTTPS API address with no path, query, credentials or fragment.',
      ),
      findsOneWidget,
    );
    expect(api.posts, isEmpty);
  });

  testWidgets('Android back returns a root scan to Dashboard without exiting', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/scan',
      routes: [
        GoRoute(
          path: '/home',
          builder:
              (_, _) =>
                  const AppBackGuard(child: Scaffold(body: Text('Dashboard'))),
        ),
        GoRoute(
          path: '/scan',
          builder:
              (_, _) => const AppBackGuard(child: Scaffold(body: Text('Scan'))),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('Scan'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsOneWidget);
  });
}
