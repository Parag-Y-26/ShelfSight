import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppStrings {
  const AppStrings(this.values);
  final Map<String, String> values;
  static Map<String, String> _remoteValues = {};
  static void setResourceOverlay(dynamic resources) {
    final english = resources is Map ? resources['en'] : null;
    _remoteValues =
        english is Map
            ? {
              for (final entry in english.entries)
                if (entry.key is String &&
                    !entry.key.toString().startsWith('@') &&
                    entry.value is String)
                  entry.key as String: entry.value as String,
            }
            : {};
  }

  static const delegate = _StringsDelegate();
  String resolve(String key, Map<String, Object> args) {
    var value = _remoteValues[key] ?? values[key] ?? key;
    for (final entry in args.entries) {
      value = value.replaceAll('{${entry.key}}', entry.value.toString());
    }
    return value;
  }
}

String tr(
  BuildContext context,
  String key, [
  Map<String, Object> args = const {},
]) =>
    Localizations.of<AppStrings>(context, AppStrings)?.resolve(key, args) ??
    key;

class _StringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _StringsDelegate();
  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';
  @override
  Future<AppStrings> load(Locale locale) async {
    final values = <String, String>{};
    for (final module in ['core', 'retail', 'monitoring']) {
      try {
        final raw =
            jsonDecode(
                  await rootBundle.loadString('assets/l10n/${module}_en.arb'),
                )
                as Map<String, dynamic>;
        for (final entry in raw.entries) {
          if (!entry.key.startsWith('@') && entry.value is String) {
            values[entry.key] = entry.value as String;
          }
        }
      } catch (error) {
        if (kDebugMode) debugPrint('Localization module unavailable: $module');
      }
    }
    return AppStrings(values);
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppStrings> old) => false;
}
