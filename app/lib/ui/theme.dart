import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Design tokens shared by both platforms.
///
/// iOS follows Apple's Human Interface Guidelines (system colors, grouped
/// backgrounds, SF type via the platform default); Android keeps Material 3
/// with the same palette so both builds look like one product.
class Tokens {
  /// Brand accent: a calm teal (the old seed colour), readable on light and dark.
  static const accent = Color(0xFF1F8A70);
  static const accentDark = Color(0xFF3CC79F);

  /// Status colours. Never used alone: every state also has a label or icon.
  static const talk = Color(0xFFE5484D); // transmitting
  static const emergency = Color(0xFFD70015);
  static const online = Color(0xFF30A46C);
  static const connecting = Color(0xFFF5A524);

  static const radius = 14.0;
  static const radiusLarge = 22.0;
  static const gutter = 16.0;
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final accent = dark ? Tokens.accentDark : Tokens.accent;
  final scheme = ColorScheme.fromSeed(seedColor: Tokens.accent, brightness: brightness).copyWith(
    primary: accent,
    error: Tokens.talk,
    // iOS grouped background: systemGroupedBackground / secondarySystemGroupedBackground.
    surface: dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7),
    surfaceContainerLowest: dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
    surfaceContainerLow: dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF),
    surfaceContainer: dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF),
    surfaceContainerHigh: dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
    surfaceContainerHighest: dark ? const Color(0xFF3A3A3C) : const Color(0xFFD1D1D6),
    outlineVariant: dark ? const Color(0xFF38383A) : const Color(0xFFC6C6C8),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: Tokens.gutter)),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: accent,
      scaffoldBackgroundColor: scheme.surface,
      barBackgroundColor: (dark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9)).withValues(alpha: .92),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tokens.radius)),
    ),
  );
}
