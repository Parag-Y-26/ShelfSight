import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_controller.dart';
import '../core/local_analytics.dart';
import '../core/laya_decision_service.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import 'shared.dart';

class StoreSummary extends ConsumerStatefulWidget {
  const StoreSummary({super.key});
  @override
  ConsumerState<StoreSummary> createState() => _StoreSummaryState();
}

class _StoreSummaryState extends ConsumerState<StoreSummary> {
  String? _signature;
  Future<Map<String, dynamic>>? _summary;
  Future<Map<String, dynamic>> _read(AppController app) async {
    final events = await app.recordedEvents();
    final store = app.store;
    if (store == null) return {};
    final summary = summarizeLocal(app.config, store, app.shelves, events, {
      'start':
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toIso8601String(),
      'end': DateTime.now().toUtc().toIso8601String(),
      'device_settings': app.deviceOverrides,
    });
    final laya = LayaDecisionService(app.config);
    final labels = <String>[];
    final limit =
        (app.config['ai']['limits']['max_decision_shelves'] as num).toInt();
    for (final shelf in app.shelves.take(limit)) {
      final assessment = laya.assess(
        events,
        {
          ...shelf,
          'known_item_ids': [
            for (final i in app.items)
              if (i['shelf_id'] == shelf['id']) i['id'],
          ],
          'settings': app.settingsOverrides(shelfId: shelf['id'].toString()),
        },
        store: {...store, 'settings': app.settingsOverrides()},
        deviceDefaults: app.deviceOverrides,
      );
      labels.add(
        (assessment['noul'] as Map).values.any((v) => v['p_true'] != null)
            ? assessment['score']['label'].toString()
            : 'unknown',
      );
    }
    return {
      ...summary,
      'scope_limited': app.shelves.length > limit,
      'urgency': {
        for (final label in ['normal', 'watch', 'urgent', 'unknown'])
          label: labels.where((v) => v == label).length,
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final signature =
        '${app.identityGeneration}|${app.store?['id']}|${app.ledgerRevision}';
    if (signature != _signature) {
      _signature = signature;
      _summary = _read(app);
    }
    return FutureBuilder<Map<String, dynamic>>(
      future: _summary,
      builder: (context, snapshot) {
        final data =
            snapshot.connectionState == ConnectionState.done
                ? snapshot.data
                : null;
        return InfoCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(context, 'storeLedgerSummary'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                '${app.floors.length} ${tr(context, 'summaryFloors')} · ${app.shelves.length} ${tr(context, 'summaryShelves')} · ${app.products.length} ${tr(context, 'summaryProducts')}',
              ),
              if (snapshot.connectionState == ConnectionState.waiting)
                const LinearProgressIndicator(),
              if (data != null) ...[
                Text('${data['visits']} ${tr(context, 'summaryVisits')}'),
                Text(
                  '${tr(context, 'medianDwell')}: ${data['median_dwell_seconds'] == null ? tr(context, 'unknown') : '${data['median_dwell_seconds']} ${tr(context, 'secondsUnit')}'}',
                ),
                Wrap(
                  spacing: Tokens.sm,
                  runSpacing: Tokens.sm,
                  children: [
                    for (final label in [
                      'normal',
                      'watch',
                      'urgent',
                      'unknown',
                    ])
                      Chip(
                        label: Text(
                          'Laya ${tr(context, 'urgency_$label')}: ${data['urgency'][label]}',
                        ),
                      ),
                  ],
                ),
                Text(tr(context, 'aiRuleCalibration')),
                if (data['scope_limited'] == true)
                  Text(tr(context, 'aiDecisionScopeLimited')),
              ] else if (snapshot.hasError)
                Text(tr(context, 'summaryUnavailable')),
            ],
          ),
        );
      },
    );
  }
}
