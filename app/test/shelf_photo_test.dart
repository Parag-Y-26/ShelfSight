import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shelfsight/core/shelf_photo.dart';
import 'package:shelfsight/core/shelf_scan_output.dart';

void main() {
  test(
    'gallery PNG becomes a bounded JPEG and oversized dimensions are rejected',
    () {
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 8, height: 6)),
      );
      final result = prepareShelfImage({
        'bytes': bytes,
        'max_bytes': 10000,
        'max_pixels': 48,
      });
      expect(result.take(2), [0xff, 0xd8]);
      expect(img.decodeJpg(result)!.width, 8);
      expect(
        () => prepareShelfImage({
          'bytes': bytes,
          'max_bytes': 10000,
          'max_pixels': 47,
        }),
        throwsFormatException,
      );
      expect(
        () => prepareShelfImage({
          'bytes': bytes,
          'max_bytes': 1,
          'max_pixels': 48,
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'typed shelf output rejects missing candidates and impossible boxes without inventing stock',
    () {
      final config =
          jsonDecode(File('assets/defaults.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(
        () => ShelfScanStructuredOutput.parse({}, config),
        throwsFormatException,
      );
      final data = {
        'candidates': [
          {
            'name': 'User photo candidate',
            'brand': null,
            'category': null,
            'barcode': null,
            'bbox': [0.1, 0.1, 0.5, 0.8],
          },
        ],
      };
      final output = ShelfScanStructuredOutput.parse(data, config);
      expect(output.candidates.single.containsKey('quantity'), false);
      (data['candidates']!.single['bbox'] as List)[2] = 0.0;
      expect(
        () => ShelfScanStructuredOutput.parse(data, config),
        throwsFormatException,
      );
    },
  );
}
