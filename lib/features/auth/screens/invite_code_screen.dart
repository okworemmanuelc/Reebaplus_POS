import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/features/auth/screens/signup_wizard/signup_orchestrator.dart';
import 'package:reebaplus_pos/features/auth/widgets/onboarding_step_indicator.dart';
import 'package:reebaplus_pos/features/invite/services/invite_api_service.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';

class InviteCodeScreen extends ConsumerStatefulWidget {
  final String email;

  const InviteCodeScreen({super.key, required this.email});

  @override
  ConsumerState<InviteCodeScreen> createState() => _InviteCodeScreenState();
}

class _InviteCodeScreenState extends ConsumerState<InviteCodeScreen> {
  final _codeController = TextEditingController();
  bool _loading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _codeController.addListener(() {
      if (_errorMessage != null) {
        setState(() => _errorMessage = null);
      }
      // Auto-submit on a complete code. Rev 3: only 8-char human_code is
      // accepted; the legacy 6-char form was revoked in migration 0025
      // and the 8-char `code` column is no longer user-facing.
      final raw = _codeController.text.trim().toUpperCase();
      final isComplete =
          raw.length == 8 && RegExp(r'^[A-Z0-9]+$').hasMatch(raw);
      if (isComplete && !_loading) {
        _submit();
      }
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _pasteCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      _codeController.text = data.text!;
      setState(() => _errorMessage = null);
    }
  }

  Future<void> _submit() async {
    String code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _errorMessage = 'Please enter an invite code.');
      return;
    }

    if (code.contains('code=')) {
      code = code.split('code=')[1].split('&')[0];
    }

    code = code.trim().toUpperCase();

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    final api = ref.read(inviteApiServiceProvider);
    final result = await api.previewByHumanCode(code);

    if (!mounted) return;

    if (result is InviteApiErr<Map<String, dynamic>>) {
      setState(() {
        _loading = false;
        _errorMessage = result.message;
      });
      return;
    }

    setState(() => _loading = false);

    final preview = InvitePreview.fromMap(
      (result as InviteApiOk<Map<String, dynamic>>).data,
    );

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SignupOrchestrator(
          preview: preview,
          humanCode: code,
          email: widget.email,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

    return AuthBackground(
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const OnboardingStepIndicator(
                  currentStep: 2,
                  totalSteps: 7,
                  stepLabels: OnboardingStepIndicator.pathBLabels,
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    'Join Business',
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
                    'Enter the invite code shared by your manager.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: textColor.withValues(alpha: 0.7),
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 48),

                Container(
                  decoration: AppDecorations.glassCard(context).copyWith(
                    border: Border.all(
                      color: _errorMessage != null
                          ? Colors.redAccent.withValues(alpha: 0.5)
                          : textColor.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _codeController,
                          textCapitalization: TextCapitalization.characters,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 18,
                            letterSpacing: 2.0,
                            fontWeight: FontWeight.bold,
                          ),
                          onChanged: (_) {
                            if (_errorMessage != null) {
                              setState(() => _errorMessage = null);
                            }
                          },
                          onSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            hintText: '8-char code',
                            hintStyle: TextStyle(
                              color: textColor.withValues(alpha: 0.3),
                              letterSpacing: 2.0,
                            ),
                            prefixIcon: Icon(
                              Icons.vpn_key_rounded,
                              color: textColor.withValues(alpha: 0.7),
                            ),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: TextButton.icon(
                          onPressed: _pasteCode,
                          icon: const Icon(Icons.paste_rounded, size: 18),
                          label: const Text('Paste'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        color: Colors.redAccent,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 48),

                AppButton(
                  text: 'Verify Code',
                  isLoading: _loading,
                  onPressed: _loading ? null : _submit,
                ),

                const SizedBox(height: 16),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Go Back',
                      style: TextStyle(color: textColor.withValues(alpha: 0.6)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
