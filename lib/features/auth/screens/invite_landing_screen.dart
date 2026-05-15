/// Destination of the deep link `reebaplus://invite?token=...`.
///
/// Calls [InviteApiService.previewByToken] (anon-callable RPC) so the
/// invitee sees the business / role / warehouse / inviter / expiry BEFORE
/// signing in. On Continue, sets [AuthService.pendingInviteToken] and
/// pushes [EmailEntryScreen] with the invite email prefilled and locked.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/features/auth/screens/email_entry_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/features/invite/services/invite_api_service.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

class InviteLandingScreen extends ConsumerStatefulWidget {
  final String token;

  const InviteLandingScreen({super.key, required this.token});

  @override
  ConsumerState<InviteLandingScreen> createState() =>
      _InviteLandingScreenState();
}

class _InviteLandingScreenState extends ConsumerState<InviteLandingScreen> {
  _Phase _phase = _Phase.loading;
  InvitePreview? _preview;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(inviteApiServiceProvider);
    final result = await api.previewByToken(widget.token);
    if (!mounted) return;
    switch (result) {
      case InviteApiOk(:final data):
        setState(() {
          _preview = InvitePreview.fromMap(data);
          _phase = _Phase.preview;
        });
      case InviteApiErr(:final message):
        setState(() {
          _errorMessage = message;
          _phase = _Phase.error;
        });
    }
  }

  Future<void> _continue() async {
    final preview = _preview;
    if (preview == null) return;
    final auth = ref.read(authProvider);
    final supabaseAuth = Supabase.instance.client.auth;

    // If already signed in as a different email, fully sign out first so
    // the upcoming OTP creates the correct session. Preserve the invite
    // token across the logout — it's the whole reason we logged out.
    final currentUser = supabaseAuth.currentUser;
    if (currentUser != null &&
        currentUser.email?.toLowerCase() != preview.email.toLowerCase()) {
      auth.setPendingInviteToken(widget.token);
      await auth.fullLogout(preserveInviteToken: true);
    } else {
      auth.setPendingInviteToken(widget.token);
    }

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => EmailEntryScreen(
          prefilledEmail: preview.email,
          lockedEmail: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuthBackground(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_phase) {
            _Phase.loading => const Center(child: CircularProgressIndicator()),
            _Phase.error => _buildError(context),
            _Phase.preview => _buildPreview(context, _preview!),
          },
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_off_rounded,
              size: 64, color: textColor.withValues(alpha: 0.4)),
          const SizedBox(height: 24),
          Text(
            "Couldn't open this invite",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _errorMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 32),
          AppButton(
            text: 'Open app home',
            onPressed: () =>
                Navigator.of(context).popUntil((r) => r.isFirst),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview(BuildContext context, InvitePreview preview) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final daysLeft = preview.expiresAt.difference(DateTime.now()).inDays;
    final hoursLeft = preview.expiresAt.difference(DateTime.now()).inHours;
    final expiryText = daysLeft >= 1
        ? 'Expires in $daysLeft day${daysLeft == 1 ? '' : 's'}'
        : 'Expires in ${hoursLeft.clamp(0, 48)} hour${hoursLeft == 1 ? '' : 's'}';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Center(
            child: Icon(
              Icons.mail_lock_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            "You've been invited",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'to join ${preview.businessName}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: AppDecorations.glassCard(context, radius: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _row(context, Icons.badge_rounded, 'Role',
                    _humanRole(preview.role),
                    isHighlight: true),
                Divider(
                    color: textColor.withValues(alpha: 0.1), height: 28),
                _row(context, Icons.warehouse_rounded, 'Warehouse',
                    preview.warehouseName ?? 'Unassigned'),
                Divider(
                    color: textColor.withValues(alpha: 0.1), height: 28),
                _row(context, Icons.email_outlined, 'Invited at',
                    preview.email),
                Divider(
                    color: textColor.withValues(alpha: 0.1), height: 28),
                _row(context, Icons.person_rounded, 'Invited by',
                    preview.inviterName),
                Divider(
                    color: textColor.withValues(alpha: 0.1), height: 28),
                _row(context, Icons.schedule_rounded, 'Expiry', expiryText),
              ],
            ),
          ),
          const SizedBox(height: 32),
          AppButton(text: 'Continue', onPressed: _continue),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () =>
                  Navigator.of(context).popUntil((r) => r.isFirst),
              child: Text(
                "This isn't me",
                style: TextStyle(
                  color: textColor.withValues(alpha: 0.6),
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String label,
    String value, {
    bool isHighlight = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final primary = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Icon(icon, color: textColor.withValues(alpha: 0.5), size: 20),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: textColor.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight:
                      isHighlight ? FontWeight.bold : FontWeight.w500,
                  color: isHighlight ? primary : textColor,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _humanRole(String role) {
    switch (role.toLowerCase()) {
      case 'ceo':
        return 'CEO';
      case 'manager':
        return 'Manager';
      case 'stock_keeper':
        return 'Stock Keeper';
      case 'cashier':
        return 'Cashier';
      case 'rider':
        return 'Rider';
      default:
        return role.replaceAll('_', ' ').toUpperCase();
    }
  }
}

enum _Phase { loading, error, preview }
