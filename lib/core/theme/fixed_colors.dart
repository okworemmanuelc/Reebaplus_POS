import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

/// The fixed colour set (PRD #346 decision 6, #349): status colours, their
/// tints and outlines, and the category / neutral tile colours.
///
/// These colours IGNORE the design system. Blue, Amber, Purple, Green and
/// Black & White all install the same [AppFixedColors.light] instance in their
/// light theme and the same [AppFixedColors.dark] instance in their dark theme,
/// so a PRO pill, a stock badge or a pale icon tile looks the same whichever
/// scheme the owner picks. Only light vs dark differ (designer colour sheet,
/// #346 first comment).
///
/// Widgets access these via:
/// ```dart
/// Theme.of(context).extension<AppFixedColors>()!.dangerTint
/// ```
///
/// The scheme still drives primary buttons, active nav, prices and focus
/// outlines — those live on `ColorScheme` and `AppSchemeColors`.
@immutable
class AppFixedColors extends ThemeExtension<AppFixedColors> {
  /// Danger: Clear, Log Out, remove, count badges.
  final Color danger;

  /// Pale danger fill behind danger text/icons.
  final Color dangerTint;

  /// Danger outline (e.g. the Clear button border).
  final Color dangerOutline;

  /// Warning: crates, pending, low stock.
  final Color warning;

  /// Pale warning fill.
  final Color warningTint;

  /// Warning outline.
  final Color warningOutline;

  /// Green text and icons: balance, discount, profit. Darker in light mode
  /// for readability on white.
  final Color green;

  /// Green dot: stock is fine.
  final Color greenDot;

  /// Pale green fill.
  final Color greenTint;

  /// Info blue: water icons, Roles icon.
  final Color info;

  /// Pale info fill; also the fixed icon-tile fill (Home stat cards,
  /// settings rows).
  final Color infoTint;

  /// Stout and neutral icon.
  final Color neutralIcon;

  /// Stout and neutral tile fill.
  final Color neutralTile;

  /// Malt tile fill.
  final Color maltTile;

  /// Text and icons on a SOLID fixed pill, e.g. the PRO tag (white in both
  /// brightnesses; #352 PR 2).
  final Color onSolid;

  /// Purple icons and text: Home's Take Stock quick action (#362).
  final Color purple;

  /// Pale purple fill behind [purple].
  final Color purpleTint;

  const AppFixedColors({
    required this.danger,
    required this.dangerTint,
    required this.dangerOutline,
    required this.warning,
    required this.warningTint,
    required this.warningOutline,
    required this.green,
    required this.greenDot,
    required this.greenTint,
    required this.info,
    required this.infoTint,
    required this.neutralIcon,
    required this.neutralTile,
    required this.maltTile,
    required this.onSolid,
    required this.purple,
    required this.purpleTint,
  });

  /// The fixed set for every light theme.
  static final AppFixedColors light = AppFixedColors(
    danger: fixedDanger,
    dangerTint: fixedDanger.withValues(alpha: 0.10),
    dangerOutline: fixedDanger.withValues(alpha: 0.35),
    warning: fixedWarning,
    warningTint: fixedWarning.withValues(alpha: 0.15),
    warningOutline: fixedWarning.withValues(alpha: 0.55),
    green: fixedGreenTextLight,
    greenDot: fixedGreen,
    greenTint: fixedGreen.withValues(alpha: 0.15),
    info: fixedInfo,
    infoTint: fixedInfo.withValues(alpha: 0.12),
    neutralIcon: fixedNeutralInkLight,
    neutralTile: fixedNeutralInkLight.withValues(alpha: 0.08),
    maltTile: fixedMalt.withValues(alpha: 0.20),
    onSolid: fixedOnSolid,
    purple: fixedPurpleLight,
    purpleTint: fixedPurpleTintLight,
  );

  /// The fixed set for every dark theme.
  static final AppFixedColors dark = AppFixedColors(
    danger: fixedDanger,
    dangerTint: fixedDanger.withValues(alpha: 0.14),
    dangerOutline: fixedDanger.withValues(alpha: 0.45),
    warning: fixedWarning,
    warningTint: fixedWarning.withValues(alpha: 0.14),
    warningOutline: fixedWarning.withValues(alpha: 0.45),
    green: fixedGreen,
    greenDot: fixedGreen,
    greenTint: fixedGreen.withValues(alpha: 0.14),
    info: fixedInfo,
    infoTint: fixedInfo.withValues(alpha: 0.16),
    neutralIcon: fixedNeutralInkDark,
    neutralTile: Colors.white.withValues(alpha: 0.08),
    maltTile: fixedMalt.withValues(alpha: 0.16),
    onSolid: fixedOnSolid,
    purple: fixedPurpleDark,
    purpleTint: fixedPurpleTintDark,
  );

  @override
  AppFixedColors copyWith({
    Color? danger,
    Color? dangerTint,
    Color? dangerOutline,
    Color? warning,
    Color? warningTint,
    Color? warningOutline,
    Color? green,
    Color? greenDot,
    Color? greenTint,
    Color? info,
    Color? infoTint,
    Color? neutralIcon,
    Color? neutralTile,
    Color? maltTile,
    Color? onSolid,
    Color? purple,
    Color? purpleTint,
  }) {
    return AppFixedColors(
      danger: danger ?? this.danger,
      dangerTint: dangerTint ?? this.dangerTint,
      dangerOutline: dangerOutline ?? this.dangerOutline,
      warning: warning ?? this.warning,
      warningTint: warningTint ?? this.warningTint,
      warningOutline: warningOutline ?? this.warningOutline,
      green: green ?? this.green,
      greenDot: greenDot ?? this.greenDot,
      greenTint: greenTint ?? this.greenTint,
      info: info ?? this.info,
      infoTint: infoTint ?? this.infoTint,
      neutralIcon: neutralIcon ?? this.neutralIcon,
      neutralTile: neutralTile ?? this.neutralTile,
      maltTile: maltTile ?? this.maltTile,
      onSolid: onSolid ?? this.onSolid,
      purple: purple ?? this.purple,
      purpleTint: purpleTint ?? this.purpleTint,
    );
  }

  @override
  AppFixedColors lerp(AppFixedColors? other, double t) {
    if (other is! AppFixedColors) return this;
    return AppFixedColors(
      danger: Color.lerp(danger, other.danger, t)!,
      dangerTint: Color.lerp(dangerTint, other.dangerTint, t)!,
      dangerOutline: Color.lerp(dangerOutline, other.dangerOutline, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningTint: Color.lerp(warningTint, other.warningTint, t)!,
      warningOutline: Color.lerp(warningOutline, other.warningOutline, t)!,
      green: Color.lerp(green, other.green, t)!,
      greenDot: Color.lerp(greenDot, other.greenDot, t)!,
      greenTint: Color.lerp(greenTint, other.greenTint, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoTint: Color.lerp(infoTint, other.infoTint, t)!,
      neutralIcon: Color.lerp(neutralIcon, other.neutralIcon, t)!,
      neutralTile: Color.lerp(neutralTile, other.neutralTile, t)!,
      maltTile: Color.lerp(maltTile, other.maltTile, t)!,
      onSolid: Color.lerp(onSolid, other.onSolid, t)!,
      purple: Color.lerp(purple, other.purple, t)!,
      purpleTint: Color.lerp(purpleTint, other.purpleTint, t)!,
    );
  }
}
