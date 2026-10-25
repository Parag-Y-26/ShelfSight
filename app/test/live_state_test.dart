import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/core/app_controller.dart';
import 'runtime_settings_test.dart' show OfflineApi;

void main() {
  testWidgets(
    'LIVE requires a processed frame and expires on stale, stop or sign-out',
    (tester) async {
      final app = AppController.forTesting(
        api: OfflineApi(),
        config: const {
          'limits': {'max_frame_age_seconds': 5},
        },
      );
      app.markMonitoringActive(true);
      expect(app.monitoringLive, false);
      app.frameProcessed();
      expect(app.monitoringLive, true);
      await tester.pump(const Duration(seconds: 6));
      expect(app.monitoringLive, false);
      app.frameProcessed();
      expect(app.monitoringLive, true);
      app.framesStopped();
      expect(app.monitoringLive, false);
      app.markMonitoringActive(false);
      app.frameProcessed();
      expect(app.monitoringLive, false);
      app.dispose();
    },
  );
}
