import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiFailure implements Exception {
  const ApiFailure(this.key, {this.detail, this.status});
  final String key;
  final String? detail;
  final int? status;
  @override
  String toString() => detail ?? key;
}

String friendlyError(Object error) {
  if (error is ApiFailure) return error.detail ?? error.key;
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['detail'] is String) {
      return data['detail'] as String;
    }
    if (data is Map && data['detail'] is List) return 'invalidInput';
    if (error.response?.statusCode == 401) return 'sessionExpired';
    if (error.response?.statusCode == 403) return 'accessDenied';
    return 'connectionFailed';
  }
  return 'unexpectedError';
}

/// No roots are trusted here: every HTTPS and WSS connection must present the
/// exact leaf certificate whose SHA-256 was obtained out-of-band from the laptop.
bool certificateMatches(X509Certificate certificate, String fingerprint) =>
    sha256.convert(certificate.der).toString() ==
    normalizeFingerprint(fingerprint);

String normalizeFingerprint(String value) =>
    value.replaceAll(':', '').replaceAll(RegExp(r'\s'), '').toLowerCase();

Uri pairingUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const ApiFailure('invalidServerAddress');
  }
  return uri.replace(path: '');
}

class ApiClient {
  ApiClient({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  Dio? _dio;
  int _generation = 0;
  Future<T> _guard<T>(Future<T> Function() action) async {
    final generation = _generation;
    final result = await action();
    if (generation != _generation) throw const ApiFailure("sessionExpired");
    return result;
  }

  String? _uid;
  String? _token;
  String? _fingerprint;
  Uri? _base;
  DateTime? _expiry;
  final Set<WebSocket> _sockets = {};
  final Set<HttpClient> _socketClients = {};
  void Function()? onUnauthorized;
  bool get paired =>
      _token != null &&
      _base != null &&
      (_expiry?.isAfter(DateTime.now().toUtc()) ?? false);
  String? get serverAddress => _base?.toString();
  String get serverIdentity =>
      '${_base?.toString() ?? ''}|${_fingerprint ?? ''}';
  DateTime? get expiresAt => _expiry;

  HttpClient _httpClient() {
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.connectionTimeout = const Duration(seconds: 10);
    client.badCertificateCallback =
        (certificate, host, port) =>
            _base != null &&
            host == _base!.host &&
            port == _base!.port &&
            _fingerprint != null &&
            certificateMatches(certificate, _fingerprint!);
    return client;
  }

  void _configure(Uri base, String fingerprint) {
    final configuredGeneration = _generation;
    _dio?.close(force: true);
    _base = base;
    _fingerprint = fingerprint;
    _dio = Dio(
      BaseOptions(
        baseUrl: '${base.toString()}/v1',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 40),
        sendTimeout: const Duration(seconds: 15),
        followRedirects: false,
        headers: {HttpHeaders.acceptHeader: 'application/json'},
      ),
    );
    _dio!.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: _httpClient,
      validateCertificate:
          (certificate, host, port) =>
              certificate != null &&
              host == base.host &&
              port == base.port &&
              certificateMatches(certificate, fingerprint),
    );
    _dio!.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) {
          if (configuredGeneration == _generation &&
              error.response?.statusCode == 401 &&
              _token != null) {
            _token = null;
            onUnauthorized?.call();
          }
          handler.next(error);
        },
      ),
    );
  }

  Future<void> restore(String uid) async {
    final expected = _generation + 1;
    await clear(erase: false);
    if (expected != _generation) return;
    final generation = _generation;
    _uid = uid;
    final value = await _storage.read(key: 'pairing_$uid');
    if (generation != _generation) return;
    if (value == null) return;
    try {
      final data = jsonDecode(value) as Map<String, dynamic>;
      final fingerprint = normalizeFingerprint(data['fingerprint'] as String);
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
        throw const FormatException();
      }
      _expiry = DateTime.parse(data['expires_at'] as String).toUtc();
      if (!_expiry!.isAfter(DateTime.now().toUtc())) {
        await _storage.delete(key: 'pairing_$uid');
        return;
      }
      if (data['owner_uid'] != uid) throw const FormatException();
      _configure(pairingUri(data['address'] as String), fingerprint);
      _token = data['session_token'] as String;
    } catch (_) {
      await _storage.delete(key: 'pairing_$uid');
    }
  }

  Future<void> pair({
    required String address,
    required String fingerprint,
    required String secret,
    required String idToken,
    required String uid,
    required String deviceName,
  }) async {
    final base = pairingUri(address);
    final pin = normalizeFingerprint(fingerprint);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(pin) || secret.trim().isEmpty) {
      throw const ApiFailure('invalidPairing');
    }
    final expected = _generation + 1;
    await clear();
    if (expected != _generation) throw const ApiFailure("sessionExpired");
    final generation = _generation;
    _uid = uid;
    _configure(base, pin);
    final response = await _dio!.post<Map<String, dynamic>>(
      '/pair',
      data: {'pairing_secret': secret.trim(), 'device_name': deviceName.trim()},
      options: Options(
        headers: {HttpHeaders.authorizationHeader: 'Bearer $idToken'},
      ),
    );
    if (generation != _generation) throw const ApiFailure("sessionExpired");
    final data = response.data;
    if (data == null ||
        data['owner_uid'] != uid ||
        data['session_token'] is! String) {
      await clear();
      throw const ApiFailure('invalidPairing');
    }
    _expiry = DateTime.tryParse(data['expires_at']?.toString() ?? '')?.toUtc();
    if (_expiry == null || !_expiry!.isAfter(DateTime.now().toUtc())) {
      await clear();
      throw const ApiFailure('invalidPairing');
    }
    _token = data['session_token'] as String;
    await _storage.write(
      key: 'pairing_$uid',
      value: jsonEncode({
        'address': base.toString(),
        'fingerprint': pin,
        'session_token': _token,
        'expires_at': _expiry!.toIso8601String(),
        'owner_uid': uid,
      }),
    );
  }

  Dio _ready(String path) {
    final uri = Uri.tryParse(path);
    if (!path.startsWith('/') ||
        path.startsWith('//') ||
        uri == null ||
        uri.hasScheme ||
        uri.host.isNotEmpty ||
        path.contains('..')) {
      throw const ApiFailure('invalidInput');
    }
    if (!paired || _dio == null) throw const ApiFailure('sessionExpired');
    return _dio!;
  }

  Options get _options =>
      Options(headers: {HttpHeaders.authorizationHeader: 'Bearer $_token'});
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) => _guard(
    () async =>
        (await _ready(
          path,
        ).get<dynamic>(path, queryParameters: query, options: _options)).data,
  );
  Future<dynamic> post(String path, [dynamic body]) => _guard(
    () async =>
        (await _ready(
          path,
        ).post<dynamic>(path, data: body, options: _options)).data,
  );
  Future<dynamic> patch(String path, dynamic body) => _guard(
    () async =>
        (await _ready(
          path,
        ).patch<dynamic>(path, data: body, options: _options)).data,
  );
  Future<dynamic> delete(String path) => _guard(
    () async =>
        (await _ready(path).delete<dynamic>(path, options: _options)).data,
  );
  Future<dynamic> upload(String path, String filePath) async {
    final generation = _generation;
    final file = await MultipartFile.fromFile(filePath);
    if (generation != _generation) throw const ApiFailure("sessionExpired");
    return _guard(
      () async =>
          (await _ready(path).post<dynamic>(
            path,
            data: FormData.fromMap({'file': file}),
            options: _options,
          )).data,
    );
  }

  Future<String> text(String path, {Map<String, dynamic>? query}) async {
    final generation = _generation;
    final response = await _ready(path).get<String>(
      path,
      queryParameters: query,
      options: _options.copyWith(responseType: ResponseType.plain),
    );
    if (generation != _generation) throw const ApiFailure('sessionExpired');
    return response.data ?? '';
  }

  Future<WebSocket> openSocket(String path) async {
    final generation = _generation;
    _ready(path);
    final uri = _base!.replace(scheme: 'wss', path: '/v1$path');
    final client = _httpClient();
    try {
      final socket = await WebSocket.connect(
        uri.toString(),
        customClient: client,
        headers: {HttpHeaders.authorizationHeader: 'Bearer $_token'},
      );
      if (generation != _generation) {
        await socket.close();
        throw const ApiFailure("sessionExpired");
      }
      socket.pingInterval = const Duration(seconds: 15);
      _sockets.add(socket);
      _socketClients.add(client);
      void release() {
        _sockets.remove(socket);
        _socketClients.remove(client);
        client.close(force: true);
      }

      unawaited(
        socket.done.then<void>(
          (_) => release(),
          onError: (Object _, StackTrace _) => release(),
        ),
      );
      return socket;
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  Future<void> revoke() async {
    final generation = _generation;
    try {
      if (paired) await delete('/session');
    } finally {
      if (generation == _generation) await clear();
    }
  }

  Future<void> clear({bool erase = true}) async {
    ++_generation;
    final uid = _uid;
    final sockets = _sockets.toList();
    _sockets.clear();
    for (final client in _socketClients) {
      client.close(force: true);
    }
    _socketClients.clear();
    _dio?.close(force: true);
    _dio = null;
    _token = null;
    _expiry = null;
    _base = null;
    _fingerprint = null;
    _uid = null;
    for (final socket in sockets) {
      await socket.close(WebSocketStatus.goingAway);
    }
    if (erase && uid != null) await _storage.delete(key: 'pairing_$uid');
  }
}
