import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';
import '../widgets/provider_badge.dart';
import '../widgets/store_summary.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final store = controller.store;
    return AppBackGuard(
      child: Scaffold(
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async {
              try {
                await controller.refresh();
              } catch (_) {}
            },
            child: ListView(
              padding: const EdgeInsets.all(Tokens.lg),
              children: [
                Row(
                  children: [
                    Image.asset(
                      'assets/logo.jpeg',
                      width: Tokens.logoSmall,
                      height: Tokens.logoSmall,
                      semanticLabel: tr(context, 'brand'),
                    ),
                    const SizedBox(width: Tokens.sm),
                    Expanded(
                      child: Text(
                        tr(context, 'brand'),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                    ),
                    IconButton(
                      tooltip: tr(context, 'settings'),
                      onPressed: () => context.push('/settings'),
                      icon: const Icon(Icons.settings_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: Tokens.xl),
                Text(
                  tr(context, 'greeting', {'name': controller.displayName}),
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: Tokens.sm),
                Text(
                  store?['name']?.toString() ?? tr(context, 'noStore'),
                  style: Theme.of(
                    context,
                  ).textTheme.headlineSmall?.copyWith(color: Tokens.muted),
                ),
                const SizedBox(height: Tokens.lg),
                const ProviderBadge(),
                if (store != null) const StoreSummary(),
                if (controller.isOffline)
                  InfoCard(
                    child: Row(
                      children: [
                        const Icon(
                          Icons.cloud_off_outlined,
                          color: Tokens.warning,
                        ),
                        const SizedBox(width: Tokens.sm),
                        Expanded(
                          child: Text(
                            tr(context, 'cachedView', {
                              'time':
                                  controller.cacheTimestamp
                                      ?.toLocal()
                                      .toString() ??
                                  tr(context, 'unknown'),
                            }),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (controller.error != null)
                  ErrorNotice(message: tr(context, controller.error!)),
                if (store == null)
                  InfoCard(
                    child: Column(
                      children: [
                        EmptyState(
                          message: tr(context, 'setupFirst'),
                          icon: Icons.storefront_outlined,
                        ),
                        BrandButton(
                          label: tr(context, 'setupStore'),
                          icon: Icons.add_business_outlined,
                          onPressed: () => context.push('/setup'),
                        ),
                      ],
                    ),
                  ),
                if (store != null && controller.shelves.isNotEmpty) ...[
                  BrandButton(
                    label: tr(context, 'manageShelves'),
                    icon: Icons.shelves,
                    outlined: true,
                    onPressed:
                        () => context.push(
                          '/shelf/${Uri.encodeComponent(controller.shelves.first['id'].toString())}',
                        ),
                  ),
                  const SizedBox(height: Tokens.lg),
                ],
                _DashboardCard(
                  title: tr(context, 'monitoring'),
                  subtitle: tr(context, 'monitoringSubtitle'),
                  icon: Icons.center_focus_strong,
                  gradient: true,
                  live: controller.monitoringLive,
                  onTap: store == null ? null : () => context.push('/monitor'),
                ),
                const SizedBox(height: Tokens.lg),
                _DashboardCard(
                  title: tr(context, 'analytics'),
                  subtitle: tr(context, 'analyticsSubtitle'),
                  icon: Icons.insights,
                  gradient: false,
                  onTap:
                      store == null ? null : () => context.push('/analytics'),
                ),
                const SizedBox(height: Tokens.lg),
                if (store != null)
                  TextButton.icon(
                    onPressed: () => context.push('/recommendations'),
                    icon: const Icon(Icons.rule),
                    label: Text(tr(context, 'aiRecommendations')),
                  ),
                if (store != null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          store['name']?.toString() ?? '',
                          style: const TextStyle(color: Tokens.muted),
                        ),
                      ),
                      TextButton(
                        onPressed: () => context.push('/map'),
                        child: Text(tr(context, 'storeMap')),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    this.live = false,
    this.onTap,
  });
  final String title, subtitle;
  final IconData icon;
  final bool gradient, live;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final foreground = gradient ? Tokens.onAccent : Tokens.navy;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Material(
        color: Tokens.transparent,
        borderRadius: BorderRadius.circular(Tokens.radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Tokens.radius),
          child: Ink(
            decoration: BoxDecoration(
              gradient: gradient ? Tokens.gradient : null,
              color: gradient ? null : Tokens.surface,
              border:
                  gradient
                      ? null
                      : Border.all(color: Tokens.teal.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(Tokens.radius),
              boxShadow: const [Tokens.softShadow],
            ),
            child: Padding(
              padding: const EdgeInsets.all(Tokens.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        size: 94,
                        color: gradient ? Tokens.onAccent : Tokens.teal,
                      ),
                      if (live)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Tokens.sm,
                            vertical: Tokens.xs,
                          ),
                          decoration: BoxDecoration(
                            color: Tokens.live,
                            borderRadius: BorderRadius.circular(Tokens.md),
                          ),
                          child: Text(
                            tr(context, 'live'),
                            style: const TextStyle(color: Tokens.onAccent),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Tokens.lg),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: Tokens.sm),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          subtitle,
                          style: Theme.of(
                            context,
                          ).textTheme.titleMedium?.copyWith(color: foreground),
                        ),
                      ),
                      Icon(
                        Icons.arrow_circle_right_outlined,
                        size: 42,
                        color: foreground,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
