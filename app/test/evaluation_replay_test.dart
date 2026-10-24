import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/vision/evaluation_replay.dart';

void main() {
  test(
    'replay requires explicit opt-in and caller supplied labeled frames',
    () {
      expect(
        () => SyntheticReplayDetector.fromJson('[]', enabled: false),
        throwsStateError,
      );
      expect(
        () => SyntheticReplayDetector.fromJson('[]', enabled: true),
        throwsFormatException,
      );
      final replay = SyntheticReplayDetector.fromJson(
        '[{"at_ms":0,"detections":[]},{"at_ms":200,"detections":'
        '[{"bbox":[0.1,0.2,0.3,0.4],"confidence":0.8}]}]',
        enabled: true,
      );
      expect(replay.provenance, 'labeled_replay');
      expect(replay.frames.length, 2);
      expect(replay.detectionCount, 1);
    },
  );

  test('malformed and nonmonotonic labels are rejected', () {
    for (final json in [
      '[{"at_ms":0,"detections":[{"bbox":[0,0,2,2],"confidence":0.9}]}]',
      '[{"at_ms":1,"detections":[]},{"at_ms":0,"detections":[]}]',
      '[{"at_ms":0,"detections":[{"bbox":[0,0,1,1],"confidence":2}]}]',
    ]) {
      expect(
        () => SyntheticReplayDetector.fromJson(json, enabled: true),
        throwsFormatException,
      );
    }
  });
}
