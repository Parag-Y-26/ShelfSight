import 'dart:js_interop';
import 'dart:typed_data';
import 'package:camera/camera.dart';

@JS('URL.revokeObjectURL')
external void _revokeObjectURL(JSString url);

Future<void> deleteTempPhoto(String path) async {
  if (path.startsWith('blob:')) _revokeObjectURL(path.toJS);
}

Future<Uint8List> consumeTempPhoto(String path) async {
  try {
    return await XFile(path).readAsBytes();
  } finally {
    await deleteTempPhoto(path);
  }
}
