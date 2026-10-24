import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';

/// Public catalog lookup only. Never uploads photos, keys, or business records.
class OpenFoodFactsClient {
  OpenFoodFactsClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 8),
              followRedirects: false,
              headers: {
                'User-Agent': 'ShelfSight/0.1 (https://shelfsight.app)',
              },
            ),
          );
  final Dio _dio;
  static bool validBarcode(String value) =>
      RegExp(r'^(?:\d{8}|\d{12,14})$').hasMatch(value);
  Future<Map<String, dynamic>> lookup(String barcode) async {
    if (!validBarcode(barcode)) return {'found': false, 'source': 'manual'};
    final cancel = CancelToken();
    final deadline = Timer(
      const Duration(seconds: 10),
      () => cancel.cancel('Catalog timeout'),
    );
    try {
      final response = await _dio.get<ResponseBody>(
        'https://world.openfoodfacts.org/api/v2/product/$barcode.json',
        queryParameters: {
          'fields':
              'code,product_name,brands,categories,quantity,ingredients_text,allergens,nutriments,manufacturing_places',
        },
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancel,
      );
      final bytes = <int>[];
      await for (final chunk in response.data!.stream.timeout(
        const Duration(seconds: 8),
      )) {
        if (bytes.length + chunk.length > 2000000) {
          throw const FormatException('Catalog response too large');
        }
        bytes.addAll(chunk);
      }
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map || raw['status'] != 1 || raw['product'] is! Map) {
        return {'found': false, 'source': 'manual'};
      }
      final p = raw['product'] as Map;
      String? value(String key) {
        final v = p[key];
        return v is String && v.trim().isNotEmpty ? v.trim() : null;
      }

      final name = value('product_name');
      if (name == null) return {'found': false, 'source': 'manual'};
      final nutrition = <String, dynamic>{};
      if (p['nutriments'] is Map) {
        for (final e in (p['nutriments'] as Map).entries) {
          if (e.key is String && (e.value is String || e.value is num)) {
            nutrition[e.key as String] = e.value;
          }
        }
      }
      return {
        'found': true,
        'source': 'open_food_facts',
        'product': {
          'name': name,
          'barcode': barcode,
          'brand': value('brands'),
          'category': value('categories'),
          'net_weight': value('quantity'),
          'ingredients': value('ingredients_text'),
          'allergens': value('allergens'),
          'nutrition': nutrition.isEmpty ? null : nutrition,
          // Catalogs do not establish a store's price, vegetarian certification,
          // manufacturer identity or shelf life. Missing means unknown.
          'price_minor': null,
          'currency': null,
          'is_veg': null,
          'manufacturer': null,
          'shelf_life': null, 'source': 'open_food_facts',
        },
      };
    } catch (_) {
      return {
        'found': false,
        'source': 'manual',
        'offline_or_unavailable': true,
      };
    } finally {
      deadline.cancel();
    }
  }

  void close() => _dio.close(force: true);
}
