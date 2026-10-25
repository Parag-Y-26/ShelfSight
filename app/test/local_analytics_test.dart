import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/local_analytics.dart';

void main() {
  final config =
      jsonDecode(File('assets/defaults.json').readAsStringSync())
          as Map<String, dynamic>;
  String stamp(int second) =>
      DateTime.utc(2026, 1, 1, 0, 0, second).toIso8601String();
  final shelves = [
    {
      'id': 's',
      'name': '=entered-name',
      'settings': {'low_stock_threshold': 9},
    },
  ];
  final store = <String, dynamic>{'id': 'store', 'settings': {}};
  test(
    'clips visits, unions overlapping coverage, excludes replay and exports safe CSV',
    () {
      final result = summarizeLocal(
        config,
        store,
        shelves,
        [
          {
            'type': 'visit',
            'shelf_id': 's',
            'started_at': stamp(0),
            'ended_at': stamp(20),
            'provenance': 'live_camera',
          },
          {
            'type': 'visit',
            'shelf_id': 's',
            'started_at': stamp(5),
            'ended_at': stamp(10),
            'provenance': 'labeled_replay',
          },
          {
            'type': 'visit',
            'shelf_id': 's',
            'started_at': stamp(30),
            'ended_at': stamp(40),
            'provenance': 'live_camera',
          },
          {
            'type': 'coverage',
            'shelf_ids': ['s'],
            'started_at': stamp(1),
            'ended_at': stamp(8),
          },
          {
            'type': 'coverage',
            'shelf_ids': ['s'],
            'started_at': stamp(6),
            'ended_at': stamp(12),
          },
          {
            'type': 'coverage',
            'shelf_ids': ['s'],
            'started_at': stamp(13),
            'ended_at': stamp(20),
          },
          {
            'type': 'inventory_adjustment',
            'item_id': 'i',
            'shelf_id': 's',
            'product_id': 'p',
            'product_name': '=unsafe-test-label',
            'server_timestamp': stamp(0),
            'delta': 4,
            'price_minor': null,
            'currency': null,
          },
          {
            'type': 'inventory_adjustment',
            'item_id': 'i',
            'shelf_id': 's',
            'product_id': 'p',
            'product_name': '=unsafe-test-label',
            'server_timestamp': stamp(1),
            'delta': -1,
            'price_minor': null,
            'currency': null,
          },
        ],
        {'start': stamp(5), 'end': stamp(15)},
      );
      expect(result['visits'], 1);
      expect(result['mean_dwell_seconds'], 10);
      expect(result['median_dwell_seconds'], 10);
      expect(result['total_dwell_seconds'], 10);
      expect(result['coverage_seconds'], 9);
      expect(result['shelves'].single['exposure_seconds'], 9);
      expect(result['inventory'].single['quantity'], 3);
      expect(result['inventory'].single['low_stock_threshold'], 9);
      expect(result['inventory'].single['price_minor'], isNull);
      expect(result['inventory'].single['slot_exposure_seconds'], isNull);
      final csv = exportLocalCsv(result);
      expect(csv, contains("'=entered-name"));
      expect(csv, contains("'=unsafe-test-label"));
    },
  );
  test(
    'rejects ambiguous dates and reversed ranges; union covers separate intervals',
    () {
      expect(
        () => summarizeLocal(config, store, shelves, [], {
          'start': '2026-01-01',
          'end': stamp(3),
        }),
        throwsFormatException,
      );
      expect(
        () => summarizeLocal(config, store, shelves, [], {
          'start': stamp(3),
          'end': stamp(2),
        }),
        throwsFormatException,
      );
      expect(intervalUnion([]), 0);
      expect(intervalUnion([(0, 3), (1, 2), (5, 9)]), 7);
    },
  );
}
