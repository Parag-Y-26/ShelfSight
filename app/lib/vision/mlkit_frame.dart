import 'dart:typed_data';
import 'frame_encoder.dart';

class MlKitFrame {
  const MlKitFrame(
    this.bytes,
    this.width,
    this.height,
    this.rotation,
    this.format,
    this.rowStride,
  );
  final Uint8List bytes;
  final int width, height, rotation, rowStride;
  final String format;
}

/// Resize camera buffers directly into ML Kit's raw formats. No JPEG encoding,
/// disk file, base64, RGB conversion on Android, or network request is involved.
/// Rotation stays in metadata; bounds returned by ML Kit use upright coordinates.
MlKitFrame packMlKitFrame(RawCameraFrame frame) {
  final size = uprightDimensions(
    frame.width,
    frame.height,
    0,
    frame.maxDimension,
  );
  final w = size.width - size.width % 2, h = size.height - size.height % 2;
  if (w <= 0 || h <= 0) throw ArgumentError('Invalid ML Kit frame');
  if (frame.format == 'bgra8888' && frame.planes.length == 1) {
    final output = Uint8List(w * h * 4), plane = frame.planes.single;
    for (var y = 0; y < h; y++) {
      final sy = y * frame.height ~/ h;
      for (var x = 0; x < w; x++) {
        final sx = x * frame.width ~/ w;
        final source = sy * plane.rowStride + sx * plane.pixelStride;
        final dest = (y * w + x) * 4;
        output.setRange(dest, dest + 4, plane.bytes, source);
      }
    }
    // The iOS ML Kit bridge creates UIImage from a pixel buffer and ignores
    // rotation metadata. Rotate pixels here so its result and preview agree.
    if (frame.rotation == 0) {
      return MlKitFrame(output, w, h, 0, 'bgra8888', w * 4);
    }
    final rw = frame.rotation % 180 == 0 ? w : h,
        rh = frame.rotation % 180 == 0 ? h : w;
    final rotated = Uint8List(output.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final (rx, ry) = switch (frame.rotation) {
          90 => (h - 1 - y, x),
          180 => (w - 1 - x, h - 1 - y),
          270 => (y, w - 1 - x),
          _ => throw ArgumentError('Invalid rotation'),
        };
        rotated.setRange(
          (ry * rw + rx) * 4,
          (ry * rw + rx) * 4 + 4,
          output,
          (y * w + x) * 4,
        );
      }
    }
    return MlKitFrame(rotated, rw, rh, 0, 'bgra8888', rw * 4);
  }
  if (frame.format != 'yuv420' || frame.planes.length != 3) {
    throw ArgumentError('Unsupported ML Kit camera format');
  }
  final out = Uint8List(w * h * 3 ~/ 2),
      yp = frame.planes[0],
      up = frame.planes[1],
      vp = frame.planes[2];
  for (var y = 0; y < h; y++) {
    final sy = y * frame.height ~/ h;
    for (var x = 0; x < w; x++) {
      final sx = x * frame.width ~/ w;
      out[y * w + x] = yp.bytes[sy * yp.rowStride + sx * yp.pixelStride];
    }
  }
  for (var y = 0; y < h ~/ 2; y++) {
    final sy = (y * frame.height ~/ h);
    for (var x = 0; x < w ~/ 2; x++) {
      final sx = x * frame.width ~/ w;
      final dest = w * h + y * w + x * 2;
      out[dest] = vp.bytes[sy * vp.rowStride + sx * vp.pixelStride];
      out[dest + 1] = up.bytes[sy * up.rowStride + sx * up.pixelStride];
    }
  }
  return MlKitFrame(out, w, h, frame.rotation, 'nv21', w);
}
