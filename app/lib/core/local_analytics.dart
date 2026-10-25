import 'dart:math' as math;
import 'configuration.dart';

double intervalUnion(List<(double, double)> intervals) {
  if (intervals.isEmpty) return 0;
  intervals.sort((a, b) => a.$1.compareTo(b.$1));
  var (start, end) = intervals.first;
  var total = 0.0;
  for (final (a, b) in intervals.skip(1)) {
    if (a <= end) {
      end = math.max(end, b);
    } else {
      total += end - start;
      start = a;
      end = b;
    }
  }
  return total + end - start;
}

/// Same ledger semantics as server analytics: clipped visits, unioned coverage,
/// inventory corrections as-of end, and explicit exclusion of labeled replay.
Map<String, dynamic> summarizeLocal(
  Map<String, dynamic> config,
  Map<String, dynamic> store,
  List<Map<String, dynamic>> shelves,
  List<Map<String, dynamic>> events,
  Map<String, dynamic> query,
) {
  double time(dynamic value) {
    final text = value?.toString() ?? '';
    if (!RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(text)) {
      throw const FormatException('Timezone required');
    }
    return DateTime.parse(text).millisecondsSinceEpoch / 1000;
  }

  final start = query['start'], end = query['end'];
  final a = time(start), b = time(end);
  if (b <= a) throw const FormatException('Invalid time range');
  final rows = {
    for (final s in shelves)
      s['id']: {
        'shelf_id': s['id'],
        'name': s['name'],
        'visits': 0,
        'dwell_seconds': 0.0,
        'exposure_seconds': 0.0,
      },
  };
  final coverage = <(double, double)>[];
  final exposure = <String, List<(double, double)>>{};
  final inventory = <String, Map<String, dynamic>>{};
  final samples = <double>[];
  final shelfSamples = <String, List<double>>{};
  final placements = <String, List<Map<String, dynamic>>>{};
  var visits = 0;
  var dwell = 0.0;
  for (final e in events) {
    if (e['provenance'] == 'labeled_replay') continue;
    final kind = e['type'];
    if (kind == 'visit' || kind == 'coverage') {
      final left = math.max(a, time(e['started_at'])),
          right = math.min(b, time(e['ended_at']));
      if (right <= left) continue;
      if (kind == 'visit') {
        visits++;
        dwell += right - left;
        samples.add(right - left);
        (shelfSamples[e['shelf_id']] ??= []).add(right - left);
        final row = rows[e['shelf_id']];
        if (row != null) {
          row['visits'] = (row['visits'] as int) + 1;
          row['dwell_seconds'] = (row['dwell_seconds'] as num) + right - left;
        }
      } else {
        coverage.add((left, right));
        for (final id in e['shelf_ids'] as List) {
          (exposure[id] ??= []).add((left, right));
        }
      }
    } else if (kind == 'inventory_adjustment' &&
        time(e['server_timestamp']) < b) {
      final id = e['item_id'] as String;
      (placements[id] ??= []).add(e);
      inventory[id] ??= {
        'item_id': id,
        'shelf_id': e['shelf_id'],
        'product_id': e['product_id'],
        'quantity': 0,
      };
      final item = inventory[id]!;
      item.addAll({
        'quantity': (item['quantity'] as num) + (e['delta'] as num),
        'name': e['product_name'],
        'price_minor': e['price_minor'],
        'currency': e['currency'],
        'last_corrected_at': e['server_timestamp'],
        'row': e['row'],
        'slot': e['slot'],
      });
    }
  }
  for (final e in exposure.entries) {
    rows[e.key]?['exposure_seconds'] = intervalUnion(e.value);
  }
  final runtime = RuntimeConfiguration(config);
  double? median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  for (final row in rows.values) {
    final values = shelfSamples[row['shelf_id']] ?? [];
    row['mean_dwell_seconds'] =
        values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
    row['median_dwell_seconds'] = median(values);
  }
  for (final item in inventory.values) {
    final history = placements[item['item_id']]!;
    double? covered;
    for (var i = 0; i < history.length; i++) {
      final e = history[i];
      if (item['row'] is! num ||
          item['slot'] is! num ||
          e['row'] != item['row'] ||
          e['slot'] != item['slot']) {
        continue;
      }
      final left = math.max(a, time(e['server_timestamp'])),
          right =
              i + 1 < history.length
                  ? math.min(b, time(history[i + 1]['server_timestamp']))
                  : b;
      if (right <= left) continue;
      covered ??= 0;
      covered += intervalUnion([
        for (final interval in exposure[e['shelf_id']] ?? <(double, double)>[])
          if (math.min(right, interval.$2) > math.max(left, interval.$1))
            (math.max(left, interval.$1), math.min(right, interval.$2)),
      ]);
    }
    item['slot_exposure_seconds'] = covered;
    item['slot_exposure_basis'] =
        'calibrated_shelf_zone_coverage_while_slot_recorded';
    item['low_stock_threshold'] =
        runtime.resolve(
          device: Map<String, dynamic>.from(
            query['device_settings'] as Map? ?? {},
          ),
          store: store,
          shelf: shelves.where((s) => s['id'] == item['shelf_id']).firstOrNull,
        )['low_stock_threshold'];
  }
  final ranked =
      rows.values.toList()..sort((x, y) {
        final c = (y['visits'] as int).compareTo(x['visits'] as int);
        return c != 0
            ? c
            : x['name'].toString().compareTo(y['name'].toString());
      });
  return {
    'start': start,
    'end': end,
    'coverage_seconds': intervalUnion(coverage),
    'visits': visits,
    'total_dwell_seconds': dwell,
    'mean_dwell_seconds': samples.isEmpty ? null : dwell / samples.length,
    'median_dwell_seconds': median(samples),
    'shelves': ranked,
    'inventory': inventory.values.toList(),
    'capabilities': {
      ...Map<String, dynamic>.from(config['capabilities'] as Map? ?? {}),
      'visits': true,
    },
    'generated_at': DateTime.now().toUtc().toIso8601String(),
  };
}

