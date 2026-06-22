import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';

class GlassyCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Border? border;
  final Color? backgroundColor;

  const GlassyCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = 16.0,
    this.border,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final modalRoute = ModalRoute.of(context);
    final animation = modalRoute?.animation;
    final secondaryAnimation = modalRoute?.secondaryAnimation;

    Widget buildCard(bool isAnimating) {
      final container = Container(
        padding: padding ?? EdgeInsets.all(context.getRSize(16)),
        decoration: BoxDecoration(
          color: backgroundColor ?? (isAnimating
              ? (isDark
                  ? theme.colorScheme.surface.withValues(alpha: 0.85)
                  : theme.colorScheme.surface.withValues(alpha: 0.95))
              : (isDark
                  ? theme.colorScheme.surface.withValues(alpha: 0.25)
                  : theme.colorScheme.surface.withValues(alpha: 0.6))),
          borderRadius: BorderRadius.circular(radius),
          border: border ?? Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.05)
                : theme.colorScheme.primary.withValues(alpha: 0.05),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              spreadRadius: 0,
            )
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: child,
        ),
      );

      if (isAnimating) {
        return container;
      }

      return BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: container,
      );
    }

    if (animation == null && secondaryAnimation == null) {
      return Container(
        margin: margin,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: buildCard(false),
        ),
      );
    }

    final Listenable listenable = Listenable.merge([
      if (animation != null) animation,
      if (secondaryAnimation != null) secondaryAnimation,
    ]);

    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AnimatedBuilder(
          animation: listenable,
          builder: (context, _) {
            final isAnimating = (animation != null && !animation.isCompleted && !animation.isDismissed) ||
                                (secondaryAnimation != null && !secondaryAnimation.isCompleted && !secondaryAnimation.isDismissed);
            return buildCard(isAnimating);
          },
        ),
      ),
    );
  }
}

