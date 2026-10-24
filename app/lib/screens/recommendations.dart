import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_controller.dart';
import '../core/autonomous_decision_engine.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';

class RecommendationsScreen extends ConsumerStatefulWidget {
  const RecommendationsScreen({super.key});
  @override
  ConsumerState<RecommendationsScreen> createState() =>
      _RecommendationsScreenState();
}

class _RecommendationsScreenState extends ConsumerState<RecommendationsScreen> {
  @override
  void initState() {
    super.initState();
    final app = ref.read(appControllerProvider);
    final storeId = app.store?['id']?.toString(),
        generation = app.identityGeneration;
    app
        .latestLocalDecision()
        .then((plan) {
          if (mounted &&
              !_busy &&
              _plan == null &&
              app.store?['id'] == storeId &&
              app.identityGeneration == generation &&
              plan != null) {
            setState(() {
              _plan = plan;
              _planStoreId = storeId;
              _planGeneration = generation;
            });
          }
        })
        .catchError((Object _) {});
  }

  bool _busy = false;
  AutonomousActionPlan? _plan;
  String? _planStoreId;
  int? _planGeneration;
  String? _error;
  Future<void> _generate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _plan = null;
    });
    try {
      final app = ref.read(appControllerProvider);
      final storeId = app.store?['id']?.toString();
      final generation = app.identityGeneration;
      final result = await app.recommendations();
      if (mounted &&
          generation == app.identityGeneration &&
          app.store?['id']?.toString() == storeId) {
        setState(() {
          _plan = result;
          _planStoreId = storeId;
          _planGeneration = generation;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'aiDecisionFailed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final currentPlan =
        app.store?['id']?.toString() == _planStoreId &&
                app.identityGeneration == _planGeneration
            ? _plan
            : null;
    return PageScaffold(
      title: tr(context, 'aiRecommendations'),
      child: ListView(
        padding: const EdgeInsets.all(Tokens.md),
        children: [
          Text(tr(context, 'aiDecisionConsent')),
          BrandButton(
            label: tr(context, 'aiReviewRecommendations'),
            onPressed: _busy || app.store == null ? null : _generate,
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) ErrorNotice(message: tr(context, _error!)),
          if (currentPlan case final plan?) ...[
            Text(plan.data['disclaimer'] as String),
            Text(tr(context, 'aiRuleCalibration')),
            if (plan.data['scope_limited'] == true)
              Text(tr(context, 'aiDecisionScopeLimited')),
            if (plan.actions.isEmpty)
              EmptyState(message: tr(context, 'aiNoEvidence')),
            for (final action in plan.actions)
              InfoCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'aiAction_${action['type']}'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      app.config['ai']['decision_policy']['reasons'][action['type']]
                          as String,
                    ),
                    SelectableText('shelf_id: ${action['shelf_id']}'),
                    SelectableText(
                      'event_ids: ${(action['event_ids'] as List).join(', ')}',
                    ),
                    Text(tr(context, 'aiRequiresReview')),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
