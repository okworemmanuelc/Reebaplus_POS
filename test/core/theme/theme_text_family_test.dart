// #349 — every text style in all 10 themes (5 schemes x light/dark) uses the
// bundled DM Sans family, and switching the family changed nothing else.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';

final Map<String, ThemeData Function()> _themes = {
  'blue light': AppTheme.light,
  'blue dark': AppTheme.dark,
  'amber light': AppTheme.amberLight,
  'amber dark': AppTheme.amberDarkTheme,
  'purple light': AppTheme.purpleLight,
  'purple dark': AppTheme.purpleDarkTheme,
  'green light': AppTheme.greenLight,
  'green dark': AppTheme.greenDarkTheme,
  'bw light': AppTheme.bwLight,
  'bw dark': AppTheme.bwDarkTheme,
};

Map<String, TextStyle?> _textThemeStyles(TextTheme t) => {
  'displayLarge': t.displayLarge,
  'displayMedium': t.displayMedium,
  'displaySmall': t.displaySmall,
  'headlineLarge': t.headlineLarge,
  'headlineMedium': t.headlineMedium,
  'headlineSmall': t.headlineSmall,
  'titleLarge': t.titleLarge,
  'titleMedium': t.titleMedium,
  'titleSmall': t.titleSmall,
  'bodyLarge': t.bodyLarge,
  'bodyMedium': t.bodyMedium,
  'bodySmall': t.bodySmall,
  'labelLarge': t.labelLarge,
  'labelMedium': t.labelMedium,
  'labelSmall': t.labelSmall,
};

/// The component slots that carry their own text style.
Map<String, TextStyle?> _slotStyles(ThemeData t) {
  final nav = t.navigationBarTheme.labelTextStyle;
  return {
    'appBar.titleTextStyle': t.appBarTheme.titleTextStyle,
    'appBar.toolbarTextStyle': t.appBarTheme.toolbarTextStyle,
    'chip.labelStyle': t.chipTheme.labelStyle,
    'chip.secondaryLabelStyle': t.chipTheme.secondaryLabelStyle,
    'input.hintStyle': t.inputDecorationTheme.hintStyle,
    'input.labelStyle': t.inputDecorationTheme.labelStyle,
    'input.floatingLabelStyle': t.inputDecorationTheme.floatingLabelStyle,
    'input.helperStyle': t.inputDecorationTheme.helperStyle,
    'input.errorStyle': t.inputDecorationTheme.errorStyle,
    'bottomNav.selectedLabelStyle':
        t.bottomNavigationBarTheme.selectedLabelStyle,
    'bottomNav.unselectedLabelStyle':
        t.bottomNavigationBarTheme.unselectedLabelStyle,
    'navBar.label(idle)': nav?.resolve(const <WidgetState>{}),
    'navBar.label(selected)': nav?.resolve(const {WidgetState.selected}),
  };
}

void _expectSameExceptFamily(
  TextStyle? after,
  TextStyle? before,
  String label,
) {
  if (before == null) {
    expect(after, isNull, reason: label);
    return;
  }
  expect(after, isNotNull, reason: label);
  expect(after!.fontFamily, appFontFamily, reason: label);
  expect(after.fontSize, before.fontSize, reason: '$label size');
  expect(after.fontWeight, before.fontWeight, reason: '$label weight');
  expect(after.fontStyle, before.fontStyle, reason: '$label style');
  expect(after.color, before.color, reason: '$label colour');
  expect(after.letterSpacing, before.letterSpacing, reason: '$label spacing');
  expect(after.height, before.height, reason: '$label height');
  expect(after.decoration, before.decoration, reason: '$label decoration');
}

void main() {
  for (final entry in _themes.entries) {
    test('${entry.key}: every text style uses DM Sans', () {
      final theme = entry.value();
      for (final style in _textThemeStyles(theme.textTheme).entries) {
        expect(
          style.value?.fontFamily,
          appFontFamily,
          reason: 'textTheme.${style.key}',
        );
      }
      for (final style in _textThemeStyles(theme.primaryTextTheme).entries) {
        expect(
          style.value?.fontFamily,
          appFontFamily,
          reason: 'primaryTextTheme.${style.key}',
        );
      }
      var slotsChecked = 0;
      for (final slot in _slotStyles(theme).entries) {
        if (slot.value == null) continue; // not set → falls back to textTheme
        slotsChecked++;
        expect(slot.value!.fontFamily, appFontFamily, reason: slot.key);
      }
      // Every builder sets at least the chip label and the input hint.
      expect(slotsChecked, greaterThanOrEqualTo(2));
    });
  }

  test('withAppFont changes only the family', () {
    // A theme with every slot set, sizes/weights/colours/spacing chosen to be
    // distinct, run through the same helper the 10 builders use.
    const s = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Color(0xFF123456),
      letterSpacing: 0.4,
      height: 1.3,
      fontStyle: FontStyle.italic,
    );
    final before = ThemeData(
      useMaterial3: true,
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        bodySmall: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
      ),
      appBarTheme: const AppBarTheme(titleTextStyle: s, toolbarTextStyle: s),
      chipTheme: const ChipThemeData(labelStyle: s, secondaryLabelStyle: s),
      inputDecorationTheme: const InputDecorationTheme(
        hintStyle: s,
        labelStyle: s,
        floatingLabelStyle: s,
        helperStyle: s,
        errorStyle: s,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        selectedLabelStyle: s,
        unselectedLabelStyle: s,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        labelTextStyle: WidgetStatePropertyAll(s),
      ),
    );
    final after = AppTheme.withAppFont(before);
    final b = _textThemeStyles(before.textTheme);
    final a = _textThemeStyles(after.textTheme);
    for (final key in b.keys) {
      _expectSameExceptFamily(a[key], b[key], 'textTheme.$key');
    }
    final bs = _slotStyles(before);
    final as = _slotStyles(after);
    for (final key in bs.keys) {
      _expectSameExceptFamily(as[key], bs[key], key);
    }
  });
}
