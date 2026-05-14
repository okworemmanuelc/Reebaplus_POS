// Four-screen signup wizard orchestrator.
//
// Owns the SignupWizardData for one signup attempt and walks the user
// through:
//
//   1. SignupConfirmScreen   — preview business + role
//   2. SignupDetailsScreen   — name, staff phone
//   3. SignupContactsScreen  — next-of-kin (required) + guarantor (optional)
//   4. CreatePinScreen       — existing widget, isJoinFlow=true
//
// Redemption (InviteApiService.redeemByHumanCode) runs at the screens-3
// → 4 boundary — BEFORE pushing CreatePinScreen — so the user / membership
// rows exist locally by the time the PIN screen needs them. CreatePinScreen
// then dual-writes the PIN through AuthService.setUserPin (existing path).
//
// After CreatePinScreen completes, the home screen is reached via the
// existing post-PIN navigation; WelcomeVerificationModal is shown by the
// home screen on first visit (not by the orchestrator — keeps the
// orchestrator's lifetime bounded to the signup flow itself).
//
// Flow control: Navigator.push for forward steps, Navigator.pop for back.
// On Cancel from screen 1 the orchestrator pops back to InviteCodeScreen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/existing_account_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/signup_wizard/signup_confirm_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/signup_wizard/signup_contacts_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/signup_wizard/signup_details_screen.dart';
import 'package:reebaplus_pos/features/auth/screens/signup_wizard/signup_wizard_data.dart';
import 'package:reebaplus_pos/features/invite/services/invite_api_service.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

class SignupOrchestrator extends ConsumerStatefulWidget {
  final InvitePreview preview;
  final String humanCode;
  final String email;

  const SignupOrchestrator({
    super.key,
    required this.preview,
    required this.humanCode,
    required this.email,
  });

  @override
  ConsumerState<SignupOrchestrator> createState() => _SignupOrchestratorState();
}

class _SignupOrchestratorState extends ConsumerState<SignupOrchestrator> {
  late final SignupWizardData _data;
  // Reentry guard for the redemption RPC. The contacts screen also owns
  // a local _busy flag for its UI; this is belt-and-braces for the case
  // where some other path could call _redeemAndPushPin twice.
  bool _redeeming = false;

  @override
  void initState() {
    super.initState();
    _data = SignupWizardData(
      preview: widget.preview,
      humanCode: widget.humanCode,
      email: widget.email,
    );
  }

  void _toDetails() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SignupDetailsScreen(
        data: _data,
        onContinue: _toContacts,
        onBack: () => Navigator.of(context).pop(),
      ),
    ));
  }

  void _toContacts() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SignupContactsScreen(
        data: _data,
        // SignupContactsScreen awaits this — its own busy flag drives the
        // Continue button's loading state during redemption.
        onContinue: _redeemAndPushPin,
        onBack: () => Navigator.of(context).pop(),
      ),
    ));
  }

  /// Screens-3 → 4 boundary: redeem the invite (creates user + membership
  /// + writes wizard fields) before pushing CreatePinScreen.
  Future<void> _redeemAndPushPin() async {
    if (_redeeming) return;
    _redeeming = true;
    try {
      await _runRedeem();
    } finally {
      _redeeming = false;
    }
  }

  Future<void> _runRedeem() async {
    final api = ref.read(inviteApiServiceProvider);
    final auth = ref.read(authProvider);
    final sync = ref.read(supabaseSyncServiceProvider);

    final result = await api.redeemByHumanCode(
      humanCode: _data.humanCode,
      userName: _data.userName,
      staffPhone: _data.staffPhone,
      nextOfKinName: _data.nokName,
      nextOfKinPhone: _data.nokPhone,
      nextOfKinRelation: _data.nokRelation,
      guarantorName: _data.guarantorName,
      guarantorPhone: _data.guarantorPhone,
      guarantorRelation: _data.guarantorRelation,
    );

    if (!mounted) return;

    if (result is InviteApiErr<Map<String, dynamic>>) {
      AppNotification.showError(context, result.message);
      return;
    }
    final data = (result as InviteApiOk<Map<String, dynamic>>).data;

    final membership = data['membership'] as Map?;
    final businessId = membership?['business_id']?.toString();
    if (businessId == null || businessId.isEmpty) {
      AppNotification.showError(
        context,
        'Server returned an unexpected response. Please retry.',
      );
      return;
    }

    // Seed local Drift directly from the RPC response so user/membership
    // exist for the PIN screen even before any background pull completes.
    try {
      await sync.applyServerResponse('accept_invite', data);
    } catch (e) {
      debugPrint('[SignupOrchestrator] applyServerResponse failed: $e');
    }

    // Background pull for warehouses / products / etc. The PIN screen
    // doesn't depend on this finishing.
    try {
      await auth.syncOnLogin(businessId);
      await auth.upsertLocalUserFromProfile();
    } catch (e) {
      debugPrint('[SignupOrchestrator] sync failed: $e');
    }

    final localUser = await auth.getUserByEmail(widget.email.toLowerCase());
    if (!mounted) return;

    if (localUser == null) {
      // Post-server-success local-seed failure: the cloud has the user +
      // membership (we got InviteApiOk above with a real business_id),
      // but applyServerResponse and syncOnLogin both swallowed their
      // exceptions and getUserByEmail still returned null. Don't strand
      // the user on this screen — retrying redeem from here just hits
      // the same local-seed cliff. Pivot to ExistingAccountScreen which
      // is the canonical recovery path for "cloud has account, local
      // doesn't" — it retries syncOnLogin behind clean UI and routes to
      // PIN setup with the right copy. The invite is already consumed,
      // so this is a one-way redirect (pushAndRemoveUntil).
      auth.consumePendingInviteToken();
      final roleTier =
          (data['membership'] as Map?)?['role_tier'] as int? ?? 1;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => ExistingAccountScreen(
            email: widget.email,
            account: SupabaseAccountInfo(
              businessId: businessId,
              businessName: widget.preview.businessName,
              role: widget.preview.role,
              roleTier: roleTier,
            ),
          ),
        ),
        (route) => route.isFirst,
      );
      return;
    }

    auth.consumePendingInviteToken();

    if (!mounted) return;
    // Replace the orchestrator stack with CreatePinScreen — back-navigation
    // from PIN should NOT land on screen 3 (the invite is already accepted).
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => CreatePinScreen(user: localUser, isJoinFlow: true),
      ),
      (route) => route.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SignupConfirmScreen(
      data: _data,
      onContinue: _toDetails,
      onCancel: () => Navigator.of(context).pop(),
    );
  }
}
