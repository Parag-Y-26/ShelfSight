import 'configuration.dart';

/// Mobile offline fallback for the Laya typed protocol. Values marked
/// deterministic_policy are truth values of evidence rules, not predictions
/// with empirically measured probability calibration.
class LayaDecisionService {
  LayaDecisionService(this.config);
  final Map<String, dynamic> config;

  Map<String, dynamic> choice(
    String task,
    List<String> available,
    Map<String, dynamic> health,
  ) {
    final profiles = config['ai']['providers'] as Map;
    final ranked =
        profiles.keys.where(available.contains).cast<String>().toList();
    if (ranked.isEmpty) {
      throw const FormatException('No configured AI provider');
    }
    num metric(String provider, String field) =>
        health[provider] is Map && health[provider][field] is num
            ? health[provider][field] as num
            : 0;
    ranked.sort((a, b) {
      final errors = metric(a, 'error_rate').compareTo(metric(b, 'error_rate'));
      if (errors != 0) return errors;
      final latency = metric(
        a,
        'latency_ms',
      ).compareTo(metric(b, 'latency_ms'));
      return latency != 0
          ? latency
          : profiles.keys
              .toList()
              .indexOf(a)
              .compareTo(profiles.keys.toList().indexOf(b));
    });
    final provider = ranked.first;
    return {
      'provider': provider,
      'type': 'choice',
      'choice': provider,
      'model':
          profiles[provider][task == 'shelf_scan'
              ? 'vision_model'
              : 'decision_model'],
      'calibration_status': 'deterministic_policy',
    };
  }

  Map<String, dynamic> score(Map<String, dynamic> telemetry) {
    final stock = telemetry['recorded_stock'] as num?;
    final threshold = telemetry['low_stock_threshold'] as num?;
    final defaults = config['settings'] as Map;
    final dwell = telemetry['median_dwell_sec'] as num?;
    final watch =
        (telemetry['visit_count'] as num? ?? 0) >=
            (telemetry['decision_min_visits'] as num? ??
                defaults['decision_min_visits'] as num) &&
        dwell != null &&
        dwell <
            (telemetry['dwell_cutoff_sec'] as num? ??
                defaults['dwell_cutoff_sec'] as num);
    final value =
        stock != null && threshold != null && stock <= threshold
            ? 2.0
            : watch
            ? 1.0
            : 0.0;
    return {
      'value': value,
      'type': 'score',
      'label': ['normal', 'watch', 'urgent'][value.toInt()],
      'calibration_status': 'deterministic_policy',
    };
  }

  Map<String, dynamic> noul(
    List<Map<String, dynamic>> events,
    Map<String, dynamic> shelf, {
    Map<String, dynamic>? store,
    Map<String, dynamic> deviceDefaults = const {},
    DateTime? now,
  }) => Map<String, dynamic>.from(
    assess(
          events,
          shelf,
          store: store,
          deviceDefaults: deviceDefaults,
          now: now,
        )['noul']
        as Map,
  );

