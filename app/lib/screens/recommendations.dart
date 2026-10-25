import 'package:flutter/material.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';
import '../widgets/decision_panel.dart';

class RecommendationsScreen extends StatelessWidget {
  const RecommendationsScreen({super.key});
  @override
  Widget build(BuildContext context) => PageScaffold(
    title: tr(context, 'aiRecommendations'),
    child: ListView(
      padding: const EdgeInsets.all(Tokens.md),
      children: const [DecisionPanel()],
    ),
  );
}
