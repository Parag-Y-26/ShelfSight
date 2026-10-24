import 'dart:convert';

/// Tab-local cache, cleared on identity switch. No browser persistence claim.
class OwnerCache {
  final _events = <String, Map<String, dynamic>>{};
  final _values = <String, Map<String, dynamic>>{};
  Future<void> open(String uid, {String server = ''}) async {
    _values.clear();
    _events.clear();
  }

  Future<void> recordEvents(
    String storeId,
    List<Map<String, dynamic>> events,
  ) async {
    for (final event in events) {
      if (event['id'] is String && event['store_id'] == storeId) {
        _events.putIfAbsent(
          '$storeId|${event['id']}',
          () => Map<String, dynamic>.from(jsonDecode(jsonEncode(event)) as Map),
        );
      }
    }
  }

  Future<List<Map<String, dynamic>>> readEvents(
    String storeId, {
    int limit = 10000,
  }) async {
    if (limit <= 0) throw const FormatException('Invalid ledger limit');
    final rows =
        _events.values
            .where((e) => e['store_id'] == storeId)
            .map(Map<String, dynamic>.from)
            .toList();
    return rows.length > limit ? rows.sublist(rows.length - limit) : rows;
  }

  Future<void> put(String key, dynamic value) async {
    _values[key] = {
      'value': jsonDecode(jsonEncode(value)),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>?> read(String key) async => _values[key];
  Future<void> erase() async {
    _values.clear();
    _events.clear();
  }

  Future<void> close() async {
    _values.clear();
    _events.clear();
  }
}
