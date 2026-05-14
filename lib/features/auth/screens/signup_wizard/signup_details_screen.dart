// Screen 2 — full name + staff phone.
//
// Both fields required. Phone validated with Nigerian mobile regex.
// Pre-fills name from data.userName if the orchestrator was seeded with one.

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/features/auth/screens/signup_wizard/phone_validator.dart';
import 'package:reebaplus_pos/features/auth/screens/signup_wizard/signup_wizard_data.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/onboarding_step_indicator.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

class SignupDetailsScreen extends StatefulWidget {
  final SignupWizardData data;
  final VoidCallback onContinue;
  final VoidCallback onBack;

  const SignupDetailsScreen({
    super.key,
    required this.data,
    required this.onContinue,
    required this.onBack,
  });

  @override
  State<SignupDetailsScreen> createState() => _SignupDetailsScreenState();
}

class _SignupDetailsScreenState extends State<SignupDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.data.userName)
      ..addListener(() => widget.data.userName = _nameCtrl.text);
    _phoneCtrl = TextEditingController(text: widget.data.staffPhone)
      ..addListener(() => widget.data.staffPhone = _phoneCtrl.text);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  String? _validateName(String? raw) {
    final v = (raw ?? '').trim();
    if (v.isEmpty) return 'Required';
    if (v.length < 2) return 'Use your full name';
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    // Trim once on submit. The listeners keep the live (untrimmed) text in
    // data so back-navigation re-fills the field exactly as typed; the
    // canonical value goes in only as we leave the screen.
    widget.data.userName = _nameCtrl.text.trim();
    widget.data.staffPhone = _phoneCtrl.text.trim();
    widget.onContinue();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

    return AuthBackground(
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back, color: textColor),
                    onPressed: widget.onBack,
                  ),
                ]),
                const OnboardingStepIndicator(
                  currentStep: 4,
                  totalSteps: 7,
                  stepLabels: OnboardingStepIndicator.pathBLabels,
                ),
                const SizedBox(height: 24),
                Center(
                  child: Text(
                    'Tell us about you',
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
                    'Your name and a phone number we can reach you on.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: textColor.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: AppDecorations.glassCard(context),
                  child: TextFormField(
                    controller: _nameCtrl,
                    keyboardType: TextInputType.name,
                    textCapitalization: TextCapitalization.words,
                    style: TextStyle(color: textColor, fontSize: 18),
                    decoration: AppDecorations.authInputDecoration(
                      context,
                      label: 'Full name',
                      prefixIcon: Icons.person_outline_rounded,
                    ),
                    validator: _validateName,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: AppDecorations.glassCard(context),
                  child: TextFormField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    style: TextStyle(color: textColor, fontSize: 18),
                    decoration: AppDecorations.authInputDecoration(
                      context,
                      label: 'Your phone number',
                      prefixIcon: Icons.phone_outlined,
                    ),
                    validator: validatePhoneRequired,
                  ),
                ),
                const SizedBox(height: 32),
                AppButton(text: 'Continue', onPressed: _submit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
