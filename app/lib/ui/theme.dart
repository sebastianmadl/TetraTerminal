import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
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
  final p = defaultTargetPlatform;
  return p == TargetPlatform.iOS || p == TargetPlatform.macOS ? _appleTheme(brightness) : _expressiveTheme(brightness);
}

ThemeData _appleTheme(Brightness brightness) {
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

/// Android: Material 3 Expressive. Tonal surfaces from the brand seed, roomy
/// shapes (large corners, pill indicators), emphasized headlines, and the
/// same accent and status colours as iOS.
ThemeData _expressiveTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: Tokens.accent,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  ).copyWith(primary: dark ? Tokens.accentDark : Tokens.accent, error: Tokens.talk);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  final text = base.textTheme;
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text.copyWith(
      // Emphasized type for titles and headers.
      displaySmall: text.displaySmall?.copyWith(fontWeight: FontWeight.w600),
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 76,
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.primary.withValues(alpha: dark ? .30 : .18),
      indicatorShape: const StadiumBorder(),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12.5,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: s.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            size: 24,
            color: s.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant,
          )),
    ),
    cardTheme: CardThemeData(elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStateProperty.all(const StadiumBorder()),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbIcon: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? const Icon(Icons.check_rounded) : null),
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: Tokens.gutter + 4)),
    bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true, shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28)))),
    dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

/// Material 3 Expressive "cookie" shape: a circle with [lobes] soft scallops
/// (the shape library's 9- and 12-sided cookies). Used for the Android PTT.
class CookieBorder extends OutlinedBorder {
  const CookieBorder({this.lobes = 12, this.depth = .055, this.rotation = 0, super.side});
  final int lobes;
  /// Scallop depth as a fraction of the radius.
  final double depth;
  /// Turns (0..1), for the slow spin while transmitting.
  final double rotation;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  Path _path(Rect rect) {
    final c = rect.center;
    final r = rect.shortestSide / 2;
    final path = Path();
    const steps = 240;
    for (var i = 0; i <= steps; i++) {
      final a = 2 * math.pi * i / steps;
      final rr = r * (1 - depth + depth * math.cos(lobes * (a + 2 * math.pi * rotation)));
      final pt = c + Offset(math.cos(a), math.sin(a)) * rr;
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    return path..close();
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _path(rect.deflate(side.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    canvas.drawPath(_path(rect), side.toPaint());
  }

  @override
  ShapeBorder scale(double t) => CookieBorder(lobes: lobes, depth: depth, rotation: rotation, side: side.scale(t));

  @override
  CookieBorder copyWith({BorderSide? side}) => CookieBorder(lobes: lobes, depth: depth, rotation: rotation, side: side ?? this.side);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) =>
      a is CookieBorder ? CookieBorder(lobes: lobes, depth: lerpDouble(a.depth, depth, t)!, rotation: lerpDouble(a.rotation, rotation, t)!, side: side) : super.lerpFrom(a, t);
}
