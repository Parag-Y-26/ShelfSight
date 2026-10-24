import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:typed_data';
import 'api_client.dart';

/// Shared screen contract. Paths identify existing domain operations; a local
/// repository executes SQLite transactions without creating any HTTP request.
abstract class ShelfSightRepository {
  bool get ready;
  bool get isStandalone;
  String get identity;
  Future<dynamic> get(String path, {Map<String, dynamic>? query});
  Future<dynamic> post(String path, [dynamic body]);
  Future<dynamic> patch(String path, dynamic body);
  Future<dynamic> delete(String path);
  Future<String> text(String path, {Map<String, dynamic>? query});
  Future<dynamic> upload(String path, String filePath);
  Future<dynamic> uploadBytes(String path, Uint8List bytes);
  Future<WebSocketChannel> openSocket(String path);
}

class RemoteServerRepository implements ShelfSightRepository {
  RemoteServerRepository(this.client);
  final ApiClient client;
  @override
  bool get ready => client.paired;
  @override
  bool get isStandalone => false;
  @override
  String get identity => client.serverIdentity;
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      client.get(path, query: query);
  @override
  Future<dynamic> post(String path, [dynamic body]) => client.post(path, body);
  @override
  Future<dynamic> patch(String path, dynamic body) => client.patch(path, body);
  @override
  Future<dynamic> delete(String path) => client.delete(path);
  @override
  Future<String> text(String path, {Map<String, dynamic>? query}) =>
      client.text(path, query: query);
  @override
  Future<dynamic> upload(String path, String filePath) =>
      client.upload(path, filePath);
  @override
  Future<dynamic> uploadBytes(String path, Uint8List bytes) =>
      client.uploadBytes(path, bytes);
  @override
  Future<WebSocketChannel> openSocket(String path) => client.openSocket(path);
}
