import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

class AuthBackground extends StatelessWidget {
  final Widget child;
  final bool resizeToAvoidBottomInset;

  const AuthBackground({
    super.key,
    required this.child,
    this.resizeToAvoidBottomInset = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Use the generated light background for light theme
    final bgImage = isDark
        ? 'assets/images/auth_bg.png'
        : 'assets/images/auth_bg_light.png';

    // Choose overlay colors based on theme
    final overlayColor = isDark ? Colors.black : Colors.white;
    final overlayOpacity = isDark
        ? 0.45
        : 0.6; // Slightly more wash for light mode
    const blurSigma = 20.0;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      body: Stack(
        children: [
          // Background Image (Isolated with RepaintBoundary)
          RepaintBoundary(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Image.asset(
                    bgImage,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: isDark ? Colors.black : Colors.grey[100],
                    ),
                  ),
                ),
                // Blur overlay
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: blurSigma,
                      sigmaY: blurSigma,
                    ),
                    child: Container(
                      color: overlayColor.withValues(alpha: overlayOpacity),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Center(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: !context.isPhone ? 480.0 : double.infinity,
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
