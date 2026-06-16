import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

/// The branded auth backdrop from the Welcome screen (master plan §4.3):
/// a base surface, two soft accent glows in opposite corners (top-right +
/// bottom-left), and a faint dotted grid. Shared by the Welcome screen and the
/// CEO Sign Up flow so they read as one branded surface.
///
/// Theme-aware: dark mode keeps the dark base; light mode uses the theme's
/// light scaffold colour with dark dots. Both glows follow the active accent
/// ([ColorScheme.primary]) so the flow matches the business colour. The glows
/// use a smooth full-radius falloff and a balanced diagonal placement so the
/// backdrop reads uniform — no visible edge/seam.
class BrandedAuthBackground extends StatelessWidget {
  final Widget child;

  const BrandedAuthBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final base = isDark ? adBg : theme.scaffoldBackgroundColor;
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
      decoration: BoxDecoration(color: base),
      child: Stack(
        children: [
          cornerGlow(const Alignment(1.0, -1.0)), // top-right
          cornerGlow(const Alignment(-1.0, 1.0)), // bottom-left
          Positioned.fill(
            child: CustomPaint(painter: _DotGridPainter(dotColor)),
          ),
          child,
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
