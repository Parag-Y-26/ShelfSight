import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

Uri apiUri(String value) {
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

String normalizeFingerprint(String value) =>
    value.replaceAll(':', '').replaceAll(RegExp(r'\s'), '').toLowerCase();

bool certificateMatches(X509Certificate certificate, String fingerprint) =>
    sha256.convert(certificate.der).toString() ==
    normalizeFingerprint(fingerprint);

class ApiClient {
  ApiClient({
    FlutterSecureStorage? storage,
    Dio Function(BaseOptions)? createDio,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _createDio = createDio;
  final FlutterSecureStorage _storage;
  final Dio Function(BaseOptions)? _createDio;
  String? _cloudAddress;
  String? _fingerprint;
  bool _localMode = false;
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
  Uri? _base;
  DateTime? _expiry;
  final Set<WebSocket> _sockets = {};
  final Set<HttpClient> _socketClients = {};
  void Function()? onUnauthorized;
  bool get paired =>
      _token != null &&
      _base != null &&
      (_expiry?.isAfter(DateTime.now().toUtc()) ?? false);
  String? get serverAddress => _cloudAddress ?? _base?.toString();
  bool get localMode => _localMode;
  bool get hasApiAddress => serverAddress?.isNotEmpty == true;
  String get serverIdentity =>
      _fingerprint == null
          ? _base?.toString() ?? ''
          : '${_base?.toString()}|$_fingerprint';
  DateTime? get expiresAt => _expiry;

  HttpClient _httpClient() {
    final client =
        _localMode
            ? HttpClient(context: SecurityContext(withTrustedRoots: false))
            : HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    if (_localMode) {
      client.badCertificateCallback =
          (certificate, host, port) =>
              _base != null &&
              _fingerprint != null &&
              host == _base!.host &&
              port == _base!.port &&
              certificateMatches(certificate, _fingerprint!);
    }
    return client;
  }

  void _configure(Uri base, {String? fingerprint}) {
    final configuredGeneration = _generation;
    _dio?.close(force: true);
    _base = base;
    _fingerprint = fingerprint;
    _localMode = fingerprint != null;
    final options = BaseOptions(
      baseUrl: '${base.toString()}/v1',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 40),
      sendTimeout: const Duration(seconds: 15),
      followRedirects: false,
      headers: {HttpHeaders.acceptHeader: 'application/json'},
    );
    _dio = _createDio?.call(options) ?? Dio(options);
    if (_createDio == null) {
      _dio!.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: _httpClient,
        validateCertificate:
            fingerprint == null
                ? null
                : (certificate, host, port) =>
                    certificate != null &&
                    host == base.host &&
                    port == base.port &&
                    certificateMatches(certificate, fingerprint),
      );
    }
    _dio!.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) {
          if (configuredGeneration == _generation &&
              error.response?.statusCode == 401 &&
              _token != null) {
            unawaited(clear().catchError((Object _) {}));
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
    _localMode = await _storage.read(key: 'api_mode') == 'local';
    _cloudAddress =
        await _storage.read(key: 'api_address') ??
        const String.fromEnvironment('SHELFSIGHT_API_URL');
    if (generation != _generation || !hasApiAddress) return;
    if (_localMode) {
      final value = await _storage.read(key: 'pairing_$uid');
      if (generation != _generation || value == null) return;
      try {
        final data = jsonDecode(value) as Map<String, dynamic>;
        final fingerprint = normalizeFingerprint(data['fingerprint'] as String);
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
            data['address'] != _cloudAddress ||
            data['owner_uid'] != uid ||
            data['session_token'] is! String ||
            (data['session_token'] as String).isEmpty) {
          throw const FormatException();
        }
        _configure(apiUri(_cloudAddress!), fingerprint: fingerprint);
        _expiry = DateTime.parse(data['expires_at'] as String).toUtc();
        if (!_expiry!.isAfter(DateTime.now().toUtc())) {
          await _storage.delete(key: 'pairing_$uid');
          return;
        }
        _token = data['session_token'] as String;
      } catch (_) {
        _token = null;
        _fingerprint = null;
        await _storage.delete(key: 'pairing_$uid');
      }
      return;
    }
    _configure(apiUri(_cloudAddress!));
    final value = await _storage.read(key: 'cloud_session_$uid');
    if (generation != _generation) return;
    if (value == null) return;
    try {
      final data = jsonDecode(value) as Map<String, dynamic>;
      if (data['address'] != _cloudAddress ||
          data['owner_uid'] != uid ||
          data['session_token'] is! String ||
          (data['session_token'] as String).isEmpty) {
        throw const FormatException();
      }
      _expiry = DateTime.parse(data['expires_at'] as String).toUtc();
      if (!_expiry!.isAfter(DateTime.now().toUtc())) {
        await _storage.delete(key: 'cloud_session_$uid');
        return;
      }
      _token = data['session_token'] as String;
    } catch (_) {
      _token = null;
      await _storage.delete(key: 'cloud_session_$uid');
    }
  }

  Future<void> setApiAddress(String address) async {
    final base = apiUri(address);
    try {
      await revoke();
    } catch (_) {
      // Local credentials are cleared even if the previous API is offline.
    }
    _cloudAddress = base.toString();
    _localMode = false;
    await _storage.write(key: 'api_address', value: _cloudAddress);
    await _storage.write(key: 'api_mode', value: 'cloud');
  }

  Future<void> connectCloud({
    required String idToken,
    required String uid,
  }) async {
    if (!hasApiAddress) throw const ApiFailure('apiAddressRequired');
    final base = apiUri(_cloudAddress!);
    final expected = _generation + 1;
    await clear();
    if (expected != _generation) throw const ApiFailure('sessionExpired');
    final generation = _generation;
    _uid = uid;
    _configure(base);
    final response = await _dio!.post<Map<String, dynamic>>(
      '/cloud-session',
      data: {'device_name': 'ShelfSight Android'},
      options: Options(
        headers: {HttpHeaders.authorizationHeader: 'Bearer $idToken'},
      ),
    );
    if (generation != _generation) throw const ApiFailure('sessionExpired');
    final data = response.data;
    final expiry =
        DateTime.tryParse(data?['expires_at']?.toString() ?? '')?.toUtc();
    if (data == null ||
        data['owner_uid'] != uid ||
        data['session_token'] is! String ||
        (data['session_token'] as String).isEmpty ||
        expiry == null ||
        !expiry.isAfter(DateTime.now().toUtc())) {
      await clear();
      throw const ApiFailure('invalidResponse');
    }
    _token = data['session_token'] as String;
    _expiry = expiry;
    await _storage.write(key: 'api_mode', value: 'cloud');
    await _storage.write(
      key: 'cloud_session_$uid',
      value: jsonEncode({
        'address': base.toString(),
        'owner_uid': uid,
        'session_token': _token,
        'expires_at': expiry.toIso8601String(),
      }),
    );
    if (generation != _generation) {
      await _storage.delete(key: 'cloud_session_$uid');
      throw const ApiFailure('sessionExpired');
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
    final base = apiUri(address);
    final pin = normalizeFingerprint(fingerprint);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(pin) ||
        secret.trim().isEmpty ||
        deviceName.trim().isEmpty) {
      throw const ApiFailure('invalidPairing');
    }
    final expected = _generation + 1;
    await clear();
    if (expected != _generation) throw const ApiFailure('sessionExpired');
    final generation = _generation;
    _uid = uid;
    _cloudAddress = base.toString();
    _localMode = true;
    await _storage.write(key: 'api_address', value: _cloudAddress);
    await _storage.write(key: 'api_mode', value: 'local');
    _configure(base, fingerprint: pin);
    try {
      final response = await _dio!.post<Map<String, dynamic>>(
        '/pair',
        data: {
          'pairing_secret': secret.trim(),
          'device_name': deviceName.trim(),
        },
        options: Options(
          headers: {HttpHeaders.authorizationHeader: 'Bearer $idToken'},
        ),
      );
      if (generation != _generation) {
        throw const ApiFailure('sessionExpired');
      }
      final data = response.data;
      final expiry =
          DateTime.tryParse(data?['expires_at']?.toString() ?? '')?.toUtc();
      if (data == null ||
          data['owner_uid'] != uid ||
          data['session_token'] is! String ||
          (data['session_token'] as String).isEmpty ||
          expiry == null ||
          !expiry.isAfter(DateTime.now().toUtc())) {
        throw const ApiFailure('invalidPairing');
      }
      _token = data['session_token'] as String;
      _expiry = expiry;
      await _storage.write(
        key: 'pairing_$uid',
        value: jsonEncode({
          'address': base.toString(),
          'fingerprint': pin,
          'owner_uid': uid,
          'session_token': _token,
          'expires_at': expiry.toIso8601String(),
        }),
      );
      if (generation != _generation) {
        await _storage.delete(key: 'pairing_$uid');
        throw const ApiFailure('sessionExpired');
      }
    } catch (_) {
      if (generation == _generation) {
        await clear();
        _cloudAddress = base.toString();
        _localMode = true;
      }
      rethrow;
    }
  }

  Dio _ready(String path) {
    final uri = Uri.tryParse(path);
    if (!path.startsWith('/') ||
        path.startsWith('//') ||
        uri == null ||
        uri.hasScheme ||
        uri.host.isNotEmpty ||
        path.contains('..') ||
        path.contains('\\')) {
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

  Future<dynamic> uploadBytes(String path, Uint8List bytes) => _guard(
    () async =>
        (await _ready(path).post<dynamic>(
          path,
          data: FormData.fromMap({
            'file': MultipartFile.fromBytes(bytes, filename: 'capture.jpg'),
          }),
          options: _options,
        )).data,
  );

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

  Future<WebSocketChannel> openSocket(String path) async {
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
      return IOWebSocketChannel(socket);
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
    if (erase && uid != null) {
      await _storage.delete(key: 'cloud_session_$uid');
      await _storage.delete(key: 'pairing_$uid');
    }
  }
}
