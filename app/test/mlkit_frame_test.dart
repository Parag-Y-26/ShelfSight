import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/vision/mlkit_frame.dart';
import 'package:shelfsight/vision/frame_encoder.dart';

void main() {
  test('Android uses NV21 VU interleave and honors padded camera strides', () {
    final raw = RawCameraFrame(
      width: 2,
      height: 2,
      planes: [
        FramePlane(
          bytes: Uint8List.fromList([11, 12, 0, 13, 14, 0]),
          rowStride: 3,
          pixelStride: 1,
        ),
        FramePlane(
          bytes: Uint8List.fromList([101, 0]),
          rowStride: 2,
          pixelStride: 2,
        ),
        FramePlane(
          bytes: Uint8List.fromList([201, 0]),
          rowStride: 2,
          pixelStride: 2,
        ),
      ],
      format: 'yuv420',
      rotation: 90,
      maxDimension: 640,
      orientation: 'portraitUp',
      capturedAtMs: 1000,
    );
    final f = packMlKitFrame(raw);
    expect(f.bytes, [11, 12, 13, 14, 201, 101]);
    expect(f.format, 'nv21');
    expect(f.rotation, 90);
  });
  test('iOS rotates actual BGRA pixels upright before the native bridge', () {
    final bytes = Uint8List(2 * 4 * 4);
    for (var i = 0; i < 8; i++) {
      bytes[i * 4] = i;
      bytes[i * 4 + 3] = 255;
    }
    final f = packMlKitFrame(
      RawCameraFrame(
        width: 2,
        height: 4,
        planes: [FramePlane(bytes: bytes, rowStride: 8, pixelStride: 4)],
        format: 'bgra8888',
        rotation: 90,
        maxDimension: 640,
        orientation: 'portraitUp',
        capturedAtMs: 1000,
      ),
    );
    expect(f.width, 4);
    expect(f.height, 2);
    expect(f.rotation, 0);
    expect(
      [for (var i = 0; i < 8; i++) f.bytes[i * 4]],
      [6, 4, 2, 0, 7, 5, 3, 1],
    );
  });
  test('unsupported camera buffers fail closed', () {
    expect(
      () => packMlKitFrame(
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
      throwsArgumentError,
    );
  });
}
