import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'frame_encoder.dart';
import 'local_tracker.dart';
import 'mlkit_frame.dart';
import 'person_detector.dart';

PersonDetector createLocalPersonDetector() => MlKitPersonDetector();

/// ML Kit's generic object categories do NOT include person. Use bundled base
/// pose landmarks as person evidence and object bounds only when they contain
/// that body. ML Kit base pose follows the prominent person: crowded multi-person
/// coverage is not claimed, and obscured feet abstain from visit counting.
class MlKitPersonDetector implements PersonDetector {
  final _objects = ObjectDetector(
    options: ObjectDetectorOptions(
      mode: DetectionMode.stream,
      classifyObjects: false,
      multipleObjects: true,
    ),
  );
  final _poses = PoseDetector(
    options: PoseDetectorOptions(
      model: PoseDetectionModel.base,
      mode: PoseDetectionMode.stream,
    ),
  );
  @override
  Future<List<PersonDetection>> detect(
    RawCameraFrame raw, {
    required double threshold,
  }) async {
    final frame = await compute(packMlKitFrame, raw);
    final rotation = InputImageRotationValue.fromRawValue(frame.rotation);
    if (rotation == null) throw ArgumentError('Invalid camera rotation');
    final input = InputImage.fromBytes(
      bytes: frame.bytes,
      metadata: InputImageMetadata(
        size: Size(frame.width.toDouble(), frame.height.toDouble()),
        rotation: rotation,
        format:
            frame.format == 'nv21'
                ? InputImageFormat.nv21
                : InputImageFormat.bgra8888,
        bytesPerRow: frame.rowStride,
      ),
    );
    final (objects, poses) =
        await (_objects.processImage(input), _poses.processImage(input)).wait;
    final width =
        (frame.rotation % 180 == 0 ? frame.width : frame.height).toDouble();
    final height =
        (frame.rotation % 180 == 0 ? frame.height : frame.width).toDouble();
    final result = <PersonDetection>[];
    for (final pose in poses) {
      const requiredPoints = [
        PoseLandmarkType.leftShoulder,
        PoseLandmarkType.rightShoulder,
        PoseLandmarkType.leftHip,
        PoseLandmarkType.rightHip,
        PoseLandmarkType.leftAnkle,
        PoseLandmarkType.rightAnkle,
      ];
      final evidence = [for (final key in requiredPoints) pose.landmarks[key]];
      if (evidence.any(
        (p) => p == null || !p.likelihood.isFinite || p.likelihood < threshold,
      )) {
        continue;
      }
      final points =
          pose.landmarks.values
              .where(
                (p) =>
                    p.likelihood >= threshold &&
                    p.x.isFinite &&
                    p.y.isFinite &&
                    p.x >= 0 &&
                    p.x <= width &&
                    p.y >= 0 &&
                    p.y <= height,
              )
              .toList();
      if (evidence.any((p) => !points.contains(p))) continue;
      var box = Rect.fromLTRB(
        points.map((p) => p.x).reduce(math.min),
        points.map((p) => p.y).reduce(math.min),
        points.map((p) => p.x).reduce(math.max),
        points.map((p) => p.y).reduce(math.max),
      );
      // Object localization refines a pose only when all critical body landmarks
      // lie inside it, avoiding a shelf or merchandise box being called a person.
      final candidates =
          objects
              .where(
                (o) =>
                    o.boundingBox.width > 0 &&
                    o.boundingBox.height > 0 &&
                    o.boundingBox.width * o.boundingBox.height <=
                        box.width * box.height * 2 &&
                    evidence.every(
                      (p) => o.boundingBox.contains(Offset(p!.x, p.y)),
                    ),
              )
              .toList()
            ..sort(
              (a, b) => (a.boundingBox.width * a.boundingBox.height).compareTo(
                b.boundingBox.width * b.boundingBox.height,
              ),
            );
      if (candidates.isNotEmpty) box = candidates.first.boundingBox;
      final normalized = Rect.fromLTRB(
        (box.left / width).clamp(0, 1),
        (box.top / height).clamp(0, 1),
        (box.right / width).clamp(0, 1),
        (box.bottom / height).clamp(0, 1),
      );
      final detection = PersonDetection(
        normalized,
        evidence.map((p) => p!.likelihood).reduce(math.min),
      );
      if (detection.valid) result.add(detection);
    }
    return result;
  }

  @override
  Future<void> close() async {
    await Future.wait([_objects.close(), _poses.close()]);
  }
}
