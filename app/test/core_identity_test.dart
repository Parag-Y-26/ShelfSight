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

class StoreSelectionApi extends PendingApi {
  final snapshots = <String, Completer<dynamic>>{};
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      (snapshots[path] ??= Completer<dynamic>()).future;
}

class WipeApi extends PendingApi {
  @override
  Future<dynamic> delete(String path) async => null;
}

class PausedEraseCache extends MemoryCache {
  final entered = Completer<void>(), resume = Completer<void>();
  bool first = true;
  @override
  Future<void> erase() async {
    if (first) {
      first = false;
      entered.complete();
      await resume.future;
    }
    await super.erase();
  }
}

void main() {
  test(
    'a wipe finishing after cache erase cannot clear the next profile',
    () async {
      final cache = PausedEraseCache();
      final app = AppController.forTesting(
        api: WipeApi(),
        cache: cache,
        store: {'id': 'old-profile-store'},
      );
      final pending = app.deleteAllStoreData();
      final rejected = expectLater(pending, throwsA(isA<ApiFailure>()));
      await cache.entered.future;
      await app.disconnect();
      app.store = {'id': 'new-profile-store'};
      app.products = [
        {'id': 'new-private-product'},
      ];
      cache.resume.complete();
      await rejected;
      expect(app.store?['id'], 'new-profile-store');
      expect(app.products.single['id'], 'new-private-product');
      app.dispose();
    },
  );
  test('a late store snapshot cannot undo a newer store selection', () async {
    final api = StoreSelectionApi();
    final cache = MemoryCache();
    final app = AppController.forTesting(api: api, cache: cache);
    final first = app.selectStore('first');
    final second = app.selectStore('second');
    api.snapshots['/stores/second/snapshot']!.complete({
      'store': {'id': 'second'},
      'products': [
        {'name': 'Current store product'},
      ],
    });
    await second;
    api.snapshots['/stores/first/snapshot']!.complete({
      'store': {'id': 'first'},
      'products': [
        {'name': 'Previous store product'},
      ],
    });
    await first;
    expect(app.store?['id'], 'second');
    expect(app.products.single['name'], 'Current store product');
    expect(cache.values['snapshot']['store']['id'], 'second');
    app.dispose();
  });

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
