import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/laya_decision_service.dart';
import 'package:shelfsight/core/ai_provider_router.dart';
import 'package:shelfsight/core/autonomous_decision_engine.dart';
import 'ai_provider_router_test.dart' show MemoryCredentials;
import 'ai_provider_router_test.dart' show FakeAiTransport;

void main() {
  test('score consumes visit dwell and recorded-stock rubric', () {
    final config =
        jsonDecode(File('assets/defaults.json').readAsStringSync())
            as Map<String, dynamic>;
    final laya = LayaDecisionService(config);
    final telemetry = {
      'recorded_stock': 100,
      'low_stock_threshold': 5,
      'visit_count': 5,
      'median_dwell_sec': 1,
    };
    expect(laya.score(telemetry)['value'], 1);
    expect(laya.score({...telemetry, 'median_dwell_sec': 10})['value'], 0);
    expect(laya.score({...telemetry, 'recorded_stock': 2})['value'], 2);
    expect(laya.noul([], {'id': 's'})['restock_alert']['p_true'], isNull);
  });
  test(
    'invented decision citations are rejected before returning a plan',
    () async {
      final config =
          jsonDecode(File('assets/defaults.json').readAsStringSync())
              as Map<String, dynamic>;
      final keys = MemoryCredentials();
      await keys.setKey('openrouter', 'test-key');
      final transport =
          FakeAiTransport()
            ..result = {
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'actions': [
                        {
                          'type': 'RESTOCK_ALERT',
                          'shelf_id': 's',
                          'event_ids': ['invented-event'],
                        },
                      ],
                      'requires_review': true,
                      'disclaimer': config['ai']['disclaimer'],
                    }),
                  },
                },
              ],
            };
      final engine = AutonomousDecisionEngine(
        LayaDecisionService(config),
        AiProviderRouter(config, credentials: keys, transport: transport),
      );
      final plan = await engine.decide(
        [
          {
            'id': 'real-event',
            'shelf_id': 's',
            'item_id': 'i',
            'type': 'inventory_adjustment',
            'quantity': 2,
            'provenance': 'user_input',
            'server_timestamp': DateTime.now().toUtc().toIso8601String(),
          },
        ],
        [
          {
            'id': 's',
            'known_item_ids': ['i'],
          },
        ],
      );
      expect(plan.actions.single['event_ids'], ['real-event']);
      expect(plan.data['source'], 'deterministic_policy');
      expect(transport.calls.length, 1);
    },
  );
  test(
    'stale/missing inventory abstains and zero threshold cannot create false alert',
    () async {
      final config =
          jsonDecode(File('assets/defaults.json').readAsStringSync())
              as Map<String, dynamic>;
      final laya = LayaDecisionService(config);
      final now = DateTime.now().toUtc();
      Map<String, dynamic> event(String id, int quantity, [int days = 0]) => {
        'id': id,
        'item_id': id,
        'shelf_id': 's',
        'type': 'inventory_adjustment',
        'quantity': quantity,
        'provenance': 'user_input',
        'server_timestamp':
            now.subtract(Duration(days: days)).toIso8601String(),
      };
      expect(
        laya.assess(
          [event('old', 100, 2), event('recent', 2)],
          {'id': 's'},
          now: now,
        )['telemetry']['recorded_stock'],
        isNull,
      );
      expect(
        laya.assess(
          [event('recent', 2)],
          {
            'id': 's',
            'known_item_ids': ['missing', 'recent'],
          },
          now: now,
        )['noul']['restock_alert']['p_true'],
        isNull,
      );
      final engine = AutonomousDecisionEngine(
        laya,
        AiProviderRouter(config, credentials: MemoryCredentials()),
      );
      final plan = await engine.decide(
        [event('recent', 100)],
        [
          {
            'id': 's',
            'settings': {'decision_probability_threshold': 0},
          },
        ],
      );
      expect(plan.actions, isEmpty);
    },
  );
  late LayaDecisionService laya;
  setUp(
    () =>
        laya = LayaDecisionService(
          jsonDecode(File('assets/defaults.json').readAsStringSync())
              as Map<String, dynamic>,
        ),
  );
  test('choice uses recent reliability and task-specific model profile', () {
    final route = laya.choice(
      'shelf_scan',
      ['gemini', 'nvidia_nim'],
      {
        'gemini': {'error_rate': 1, 'latency_ms': 20},
        'nvidia_nim': {'error_rate': 0, 'latency_ms': 100},
      },
    );
    expect(route['provider'], 'nvidia_nim');
    expect(route['model'], 'meta/llama-4-maverick-17b-128e-instruct');
  });
  test('noul abstains without ledger records and excludes labeled replay', () {
    expect(
      laya.assess([], {'id': 's'})['noul']['restock_alert']['p_true'],
      isNull,
    );
    final event = {
      'id': 'stock-event',
      'shelf_id': 's',
      'item_id': 'i',
      'type': 'inventory_adjustment',
      'quantity': 2,
      'provenance': 'user_input',
      'server_timestamp': DateTime.now().toUtc().toIso8601String(),
    };
    final result = laya.assess([event], {'id': 's'});
    expect(result['noul']['restock_alert']['p_true'], 1);
    expect(result['noul']['restock_alert']['event_ids'], ['stock-event']);
    expect(result['score']['label'], 'urgent');
    expect(
      laya.assess(
        [
          {...event, 'provenance': 'labeled_replay'},
        ],
        {'id': 's'},
      )['noul']['restock_alert']['p_true'],
      isNull,
    );
  });
}
