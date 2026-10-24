import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The bundled schema also drives server validation. No widget owns defaults.
class RuntimeConfiguration {
  RuntimeConfiguration(this.schema, {TargetPlatform? platform})
    : platform = platform ?? defaultTargetPlatform;

  final Map<String, dynamic> schema;
  final TargetPlatform platform;

  Map<String, dynamic> normalize(Map<String, dynamic> values) {
    final aliases = schema['legacy_settings'] as Map? ?? {};
    final result = <String, dynamic>{};
    for (final entry in values.entries) {
      final alias = aliases[entry.key];
      if (alias is Map) {
        var value = entry.value;
        if (alias['reciprocal_scale'] is num) {
          if (value is! num || !value.isFinite || value <= 0) {
            throw const FormatException('invalidSetting');
          }
          value = (alias['reciprocal_scale'] as num) / value;
        }
        final key = alias['key'] as String;
        if (!values.containsKey(key)) result[key] = value;
      } else {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  Map<String, dynamic> validate(Map<String, dynamic> values) {
    final result = normalize(values);
    final rules = schema['setting_rules'] as Map? ?? {};
    for (final key in result.keys.toList()) {
      final value = result[key];
      final rule = rules[key];
      if (rule is! Map) throw const FormatException('invalidSetting');
      if (rule['type'] == 'string') {
        if (value is! String || !(rule['enum'] as List).contains(value)) {
          throw const FormatException('invalidSetting');
        }
        continue;
      }
      if (value is! num ||
          !value.isFinite ||
          (rule['type'] == 'integer' && value % 1 != 0) ||
          (rule['min'] is num && value < rule['min']) ||
          (rule['max'] is num && value > rule['max']) ||
          (rule['exclusive_min'] is num && value <= rule['exclusive_min'])) {
        throw const FormatException('invalidSetting');
      }
      if (rule['type'] == 'integer') result[key] = value.toInt();
    }
    final limits = schema['limits'] as Map? ?? {};
    final dimension = result['frame_max_dimension'];
    final fps = result['monitoring_sample_fps'];
    if ((dimension is num &&
            limits['max_image_pixels'] is num &&
            dimension * dimension > limits['max_image_pixels']) ||
        (fps is num &&
            limits['max_frame_age_seconds'] is num &&
            1 / fps >= limits['max_frame_age_seconds'])) {
      throw const FormatException('invalidSetting');
    }
    return result;
  }

  Map<String, dynamic> resolve({
    Map<String, dynamic> device = const {},
    Map<String, dynamic>? store,
    Map<String, dynamic>? shelf,
  }) {
    final platforms = schema['platform_defaults'] as Map? ?? {};
    return {
      ...Map<String, dynamic>.from(schema['settings'] as Map? ?? {}),
      ...Map<String, dynamic>.from(platforms[platform.name] as Map? ?? {}),
      ...validate(device),
      ...validate(Map<String, dynamic>.from(store?['settings'] as Map? ?? {})),
      ...validate(Map<String, dynamic>.from(shelf?['settings'] as Map? ?? {})),
    };
  }
}

/// Device preferences survive sign-out and reconnect. Business overrides are
/// namespaced by owner, server and store in the controller before storage.
class DeviceSettingsStore {
  DeviceSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _key = 'shelfsight.runtime_configuration.v2';

  Future<Map<String, dynamic>> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return {};
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<void> write(Map<String, dynamic> values) =>
      _storage.write(key: _key, value: jsonEncode(values));
}
