// Screen 1 — confirm role + business assignment.
//
// Shows what the inviter set up: business, role, warehouse (if any), inviter
// name. Read-only — if anything is wrong, user cancels and asks for a new
// invite. "Yes, this is correct" advances to SignupDetailsScreen.

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/features/auth/screens/signup_wizard/signup_wizard_data.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/onboarding_step_indicator.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

class SignupConfirmScreen extends StatelessWidget {
  final SignupWizardData data;
  final VoidCallback onContinue;
  final VoidCallback onCancel;

  const SignupConfirmScreen({
    super.key,
    required this.data,
    required this.onContinue,
    required this.onCancel,
  });

  String _roleLabel(String role) {
    switch (role) {
      case 'admin':
        return 'Admin';
      case 'manager':
        return 'Manager';
      case 'cashier':
        return 'Cashier';
      case 'driver':
        return 'Driver';
      case 'warehouse':
        return 'Warehouse';
      case 'staff':
      default:
        return 'Staff';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final preview = data.preview;

    return AuthBackground(
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const OnboardingStepIndicator(
                currentStep: 3,
                totalSteps: 7,
                stepLabels: OnboardingStepIndicator.pathBLabels,
              ),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  'Confirm your invitation',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  '${preview.inviterName} invited you to join.',
                  style: TextStyle(
                    fontSize: 15,
                    color: textColor.withValues(alpha: 0.7),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: AppDecorations.glassCard(context),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv(textColor, 'Business', preview.businessName),
                    const SizedBox(height: 16),
                    _kv(textColor, 'Role', _roleLabel(preview.role)),
                    if (preview.warehouseName != null) ...[
                      const SizedBox(height: 16),
                      _kv(textColor, 'Warehouse', preview.warehouseName!),
                    ],
                    const SizedBox(height: 16),
                    _kv(textColor, 'Email', preview.email),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              AppButton(text: 'Yes, this is correct', onPressed: onContinue),
              const SizedBox(height: 8),
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(Color textColor, String k, String v) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          k,
          style: TextStyle(
            fontSize: 12,
            color: textColor.withValues(alpha: 0.6),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          v,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
      ],
    );
  }
}
