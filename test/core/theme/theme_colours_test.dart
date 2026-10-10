// #349 — designer colour sheet values (PRD #346, first comment) and the fixed
// colour set that ignores the design system.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';

/// Every ThemeData the app builds (main.dart's design-system switch).
final Map<String, ThemeData Function()> _lightThemes = {
  'blue': AppTheme.light,
  'amber': AppTheme.amberLight,
  'purple': AppTheme.purpleLight,
  'green': AppTheme.greenLight,
  'bw': AppTheme.bwLight,
};
final Map<String, ThemeData Function()> _darkThemes = {
  'blue': AppTheme.dark,
  'amber': AppTheme.amberDarkTheme,
  'purple': AppTheme.purpleDarkTheme,
  'green': AppTheme.greenDarkTheme,
  'bw': AppTheme.bwDarkTheme,
};

/// `#RRGGBB` @ alpha, as the colour sheet writes it.
Color _hex(int rgb, [double alpha = 1]) =>
    Color(0xFF000000 | rgb).withValues(alpha: alpha);

void _expectColour(Color actual, Color expected, String label) {
  // Compare components (withValues stores floats; ==-identity is not the
  // contract, the visible colour is). 1/255 tolerance covers 8-bit hexes.
  const tol = 1 / 255;
  expect(actual.r, closeTo(expected.r, tol), reason: '$label red');
  expect(actual.g, closeTo(expected.g, tol), reason: '$label green');
  expect(actual.b, closeTo(expected.b, tol), reason: '$label blue');
  expect(actual.a, closeTo(expected.a, tol), reason: '$label alpha');
}

List<Color> _fixedValues(AppFixedColors f) => [
  f.danger,
  f.dangerTint,
  f.dangerOutline,
  f.warning,
  f.warningTint,
  f.warningOutline,
  f.green,
  f.greenDot,
  f.greenTint,
  f.info,
  f.infoTint,
  f.neutralIcon,
  f.neutralTile,
  f.maltTile,
  f.onSolid,
  f.purple,
  f.purpleTint,
];

