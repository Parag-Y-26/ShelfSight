import 'dart:io';

Future<void> deleteTempPhoto(String path) async {
  await File(path).delete();
}
