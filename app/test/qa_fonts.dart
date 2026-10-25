import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

Future<void> loadQaFonts() async {
  await (FontLoader('Inter')
    ..addFont(rootBundle.load('assets/fonts/Inter.ttf'))).load();
  final file = File('.dart_tool/package_config.json').absolute;
  final config = jsonDecode(await file.readAsString()) as Map;
  final flutter = (config['packages'] as List).whereType<Map>().firstWhere(
    (p) => p['name'] == 'flutter',
  );
  final root =
      Directory.fromUri(
        file.uri.resolve(flutter['rootUri'] as String),
      ).parent.parent;
  final bytes =
      await File(
        '${root.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes();
  await (FontLoader('MaterialIcons')
    ..addFont(SynchronousFuture(ByteData.sublistView(bytes)))).load();
}
