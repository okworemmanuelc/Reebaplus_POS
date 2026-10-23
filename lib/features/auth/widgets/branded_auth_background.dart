import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';

/// The branded auth backdrop from the Welcome screen (master plan §4.3):
/// a base surface, two soft accent glows in opposite corners (top-right +
/// bottom-left), and a faint dotted grid. Shared by the Welcome screen and the
/// CEO Sign Up flow so they read as one branded surface.
///
/// Theme-aware: the base is the app's shared page fade
/// ([AppDecorations.pageBackground]); dots are light in dark mode and dark in
/// light mode. Both glows follow the active accent
/// ([ColorScheme.primary]) so the flow matches the business colour. The glows
/// use a smooth full-radius falloff and a balanced diagonal placement so the
/// backdrop reads uniform — no visible edge/seam.
///
/// [child] is centred and capped at [maxWidth] (raw dp, default 480) on every
/// size. A screen too short for one column (a phone sideways) may pass a wider
/// cap for a two-column layout.
class BrandedAuthBackground extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const BrandedAuthBackground({
    super.key,
    required this.child,
    this.maxWidth = 480.0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;
    // Light mode reads almost flat at a low alpha, so the glow is stronger
    // there; dark mode keeps its subtler accent wash. Stops run the full
    // radius (0 → 1) for a smooth falloff with no visible ring/seam.
    final glowAlpha = isDark ? 0.30 : 0.50;
    final dotColor = (isDark ? Colors.white : Colors.black).withValues(
      alpha: isDark ? 0.03 : 0.04,
    );

    Widget cornerGlow(Alignment center) => Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: center,
            radius: 1.3,
            colors: [
              accent.withValues(alpha: glowAlpha),
              Colors.transparent,
            ],
            stops: const [0.0, 1.0],
          ),
        ),
      ),
    );

    return DecoratedBox(
      decoration: AppDecorations.pageBackground(context),
      child: Stack(
        children: [
          cornerGlow(const Alignment(1.0, -1.0)), // top-right
          cornerGlow(const Alignment(-1.0, 1.0)), // bottom-left
          Positioned.fill(
            child: CustomPaint(painter: _DotGridPainter(dotColor)),
          ),
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  static const double _spacing = 28;
  static const double _radius = 1.0;

  final Color color;
  const _DotGridPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (double y = _spacing; y < size.height; y += _spacing) {
      for (double x = _spacing; x < size.width; x += _spacing) {
        canvas.drawCircle(Offset(x, y), _radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) =>
      oldDelegate.color != color;
}
