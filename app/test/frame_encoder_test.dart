import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shelfsight/vision/frame_encoder.dart';

RawCameraFrame frame({
  required int width,
  required int height,
  required List<FramePlane> planes,
  String format = 'yuv420',
  int rotation = 0,
  int maxDimension = 100,
}) => RawCameraFrame(
  width: width,
  height: height,
  planes: planes,
  format: format,
  rotation: rotation,
  maxDimension: maxDimension,
  orientation: 'portraitUp',
  capturedAtMs: 123456789,
);

void main() {
  test('YUV respects padded Y rows and interleaved UV pixel strides', () {
    final decoded = decodeCameraPixels(
      frame(
        width: 4,
        height: 2,
        planes: [
          FramePlane(
            bytes: Uint8List.fromList([
              16,
              16,
              235,
              235,
              99,
              99,
              16,
              16,
              235,
              235,
              99,
              99,
            ]),
            rowStride: 6,
            pixelStride: 1,
          ),
          FramePlane(
            bytes: Uint8List.fromList([128, 99, 128]),
            rowStride: 4,
            pixelStride: 2,
          ),
          FramePlane(
            bytes: Uint8List.fromList([128, 99, 128]),
            rowStride: 4,
            pixelStride: 2,
          ),
        ],
      ),
    );
    expect(decoded.getPixel(0, 1).r, 0);
    expect(decoded.getPixel(1, 1).g, 0);
    expect(decoded.getPixel(2, 1).b, 255);
    expect(decoded.getPixel(3, 1).r, 255);
  });

  test('separate U and V row strides survive odd image dimensions', () {
    final decoded = decodeCameraPixels(
      frame(
        width: 3,
        height: 3,
        planes: [
          FramePlane(
            bytes: Uint8List.fromList(List.filled(15, 100)),
            rowStride: 5,
            pixelStride: 1,
          ),
          FramePlane(
            bytes: Uint8List.fromList([128, 128, 0, 0, 128, 255]),
            rowStride: 4,
            pixelStride: 1,
          ),
          FramePlane(
            bytes: Uint8List.fromList([128, 128, 0, 128, 128]),
            rowStride: 3,
            pixelStride: 1,
          ),
        ],
      ),
    );
    final neutral = decoded.getPixel(0, 0);
    final tinted = decoded.getPixel(2, 2);
    expect(neutral.r, neutral.b);
    expect(tinted.b, greaterThan(neutral.b));
    expect(tinted.r, neutral.r);
  });

  test('BGRA preserves channel order and ignores row padding', () {
    final decoded = decodeCameraPixels(
      frame(
        width: 1,
        height: 2,
        format: 'bgra8888',
        planes: [
          FramePlane(
            bytes: Uint8List.fromList([
              0,
              0,
              255,
              255,
              99,
              99,
              99,
              99,
              255,
              0,
              0,
              255,
            ]),
            rowStride: 8,
            pixelStride: 4,
          ),
        ],
      ),
    );
    expect(decoded.getPixel(0, 0).r, 255);
    expect(decoded.getPixel(0, 0).b, 0);
    expect(decoded.getPixel(0, 1).b, 255);
  });

  test('truncated and malformed planes fail before pixel access', () {
    expect(
      () => decodeCameraPixels(
        frame(
          width: 2,
          height: 2,
          planes: [
            FramePlane(bytes: Uint8List(2), rowStride: 2, pixelStride: 1),
            FramePlane(bytes: Uint8List(1), rowStride: 1, pixelStride: 1),
            FramePlane(bytes: Uint8List(1), rowStride: 1, pixelStride: 1),
          ],
        ),
      ),
      throwsArgumentError,
    );
  });

  test('sensor and device orientation produce upright dimensions', () {
    expect(uprightRotation(90, 'portraitUp'), 90);
    expect(uprightRotation(90, 'landscapeLeft'), 0);
    expect(uprightRotation(90, 'portraitDown'), 270);
    expect(uprightRotation(90, 'landscapeRight'), 180);
    expect(uprightDimensions(1280, 720, 90, 640), (width: 360, height: 640));
    expect(uprightDimensions(320, 240, 0, 640), (width: 320, height: 240));
  });

  test('JPEG rotation agrees with metadata and never upscales', () {
    final result = encodeCameraFrame(
      frame(
        width: 2,
        height: 1,
        format: 'bgra8888',
        rotation: 90,
        planes: [
          FramePlane(
            bytes: Uint8List.fromList([0, 0, 255, 255, 255, 0, 0, 255]),
            rowStride: 8,
            pixelStride: 4,
          ),
        ],
      ),
    );
    final decoded = image.decodeJpg(result.jpeg)!;
    expect((result.width, result.height), (1, 2));
    expect((decoded.width, decoded.height), (1, 2));
    expect(result.capturedAtMs, 123456789);
    expect(result.orientation, 'portraitUp');
    expect(decoded.getPixel(0, 0).r, greaterThan(decoded.getPixel(0, 0).b));
    expect(decoded.getPixel(0, 1).b, greaterThan(decoded.getPixel(0, 1).r));
  });
}
