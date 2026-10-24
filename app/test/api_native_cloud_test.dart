import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/api_native.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Map<String, dynamic> response = {
    'owner_uid': 'owner-a',
    'session_token': 'opaque-device-session',
    'expires_at':
        DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'Android connects to hosted HTTPS API using Supabase without pairing',
    () async {
      final adapter = _Adapter();
      final api = ApiClient(
        createDio: (options) => Dio(options)..httpClientAdapter = adapter,
      );
      await api.setApiAddress('https://api.example.com/');
      await api.connectCloud(idToken: 'supabase-access-token', uid: 'owner-a');
      expect(api.paired, isTrue);
      expect(api.serverAddress, 'https://api.example.com');
      expect(
        adapter.requests.single.uri.toString(),
        'https://api.example.com/v1/cloud-session',
      );
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer supabase-access-token',
      );
      expect(adapter.requests.single.followRedirects, isFalse);
      expect(adapter.requests.single.data, {
        'device_name': 'ShelfSight Android',
      });
      await api.get('/stores');
      expect(
        adapter.requests.last.headers['Authorization'],
        'Bearer opaque-device-session',
      );
      final restored = ApiClient(
        createDio: (options) => Dio(options)..httpClientAdapter = adapter,
      );
      await restored.restore('owner-a');
      expect(restored.paired, isTrue);
      await restored.clear();
      await api.clear();
    },
  );

  test(
    'Android pairs to a local HTTPS server with the displayed fingerprint',
    () async {
      final adapter = _Adapter();
      final api = ApiClient(
        createDio: (options) => Dio(options)..httpClientAdapter = adapter,
      );
      final fingerprint = List.filled(64, 'a').join();
      await api.pair(
        address: 'https://192.168.1.42:8443',
        fingerprint: fingerprint,
        secret: 'one-use-pairing-code',
        idToken: 'supabase-access-token',
        uid: 'owner-a',
        deviceName: 'My phone',
      );
      expect(api.paired, isTrue);
      expect(api.localMode, isTrue);
      expect(api.serverAddress, 'https://192.168.1.42:8443');
      expect(api.serverIdentity, 'https://192.168.1.42:8443|$fingerprint');
      expect(
        adapter.requests.single.uri.toString(),
        'https://192.168.1.42:8443/v1/pair',
      );
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer supabase-access-token',
      );
      expect(adapter.requests.single.data, {
        'pairing_secret': 'one-use-pairing-code',
        'device_name': 'My phone',
      });

      final restored = ApiClient(
        createDio: (options) => Dio(options)..httpClientAdapter = adapter,
      );
      await restored.restore('owner-a');
      expect(restored.paired, isTrue);
      expect(restored.localMode, isTrue);
      await restored.clear();
      await api.clear();
    },
  );

  test('stored cloud sessions cannot be restored by another account', () async {
    final adapter = _Adapter();
    final api = ApiClient(
      createDio: (options) => Dio(options)..httpClientAdapter = adapter,
    );
    await api.setApiAddress('https://api.example.com');
    await api.connectCloud(idToken: 'supabase-access-token', uid: 'owner-a');
    await api.restore('owner-b');
    expect(api.paired, isFalse);
    await api.clear();
  });

  test(
    'Android rejects unsafe API addresses before sending credentials',
    () async {
      final api = ApiClient();
      for (final address in [
        'http://api.example.com',
        'https://name:secret@api.example.com',
        'https://api.example.com/v1',
        'https://api.example.com?token=x',
        'https://api.example.com/#fragment',
      ]) {
        await expectLater(
          api.setApiAddress(address),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(api.paired, isFalse);
    },
  );

  test(
    'cloud login rejects mismatched identity and expired sessions',
    () async {
      final adapter = _Adapter();
      final api = ApiClient(
        createDio: (options) => Dio(options)..httpClientAdapter = adapter,
      );
      await api.setApiAddress('https://api.example.com');
      adapter.response['owner_uid'] = 'someone-else';
      await expectLater(
        api.connectCloud(idToken: 'identity', uid: 'owner-a'),
        throwsA(isA<ApiFailure>()),
      );
      expect(api.paired, isFalse);
      adapter.response['owner_uid'] = 'owner-a';
      adapter.response['expires_at'] = '2000-01-01T00:00:00Z';
      await expectLater(
        api.connectCloud(idToken: 'identity', uid: 'owner-a'),
        throwsA(isA<ApiFailure>()),
      );
      expect(api.paired, isFalse);
    },
  );
}
