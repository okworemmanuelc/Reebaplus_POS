import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

/// One reusable, themed shimmer primitive for the first-load skeletons
/// (brief §4.4). There is no `shimmer` package dependency — this drives a single
/// [AnimationController] per skeleton subtree and sweeps a highlight across every
/// [SkeletonBox] beneath it via a [ShaderMask], so an arbitrary number of
/// skeleton boxes animate in lock-step from one controller.
///
/// Colours route through the token system (`colorScheme.onSurface` tints) so the
/// skeletons read correctly under all five themes, light and dark.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Faint base, slightly brighter highlight — subtle, not flashy.
    final base = scheme.onSurface.withValues(alpha: 0.07);
    final highlight = scheme.onSurface.withValues(alpha: 0.16);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            // Slide a diagonal highlight band across the bounds.
            final dx = (bounds.width + bounds.height) * 2;
            final slide = _controller.value * dx - bounds.height;
            return LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [base, highlight, base],
              stops: const [0.35, 0.5, 0.65],
              transform: _SlideGradient(slide),
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Slides a gradient horizontally by [translate] device pixels.
class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.translate);

  final double translate;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(translate, 0, 0);
  }
}

/// A single rounded placeholder block. Fill it with the skeleton tint; the
/// ancestor [Shimmer] paints the moving highlight over it. Sizes are passed as
/// already-scaled values (callers use `context.getRSize`).
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = 12,
    this.shape = BoxShape.rectangle,
  });

  final double? width;
  final double? height;
  final double radius;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    // Opaque-ish fill so the ShaderMask has a surface to paint the highlight on.
    final fill = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: fill,
        shape: shape,
        borderRadius: shape == BoxShape.circle
            ? null
            : BorderRadius.circular(radius),
      ),
    );
  }
}

/// A short text-line placeholder. [widthFactor] sizes it as a fraction of the
/// available width so lines look like ragged text.
class SkeletonLine extends StatelessWidget {
  const SkeletonLine({
    super.key,
    this.widthFactor = 1.0,
    this.height = 12,
  });

  final double widthFactor;
  final double height;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor.clamp(0.0, 1.0),
      child: SkeletonBox(height: context.getRSize(height), radius: 6),
    );
  }
}
