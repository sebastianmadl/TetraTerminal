import 'dart:ui';

import 'package:flutter/material.dart';

import 'adaptive.dart';

/// Liquid Glass style surface for the functional layer (tab bar, PTT dock):
/// blur of the content beneath, a translucent fill, a one-pixel light rim and
/// a soft shadow (HIG "Materials" / Liquid Glass; Flutter translation from
/// the apple-design skill). With high contrast on it falls back to an opaque
/// fill, since Flutter exposes no reduce-transparency signal.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 28, this.padding = EdgeInsets.zero, this.tint});
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final opaque = MediaQuery.of(context).highContrast;
    final fill = tint ?? (dark ? const Color(0xFF1C1C1E) : Colors.white);
    final shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? .35 : .08), blurRadius: 20, offset: const Offset(0, 4))],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          enabled: !opaque,
          filter: ImageFilter.compose(outer: ImageFilter.blur(sigmaX: 20, sigmaY: 20), inner: const ColorFilter.matrix(_saturate)),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: shape,
              // Light catching the top edge of the material.
              gradient: opaque
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [fill.withValues(alpha: dark ? .62 : .72), fill.withValues(alpha: dark ? .52 : .58)],
                    ),
              color: opaque ? fill : null,
              border: Border.all(color: Colors.white.withValues(alpha: dark ? .14 : .7), width: 1),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Saturation 1.6: the colour of the content shows through the glass.
const List<double> _saturate = [
  1.4528, -0.4288, -0.0240, 0, 0, //
  -0.1272, 1.1512, -0.0240, 0, 0, //
  -0.1272, -0.4288, 1.5560, 0, 0, //
  0, 0, 0, 1, 0,
];

/// Floating glass tab bar (iOS 26+ style): a capsule inset from the screen
/// edges, the selected tab on a tinted lens that slides between tabs.
class GlassTabBar extends StatelessWidget {
  const GlassTabBar({super.key, required this.items, required this.index, required this.onTap, this.badges = const {}});
  final List<(IconData, IconData, String)> items; // (icon, selected icon, label)
  final int index;
  final ValueChanged<int> onTap;
  final Set<int> badges;

  static const barHeight = 62.0;

  /// Space content should leave at the bottom so nothing hides behind the bar.
  static double inset(BuildContext context) => barHeight + 12 + MediaQuery.of(context).padding.bottom.clamp(12, 40);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).padding.bottom.clamp(12.0, 40.0);
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, bottom),
      child: Glass(
        radius: barHeight / 2,
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          height: barHeight - 8,
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth / items.length;
            return Stack(children: [
              AnimatedPositioned(
                duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                left: w * index,
                top: 0,
                bottom: 0,
                width: w,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(barHeight / 2),
                  ),
                ),
              ),
              Row(children: [
                for (final (i, it) in items.indexed)
                  Expanded(
                    child: Semantics(
                      selected: i == index,
                      button: true,
                      label: it.$3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onTap(i),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Badge(
                            isLabelVisible: badges.contains(i),
                            smallSize: 8,
                            child: Icon(i == index ? it.$2 : it.$1, size: 24, color: i == index ? scheme.primary : scheme.onSurface),
                          ),
                          const SizedBox(height: 2),
                          Text(it.$3,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: i == index ? FontWeight.w600 : FontWeight.w500,
                                color: i == index ? scheme.primary : scheme.onSurface,
                              )),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ]);
          }),
        ),
      ),
    );
  }
}

/// Bottom space content leaves for the floating bar (0 on Android).
double floatingBarInset(BuildContext context) => isApple(context) ? GlassTabBar.inset(context) : 0;