  Map<String, dynamic> assess(
    List<Map<String, dynamic>> events,
    Map<String, dynamic> shelf, {
    Map<String, dynamic>? store,
    Map<String, dynamic> deviceDefaults = const {},
    DateTime? now,
  }) {
    now = (now ?? DateTime.now()).toUtc();
    final settings = RuntimeConfiguration(
      config,
    ).resolve(device: deviceDefaults, store: store, shelf: shelf);
    final ai = config['ai'] as Map;
    final policy = ai['decision_policy'] as Map;
    final seen = <String>{};
    final stock =
        <String, ({int quantity, String id, DateTime at, double age})>{};
    final valid =
        events.where((event) {
          final id = event['id'];
          if (id is! String ||
              id.isEmpty ||
              seen.contains(id) ||
              !(ai['evidence_provenance'] as List).contains(
                event['provenance'],
              )) {
            return false;
          }
          if (event['shelf_id'] != shelf['id'] &&
              !(event['type'] == 'coverage' &&
                  event['shelf_ids'] is List &&
                  (event['shelf_ids'] as List).contains(shelf['id']))) {
            return false;
          }
          final at = DateTime.tryParse(
            event['server_timestamp']?.toString() ?? '',
          );
          if (at == null ||
              !RegExp(
                r'(Z|[+-]\d{2}:\d{2})$',
              ).hasMatch(event['server_timestamp'].toString())) {
            return false;
          }
          final age = now!.difference(at.toUtc()).inMicroseconds / 1000000;
          if (age >= 0 &&
              event['type'] == 'inventory_adjustment' &&
              event['item_id'] is String) {
            final quantity = event['quantity'] ?? event['new_quantity'];
            final itemId = event['item_id'] as String;
            if (quantity is int &&
                quantity >= 0 &&
                (stock[itemId] == null || !at.isBefore(stock[itemId]!.at))) {
              stock[itemId] = (quantity: quantity, id: id, at: at, age: age);
            }
          }
          if (age < 0 || age > (policy['evidence_max_age_seconds'] as num)) {
            return false;
          }
          seen.add(id);
          return true;
        }).toList();
    final visits = <Map<String, dynamic>>[];
    final incomplete = <Map<String, dynamic>>[];
    final coverage = <({String id, double start, double end})>[];
    for (final event in valid) {
      if (event['type'] == 'visit') {
        final dwell = event['dwell_seconds'];
        if (dwell is num && dwell.isFinite && dwell >= 0) {
          if (event['incomplete'] == true) incomplete.add(event);
          if (event['incomplete'] == false) visits.add(event);
        }
      } else if (event['type'] == 'coverage' && event['incomplete'] == false) {
        final start = DateTime.tryParse(event['started_at']?.toString() ?? '');
        final end = DateTime.tryParse(event['ended_at']?.toString() ?? '');
        if (start != null && end != null && end.isAfter(start)) {
          coverage.add((
            id: event['id'] as String,
            start: start.microsecondsSinceEpoch / 1000000,
            end: end.microsecondsSinceEpoch / 1000000,
          ));
        }
      }
    }
    final dwell =
        visits.map((e) => (e['dwell_seconds'] as num).toDouble()).toList()
          ..sort();
    final middle = dwell.length ~/ 2;
    final median =
        dwell.isEmpty
            ? null
            : dwell.length.isOdd
            ? dwell[middle]
            : (dwell[middle - 1] + dwell[middle]) / 2;
    final known =
        shelf['known_item_ids'] is List
            ? (shelf['known_item_ids'] as List).cast<String>().toSet()
            : stock.keys.toSet();
    final complete =
        known.isNotEmpty &&
        known.length == stock.length &&
        known.every(
          (id) =>
              stock.containsKey(id) &&
              stock[id]!.age <= (policy['evidence_max_age_seconds'] as num),
        );
    final recorded =
        complete
            ? known.fold<int>(0, (sum, id) => sum + stock[id]!.quantity)
            : null;
    final telemetry = <String, dynamic>{
      'visit_count': visits.length,
      'median_dwell_sec': median,
      'recorded_stock': recorded,
      'stock_evidence_complete': complete,
      'low_stock_threshold': settings['low_stock_threshold'],
      'dwell_cutoff_sec': settings['dwell_cutoff_sec'],
      'decision_min_visits': settings['decision_min_visits'],
    };
    final sorted = [...coverage]..sort((a, b) => a.start.compareTo(b.start));
    double totalCoverage = 0, lastEnd = -double.infinity;
    for (final interval in sorted) {
      final left = interval.start > lastEnd ? interval.start : lastEnd;
      if (interval.end > left) totalCoverage += interval.end - left;
      if (interval.end > lastEnd) lastEnd = interval.end;
    }
    final enough =
        visits.length >= (settings['decision_min_visits'] as num) &&
        totalCoverage >= (settings['decision_min_coverage_sec'] as num);
    Map<String, dynamic> probability(
      bool supported,
      bool yes,
      List<String> ids,
    ) => {
      'p_true':
          supported && ids.length <= (policy['max_event_ids'] as num)
              ? (yes ? 1.0 : 0.0)
              : null,
      'type': 'noul',
      'event_ids': ids.take((policy['max_event_ids'] as num).toInt()).toList(),
      'eligible':
          supported && yes && ids.length <= (policy['max_event_ids'] as num),
      'calibration_status': 'deterministic_policy',
    };
    return {
      'shelf_id': shelf['id'],
      'telemetry': telemetry,
      'score': score(telemetry),
      'probability_threshold': settings['decision_probability_threshold'],
      'noul': {
        'restock_alert': probability(
          recorded != null,
          recorded != null &&
              recorded <= (settings['low_stock_threshold'] as num),
          (known.toList()..sort())
              .where(stock.containsKey)
              .map((id) => stock[id]!.id)
              .toList(),
        ),
        'planogram_swap': probability(
          enough,
          enough &&
              median != null &&
              median < (settings['dwell_cutoff_sec'] as num),
          [
            ...visits.map((e) => e['id'] as String),
            ...coverage.map((e) => e.id),
          ],
        ),
        'calibration_check': probability(
          incomplete.isNotEmpty,
          incomplete.isNotEmpty,
          incomplete.map((e) => e['id'] as String).toList(),
        ),
      },
    };
  }
}
