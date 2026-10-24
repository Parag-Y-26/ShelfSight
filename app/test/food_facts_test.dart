import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/food_facts_client.dart';
import 'package:shelfsight/core/temp_photo.dart';

class CatalogTransport implements HttpClientAdapter {
  CatalogTransport(this.response);
  final Map<String, dynamic> response;
  RequestOptions? request;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'direct OFF request preserves absent price allergens and nutrients as unknown',
    () async {
      final transport = CatalogTransport({
        'status': 1,
        'product': {'product_name': 'Catalog entry', 'brands': 'Catalog brand'},
      });
      final client = OpenFoodFactsClient(
        dio: Dio()..httpClientAdapter = transport,
      );
      final result = await client.lookup('1234567890123');
      expect(transport.request!.uri.host, 'world.openfoodfacts.org');
      expect(transport.request!.uri.path, '/api/v2/product/1234567890123.json');
      expect(transport.request!.headers.containsKey('Authorization'), false);
      final p = result['product'] as Map;
      for (final key in [
        'price_minor',
        'allergens',
        'nutrition',
        'is_veg',
        'manufacturer',
        'shelf_life',
      ]) {
        expect(p[key], isNull, reason: key);
      }
      expect((await client.lookup('not a barcode'))['found'], false);
      client.close();
    },
  );
  test('missing catalog name or unknown barcode yields manual entry', () async {
    for (final data in [
      <String, dynamic>{'status': 0},
      {
        'status': 1,
        'product': {'code': '12345678'},
      },
    ]) {
      final client = OpenFoodFactsClient(
        dio: Dio()..httpClientAdapter = CatalogTransport(data),
      );
      expect((await client.lookup('12345678'))['found'], false);
      client.close();
    }
  });
  test(
    'temporary capture is consumed then deleted, repeated cleanup is safe',
    () async {
      final dir = await Directory.systemTemp.createTemp('shelfsight_temp_test');
      try {
        final file = File('${dir.path}/capture.jpg');
        await file.writeAsBytes([1, 2, 3]);
        expect(await consumeTempPhoto(file.path), [1, 2, 3]);
        expect(await file.exists(), false);
        await deleteTempPhoto(file.path);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
