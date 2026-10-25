import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:async';
import 'package:web/web.dart' as web;

Future<void> exportCsv(
  String csv,
  String filename, {
  required Rect origin,
}) async {
  final data = Uint8List.fromList(utf8.encode(csv));
  final blob = web.Blob(
    [data.toJS].toJS,
    web.BlobPropertyBag(type: 'text/csv;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor =
      web.HTMLAnchorElement()
        ..href = url
        ..download = filename;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
}
