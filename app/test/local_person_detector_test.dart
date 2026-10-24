import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:shelfsight/vision/local_person_detector_native.dart';
import 'package:shelfsight/vision/frame_encoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const objectChannel = MethodChannel('google_mlkit_object_detector'),
      poseChannel = MethodChannel('google_mlkit_pose_detector');
  var bodyVisible = true, feetVisible = true;
  Map<dynamic, dynamic>? request;
  setUp(() {
    bodyVisible = true;
    feetVisible = true;
    messenger.setMockMethodCallHandler(objectChannel, (call) async {
      if (call.method.contains('close')) return null;
      request = call.arguments as Map;
      // A confidently localized object is deliberately NOT a person label.
      return [
        {
          'rect': {'left': 0.0, 'top': 0.0, 'right': 2.0, 'bottom': 2.0},
          'trackingId': 1,
          'labels': [],
        },
      ];
    });
    messenger.setMockMethodCallHandler(poseChannel, (call) async {
      if (call.method.contains('close')) return null;
      if (!bodyVisible) return [];
      final points = {
        PoseLandmarkType.nose: (1.0, .1),
        PoseLandmarkType.leftShoulder: (.5, .5),
        PoseLandmarkType.rightShoulder: (1.5, .5),
        PoseLandmarkType.leftHip: (.5, 1.0),
        PoseLandmarkType.rightHip: (1.5, 1.0),
        PoseLandmarkType.leftAnkle: (.5, 1.8),
        PoseLandmarkType.rightAnkle: (1.5, 1.8),
      };
      return [
        [
          for (final e in points.entries)
            {
              'type': e.key.index,
              'x': e.value.$1,
              'y': e.value.$2,
              'z': 0.0,
              'likelihood':
                  !feetVisible && e.key == PoseLandmarkType.leftAnkle
                      ? 0.1
                      : 0.9,
            },
        ],
      ];
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(objectChannel, null);
    messenger.setMockMethodCallHandler(poseChannel, null);
  });
  RawCameraFrame frame() => RawCameraFrame(
    width: 2,
    height: 2,
    planes: [
      FramePlane(bytes: Uint8List(4), rowStride: 2, pixelStride: 1),
      FramePlane(bytes: Uint8List(1), rowStride: 1, pixelStride: 1),
      FramePlane(bytes: Uint8List(1), rowStride: 1, pixelStride: 1),
    ],
    format: 'yuv420',
    rotation: 0,
    maxDimension: 640,
    orientation: 'portraitUp',
    capturedAtMs: 1000,
  );
  test(
    'object localization needs real body and foot landmarks before emitting a person',
    () async {
      final detector = MlKitPersonDetector();
      var result = await detector.detect(frame(), threshold: .45);
      expect(result, hasLength(1));
      expect(result.single.confidence, .9);
      expect(result.single.bbox.bottom, .9);
      expect(request!['options']['mode'], 0);
      expect(request!['imageData']['metadata']['image_format'], 17);
      feetVisible = false;
      expect(await detector.detect(frame(), threshold: .45), isEmpty);
      bodyVisible = false;
      expect(await detector.detect(frame(), threshold: .45), isEmpty);
      await detector.close();
    },
  );
}
