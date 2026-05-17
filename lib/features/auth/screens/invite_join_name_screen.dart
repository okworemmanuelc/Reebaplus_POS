/// Post-OTP screen on the deep-link invite path.
///
/// Captures the invitee's name → calls [InviteApiService.redeemByToken]
/// (atomic profile + user insert + invite-accepted flip in one RPC) →
/// syncs cloud → local → pushes CreatePinScreen with the freshly-created
/// local user.
///
/// The manual-code fallback (InviteCodeScreen) routes to a similar
/// experience via [redeemByCode] — kept as a separate widget below.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/features/auth/widgets/onboarding_step_indicator.dart';
import 'package:reebaplus_pos/features/invite/services/invite_api_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

class InviteJoinNameScreen extends ConsumerStatefulWidget {
  /// Pass exactly one of [token], [code], or [humanCode]:
  ///   • [token]     — deep-link path (URL-safe long random)
  ///   • [code]      — 8-char legacy code
  ///   • [humanCode] — 6-char Phase-2 in-person code (no 0/O/1/I)
  final String? token;
  final String? code;
  final String? humanCode;
  final String email;

  const InviteJoinNameScreen({
    super.key,
    this.token,
    this.code,
    this.humanCode,
    required this.email,
  }) : assert(
          (token == null ? 0 : 1) +
                  (code == null ? 0 : 1) +
                  (humanCode == null ? 0 : 1) ==
              1,
          'Exactly one of token/code/humanCode must be provided',
        );

  @override
  ConsumerState<InviteJoinNameScreen> createState() =>
      _InviteJoinNameScreenState();
}

class _InviteJoinNameScreenState
    extends ConsumerState<InviteJoinNameScreen> {
  final _nameController = TextEditingController();
  bool _loading = false;
  bool _submitted = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitted) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      AppNotification.showError(context, 'Please enter your full name.');
      return;
    }

    setState(() => _loading = true);

    final api = ref.read(inviteApiServiceProvider);
    final auth = ref.read(authProvider);

    final InviteApiResult<Map<String, dynamic>> result;
    if (widget.token != null) {
      result = await api.redeemByToken(token: widget.token!, userName: name);
    } else if (widget.humanCode != null) {
      // STUB — full wizard rewrite (signup_wizard/) supplies the real
      // staff_phone / next_of_kin / guarantor fields. This single-screen
      // path is being deleted; the empty values exist only to keep the
      // tree compiling during the transition.
      result = await api.redeemByHumanCode(
        humanCode: widget.humanCode!,
        userName: name,
        staffPhone: '',
        nextOfKinName: '',
        nextOfKinPhone: '',
        nextOfKinRelation: '',
      );
    } else {
      result = await api.redeemByCode(code: widget.code!, userName: name);
    }

    if (!mounted) return;

    if (result is InviteApiErr<Map<String, dynamic>>) {
      setState(() => _loading = false);
      AppNotification.showError(context, result.message);
      return;
    }
    final data = (result as InviteApiOk<Map<String, dynamic>>).data;

    // Phase 1: redeem-invite now returns canonical {user, membership, invite}
    // (atomic accept_invite RPC). business_id lives on the membership row.
    final membership = data['membership'] as Map?;
    final businessId =
        membership?['business_id']?.toString() ?? data['business_id']?.toString();
    if (businessId == null || businessId.isEmpty) {
      setState(() => _loading = false);
      AppNotification.showError(
        context,
        'Server returned an unexpected response. Please retry.',
      );
      return;
    }

    // Seed local Drift directly from the RPC response so the user/membership
    // exist for the PIN screen even before the snapshot pull completes.
    try {
      final sync = ref.read(supabaseSyncServiceProvider);
      await sync.applyServerResponse('accept_invite', data);
    } catch (e) {
      debugPrint('[InviteJoinName] applyServerResponse failed: $e');
    }

    // Background pull for everything else this user can see (warehouses,
    // products, etc.). The user/membership are already locally seeded
    // above, so the PIN screen doesn't depend on this finishing.
    try {
      await auth.syncOnLogin(businessId);
      await auth.upsertLocalUserFromProfile();
    } catch (e) {
      debugPrint('[InviteJoinName] sync failed: $e');
    }

    final localUser = await auth.getUserByEmail(widget.email.toLowerCase());
    if (!mounted) return;

    if (localUser == null) {
      setState(() => _loading = false);
      AppNotification.showError(
        context,
        'Could not load your account locally. Please retry.',
      );
      return;
    }

    // Drop the pending token now that redemption succeeded — read-and-clear.
    auth.consumePendingInviteToken();
    _submitted = true;

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CreatePinScreen(user: localUser, isJoinFlow: true),
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
        child: SingleChildScrollView(
          padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const OnboardingStepIndicator(
                currentStep: 4,
                totalSteps: 6,
                stepLabels: OnboardingStepIndicator.pathBLabels,
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Welcome to the team',
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
                  'What is your full name?',
                  style: TextStyle(
                    fontSize: 15,
                    color: textColor.withValues(alpha: 0.7),
                  ),
                ),
              ),
              const SizedBox(height: 48),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: AppDecorations.glassCard(context),
                child: TextField(
                  controller: _nameController,
                  keyboardType: TextInputType.name,
                  textCapitalization: TextCapitalization.words,
                  autofocus: true,
                  style: TextStyle(color: textColor, fontSize: 18),
                  decoration: AppDecorations.authInputDecoration(
                    context,
                    label: 'Full Name',
                    prefixIcon: Icons.person_outline_rounded,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              AppButton(
                text: 'Continue',
                isLoading: _loading,
                onPressed: _loading ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
