import 'package:flutter/material.dart';

import '../core/theme.dart';

class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.child,
    this.actions,
    this.bottom,
  });
  final String title;
  final Widget child;
  final List<Widget>? actions;
  final Widget? bottom;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      actions: actions,
    ),
    body: SafeArea(top: false, child: child),
    bottomNavigationBar:
        bottom == null
            ? null
            : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(Tokens.md),
                child: bottom,
              ),
            ),
  );
}

class BrandButton extends StatelessWidget {
  const BrandButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.outlined = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool outlined;
  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon), const SizedBox(width: Tokens.sm)],
        Flexible(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
    if (outlined) return OutlinedButton(onPressed: onPressed, child: content);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: onPressed == null ? null : Tokens.gradient,
        borderRadius: BorderRadius.circular(Tokens.md),
      ),
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: Tokens.transparent,
          shadowColor: Tokens.transparent,
          foregroundColor: Tokens.onAccent,
        ),
        onPressed: onPressed,
        child: content,
      ),
    );
  }
}

class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: Tokens.md),
    padding: const EdgeInsets.all(Tokens.md),
    decoration: BoxDecoration(
      color: Tokens.surface,
      borderRadius: BorderRadius.circular(Tokens.radius),
      border: Border.all(color: Tokens.line.withValues(alpha: 0.5)),
      boxShadow: const [Tokens.softShadow],
    ),
    child: Material(type: MaterialType.transparency, child: child),
  );
}

class ErrorNotice extends StatelessWidget {
  const ErrorNotice({super.key, required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Tokens.sm),
    child: Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(Tokens.md),
        decoration: BoxDecoration(
          color: Tokens.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(Tokens.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, color: Tokens.danger),
            const SizedBox(width: Tokens.sm),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Tokens.danger),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.icon = Icons.insights_outlined,
  });
  final String message;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(Tokens.lg),
    child: Column(
      children: [
        Icon(icon, size: 42, color: Tokens.teal),
        const SizedBox(height: Tokens.md),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Tokens.muted),
        ),
      ],
    ),
  );
}
