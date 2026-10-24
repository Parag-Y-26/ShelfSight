import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/configuration.dart';

void main() {
  late Map<String, dynamic> schema;
  setUp(() {
    schema =
        jsonDecode(File('assets/defaults.json').readAsStringSync())
            as Map<String, dynamic>;
  });

  test(
    'mobile defaults and shelf/store/global resolution share the schema',
    () {
      final config = RuntimeConfiguration(
        schema,
        platform: TargetPlatform.android,
      );
      expect(config.resolve()['execution_mode'], 'standalone_mobile');
      expect(config.resolve()['detection_confidence_threshold'], 0.45);
      expect(config.resolve()['dwell_cutoff_sec'], 3);
      expect(config.resolve()['monitoring_sample_fps'], 5);
      expect(config.resolve()['tracking_grace_sec'], 1.5);
      expect(config.resolve()['low_stock_threshold'], 5);
      expect(config.resolve()['active_ai_provider'], 'auto');
      expect(
        config.resolve(
          store: {
            'settings': {'dwell_seconds': 4},
          },
          shelf: {
            'settings': {'dwell_cutoff_sec': 8},
          },
        )['dwell_cutoff_sec'],
        8,
      );
      expect(
        RuntimeConfiguration(
          schema,
          platform: TargetPlatform.linux,
        ).resolve()['execution_mode'],
        'remote_server',
      );
    },
  );

  test('schema rejects invalid, nonfinite, unknown and mistyped settings', () {
    final config = RuntimeConfiguration(schema);
    for (final values in <Map<String, dynamic>>[
      {'monitoring_sample_fps': 0},
      {'monitoring_sample_fps': 0.2},
      {'detection_confidence_threshold': 1.1},
      {'low_stock_threshold': 2.5},
      {'active_ai_provider': 'fake'},
      {'dwell_cutoff_sec': double.nan},
      {'execution_mode': 'pretend'},
      {'unknown': 1},
    ]) {
      expect(() => config.validate(values), throwsFormatException);
    }
    expect(config.validate({'monitoring_interval_ms': 200}), {
      'monitoring_sample_fps': 5,
    });
  });
}
