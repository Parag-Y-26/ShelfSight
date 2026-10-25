import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'package:share_plus/share_plus.dart';

Future<void> exportCsv(
  String csv,
  String filename, {
  required Rect origin,
}) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile.fromData(
          Uint8List.fromList(utf8.encode(csv)),
          mimeType: 'text/csv',
          name: filename,
        ),
      ],
      fileNameOverrides: [filename],
      sharePositionOrigin: origin,
    ),
  );
}