void main() {
  group('Fixed colour set (AppFixedColors)', () {
    for (final entry in {
      Brightness.light: _lightThemes,
      Brightness.dark: _darkThemes,
    }.entries) {
      test(
        'is installed and identical in all 5 schemes (${entry.key.name})',
        () {
          final reference = entry.key == Brightness.light
              ? AppFixedColors.light
              : AppFixedColors.dark;
          for (final scheme in entry.value.entries) {
            final theme = scheme.value();
            expect(theme.brightness, entry.key, reason: scheme.key);
            final fixed = theme.extension<AppFixedColors>();
            expect(
              fixed,
              isNotNull,
              reason: '${scheme.key} lacks AppFixedColors',
            );
            expect(
              _fixedValues(fixed!),
              _fixedValues(reference),
              reason:
                  '${scheme.key} ${entry.key.name} differs from the fixed set',
            );
          }
        },
      );
    }

    test('light values equal the colour sheet', () {
      final f = AppFixedColors.light;
      _expectColour(f.danger, _hex(0xEF4444), 'danger');
      _expectColour(f.dangerTint, _hex(0xEF4444, 0.10), 'dangerTint');
      _expectColour(f.dangerOutline, _hex(0xEF4444, 0.35), 'dangerOutline');
      _expectColour(f.warning, _hex(0xFFB020), 'warning');
      _expectColour(f.warningTint, _hex(0xFFB020, 0.15), 'warningTint');
      _expectColour(f.warningOutline, _hex(0xFFB020, 0.55), 'warningOutline');
      _expectColour(f.green, _hex(0x43A047), 'green');
      _expectColour(f.greenDot, _hex(0x30D158), 'greenDot');
      _expectColour(f.greenTint, _hex(0x30D158, 0.15), 'greenTint');
      _expectColour(f.info, _hex(0x3B82F6), 'info');
      _expectColour(f.infoTint, _hex(0x3B82F6, 0.12), 'infoTint');
      _expectColour(f.neutralIcon, _hex(0x0B1220), 'neutralIcon');
      _expectColour(f.neutralTile, _hex(0x0B1220, 0.08), 'neutralTile');
      _expectColour(f.maltTile, _hex(0x60A5FA, 0.20), 'maltTile');
      _expectColour(f.onSolid, _hex(0xFFFFFF, 1.0), 'onSolid');
      _expectColour(f.purple, _hex(0x7C3AED), 'purple');
      _expectColour(f.purpleTint, _hex(0xF3EEFF), 'purpleTint');
    });

    test('dark values equal the colour sheet', () {
      final f = AppFixedColors.dark;
      _expectColour(f.danger, _hex(0xEF4444), 'danger');
      _expectColour(f.dangerTint, _hex(0xEF4444, 0.14), 'dangerTint');
      _expectColour(f.dangerOutline, _hex(0xEF4444, 0.45), 'dangerOutline');
      _expectColour(f.warning, _hex(0xFFB020), 'warning');
      _expectColour(f.warningTint, _hex(0xFFB020, 0.14), 'warningTint');
      _expectColour(f.warningOutline, _hex(0xFFB020, 0.45), 'warningOutline');
      _expectColour(f.green, _hex(0x30D158), 'green');
      _expectColour(f.greenDot, _hex(0x30D158), 'greenDot');
      _expectColour(f.greenTint, _hex(0x30D158, 0.14), 'greenTint');
      _expectColour(f.info, _hex(0x3B82F6), 'info');
      _expectColour(f.infoTint, _hex(0x3B82F6, 0.16), 'infoTint');
      _expectColour(f.neutralIcon, _hex(0xE2E8F0), 'neutralIcon');
      _expectColour(f.neutralTile, _hex(0xFFFFFF, 0.08), 'neutralTile');
      _expectColour(f.maltTile, _hex(0x60A5FA, 0.16), 'maltTile');
      _expectColour(f.onSolid, _hex(0xFFFFFF, 1.0), 'onSolid');
      _expectColour(f.purple, _hex(0xA78BFA), 'purple');
      _expectColour(f.purpleTint, _hex(0x241B3D), 'purpleTint');
    });
  });

  test('purple survives copyWith and lerp (#362)', () {
    final l = AppFixedColors.light;
    final d = AppFixedColors.dark;
    expect(l.copyWith().purple, l.purple);
    expect(l.copyWith().purpleTint, l.purpleTint);
    expect(l.copyWith(purple: d.purple).purple, d.purple);
    expect(l.lerp(d, 0).purple, l.purple);
    expect(l.lerp(d, 1).purpleTint, d.purpleTint);
  });

  group('Blue Classic matches the colour sheet', () {
    test('light', () {
      final t = AppTheme.light();
      final cs = t.colorScheme;
      final s = t.extension<AppSchemeColors>()!;
      // System values (already in colors.dart).
      _expectColour(t.scaffoldBackgroundColor, _hex(0xF8FAFC), 'background');
      _expectColour(cs.surface, _hex(0xFFFFFF), 'surface');
      _expectColour(cs.onSurface, _hex(0x0F172A), 'main text');
      _expectColour(t.dividerColor, _hex(0xE2E8F0), 'border');
      _expectColour(cs.primary, _hex(0x2563EB), 'primary');
      _expectColour(cs.secondary, _hex(0x60A5FA), 'secondary');
      _expectColour(cs.onPrimary, _hex(0xFFFFFF), 'on gradient');
      // Project values.
      _expectColour(s.backgroundFade, _hex(0xEEF3FD), 'background fade');
      _expectColour(s.cardFill, _hex(0xFFFFFF, 0.90), 'card fill');
      _expectColour(s.mutedOnSurface2, _hex(0x475569), 'muted on Surface 2');
      _expectColour(s.primaryTint, _hex(0x2563EB, 0.12), 'primary tint');
      _expectColour(s.primaryGlow, _hex(0x2563EB, 0.30), 'primary glow');
      _expectColour(s.linkHover, _hex(0x1D4ED8), 'link hover');
      _expectColour(s.cardShadow, _hex(0x000000, 0.05), 'card shadow');
      _expectColour(s.scrim, _hex(0x000000, 0.35), 'dim');
      _expectColour(s.panelShadow, _hex(0x0F172A, 0.12), 'panel shadow');
      _expectColour(s.topBarShadow, _hex(0x0F172A, 0.05), 'top bar shadow');
    });

    test('dark', () {
      final t = AppTheme.dark();
      final cs = t.colorScheme;
      final s = t.extension<AppSchemeColors>()!;
      _expectColour(t.scaffoldBackgroundColor, _hex(0x090D14), 'background');
      _expectColour(cs.surface, _hex(0x111827), 'surface');
      _expectColour(cs.onSurface, _hex(0xF8FAFC), 'main text');
      _expectColour(t.dividerColor, _hex(0xFFFFFF, 0.12), 'border');
      _expectColour(cs.primary, _hex(0x3B82F6), 'primary');
      _expectColour(cs.secondary, _hex(0x60A5FA), 'secondary');
      // Deliberate change: white (not black) on the gradient in dark mode.
      _expectColour(cs.onPrimary, _hex(0xFFFFFF), 'on gradient');
      _expectColour(s.backgroundFade, _hex(0x0C1526), 'background fade');
      _expectColour(s.cardFill, _hex(0x111827, 0.72), 'card fill');
      _expectColour(s.mutedOnSurface2, _hex(0xA0AEC0), 'muted on Surface 2');
      _expectColour(s.primaryTint, _hex(0x3B82F6, 0.16), 'primary tint');
      _expectColour(s.primaryGlow, _hex(0x3B82F6, 0.30), 'primary glow');
      _expectColour(s.linkHover, _hex(0x60A5FA), 'link hover');
      _expectColour(s.cardShadow, _hex(0x000000, 0.25), 'card shadow');
      _expectColour(s.scrim, _hex(0x000000, 0.55), 'dim');
      _expectColour(s.panelShadow, _hex(0x000000, 0.50), 'panel shadow');
      _expectColour(s.topBarShadow, _hex(0x000000, 0.30), 'top bar shadow');
    });
  });

  group('Scheme colours (AppSchemeColors) in the other schemes', () {
    for (final entry in {
      Brightness.light: _lightThemes,
      Brightness.dark: _darkThemes,
    }.entries) {
      test(
        'use Blue\'s alpha values on their own colours (${entry.key.name})',
        () {
          final isLight = entry.key == Brightness.light;
          for (final scheme in entry.value.entries) {
            final t = scheme.value();
            final s = t.extension<AppSchemeColors>();
            expect(s, isNotNull, reason: '${scheme.key} lacks AppSchemeColors');
            final primary = t.colorScheme.primary;
            _expectColour(
              s!.primaryTint,
              primary.withValues(alpha: isLight ? 0.12 : 0.16),
              '${scheme.key} primary tint',
            );
            _expectColour(
              s.primaryGlow,
              primary.withValues(alpha: 0.30),
              '${scheme.key} glow',
            );
            _expectColour(
              s.cardFill,
              t.colorScheme.surface.withValues(alpha: isLight ? 0.90 : 0.72),
              '${scheme.key} card fill',
            );
            // The fade and hover must be visibly distinct from their base.
            expect(
              s.backgroundFade,
              isNot(t.scaffoldBackgroundColor),
              reason: '${scheme.key} fade equals the background',
            );
            expect(s.linkHover, isNot(primary), reason: '${scheme.key} hover');
          }
        },
      );
    }

    test('other schemes keep their own primary (fixed set does not leak)', () {
      expect(
        AppTheme.amberLight().colorScheme.primary,
        isNot(const Color(0xFF2563EB)),
      );
      expect(AppTheme.bwDarkTheme().colorScheme.onPrimary, Colors.black);
    });
  });
}
