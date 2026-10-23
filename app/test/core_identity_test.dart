import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/cache.dart';

class PendingApi extends ApiClient {
  final response = Completer<dynamic>();
  @override
  bool get paired => true;
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      response.future;
  @override
  Future<void> revoke() async {}
}

class MemoryCache extends OwnerCache {
  final values = <String, dynamic>{};
  @override
  Future<void> put(String key, dynamic value) async {
    values[key] = value;
  }

  @override
  Future<void> erase() async {
    values.clear();
  }

  @override
  Future<void> close() async {}
}

void main() {
  test(
    'late stores response cannot repopulate state after disconnect',
    () async {
      final api = PendingApi();
      final cache = MemoryCache();
      final app = AppController.forTesting(api: api, cache: cache);
      final pending = app.loadStores();
      await app.disconnect();
      api.response.complete({
        'items': [
          {'id': 'previous-owner-store'},
        ],
      });
      await pending;
      expect(app.stores, isEmpty);
      expect(cache.values, isEmpty);
      app.dispose();
    },
  );
  test('late snapshot cannot repopulate previous owner data', () async {
    final api = PendingApi();
    final cache = MemoryCache();
    final app = AppController.forTesting(api: api, cache: cache);
    final pending = app.selectStore('previous-owner-store');
    await app.disconnect();
    api.response.complete({
      'store': {'id': 'previous-owner-store'},
      'products': [
        {'name': 'private test item'},
      ],
    });
    await pending;
    expect(app.store, isNull);
    expect(app.products, isEmpty);
    expect(cache.values, isEmpty);
    app.dispose();
  });
  test(
    'stale refresh failure cannot set the new identity error state',
    () async {
      final api = PendingApi();
      final app = AppController.forTesting(api: api, cache: MemoryCache());
      final pending = app.refresh();
      await app.disconnect();
      api.response.completeError(const ApiFailure('accessDenied'));
      await pending;
      expect(app.error, isNull);
      expect(app.monitoringActive, isFalse);
      app.dispose();
    },
  );
}
