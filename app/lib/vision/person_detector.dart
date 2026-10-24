import 'frame_encoder.dart';
import 'local_tracker.dart';

abstract class PersonDetector {
  Future<List<PersonDetection>> detect(
    RawCameraFrame frame, {
    required double threshold,
  });
  Future<void> close();
}
