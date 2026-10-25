import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/vision/frame_encoder.dart';
import 'package:shelfsight/vision/local_barcode_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live reader sends NV21 camera bytes to ML Kit and releases its scanner',
    () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('google_mlkit_barcode_scanning');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'vision#closeBarcodeScanner') return null;
            return [
              for (final code in ['12345678', '12345678', 'unknown'])
                {
                  'type': 0,
                  'format': 64,
                  'rawValue': code,
                  'displayValue': code,
                  'rawBytes': null,
                  'rect': {
                    'left': 0.0,
                    'top': 0.0,
                    'right': 1.0,
                    'bottom': 1.0,
                  },
                  'points': <dynamic>[],
                },
            ];
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final reader = LocalBarcodeReader();
      final result = await reader.read(
        RawCameraFrame(
          width: 2,
          height: 2,
          planes: [
            FramePlane(
              bytes: Uint8List.fromList([1, 2, 3, 4]),
              rowStride: 2,
              pixelStride: 1,
            ),
            FramePlane(
              bytes: Uint8List.fromList([5]),
              rowStride: 1,
              pixelStride: 1,
            ),
            FramePlane(
              bytes: Uint8List.fromList([6]),
              rowStride: 1,
              pixelStride: 1,
            ),
          ],
          format: 'yuv420',
          rotation: 90,
          maxDimension: 640,
          orientation: 'portraitUp',
          capturedAtMs: 1000,
        ),
      );
      expect(result, ['12345678']);
      final image = (calls.single.arguments as Map)['imageData'] as Map;
      expect(image['bytes'], [1, 2, 3, 4, 6, 5]);
      await reader.close();
      expect(calls.last.method, 'vision#closeBarcodeScanner');
      expect(
        () => reader.read(
          const RawCameraFrame(
            width: 2,
            height: 2,
            planes: [],
            format: 'unknown',
            rotation: 0,
            maxDimension: 640,
            orientation: 'portraitUp',
            capturedAtMs: 1000,
          ),
        ),
        throwsStateError,
      );
    },
  );
}
