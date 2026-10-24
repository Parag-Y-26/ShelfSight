import 'dart:convert';

Object? validateAiJson(Map<String, dynamic> schema, Object? value) {
  final types =
      schema['type'] is List ? schema['type'] as List : [schema['type']];
  bool matches(dynamic type) => switch (type) {
    'null' => value == null,
    'object' => value is Map,
    'array' => value is List,
    'string' => value is String,
    'boolean' => value is bool,
    'integer' => value is int,
    'number' => value is num && value.isFinite,
    _ => false,
  };
  if (!types.any(matches) ||
      (schema['enum'] is List && !(schema['enum'] as List).contains(value))) {
    throw const FormatException('Invalid structured AI output');
  }
  if (value == null) return null;
  if (value is Map) {
    final properties = schema['properties'] as Map? ?? {};
    if (!(schema['required'] as List? ?? []).every(value.containsKey) ||
        (schema['additionalProperties'] == false &&
            value.keys.any((k) => !properties.containsKey(k)))) {
      throw const FormatException('Missing or unsupported AI fields');
    }
    for (final entry in value.entries) {
      if (properties[entry.key] is Map) {
        validateAiJson(
          Map<String, dynamic>.from(properties[entry.key] as Map),
          entry.value,
        );
      }
    }
  } else if (value is List) {
    if (value.length < (schema['minItems'] as num? ?? 0) ||
        value.length > (schema['maxItems'] as num? ?? double.infinity)) {
      throw const FormatException('AI array exceeds its bounds');
    }
    for (final item in value) {
      validateAiJson(Map<String, dynamic>.from(schema['items'] as Map), item);
    }
  } else if (value is String) {
    if (value.length < (schema['minLength'] as num? ?? 0) ||
        value.length > (schema['maxLength'] as num? ?? double.infinity)) {
      throw const FormatException('AI text exceeds its bounds');
    }
  } else if (value is num) {
    if (value < (schema['minimum'] as num? ?? -double.infinity) ||
        value > (schema['maximum'] as num? ?? double.infinity)) {
      throw const FormatException('AI number exceeds its bounds');
    }
  }
  return value;
}

Map<String, dynamic> geminiResponseSchema(Map<String, dynamic> schema) {
  final kinds =
      schema['type'] is List ? schema['type'] as List : [schema['type']];
  return {
    'type': kinds.firstWhere((kind) => kind != 'null').toString().toUpperCase(),
    if (kinds.contains('null')) 'nullable': true,
    for (final key in [
      'required',
      'minItems',
      'maxItems',
      'minimum',
      'maximum',
    ])
      if (schema.containsKey(key)) key: schema[key],
    if (schema['enum'] is List &&
        (schema['enum'] as List).every((v) => v is String))
      'enum': schema['enum'],
    if (schema['properties'] is Map)
      'properties': {
        for (final entry in (schema['properties'] as Map).entries)
          entry.key: geminiResponseSchema(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      },
    if (schema['items'] is Map)
      'items': geminiResponseSchema(
        Map<String, dynamic>.from(schema['items'] as Map),
      ),
  };
}

Map<String, dynamic> parseAiJson(String text) {
  text = text.trim();
  if (text.startsWith('```') && text.endsWith('```')) {
    text = text.substring(3, text.length - 3).trim();
    if (text.startsWith('json')) text = text.substring(4).trimLeft();
  }
  return Map<String, dynamic>.from(jsonDecode(text) as Map);
}

/// Editable positions derive from image boxes. Counts and confidence stay unknown.
List<Map<String, dynamic>> arrangeScanCandidates(List<dynamic> values) {
  final candidates =
      values.map((e) => Map<String, dynamic>.from(e as Map)).toList()..sort(
        (a, b) => ((a['bbox'][1] + a['bbox'][3]) as num).compareTo(
          (b['bbox'][1] + b['bbox'][3]) as num,
        ),
      );
  final rows = <({num top, num bottom, List<Map<String, dynamic>> items})>[];
  for (final candidate in candidates) {
    final box = candidate['bbox'] as List;
    final center = ((box[1] as num) + (box[3] as num)) / 2;
    var row =
        rows.where((r) => r.top <= center && center <= r.bottom).firstOrNull;
    if (row == null) {
      row = (
        top: box[1] as num,
        bottom: box[3] as num,
        items: <Map<String, dynamic>>[],
      );
      rows.add(row);
    }
    row.items.add(candidate);
  }
  final result = <Map<String, dynamic>>[];
  for (var index = 0; index < rows.length; index++) {
    final items =
        rows[index].items..sort(
          (a, b) => (a['bbox'][0] as num).compareTo(b['bbox'][0] as num),
        );
    for (var slot = 0; slot < items.length; slot++) {
      result.add({
        ...items[slot],
        'row': index + 1,
        'slot': slot + 1,
        'confidence': null,
      });
    }
  }
  return result;
}
