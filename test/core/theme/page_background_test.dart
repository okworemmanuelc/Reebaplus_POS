// #351 — pageBackground must have exactly 2 gradient stops, both fully opaque,
// top = scaffoldBackgroundColor, bottom = AppSchemeColors.backgroundFade.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';

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

void main() {
  for (final entry in _themes.entries) {
    testWidgets(
      '${entry.key}: pageBackground has 2 opaque stops matching theme',
      (tester) async {
        late BoxDecoration decoration;
        final theme = entry.value();

        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Builder(
              builder: (context) {
                decoration = AppDecorations.pageBackground(context);
                return const SizedBox();
              },
            ),
          ),
        );

        final gradient = decoration.gradient;
        expect(
          gradient,
          isA<LinearGradient>(),
          reason: '${entry.key}: must be LinearGradient',
        );
        final linear = gradient! as LinearGradient;

        expect(
          linear.begin,
          Alignment.topCenter,
          reason: '${entry.key}: begin alignment',
        );
        expect(
          linear.end,
          Alignment.bottomCenter,
          reason: '${entry.key}: end alignment',
        );
        expect(
          linear.colors.length,
          2,
          reason: '${entry.key}: exactly 2 stops',
        );

        final topStop = linear.colors[0];
        final bottomStop = linear.colors[1];

        expect(
          topStop.a,
          1.0,
          reason: '${entry.key}: top stop must be fully opaque',
        );
        expect(
          bottomStop.a,
          1.0,
          reason: '${entry.key}: bottom stop must be fully opaque',
        );

        expect(
          topStop,
          theme.scaffoldBackgroundColor,
          reason: '${entry.key}: top stop == scaffoldBackgroundColor',
        );
        expect(
          bottomStop,
          theme.extension<AppSchemeColors>()!.backgroundFade,
          reason: '${entry.key}: bottom stop == backgroundFade',
        );
      },
    );
  }
}
