import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/strings.dart';
import 'package:shelfsight/core/theme.dart';
import 'package:shelfsight/screens/settings.dart';

import 'runtime_settings_test.dart' show MemorySettings, OfflineApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await font.load();
    final packagesFile = File('.dart_tool/package_config.json').absolute;
    final packages = jsonDecode(await packagesFile.readAsString()) as Map;
    final flutter = (packages['packages'] as List).whereType<Map>().firstWhere(
      (p) => p['name'] == 'flutter',
    );
    final flutterRoot =
        Directory.fromUri(
          packagesFile.uri.resolve(flutter['rootUri'] as String),
        ).parent.parent;
    final icons =
        await File(
          '${flutterRoot.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes();
    await (FontLoader('MaterialIcons')
      ..addFont(SynchronousFuture(ByteData.sublistView(icons)))).load();
  });
  testWidgets(
    'unpaired mobile settings edit, persist and gate labeled replay',
    (tester) async {
      tester.view.physicalSize = const Size(430, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemorySettings();
      final app = AppController.forTesting(
        api: OfflineApi(),
        settingsStore: storage,
        signedIn: false,
        config:
            jsonDecode(File('assets/defaults.json').readAsStringSync())
                as Map<String, dynamic>,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWith((ref) => app)],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            locale: const Locale('en'),
            localizationsDelegates: const [
              AppStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/settings_device.png'),
      );

      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Visit dwell cutoff (seconds)'),
        250,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Visit dwell cutoff (seconds)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '-1');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter a value within'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '8.5');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(storage.values['global']['dwell_cutoff_sec'], 8.5);

      await tester.scrollUntilVisible(
        find.text('Active AI provider'),
        250,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Auto (Laya Router)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter').last);
      await tester.pumpAndSettle();
      expect(storage.values['global']['active_ai_provider'], 'openrouter');

      await tester.scrollUntilVisible(
        find.text('Run Labeled Evaluation Replay'),
        350,
        scrollable: scrollable,
      );
      expect(find.byType(TextField), findsNothing);
      await tester.ensureVisible(find.text('Run Labeled Evaluation Replay'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run Labeled Evaluation Replay'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Load labeled replay'),
        200,
        scrollable: scrollable,
      );
      await tester.enterText(
        find.byType(TextField),
        '[{"at_ms":0,"detections":[]}]',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Load labeled replay'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load labeled replay'));
      await tester.pumpAndSettle();
      expect(find.text('labeled_replay'), findsOneWidget);
      expect(
        find.textContaining('1 labeled frames, 0 supplied detections.'),
        findsOneWidget,
      );
      expect(app.stores, isEmpty);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/settings_replay.png'),
      );
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}
