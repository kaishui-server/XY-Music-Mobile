import 'package:flutter/material.dart';

import 'xy_theme.dart';

class XyPageBackground extends StatelessWidget {
  const XyPageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        gradient: dark
            ? const RadialGradient(
                center: Alignment(1.15, -1.0),
                radius: 1.05,
                colors: [Color(0x2EEC4141), Color(0x001F1F1F)],
                stops: [0, 0.7],
              )
            : const RadialGradient(
                center: Alignment(1.1, -1.0),
                radius: 1.05,
                colors: [Color(0x16EC4141), Color(0x00F5F5F5)],
                stops: [0, 0.7],
              ),
      ),
      child: child,
    );
  }
}

class XyPanel extends StatelessWidget {
  const XyPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = XyRadii.large,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color:
            color ??
            theme.colorScheme.surface.withValues(alpha: dark ? 0.9 : 0.94),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: dark ? XyColors.darkBorder : XyColors.lightBorder,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.18 : 0.05),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
