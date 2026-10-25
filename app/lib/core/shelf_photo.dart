import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Isolate entry: enforce limits before pixel allocation, rotate EXIF upright,
/// strip metadata and send a still JPEG matching the provider's declared MIME.
Uint8List prepareShelfImage(Map<String, dynamic> input) {
  final bytes = input['bytes'] as Uint8List,
      maxBytes = input['max_bytes'] as int,
      maxPixels = input['max_pixels'] as int;
  if (bytes.length > maxBytes) throw const FormatException('image_limit');
  final decoder = img.findDecoderForData(bytes),
      info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > maxPixels) {
    throw const FormatException('image_limit');
  }
  final image = decoder!.decodeFrame(0);
  if (image == null) throw const FormatException('Invalid photo');
  final upright = img.bakeOrientation(image)..exif = img.ExifData();
  final encoded = Uint8List.fromList(img.encodeJpg(upright));
  if (encoded.length > maxBytes) throw const FormatException('image_limit');
  return encoded;
}
