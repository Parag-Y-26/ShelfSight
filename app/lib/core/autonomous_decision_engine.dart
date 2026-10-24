import 'dart:convert';

import 'ai_provider_router.dart';
import 'laya_decision_service.dart';

class AutonomousActionPlan {
  AutonomousActionPlan(this.data);
  final Map<String, dynamic> data;
  List<Map<String, dynamic>> get actions =>
      (data['actions'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
}

class AutonomousDecisionEngine {
  AutonomousDecisionEngine(this.laya, this.router);
  final LayaDecisionService laya;
  final AiProviderRouter router;

  Future<AutonomousActionPlan> decide(
    List<Map<String, dynamic>> ledger,
    List<Map<String, dynamic>> shelves, {
    Map<String, dynamic>? store,
    Map<String, dynamic> deviceDefaults = const {},
    String preferred = 'auto',
  }) async {
    final ai = laya.config['ai'] as Map;
    final maxEvents = (ai['limits']['max_decision_events'] as num).toInt();
    final events =
        ledger.length > maxEvents
            ? ledger.sublist(ledger.length - maxEvents)
            : ledger;
    final now = DateTime.now().toUtc();
    final maxShelves = (ai['limits']['max_decision_shelves'] as num).toInt();
    final assessments =
        shelves
            .take(maxShelves)
            .map(
              (shelf) => laya.assess(
                events,
                shelf,
                store: store,
                deviceDefaults: deviceDefaults,
                now: now,
              ),
            )
            .toList();
    final eligible = <String, Map<String, dynamic>>{};
    for (final assessment in assessments) {
      for (final entry in (assessment['noul'] as Map).entries) {
        final value = entry.value as Map;
        if (value['p_true'] is num &&
            value['eligible'] == true &&
            value['p_true'] > 0 &&
            value['p_true'] >= assessment['probability_threshold'] &&
            (value['event_ids'] as List).isNotEmpty) {
          final type = entry.key.toString().toUpperCase();
          eligible['$type|${assessment['shelf_id']}'] = {
            'type': type,
            'shelf_id': assessment['shelf_id'],
            'event_ids': value['event_ids'],
          };
        }
      }
    }
    final actions =
        eligible.values
            .take((ai['decision_policy']['max_actions'] as num).toInt())
            .toList();
    var plan = <String, dynamic>{
      'actions': actions,
      'disclaimer': ai['disclaimer'],
      'requires_review': true,
    };
    var source = 'deterministic_policy';
    if (actions.isNotEmpty) {
      try {
        final result = await router.generate(
          'autonomous_decision',
          jsonEncode({
            'instructions':
                'Select only useful eligible actions. Copy exact event_ids, shelf_id and disclaimer. Do not infer sales or product interactions.',
            'eligible_actions': actions,
            'verified_telemetry': {
              for (final value in assessments)
                value['shelf_id']: value['telemetry'],
            },
            'urgency': {
              for (final value in assessments)
                value['shelf_id']: value['score'],
            },
            'disclaimer': ai['disclaimer'],
          }),
          preferred: preferred,
          validate: (candidate) {
            if ((candidate['actions'] as List).length >
                (ai['decision_policy']['max_actions'] as num)) {
              throw const FormatException('Action limit exceeded');
            }
            final seen = <String>{};
            for (final action in candidate['actions'] as List) {
              final key = '${action['type']}|${action['shelf_id']}';
              final expected = eligible[key];
              final ids = (action['event_ids'] as List).cast<String>();
              if (expected == null ||
                  !seen.add(key) ||
                  ids.length != ids.toSet().length ||
                  ids.length != (expected['event_ids'] as List).length ||
                  !ids.toSet().containsAll(
                    (expected['event_ids'] as List).cast<String>(),
                  )) {
                throw const FormatException(
                  'Unsupported recommendation evidence',
                );
              }
            }
          },
        );
        plan = result.data;
        source = result.provider;
      } on AiProviderFailure {
        // The deterministic evidence plan remains available offline.
      } on FormatException {
        // An oversized prompt cannot suppress an otherwise valid evidence plan.
      }
    }
    return AutonomousActionPlan({
      ...plan,
      'source': source,
      'assessments': assessments,
      'calibration_status': 'not_empirically_validated',
      'scope_limited': shelves.length > maxShelves,
    });
  }
}
