import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A wrapper around [BackdropFilter] that disables the expensive rasterization
/// of the Gaussian blur while the current page route is animating (e.g. sliding).
/// When [isAnimating] is true, it falls back to the provided [fallbackBuilder],
/// which typically renders a solid or translucent background without blur.
class OptimizedBackdropFilter extends StatelessWidget {
  final ui.ImageFilter filter;
  final Widget child;
  final Widget Function(BuildContext context, Widget child) fallbackBuilder;

  const OptimizedBackdropFilter({
    super.key,
    required this.filter,
    required this.child,
    required this.fallbackBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final modalRoute = ModalRoute.of(context);
    final animation = modalRoute?.animation;
    final secondaryAnimation = modalRoute?.secondaryAnimation;

    if (animation == null && secondaryAnimation == null) {
      return BackdropFilter(
        filter: filter,
        child: child,
      );
    }

    final Listenable listenable = Listenable.merge([
      if (animation != null) animation,
      if (secondaryAnimation != null) secondaryAnimation,
    ]);

    return AnimatedBuilder(
      animation: listenable,
      builder: (context, _) {
        final isAnimating = (animation != null && !animation.isCompleted && !animation.isDismissed) ||
                            (secondaryAnimation != null && !secondaryAnimation.isCompleted && !secondaryAnimation.isDismissed);
        if (isAnimating) {
          return fallbackBuilder(context, child);
        }
        return BackdropFilter(
          filter: filter,
          child: child,
        );
      },
    );
  }
}
