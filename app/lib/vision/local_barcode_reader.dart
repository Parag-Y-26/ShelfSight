import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'frame_encoder.dart';
import 'mlkit_frame.dart';

class LocalBarcodeReader {
  final _scanner = BarcodeScanner(
    formats: [
      BarcodeFormat.ean8,
      BarcodeFormat.ean13,
      BarcodeFormat.upca,
      BarcodeFormat.upce,
    ],
  );
  Future<List<String>>? _pending;
  bool _closed = false;
  Future<List<String>> read(RawCameraFrame raw) {
    if (_closed) throw StateError('Barcode reader closed');
    return _pending ??= _read(raw).whenComplete(() => _pending = null);
  }

  Future<List<String>> _read(RawCameraFrame raw) async {
    final frame = await compute(packMlKitFrame, raw);
    final rotation = InputImageRotationValue.fromRawValue(frame.rotation);
    if (rotation == null) throw ArgumentError('Unsupported camera rotation');
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
    return (await _scanner.processImage(input))
        .map((b) => b.rawValue)
        .whereType<String>()
        .where((b) => RegExp(r'^(?:\d{8}|\d{12,14})$').hasMatch(b))
        .toSet()
        .toList();
  }

  Future<void> close() async {
    _closed = true;
    try {
      await _pending;
    } catch (_) {}
    await _scanner.close();
  }
}
