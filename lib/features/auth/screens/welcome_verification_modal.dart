// Welcome modal shown once after a fresh staff signup completes.
// Full-screen, single "Got it" button. Persists nothing — the daily
// home-screen banner takes over from here.

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

class WelcomeVerificationModal extends StatelessWidget {
  final VoidCallback onDismiss;

  const WelcomeVerificationModal({super.key, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final primary = theme.colorScheme.primary;

    return AuthBackground(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(Icons.verified_outlined, size: 80, color: primary),
              const SizedBox(height: 20),
              Text(
                'Welcome aboard',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'You have 14 days to upload your verification documents. '
                "We'll remind you on the home screen each day until then.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: textColor.withValues(alpha: 0.7),
                  height: 1.5,
                ),
              ),
              const Spacer(),
              AppButton(text: 'Got it', onPressed: onDismiss),
            ],
          ),
        ),
      ),
    );
  }
}
