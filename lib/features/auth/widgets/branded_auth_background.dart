import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

/// The branded dark auth backdrop from the Welcome screen (master plan §4.3):
/// dark base (`adBg`), a soft amber glow from the top-right corner, and a
/// faint dotted grid. Shared by the Welcome screen and the CEO Sign Up flow so
/// they read as one branded surface.
class BrandedAuthBackground extends StatelessWidget {
  final Widget child;

  const BrandedAuthBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: adBg),
      child: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.9, -0.9),
                  radius: 1.1,
                  colors: [amberGlow, Colors.transparent],
                  stops: [0.0, 0.55],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(painter: _DotGridPainter()),
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

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.03);
    for (double y = _spacing; y < size.height; y += _spacing) {
      for (double x = _spacing; x < size.width; x += _spacing) {
        canvas.drawCircle(Offset(x, y), _radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) => false;
}
