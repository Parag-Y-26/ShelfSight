import 'dart:convert';

/// Tab-local cache, cleared on identity switch. No browser persistence claim.
class OwnerCache {
  final _values = <String, Map<String, dynamic>>{};
  Future<void> open(String uid, {String server = ''}) async => _values.clear();
  Future<void> put(String key, dynamic value) async {
    _values[key] = {
      'value': jsonDecode(jsonEncode(value)),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>?> read(String key) async => _values[key];
  Future<void> erase() async => _values.clear();
  Future<void> close() async => _values.clear();
}
