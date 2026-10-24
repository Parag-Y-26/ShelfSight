import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shelfsight/core/app_controller.dart';
import 'package:shelfsight/core/standalone_repository.dart';
import 'package:shelfsight/vision/monitoring_controller.dart';
import 'package:shelfsight/vision/person_detector.dart';
import 'package:shelfsight/vision/local_tracker.dart';
import 'package:shelfsight/vision/frame_encoder.dart';
import 'standalone_controller_test.dart' show NoServerApi, LocalTestCache;
import 'runtime_settings_test.dart' show MemorySettings;
import 'ai_provider_router_test.dart' show MemoryCredentials;

class _ObservedPerson implements PersonDetector {
  bool closed = false;
  @override
  Future<List<PersonDetection>> detect(
    RawCameraFrame frame, {
    required double threshold,
  }) async => [const PersonDetection(Rect.fromLTRB(.2, .1, .4, .8), .9)];
  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
    'local monitoring controller writes actual SQLite visits and coverage with no socket',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'shelfsight_monitor_test',
      );
      final config =
          jsonDecode(await File('assets/defaults.json').readAsString())
              as Map<String, dynamic>;
      final repo = StandaloneMobileRepository(
        config: config,
        factory: databaseFactoryFfi,
        databasePath: '${dir.path}/ledger.db',
      );
      final api = NoServerApi(), keys = MemoryCredentials();
      await keys.setKey('gemini', 'dummy-monitor-test');
      final app = AppController.forTesting(
        api: api,
        config: config,
        localRepository: repo,
        cache: LocalTestCache(),
        settingsStore: MemorySettings(),
        aiCredentials: keys,
      );
      final detector = _ObservedPerson(),
          monitor = MonitoringController(app, detectorFactory: () => detector);
      try {
        await app.enterStandalone();
        final s = await repo.post('/stores', {
          'name': 'Monitoring test',
          'type_id': 'grocery',
          'goal_id': 'demand',
          'unit': 'm',
          'currency': 'INR',
          'timezone': 'UTC',
          'shelf_count': 1,
          'floor': {'name': 'Floor', 'width': 10, 'length': 10},
        });
        await app.refresh();
        final camera = CameraController(
          const CameraDescription(
            name: 'test-only',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 0,
          ),
          ResolutionPreset.low,
        );
        camera.value = camera.value.copyWith(
          isInitialized: true,
          previewSize: const Size(2, 2),
        );
        monitor.camera = camera;
        monitor.frameWidth = 2;
        monitor.frameHeight = 2;
        monitor.orientation = 'portraitUp';
        monitor.phase = MonitorPhase.calibrating;
        monitor.selectShelf(app.shelves.single['id']);
        monitor.setZone(const Rect.fromLTWH(0, 0, 1, 1));
        await monitor.saveCalibration();
        monitor.setCameraConfirmed(true);
        await monitor.start();
        expect(monitor.running, true);
        expect(app.monitoringActive, true);
        final start = DateTime.now().millisecondsSinceEpoch - 4000;
        for (var i = 0; i <= 16; i++) {
          await monitor.submitFrame(
            RawCameraFrame(
              width: 2,
              height: 2,
              planes: [
                FramePlane(bytes: Uint8List(4), rowStride: 2, pixelStride: 1),
              ],
              format: 'test-only',
              rotation: 0,
              maxDimension: 640,
              orientation: 'portraitUp',
              capturedAtMs: start + i * 200,
            ),
          );
        }
        expect(monitor.phase, MonitorPhase.live);
        expect(monitor.acknowledgedFrames, 17);
        expect(monitor.transmittedBytes, 0);
        expect(monitor.processingMs, isNonNegative);
        expect(api.networkCalls, 0);
        await monitor.stop();
        final events = await repo.ledger(s['id']);
        final visit = events.firstWhere((e) => e['type'] == 'visit');
        expect(visit['provenance'], 'live_camera');
        expect(visit['is_incomplete'], true);
        expect(visit['dwell_seconds'], closeTo(3.2, .001));
        expect(events.where((e) => e['type'] == 'coverage'), hasLength(1));
        expect(detector.closed, true);
        expect(app.monitoringActive, false);
        monitor.camera =
            null; // Test-only unregistered camera has no native handle.
        await camera.dispose();
      } finally {
        monitor.dispose();
        app.dispose();
        await repo.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
