import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/configuration.dart';

class MemorySettings extends DeviceSettingsStore {
  Map<String, dynamic> values = {};
  @override
  Future<Map<String, dynamic>> read() async =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(values)) as Map);
  @override
  Future<void> write(Map<String, dynamic> values) async {
    this.values = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(values)) as Map,
    );
  }
}

class OfflineApi extends ApiClient {
  @override
  bool get paired => false;
}

class DisconnectedApi extends OfflineApi {
  @override
  bool get paired => true;
  @override
  Future<dynamic> patch(String path, dynamic body) async =>
      throw const ApiFailure('connectionFailed');
}

void main() {
  test('a failed server save retains the local override', () async {
    final storage = MemorySettings();
    final schema =
        jsonDecode(File('assets/defaults.json').readAsStringSync())
            as Map<String, dynamic>;
    final app = AppController.forTesting(
      api: DisconnectedApi(),
      settingsStore: storage,
      config: schema,
      store: {'id': 's'},
    );
    await app.saveSettings({'dwell_cutoff_sec': 12});
    expect(app.effectiveSettings()['dwell_cutoff_sec'], 12);
    expect(app.settingsSyncPending, isTrue);
    expect(storage.values['scopes'], isNotEmpty);
    app.dispose();
  });

  test(
    'a standalone shelf blocks remote monitoring even with remote global mode',
    () async {
      final app = AppController.forTesting(
        api: OfflineApi(),
        config:
            jsonDecode(File('assets/defaults.json').readAsStringSync())
                as Map<String, dynamic>,
        store: {'id': 's'},
        shelves: [
          {
            'id': 'remote',
            'settings': {'execution_mode': 'remote_server'},
          },
          {
            'id': 'mobile',
            'settings': {'execution_mode': 'standalone_mobile'},
          },
        ],
      );
      expect(app.canUseRemoteMonitoring(['remote']), isTrue);
      expect(app.canUseRemoteMonitoring(['remote', 'mobile']), isFalse);
      expect(app.canUseRemoteMonitoring(['missing']), isFalse);
      app.dispose();
    },
  );
  test(
    'device settings survive restart and remain below store/shelf overrides',
    () async {
      final schema =
          jsonDecode(File('assets/defaults.json').readAsStringSync())
              as Map<String, dynamic>;
      final storage = MemorySettings();
      final first = AppController.forTesting(
        api: OfflineApi(),
        config: schema,
        settingsStore: storage,
      );
      await first.saveSettings({
        'dwell_cutoff_sec': 9,
        'active_ai_provider': 'openrouter',
        'execution_mode': 'remote_server',
      }, global: true);
      first.dispose();
      final second = AppController.forTesting(
        api: OfflineApi(),
        config: schema,
        settingsStore: storage,
        store: {'id': 's'},
        shelves: [
          {'id': 'h'},
        ],
      );
      await second.restoreSettings();
      expect(second.effectiveSettings()['dwell_cutoff_sec'], 9);
      expect(second.effectiveSettings()['active_ai_provider'], 'openrouter');
      await second.saveSettings({'dwell_cutoff_sec': 4});
      await second.saveSettings({'dwell_cutoff_sec': 6}, shelfId: 'h');
      expect(second.effectiveSettings()['dwell_cutoff_sec'], 4);
      expect(second.effectiveSettings({'id': 'h'})['dwell_cutoff_sec'], 6);
      await second.saveSettings({}, shelfId: 'h');
      expect(second.effectiveSettings({'id': 'h'})['dwell_cutoff_sec'], 4);
      await second.saveSettings({});
      expect(second.effectiveSettings()['dwell_cutoff_sec'], 9);
      expect(second.monitoringSettings['settings']['dwell_cutoff_sec'], 9);
      second.dispose();
    },
  );

  test('invalid settings never reach storage', () async {
    final storage = MemorySettings();
    final app = AppController.forTesting(
      api: OfflineApi(),
      settingsStore: storage,
      config:
          jsonDecode(File('assets/defaults.json').readAsStringSync())
              as Map<String, dynamic>,
    );
    await expectLater(
      app.saveSettings({'active_ai_provider': 'fake'}, global: true),
      throwsFormatException,
    );
    expect(storage.values, isEmpty);
    app.dispose();
  });
}
