import 'dart:convert';
import 'ai_contracts.dart';

class ShelfScanStructuredOutput {
  ShelfScanStructuredOutput._(this.candidates);
  final List<Map<String, dynamic>> candidates;
  factory ShelfScanStructuredOutput.parse(
    Map<String, dynamic> data,
    Map<String, dynamic> config,
  ) {
    if (data['candidates'] is! List) {
      throw const FormatException('Missing candidates');
    }
    final normalized = {
      'candidates': [
        for (final raw in data['candidates'] as List? ?? [])
          {
            for (final key in ['name', 'brand', 'category', 'barcode', 'bbox'])
              key: (raw as Map)[key],
          },
      ],
    };
    validateAiJson(
      Map<String, dynamic>.from(config['ai']['schemas']['shelf_scan'] as Map),
      normalized,
    );
    for (final candidate in normalized['candidates']!) {
      final box = candidate['bbox'] as List;
      if (box[0] >= box[2] || box[1] >= box[3]) {
        throw const FormatException('Invalid bounding box');
      }
    }
    return ShelfScanStructuredOutput._(
      List.unmodifiable([
        for (final candidate in normalized['candidates']!)
          Map<String, dynamic>.unmodifiable(candidate),
      ]),
    );
  }
  factory ShelfScanStructuredOutput.fromJson(
    String json,
    Map<String, dynamic> config,
  ) => ShelfScanStructuredOutput.parse(
    Map<String, dynamic>.from(jsonDecode(json) as Map),
    config,
  );
}
