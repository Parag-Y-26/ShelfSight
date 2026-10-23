import 'package:camera/camera.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

/// Same-origin HTTPS and Firebase-verified sessions. Tokens stay in memory.
class ApiClient {
  ApiClient({FlutterSecureStorage? storage});
  Dio? _dio;
  String? _token;
  DateTime? _expiry;
  int _generation = 0;
  final _sockets = <WebSocketChannel>{};
  void Function()? onUnauthorized;
  bool get paired =>
      _token != null && (_expiry?.isAfter(DateTime.now().toUtc()) ?? false);
  String get serverAddress => Uri.base.origin;
  String get serverIdentity => Uri.base.origin;
  DateTime? get expiresAt => _expiry;
  Future<void> restore(String uid) => clear();

  Future<void> connectCloud({
    required String idToken,
    required String uid,
  }) async {
    final expected = _generation + 1;
    await clear();
    if (expected != _generation) throw const ApiFailure('sessionExpired');
    final generation = _generation;
    _dio = Dio(
      BaseOptions(
        baseUrl: '${Uri.base.origin}/v1',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 100),
        sendTimeout: const Duration(seconds: 20),
      ),
    );
    final response = await _dio!.post<Map<String, dynamic>>(
      '/cloud-session',
      data: {'device_name': 'ShelfSight browser'},
      options: Options(headers: {'Authorization': 'Bearer $idToken'}),
    );
    if (generation != _generation) throw const ApiFailure('sessionExpired');
    final data = response.data;
    if (data == null ||
        data['owner_uid'] != uid ||
        data['session_token'] is! String) {
      throw const ApiFailure('invalidResponse');
    }
    _token = data['session_token'] as String;
    _expiry = DateTime.parse(data['expires_at'] as String).toUtc();
    _dio!.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) {
          if (generation == _generation && error.response?.statusCode == 401) {
            _token = null;
            onUnauthorized?.call();
          }
          handler.next(error);
        },
      ),
    );
  }

  Future<void> pair({
    required String address,
    required String fingerprint,
    required String secret,
    required String idToken,
    required String uid,
    required String deviceName,
  }) async {
    throw const ApiFailure('invalidPairing');
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

  Options get _options => Options(headers: {'Authorization': 'Bearer $_token'});
  Future<T> _guard<T>(Future<T> Function() action) async {
    final generation = _generation;
    final result = await action();
    if (generation != _generation) throw const ApiFailure('sessionExpired');
    return result;
  }

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
  Future<dynamic> upload(String path, String filePath) => _guard(() async {
    final generation = _generation;
    final file = await XFile(filePath).readAsBytes();
    if (generation != _generation) throw const ApiFailure('sessionExpired');
    return (await _ready(path).post<dynamic>(
      path,
      data: FormData.fromMap({
        'file': MultipartFile.fromBytes(file, filename: 'shelf.jpg'),
      }),
      options: _options,
    )).data;
  });
  Future<String> text(String path, {Map<String, dynamic>? query}) => _guard(
    () async =>
        (await _ready(path).get<String>(
          path,
          queryParameters: query,
          options: _options.copyWith(responseType: ResponseType.plain),
        )).data ??
        '',
  );
  Future<WebSocketChannel> openSocket(String path) async {
    final generation = _generation;
    final ticket = await post('$path/ticket');
    _ready(path);
    final uri = Uri.base.replace(
      scheme: Uri.base.scheme == 'https' ? 'wss' : 'ws',
      path: '/v1$path',
      query: '',
      fragment: '',
    );
    final socket = WebSocketChannel.connect(
      uri,
      protocols: ['shelfsight', ticket['ticket'] as String],
    );
    await socket.ready;
    if (generation != _generation) {
      await socket.sink.close(1001);
      throw const ApiFailure('sessionExpired');
    }
    _sockets.add(socket);
    return socket;
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
    final sockets = _sockets.toList();
    _sockets.clear();
    _dio?.close(force: true);
    _dio = null;
    _token = null;
    _expiry = null;
    for (final socket in sockets) {
      await socket.sink.close(1001);
    }
  }
}
