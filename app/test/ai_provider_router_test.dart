import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/ai_credentials.dart';
import 'package:shelfsight/core/ai_contracts.dart';
import 'package:shelfsight/core/ai_provider_router.dart';

class MemoryCredentials extends AiCredentials {
  final records = <String, Map<String, String>>{};
  @override
  Future<Map<String, String>?> readRecord(String provider) async =>
      records[provider];
  @override
  Future<void> writeRecord(String provider, Map<String, String> value) async {
    records[provider] = Map.of(value);
  }
}

class FakeAiTransport implements AiTransport {
  final calls = <Map<String, dynamic>>[];
  int failures = 0;
  Map<String, dynamic>? result;
  @override
  Future<Map<String, dynamic>> post(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> payload,
    Duration timeout,
    int maxBytes,
  ) async {
    calls.add({'uri': uri, 'headers': headers, 'body': payload});
    if (calls.length <= failures) throw const AiProviderFailure();
    return result ??
        {
          'choices': [
            {
              'message': {'content': '{"candidates":[]}'},
              'finish_reason': 'stop',
            },
          ],
        };
  }
}

void main() {
  test(
    'direct scan review positions derive from boxes without invented counts',
    () {
      final arranged = arrangeScanCandidates([
        {
          'name': 'lower',
          'bbox': [0.1, 0.6, 0.2, 0.9],
        },
        {
          'name': 'upper-right',
          'bbox': [0.6, 0.1, 0.8, 0.3],
        },
        {
          'name': 'upper-left',
          'bbox': [0.1, 0.1, 0.2, 0.3],
        },
      ]);
      expect(arranged.map((e) => e['name']), [
        'upper-left',
        'upper-right',
        'lower',
      ]);
      expect(arranged.map((e) => e['row']), [1, 1, 2]);
      expect(arranged.map((e) => e['slot']), [1, 2, 1]);
      expect(
        arranged.every(
          (e) => e['confidence'] == null && !e.containsKey('quantity'),
        ),
        isTrue,
      );
    },
  );
  late Map<String, dynamic> schema;
  setUp(
    () =>
        schema =
            jsonDecode(File('assets/defaults.json').readAsStringSync())
                as Map<String, dynamic>,
  );
  test('untrusted profile endpoints cannot receive a saved key', () async {
    final keys = MemoryCredentials();
    await keys.setKey('gemini', 'protected-test-key');
    schema['ai']['providers']['gemini']['endpoint'] =
        'https://untrusted.example/collect';
    final transport = FakeAiTransport();
    final router = AiProviderRouter(
      schema,
      credentials: keys,
      transport: transport,
    );
    await expectLater(
      router.generate('connection_test', 'test'),
      throwsA(isA<AiProviderFailure>()),
    );
    expect(transport.calls, isEmpty);
  });
  test('concurrent model edits cannot overwrite a saved key', () async {
    final keys = MemoryCredentials();
    await Future.wait([
      keys.setKey('gemini', 'retained-test-key'),
      keys.setModel('gemini', 'gemini-2.5-flash'),
      keys.setModel('gemini', 'gemini-2.5-flash', vision: false),
    ]);
    expect(await keys.key('gemini'), 'retained-test-key');
    expect(keys.records['gemini']!.length, 3);
  });
  test(
    'native Gemini, NIM and OpenRouter payloads and automatic failover',
    () async {
      final keys = MemoryCredentials();
      for (final provider in ['gemini', 'nvidia_nim', 'openrouter']) {
        await keys.setKey(provider, 'private-test-key');
      }
      final transport = FakeAiTransport()..failures = 2;
      final router = AiProviderRouter(
        schema,
        credentials: keys,
        transport: transport,
      );
      final result = await router.generate(
        'shelf_scan',
        'Identify products',
        image: Uint8List.fromList([255, 216, 1]),
      );
      expect(result.provider, 'openrouter');
      expect(transport.calls.length, 3);
      final first = transport.calls[0];
      expect(first['headers']['x-goog-api-key'], 'private-test-key');
      expect(first['uri'].toString(), isNot(contains('private-test-key')));
      expect(
        first['body']['generationConfig']['responseMimeType'],
        'application/json',
      );
      expect(
        first['body']['generationConfig']['responseSchema']['type'],
        'OBJECT',
      );
      final nim = transport.calls[1]['body'];
      expect(nim['response_format']['type'], 'json_schema');
      expect(
        nim['messages'][1]['content'][1]['image_url']['url'],
        startsWith('data:image/jpeg;base64,'),
      );
      expect(transport.calls[2]['headers']['X-Title'], 'ShelfSight');
      expect(transport.calls[2]['body']['models'].length, 3);
    },
  );
  test(
    'test connection uses only the selected key and invalid JSON fails closed',
    () async {
      final keys = MemoryCredentials();
      await keys.setKey('gemini', 'test-key');
      await keys.setKey('openrouter', 'second-key');
      final transport = FakeAiTransport()..failures = 10;
      final router = AiProviderRouter(
        schema,
        credentials: keys,
        transport: transport,
      );
      await expectLater(
        router.testConnection('gemini'),
        throwsA(isA<AiProviderFailure>()),
      );
      expect(transport.calls.length, 1);
      transport.failures = 0;
      transport.result = {
        'choices': [
          {
            'message': {'content': '{"candidates":"fake"}'},
          },
        ],
      };
      await expectLater(
        router.generate('shelf_scan', 'test', preferred: 'openrouter'),
        throwsA(isA<AiProviderFailure>()),
      );
    },
  );
  test(
    'clearing a key persists a tombstone rather than reviving compile-time keys',
    () async {
      final keys = MemoryCredentials();
      await keys.setKey('gemini', 'saved-key');
      expect(await keys.key('gemini'), 'saved-key');
      await keys.clear('gemini');
      expect(await keys.key('gemini'), isEmpty);
      expect(keys.toString(), isNot(contains('saved-key')));
    },
  );
}
