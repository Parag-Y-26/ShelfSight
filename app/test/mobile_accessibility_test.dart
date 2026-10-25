import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/theme.dart';
import 'package:shelfsight/widgets/shared.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/strings.dart';
import 'package:shelfsight/screens/auth.dart';
import 'package:shelfsight/screens/connection.dart';
import 'ai_provider_router_test.dart' show MemoryCredentials;
import 'runtime_settings_test.dart' show MemorySettings, OfflineApi;

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  testWidgets(
    'onboarding and connection reflow at 200 percent with accessible quick setup',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final semantics = tester.ensureSemantics();
      for (final size in [const Size(320, 640), const Size(568, 320)]) {
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        for (final screen in [
          const AuthScreen(),
          const CloudConnectionScreen(),
        ]) {
          final app = AppController.forTesting(
            api: OfflineApi(),
            config: jsonDecode(File('assets/defaults.json').readAsStringSync()),
            signedIn: false,
            settingsStore: MemorySettings(),
            aiCredentials: MemoryCredentials(),
          );
          await tester.pumpWidget(
            ProviderScope(
              key: UniqueKey(),
              overrides: [appControllerProvider.overrideWith((ref) => app)],
              child: MaterialApp(
                theme: buildTheme(),
                localizationsDelegates: const [
                  AppStrings.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: screen,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$screen $size');
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          final scroll = find.byType(Scrollable).first;
          await tester.drag(scroll, const Offset(0, -400));
          await tester.pumpAndSettle();
          tester.view.viewInsets = const FakeViewPadding(bottom: 120);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          tester.view.resetViewInsets();
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      debugDefaultTargetPlatformOverride=null;
    },
  );
  test('requested theme and every text/accent pairing meet 4.5:1', () {
    final theme = buildTheme();
    expect(theme.colorScheme.primary, const Color(0xFF006874));
    expect(theme.colorScheme.secondary, const Color(0xFF00838F));
    expect(theme.colorScheme.surface, const Color(0xFFF8FDFF));
    for (final background in [Tokens.surface, Tokens.pale, Colors.white]) {
      for (final text in [
        Tokens.navy,
        Tokens.muted,
        Tokens.teal,
        Tokens.warning,
        Tokens.danger,
      ]) {
        expect(
          contrast(text, background),
          greaterThanOrEqualTo(4.5),
          reason: '$text on $background',
        );
      }
    }
    for (var i = 0; i <= 100; i++) {
      expect(
        contrast(Colors.white, Color.lerp(Tokens.blue, Tokens.teal, i / 100)!),
        greaterThanOrEqualTo(4.5),
      );
    }
  });
  testWidgets(
    'shared forms reflow and keep keyboard-safe actions at narrow sizes',
    (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(568, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(568, 320),
              textScaler: TextScaler.linear(2),
              viewInsets: EdgeInsets.only(bottom: 150),
            ),
            child: PageScaffold(
              title: 'Accessible store details',
              bottom: BrandButton(label: 'Save changes', onPressed: () {}),
              child: ListView(
                children: const [
                  TextField(
                    decoration: InputDecoration(labelText: 'Store name'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        await tester.runAsync(
          () => Future.value(contrast(Tokens.navy, Tokens.surface)),
        ),
        greaterThan(4.5),
      );
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      semantics.dispose();
    },
  );
}
