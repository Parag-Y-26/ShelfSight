import 'package:flutter/material.dart';

abstract final class Tokens {
  static const navy = Color(0xFF071437);
  static const blue = Color(0xFF006874);
  static const teal = Color(0xFF006874);
  static const accent = Color(0xFF00838F);
  static const pale = Color(0xFFEAF5FC);
  static const surface = Color(0xFFF8FDFF);
  static const onAccent = Colors.white;
  static const transparent = Colors.transparent;
  static const scrim = Colors.black26;
  static const logoLarge = 148.0;
  static const logoSmall = 56.0;
  static const muted = Color(0xFF435867);
  static const line = Color(0xFF526E78);
  static const warning = Color(0xFF805400);
  static const live = Color(0xFF146C43);
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
    seedColor: Tokens.blue,
    primary: Tokens.blue,
    onPrimary: Colors.white,
    secondary: Tokens.accent,
    onSecondary: Colors.white,
    surface: Tokens.surface,
    error: Tokens.danger,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Inter',
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
  );
  return base.copyWith(
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
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
        minimumSize: const Size(48, 48),
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
        minimumSize: const Size(48, 48),
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
