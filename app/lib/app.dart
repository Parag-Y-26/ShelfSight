import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app_controller.dart';
import 'core/strings.dart';
import 'core/theme.dart';
import 'screens/auth.dart';
import 'screens/pairing.dart';
import 'screens/dashboard.dart';
import 'screens/settings.dart';
import 'screens/store_setup.dart';
import 'screens/shelf_scan.dart';
import 'screens/shelf_results.dart';
import 'screens/product.dart';
import 'screens/analytics.dart';
import 'screens/store_map.dart';
import 'screens/monitoring.dart';

final _routerProvider = Provider<GoRouter>((ref) {
  final controller = ref.read(appControllerProvider);
  final router = GoRouter(
    initialLocation: '/home',
    refreshListenable: controller,
    redirect: (context, state) {
      if (!controller.initialized) return null;
      final path = state.matchedLocation;
      if (!controller.authenticated) return path == '/login' ? null : '/login';
      if (!controller.paired) return path == '/pair' ? null : '/pair';
      if (path == '/login' || path == '/pair') return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const AuthScreen()),
      GoRoute(path: '/pair', builder: (_, _) => const PairingScreen()),
      GoRoute(path: '/home', builder: (_, _) => const DashboardScreen()),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      GoRoute(path: '/setup', builder: (_, _) => const StoreSetupScreen()),
      GoRoute(
        path: '/shelf/:id',
        builder: (_, state) =>
            ShelfResultsScreen(shelfId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/scan/:id',
        builder: (_, state) =>
            ShelfScanScreen(shelfId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/product/:id',
        builder: (_, state) =>
            ProductScreen(shelfId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/map', builder: (_, _) => const StoreMapScreen()),
      GoRoute(path: '/monitor', builder: (_, _) => const MonitoringScreen()),
      GoRoute(path: '/analytics', builder: (_, _) => const AnalyticsScreen()),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class ShelfSightApp extends ConsumerWidget {
  const ShelfSightApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    Locale locale(String tag) {
      final parts = tag.split('_');
      return Locale(parts.first, parts.length > 1 ? parts[1] : null);
    }

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => tr(context, 'brand'),
      theme: buildTheme(),
      locale: locale(controller.effectiveLocaleTag),
      supportedLocales: controller.supportedLocaleTags.map(locale).toList(),
      localizationsDelegates: const [
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: ref.watch(_routerProvider),
      builder: (context, child) => controller.initialized
          ? child ?? const SizedBox.shrink()
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}
