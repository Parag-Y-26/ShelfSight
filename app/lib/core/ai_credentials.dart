import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Native keystore/keychain; Web uses the plugin's AES-GCM WebCrypto storage.
/// Keys never enter owner caches, business configuration, logs or API requests
/// to ShelfSight's server.
class AiCredentials {
  AiCredentials({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            webOptions: WebOptions(publicKey: 'ShelfSightAiKeys'),
          );
  final FlutterSecureStorage _storage;
  final _writes = <String, Future<void>>{};
  Future<void> _mutate(
    String provider,
    Map<String, String> change, {
    bool replace = false,
  }) {
    final previous = (_writes[provider] ?? Future<void>.value()).catchError(
      (Object _) {},
    );
    final next = previous.then((_) async {
      final current =
          replace ? <String, String>{} : await readRecord(provider) ?? {};
      await writeRecord(provider, {...current, ...change});
    });
    _writes[provider] = next;
    return next;
  }

  static const providers = ['gemini', 'nvidia_nim', 'openrouter'];
  static const _injected = {
    'gemini': String.fromEnvironment('GEMINI_API_KEY'),
    'nvidia_nim': String.fromEnvironment('NVIDIA_NIM_API_KEY'),
    'openrouter': String.fromEnvironment('OPENROUTER_API_KEY'),
  };

  void _checkProvider(String provider) {
    if (!providers.contains(provider)) {
      throw const FormatException('Unknown provider');
    }
  }

  Future<Map<String, String>?> readRecord(String provider) async {
    _checkProvider(provider);
    final value = await _storage.read(key: 'shelfsight.ai.$provider.v1');
    return value == null
        ? null
        : Map<String, String>.from(jsonDecode(value) as Map);
  }

  Future<void> writeRecord(String provider, Map<String, String> value) async {
    _checkProvider(provider);
    await _storage.write(
      key: 'shelfsight.ai.$provider.v1',
      value: jsonEncode(value),
    );
  }

  Future<String> key(String provider) async {
    _checkProvider(provider);
    final record = await readRecord(provider);
    return record?['key'] ?? _injected[provider]!;
  }

  Future<void> setKey(String provider, String value) async {
    _checkProvider(provider);
    value = value.trim();
    if (value.isEmpty ||
        value.length > 8192 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid API key');
    }
    await _mutate(provider, {'key': value});
  }

  Future<void> clear(String provider) async {
    _checkProvider(provider);
    await _mutate(provider, {'key': ''}, replace: true);
  }

  Future<void> setModel(
    String provider,
    String model, {
    bool vision = true,
  }) async {
    _checkProvider(provider);
    model = model.trim();
    if (model.length > 256 ||
        model.contains('..') ||
        (model.isNotEmpty &&
            !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$').hasMatch(model))) {
      throw const FormatException('Invalid model ID');
    }
    await _mutate(provider, {
      vision ? 'vision_model' : 'decision_model': model,
    });
  }

  Future<String> model(String provider, String task, String fallback) async {
    final record = await readRecord(provider);
    final value =
        record?[task == 'shelf_scan' ? 'vision_model' : 'decision_model'];
    return value == null || value.isEmpty ? fallback : value;
  }

  @override
  String toString() => 'AiCredentials(redacted)';
}
