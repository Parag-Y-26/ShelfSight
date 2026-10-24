import 'package:flutter_test/flutter_test.dart';
import 'ai_provider_router_test.dart' show MemoryCredentials;

void main() {
  test(
    'optional dart defines are used only until replaced or removed',
    () async {
      const injected = {
        'gemini': String.fromEnvironment('GEMINI_API_KEY'),
        'nvidia_nim': String.fromEnvironment('NVIDIA_NIM_API_KEY'),
        'openrouter': String.fromEnvironment('OPENROUTER_API_KEY'),
      };
      final vault = MemoryCredentials();
      for (final entry in injected.entries) {
        expect(await vault.key(entry.key), entry.value);
        await vault.setKey(entry.key, 'runtime-override');
        expect(await vault.key(entry.key), 'runtime-override');
        await vault.clear(entry.key);
        expect(await vault.key(entry.key), isEmpty);
      }
    },
  );
}