String exportLocalCsv(Map<String, dynamic> summary) {
  String cell(dynamic v) {
    var s = v?.toString() ?? '';
    if (RegExp(r'^[\s]*[=+\-@\t\r\n]').hasMatch(s)) s = "'$s";
    return '"${s.replaceAll('"', '""')}"';
  }

  final rows = <List<dynamic>>[
    ['metric', 'name', 'value', 'unit', 'timestamp'],
    [
      'coverage',
      '',
      summary['coverage_seconds'],
      'seconds',
      summary['generated_at'],
    ],
    ['visits', '', summary['visits'], 'visits', summary['generated_at']],
    [
      'mean_dwell',
      '',
      summary['mean_dwell_seconds'],
      'seconds',
      summary['generated_at'],
    ],
    [
      'median_dwell',
      '',
      summary['median_dwell_seconds'],
      'seconds',
      summary['generated_at'],
    ],
    [
      'dwell',
      '',
      summary['total_dwell_seconds'],
      'seconds',
      summary['generated_at'],
    ],
    for (final s in summary['shelves']) ...[
      ['shelf_visits', s['name'], s['visits'], 'visits', ''],
      ['shelf_dwell', s['name'], s['dwell_seconds'], 'seconds', ''],
      ['shelf_exposure', s['name'], s['exposure_seconds'], 'seconds', ''],
    ],
    for (final i in summary['inventory'])
      [
        'recorded_inventory',
        i['name'],
        i['quantity'],
        'units',
        i['last_corrected_at'],
      ],
    for (final i in summary['inventory'])
      [
        'recorded_slot_zone_coverage',
        i['name'],
        i['slot_exposure_seconds'],
        'seconds',
        i['last_corrected_at'],
      ],
  ];
  return '${rows.map((r) => r.map(cell).join(',')).join('\r\n')}\r\n';
}
