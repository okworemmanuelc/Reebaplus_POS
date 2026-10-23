// Gallery goldens for the restyled auth parts (#462 PR 1): one small gallery
// per part, light and dark (Blue Classic), at a 390dp phone width, plus the
// BrandedAuthBackground at its default 480 cap and at a 720 cap on a wide
// canvas. Animations are frozen by pumping a fixed frame (no settle).
// The PNGs live in test/redesign/goldens/. Regenerate with:
//
//     flutter test --update-goldens test/redesign/auth_parts_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/onboarding_step_indicator.dart';
import 'package:reebaplus_pos/features/auth/widgets/otp_input.dart';
import 'package:reebaplus_pos/features/auth/widgets/pin_keypad.dart';

void main() {
  final galleries = <String, List<Widget> Function(BuildContext)>{
    'input_card': (context) => [
      const AuthInputCard(
        child: TextField(
          decoration: InputDecoration(
            labelText: 'Business name',
            hintText: 'Stallion Global',
          ),
        ),
      ),
      const AuthErrorText('That email is not valid.'),
    ],
    'step_indicator': (context) => [
      const OnboardingStepIndicator(
        currentStep: 1,
        totalSteps: 7,
        stepLabels: OnboardingStepIndicator.pathALabels,
      ),
      const OnboardingStepIndicator(
        currentStep: 4,
        totalSteps: 7,
        stepLabels: OnboardingStepIndicator.pathALabels,
      ),
      const OnboardingStepIndicator(
        currentStep: 7,
        totalSteps: 7,
        stepLabels: OnboardingStepIndicator.pathALabels,
      ),
    ],
    'pin_keypad': (context) => [
      const Center(child: PinDots(filled: 2)),
      Center(
        child: PinKeypad(onDigit: (_) {}, onBackspace: () {}),
      ),
    ],
    'otp_input': (context) {
      final onSurface = Theme.of(context).colorScheme.onSurface;
      return [
        OtpBoxRow(
          controller: TextEditingController(),
          hasError: false,
          ignorePointers: true,
          textColor: onSurface,
        ),
        OtpBoxRow(
          controller: TextEditingController(text: '4821'),
          hasError: false,
          ignorePointers: true,
          textColor: onSurface,
        ),
        OtpBoxRow(
          controller: TextEditingController(text: '482193'),
          hasError: true,
          ignorePointers: true,
          textColor: onSurface,
        ),
      ];
    },
    'autocomplete': (context) => [
      AutocompleteField(
        label: 'City',
        icon: AppIcons.location,
        initial: 'Lagos',
        options: const ['Lagos', 'Abuja'],
        onChanged: (_) {},
      ),
    ],
  };

  for (final name in galleries.keys) {
    for (final brightness in Brightness.values) {
      final themeName = brightness == Brightness.light ? 'light' : 'dark';
      testWidgets('auth parts gallery $name $themeName', (tester) async {
        tester.view.physicalSize = const Size(390, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: brightness == Brightness.light
                ? AppTheme.light()
                : AppTheme.dark(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: RepaintBoundary(
                  key: const Key('gallery'),
                  child: Builder(
                    builder: (context) => DecoratedBox(
                      decoration: AppDecorations.pageBackground(context),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final w in galleries[name]!(context)) ...[
                              w,
                              const SizedBox(height: 12),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // Past OtpBoxRow's 350ms focus timer; the step-dot pulse is frozen
        // at this frame.
        await tester.pump(const Duration(milliseconds: 400));

        await expectLater(
          find.byKey(const Key('gallery')),
          matchesGoldenFile('goldens/auth_parts_${name}_$themeName.png'),
        );
      });
    }
  }

  for (final cap in [480.0, 720.0]) {
    for (final brightness in Brightness.values) {
      final themeName = brightness == Brightness.light ? 'light' : 'dark';
      testWidgets('auth parts background ${cap.toInt()} $themeName', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: brightness == Brightness.light
                ? AppTheme.light()
                : AppTheme.dark(),
            home: Scaffold(
              body: BrandedAuthBackground(
                maxWidth: cap,
                child: Builder(
                  builder: (context) => Container(
                    height: 200,
                    decoration: AppDecorations.card(context),
                    alignment: Alignment.center,
                    child: Text('Content capped at ${cap.toInt()}'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await expectLater(
          find.byType(BrandedAuthBackground),
          matchesGoldenFile(
            'goldens/auth_parts_background_${cap.toInt()}_$themeName.png',
          ),
        );
      });
    }
  }
}
