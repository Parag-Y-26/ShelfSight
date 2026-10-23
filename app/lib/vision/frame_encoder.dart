import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class FramePlane {
  const FramePlane({
    required this.bytes,
    required this.rowStride,
    required this.pixelStride,
  });
  final Uint8List bytes;
  final int rowStride, pixelStride;
}

class RawCameraFrame {
  const RawCameraFrame({
    required this.width,
    required this.height,
    required this.planes,
    required this.format,
    required this.rotation,
    required this.maxDimension,
    required this.orientation,
    required this.capturedAtMs,
  });
  final int width, height, rotation, maxDimension, capturedAtMs;
  final String format, orientation;
  final List<FramePlane> planes;
}

class EncodedCameraFrame {
  const EncodedCameraFrame(
    this.jpeg,
    this.width,
    this.height,
    this.orientation,
    this.capturedAtMs,
  );
  final Uint8List jpeg;
  final int width, height, capturedAtMs;
  final String orientation;
}

/// Camera buffers are sensor-oriented. Back-camera preview and inference use
/// this same rotation, with no front-camera mirror transform.
int uprightRotation(
  int sensorOrientation,
  String deviceOrientation, {
  bool frontFacing = false,
}) {
  final deviceDegrees = switch (deviceOrientation) {
    'portraitUp' => 0,
    'landscapeLeft' => 90,
    'portraitDown' => 180,
    'landscapeRight' => 270,
    _ => throw ArgumentError.value(deviceOrientation, 'deviceOrientation'),
  };
  return frontFacing
      ? (sensorOrientation + deviceDegrees) % 360
      : (sensorOrientation - deviceDegrees + 360) % 360;
}

({int width, int height}) uprightDimensions(
  int width,
  int height,
  int rotation,
  int maxDimension,
) {
  if (width <= 0 || height <= 0 || maxDimension <= 0 || rotation % 90 != 0) {
    throw ArgumentError('Invalid camera frame dimensions');
  }
  final w = rotation % 180 == 0 ? width : height;
  final h = rotation % 180 == 0 ? height : width;
  final ratio = math.min(1.0, maxDimension / math.max(w, h));
  return (
    width: math.max(1, (w * ratio).round()),
    height: math.max(1, (h * ratio).round()),
  );
}

/// Top-level isolate entry point. Reading row/pixel strides individually avoids
/// the common Android color corruption caused by assuming contiguous UV planes.
EncodedCameraFrame encodeCameraFrame(RawCameraFrame frame) {
  final size = uprightDimensions(
    frame.width,
    frame.height,
    frame.rotation,
    frame.maxDimension,
  );
  final source = decodeCameraPixels(frame);
  final upright = frame.rotation == 0
      ? source
      : img.copyRotate(source, angle: frame.rotation);
  final reduced = upright.width == size.width && upright.height == size.height
      ? upright
      : img.copyResize(
          upright,
          width: size.width,
          height: size.height,
          interpolation: img.Interpolation.average,
        );
  return EncodedCameraFrame(
    Uint8List.fromList(img.encodeJpg(reduced)),
    reduced.width,
    reduced.height,
    frame.orientation,
    frame.capturedAtMs,
  );
}

img.Image decodeCameraPixels(RawCameraFrame frame) {
  if (frame.width <= 0 || frame.height <= 0) {
    throw ArgumentError('Invalid camera frame dimensions');
  }
  final output = img.Image(
    width: frame.width,
    height: frame.height,
    numChannels: 3,
  );
  if (frame.format == 'bgra8888' && frame.planes.length == 1) {
    final plane = frame.planes.single;
    _checkPlane(plane, frame.width, frame.height, 4);
    for (var y = 0; y < frame.height; y++) {
      for (var x = 0; x < frame.width; x++) {
        final i = y * plane.rowStride + x * plane.pixelStride;
        output.setPixelRgb(
          x,
          y,
          plane.bytes[i + 2],
          plane.bytes[i + 1],
          plane.bytes[i],
        );
      }
    }
    return output;
  }
  if (frame.format != 'yuv420' || frame.planes.length != 3) {
    throw ArgumentError('Unsupported camera frame format');
  }
  final yPlane = frame.planes[0];
  final uPlane = frame.planes[1];
  final vPlane = frame.planes[2];
  _checkPlane(yPlane, frame.width, frame.height, 1);
  _checkPlane(uPlane, (frame.width + 1) ~/ 2, (frame.height + 1) ~/ 2, 1);
  _checkPlane(vPlane, (frame.width + 1) ~/ 2, (frame.height + 1) ~/ 2, 1);
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      final luminance =
          yPlane.bytes[y * yPlane.rowStride + x * yPlane.pixelStride];
      final u =
          uPlane.bytes[(y ~/ 2) * uPlane.rowStride +
              (x ~/ 2) * uPlane.pixelStride] -
          128;
      final v =
          vPlane.bytes[(y ~/ 2) * vPlane.rowStride +
              (x ~/ 2) * vPlane.pixelStride] -
          128;
      final l = math.max(0, luminance - 16);
      final r = ((298 * l + 409 * v + 128) >> 8).clamp(0, 255);
      final g = ((298 * l - 100 * u - 208 * v + 128) >> 8).clamp(0, 255);
      final b = ((298 * l + 516 * u + 128) >> 8).clamp(0, 255);
      output.setPixelRgb(x, y, r, g, b);
    }
  }
  return output;
}

void _checkPlane(FramePlane plane, int width, int height, int channels) {
  if (plane.rowStride <= 0 ||
      plane.pixelStride < channels ||
      (width - 1) * plane.pixelStride + channels > plane.rowStride ||
      (height - 1) * plane.rowStride +
              (width - 1) * plane.pixelStride +
              channels >
          plane.bytes.length) {
    throw ArgumentError('Camera plane does not contain its declared pixels');
  }
}
