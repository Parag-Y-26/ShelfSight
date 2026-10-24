import 'dart:io';
import 'dart:typed_data';

Future<void> deleteTempPhoto(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}

Future<Uint8List> consumeTempPhoto(String path) async {
  try {
    return await File(path).readAsBytes();
  } finally {
    await deleteTempPhoto(path);
  }
}
