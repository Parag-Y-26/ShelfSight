import 'package:flutter/material.dart';

abstract final class Tokens {
  static const navy = Color(0xFF071437);
  static const blue = Color(0xFF0789F8);
  static const teal = Color(0xFF00B5A6);
  static const pale = Color(0xFFF0F8FD);
  static const surface = Colors.white;
  static const muted = Color(0xFF657387);
  static const line = Color(0xFFDCE7F0);
  static const warning = Color(0xFFE79517);
  static const danger = Color(0xFFC92F48);
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const radius = 24.0;
  static const gradient = LinearGradient(
    colors: [blue, teal],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
  static const softShadow = BoxShadow(
    color: Color(0x100B72A4),
    blurRadius: 20,
    offset: Offset(0, 6),
  );
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Tokens.teal,
    primary: Tokens.teal,
    secondary: Tokens.blue,
    surface: Tokens.surface,
    error: Tokens.danger,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Inter',
  );
  return base.copyWith(
    scaffoldBackgroundColor: Tokens.pale,
    textTheme: base.textTheme.apply(
      bodyColor: Tokens.navy,
      displayColor: Tokens.navy,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Tokens.pale,
      foregroundColor: Tokens.navy,
      centerTitle: false,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Tokens.pale,
      contentPadding: const EdgeInsets.all(Tokens.md),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.md),
        borderSide: const BorderSide(color: Tokens.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.md),
        borderSide: const BorderSide(color: Tokens.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.lg,
          vertical: Tokens.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tokens.md),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: Tokens.lg,
          vertical: Tokens.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Tokens.md),
        ),
      ),
    ),
  );
}
