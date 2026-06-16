import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

extension DesignTokenExtension on BuildContext {
  double get spacingXs => getRSize(AppSpacing.xs);
  double get spacingS => getRSize(AppSpacing.s);
  double get spacingM => getRSize(AppSpacing.m);
  double get spacingL => getRSize(AppSpacing.l);
  double get spacingXl => getRSize(AppSpacing.xl);
  double get spacingXxl => getRSize(AppSpacing.xxl);

  double get radiusS => AppSpacing.borderRadiusS;
  double get radiusM => AppSpacing.borderRadiusM;
  double get radiusL => AppSpacing.borderRadiusL;

  TextStyle get h1 => AppTypography.h1.copyWith(
    fontSize: getRFontSize(AppTypography.h1.fontSize!),
  );
  TextStyle get h2 => AppTypography.h2.copyWith(
    fontSize: getRFontSize(AppTypography.h2.fontSize!),
  );
  TextStyle get h3 => AppTypography.h3.copyWith(
    fontSize: getRFontSize(AppTypography.h3.fontSize!),
  );
  TextStyle get bodyLarge => AppTypography.bodyLarge.copyWith(
    fontSize: getRFontSize(AppTypography.bodyLarge.fontSize!),
  );
  TextStyle get bodyMedium => AppTypography.bodyMedium.copyWith(
    fontSize: getRFontSize(AppTypography.bodyMedium.fontSize!),
  );
  TextStyle get bodySmall => AppTypography.bodySmall.copyWith(
    fontSize: getRFontSize(AppTypography.bodySmall.fontSize!),
  );

  Color get primaryColor => Theme.of(this).colorScheme.primary;
  Color get secondaryColor => Theme.of(this).colorScheme.secondary;
  Color get surfaceColor => Theme.of(this).colorScheme.surface;
  Color get errorColor => Theme.of(this).colorScheme.error;
  Color get backgroundColor => Theme.of(this).scaffoldBackgroundColor;
}

class AppColors {
  // Brand Colors (Amber Ribaplus)
  static const Color primary = Color(0xFFF5A623);
  static const Color primaryLight = Color(0x59F5A623);
  static const Color primaryDark = Color(0xFFFF7A00);
  static const Color contrastAmber = Color(0xFFD97706);

  // Neutral Colors (Light)
  static const Color lBg = Color(0xFFF8FAFC);
  static const Color lSurface = Color(0xFFFFFFFF);
  static const Color lCard = Color(0xFFF1F5F9);
  static const Color lText = Color(0xFF0F172A);
  static const Color lSubtext = Color(0xFF64748B);
  static const Color lBorder = Color(0xFFE2E8F0);

  // Neutral Colors (Dark)
  static const Color dBg = Color(0xFF0F172A);
  static const Color dSurface = Color(0xFF1E293B);
  static const Color dCard = Color(0xFF334155);
  static const Color dText = Color(0xFFF8FAFC);
  static const Color dSubtext = Color(0xFF94A3B8);
  static const Color dBorder = Color(0xFF475569);

  // Semantic Colors
  static const Color danger = Color(0xFFEF4444);
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color info = Color(0xFF3B82F6);
}

class AppTypography {
  static const String fontFamily = 'Inter';

  static const TextStyle h1 = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.5,
  );
  static const TextStyle h2 = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.25,
  );
  static const TextStyle h3 = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle bodyLarge = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.normal,
  );
  static const TextStyle bodyMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.normal,
  );
  static const TextStyle bodySmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.normal,
  );
  static const TextStyle labelLarge = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle labelMedium = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );
}

class AppSpacing {
  static const double xs = 4.0;
  static const double s = 8.0;
  static const double m = 16.0;
  static const double l = 24.0;
  static const double xl = 32.0;
  static const double xxl = 48.0;

  static const double borderRadiusS = 8.0;
  static const double borderRadiusM = 12.0;
  static const double borderRadiusL = 16.0;
}

class AppAnimations {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  static const Curve curve = Curves.easeInOut;
}
