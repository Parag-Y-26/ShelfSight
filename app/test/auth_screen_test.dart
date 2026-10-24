import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/strings.dart';
import 'package:shelfsight/screens/auth.dart';

Future<void> _pumpAuthScreen(WidgetTester tester) async {
  final controller = AppController.forTesting(
    api: ApiClient(),
    signedIn: false,
    supabaseConfigured: true,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appControllerProvider.overrideWith((ref) => controller)],
      child: MaterialApp(
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en')],
        home: const AuthScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('maps Supabase credential errors to actionable messages', () {
    expect(authErrorKeyFor('Invalid login credentials'), 'invalidCredentials');
    expect(
      authErrorKeyFor('Invalid project API key'),
      'supabaseConfigurationFailed',
    );
    expect(authErrorKeyFor('provider is disabled'), 'providerDisabled');
    expect(authErrorKeyFor('unrecognised-error'), 'loginFailed');
  });

  testWidgets('shows a sign-up button and registration fields', (tester) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpAuthScreen(tester);

    final signUp = find.text('Sign up');
    await tester.ensureVisible(signUp);
    await tester.pumpAndSettle();
    await tester.tap(signUp);
    await tester.pumpAndSettle();

    expect(find.text('Create account'), findsWidgets);
    expect(find.widgetWithText(TextFormField, 'Your name'), findsOneWidget);
  });
}
