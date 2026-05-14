// Screen 3 — next-of-kin (required) + guarantor (optional).
//
// On Continue this screen invokes the orchestrator's redemption call (an
// async callback). While that runs, the button shows a busy state and the
// form is disabled. The orchestrator handles error display via snackbar
// and navigates onward on success.

import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/features/auth/screens/signup_wizard/phone_validator.dart';
import 'package:reebaplus_pos/features/auth/screens/signup_wizard/signup_wizard_data.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/onboarding_step_indicator.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

const _nokRelations = ['Mother', 'Father', 'Spouse', 'Sibling', 'Child', 'Other'];
const _guarantorRelations = ['Employer', 'Mentor', 'Friend', 'Family', 'Other'];

class SignupContactsScreen extends StatefulWidget {
  final SignupWizardData data;

  /// Async — the orchestrator runs the redemption RPC inside. While the
  /// returned future is in flight, this screen disables its form and
  /// shows a loading state on the Continue button.
  final Future<void> Function() onContinue;
  final VoidCallback onBack;

  const SignupContactsScreen({
    super.key,
    required this.data,
    required this.onContinue,
    required this.onBack,
  });

  @override
  State<SignupContactsScreen> createState() => _SignupContactsScreenState();
}

class _SignupContactsScreenState extends State<SignupContactsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nokNameCtrl;
  late final TextEditingController _nokPhoneCtrl;
  String? _nokRelation;
  late final TextEditingController _gNameCtrl;
  late final TextEditingController _gPhoneCtrl;
  String? _gRelation;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final d = widget.data;
    // Live-write back to data on every change so back-navigation preserves
    // typing even when the user pops without tapping Continue.
    _nokNameCtrl = TextEditingController(text: d.nokName)
      ..addListener(() => d.nokName = _nokNameCtrl.text);
    _nokPhoneCtrl = TextEditingController(text: d.nokPhone)
      ..addListener(() => d.nokPhone = _nokPhoneCtrl.text);
    _nokRelation = d.nokRelation.isEmpty ? null : d.nokRelation;
    _gNameCtrl = TextEditingController(text: d.guarantorName ?? '')
      ..addListener(() {
        d.guarantorName =
            _gNameCtrl.text.isEmpty ? null : _gNameCtrl.text;
      });
    _gPhoneCtrl = TextEditingController(text: d.guarantorPhone ?? '')
      ..addListener(() {
        d.guarantorPhone =
            _gPhoneCtrl.text.isEmpty ? null : _gPhoneCtrl.text;
      });
    _gRelation = d.guarantorRelation;
  }

  @override
  void dispose() {
    _nokNameCtrl.dispose();
    _nokPhoneCtrl.dispose();
    _gNameCtrl.dispose();
    _gPhoneCtrl.dispose();
    super.dispose();
  }

  String? _validateRequired(String? raw) {
    final v = (raw ?? '').trim();
    if (v.isEmpty) return 'Required';
    return null;
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    if (_nokRelation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Pick your next-of-kin's relationship.")),
      );
      return;
    }

    final d = widget.data;
    d.nokName = _nokNameCtrl.text.trim();
    d.nokPhone = _nokPhoneCtrl.text.trim();
    d.nokRelation = _nokRelation!;

    final gName = _gNameCtrl.text.trim();
    final gPhone = _gPhoneCtrl.text.trim();
    // Guarantor trio is all-or-nothing — if any one is filled, all three
    // are required so the partial state isn't ambiguous on the server.
    final anyG = gName.isNotEmpty || gPhone.isNotEmpty || _gRelation != null;
    if (anyG) {
      if (gName.isEmpty || gPhone.isEmpty || _gRelation == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fill in all three guarantor fields, or leave them blank.'),
          ),
        );
        return;
      }
      d.guarantorName = gName;
      d.guarantorPhone = gPhone;
      d.guarantorRelation = _gRelation;
    } else {
      d.guarantorName = null;
      d.guarantorPhone = null;
      d.guarantorRelation = null;
    }

    setState(() => _busy = true);
    try {
      await widget.onContinue();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
          child: AbsorbPointer(
            absorbing: _busy,
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back, color: textColor),
                      onPressed: _busy ? null : widget.onBack,
                    ),
                  ]),
                  const OnboardingStepIndicator(
                    currentStep: 5,
                    totalSteps: 7,
                    stepLabels: OnboardingStepIndicator.pathBLabels,
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      'Emergency contacts',
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
                      "We'll only contact your next-of-kin in an emergency. "
                      'Your guarantor vouches for you. You can edit these later '
                      'from your profile.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: textColor.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _sectionHeader(textColor, 'Next of kin'),
                  const SizedBox(height: 12),
                  _glassField(
                    child: TextFormField(
                      controller: _nokNameCtrl,
                      textCapitalization: TextCapitalization.words,
                      style: TextStyle(color: textColor, fontSize: 16),
                      decoration: AppDecorations.authInputDecoration(
                        context,
                        label: "Full name",
                        prefixIcon: Icons.person_outline_rounded,
                      ),
                      validator: _validateRequired,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _glassField(
                    child: TextFormField(
                      controller: _nokPhoneCtrl,
                      keyboardType: TextInputType.phone,
                      style: TextStyle(color: textColor, fontSize: 16),
                      decoration: AppDecorations.authInputDecoration(
                        context,
                        label: 'Phone number',
                        prefixIcon: Icons.phone_outlined,
                      ),
                      validator: validatePhoneRequired,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _glassField(
                    child: DropdownButtonFormField<String>(
                      initialValue: _nokRelation,
                      style: TextStyle(color: textColor, fontSize: 16),
                      decoration: AppDecorations.authInputDecoration(
                        context,
                        label: 'Relationship',
                        prefixIcon: Icons.favorite_border,
                      ),
                      items: _nokRelations
                          .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                          .toList(),
                      onChanged: (v) => setState(() {
                        _nokRelation = v;
                        widget.data.nokRelation = v ?? '';
                      }),
                    ),
                  ),
                  const SizedBox(height: 28),
                  _sectionHeader(textColor, 'Guarantor (optional)'),
                  const SizedBox(height: 12),
                  _glassField(
                    child: TextFormField(
                      controller: _gNameCtrl,
                      textCapitalization: TextCapitalization.words,
                      style: TextStyle(color: textColor, fontSize: 16),
                      decoration: AppDecorations.authInputDecoration(
                        context,
                        label: 'Full name',
                        prefixIcon: Icons.person_outline_rounded,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _glassField(
                    child: TextFormField(
                      controller: _gPhoneCtrl,
                      keyboardType: TextInputType.phone,
                      style: TextStyle(color: textColor, fontSize: 16),
                      decoration: AppDecorations.authInputDecoration(
                        context,
                        label: 'Phone number',
                        prefixIcon: Icons.phone_outlined,
                      ),
                      validator: validatePhoneOptional,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _glassField(
                    child: DropdownButtonFormField<String>(
                      initialValue: _gRelation,
                      style: TextStyle(color: textColor, fontSize: 16),
                      decoration: AppDecorations.authInputDecoration(
                        context,
                        label: 'Relationship',
                        prefixIcon: Icons.handshake_outlined,
                      ),
                      items: _guarantorRelations
                          .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                          .toList(),
                      onChanged: (v) => setState(() {
                        _gRelation = v;
                        widget.data.guarantorRelation = v;
                      }),
                    ),
                  ),
                  const SizedBox(height: 32),
                  AppButton(
                    text: 'Continue',
                    isLoading: _busy,
                    onPressed: _busy ? null : _submit,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(Color textColor, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: textColor,
      ),
    );
  }

  Widget _glassField({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: AppDecorations.glassCard(context),
      child: child,
    );
  }
}
