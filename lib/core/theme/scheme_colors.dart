import 'package:flutter/material.dart';

/// Scheme-driven "project" colours from the designer colour sheet (#346 first
/// comment, #349) that `ColorScheme` has no slot for.
///
/// Unlike `AppFixedColors`, these FOLLOW the design system: every scheme
/// builds its own instance from its own primary / surface / text constants at
/// the same alpha values as Blue Classic (see [AppSchemeColors.derive]).
///
/// Widgets access these via:
/// ```dart
/// Theme.of(context).extension<AppSchemeColors>()!.primaryTint
/// ```
@immutable
class AppSchemeColors extends ThemeExtension<AppSchemeColors> {
  /// Pale primary fill: the active rail item and other pale active fills.
  /// Not the screen-title icon tile — that is the solid primary gradient.
  final Color primaryTint;

  /// Shadow under primary (gradient) buttons.
  final Color primaryGlow;

  /// Link hover / pressed colour.
  final Color linkHover;

  /// Bottom stop of the screen background fade (top stop =
  /// `scaffoldBackgroundColor`).
  final Color backgroundFade;

  /// Slightly see-through card fill.
  final Color cardFill;

  /// Muted text placed on Surface 2 (inputs, grey buttons, steppers).
  final Color mutedOnSurface2;

  /// Card shadow colour.
  final Color cardShadow;

  /// Dim behind an open menu or cart panel.
  final Color scrim;

  /// Slide-in panel shadow colour.
  final Color panelShadow;

  /// Top bar shadow colour.
  final Color topBarShadow;

  const AppSchemeColors({
    required this.primaryTint,
    required this.primaryGlow,
    required this.linkHover,
    required this.backgroundFade,
    required this.cardFill,
    required this.mutedOnSurface2,
    required this.cardShadow,
    required this.scrim,
    required this.panelShadow,
    required this.topBarShadow,
  });

  /// Builds a scheme's set from its own constants, using the alpha values the
  /// designer set for Blue Classic. Every scheme goes through here so the
  /// alphas can never drift apart.
  ///
  /// [backgroundFade] is passed in (Blue has an exact hex from the sheet);
  /// other schemes pass [fadeFrom] to blend their primary into their
  /// background.
  factory AppSchemeColors.derive({
    required Brightness brightness,
    required Color primary,
    required Color surface,
    required Color textPrimary,
    required Color linkHover,
    required Color backgroundFade,
    required Color mutedOnSurface2,
  }) {
    final isLight = brightness == Brightness.light;
    return AppSchemeColors(
      primaryTint: primary.withValues(alpha: isLight ? 0.12 : 0.16),
      primaryGlow: primary.withValues(alpha: 0.30),
      linkHover: linkHover,
      backgroundFade: backgroundFade,
      cardFill: surface.withValues(alpha: isLight ? 0.90 : 0.72),
      mutedOnSurface2: mutedOnSurface2,
      cardShadow: Colors.black.withValues(alpha: isLight ? 0.05 : 0.25),
      scrim: Colors.black.withValues(alpha: isLight ? 0.35 : 0.55),
      panelShadow: isLight
          ? textPrimary.withValues(alpha: 0.12)
          : Colors.black.withValues(alpha: 0.50),
      topBarShadow: isLight
          ? textPrimary.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.30),
    );
  }

  /// Bottom stop of the background fade for schemes without a designer hex:
  /// the scheme's primary laid over its background at the strength that
  /// approximates Blue's sheet values (light 5%, dark 7%).
  static Color fadeFrom({
    required Brightness brightness,
    required Color background,
    required Color primary,
  }) {
    final alpha = brightness == Brightness.light ? 0.05 : 0.07;
    return Color.alphaBlend(primary.withValues(alpha: alpha), background);
  }

  @override
  AppSchemeColors copyWith({
    Color? primaryTint,
    Color? primaryGlow,
    Color? linkHover,
    Color? backgroundFade,
    Color? cardFill,
    Color? mutedOnSurface2,
    Color? cardShadow,
    Color? scrim,
    Color? panelShadow,
    Color? topBarShadow,
  }) {
    return AppSchemeColors(
      primaryTint: primaryTint ?? this.primaryTint,
      primaryGlow: primaryGlow ?? this.primaryGlow,
      linkHover: linkHover ?? this.linkHover,
      backgroundFade: backgroundFade ?? this.backgroundFade,
      cardFill: cardFill ?? this.cardFill,
      mutedOnSurface2: mutedOnSurface2 ?? this.mutedOnSurface2,
      cardShadow: cardShadow ?? this.cardShadow,
      scrim: scrim ?? this.scrim,
      panelShadow: panelShadow ?? this.panelShadow,
      topBarShadow: topBarShadow ?? this.topBarShadow,
    );
  }

  @override
  AppSchemeColors lerp(AppSchemeColors? other, double t) {
    if (other is! AppSchemeColors) return this;
    return AppSchemeColors(
      primaryTint: Color.lerp(primaryTint, other.primaryTint, t)!,
      primaryGlow: Color.lerp(primaryGlow, other.primaryGlow, t)!,
      linkHover: Color.lerp(linkHover, other.linkHover, t)!,
      backgroundFade: Color.lerp(backgroundFade, other.backgroundFade, t)!,
      cardFill: Color.lerp(cardFill, other.cardFill, t)!,
      mutedOnSurface2: Color.lerp(mutedOnSurface2, other.mutedOnSurface2, t)!,
      cardShadow: Color.lerp(cardShadow, other.cardShadow, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      panelShadow: Color.lerp(panelShadow, other.panelShadow, t)!,
      topBarShadow: Color.lerp(topBarShadow, other.topBarShadow, t)!,
    );
  }
}
