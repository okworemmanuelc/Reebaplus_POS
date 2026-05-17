import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';

/// Shown after OTP verification on a fresh device when the email already has
/// a Supabase account. Lists the linked business + role so the user can
/// confirm before setting up a new device PIN.
class ExistingAccountScreen extends ConsumerStatefulWidget {
  final String email;
  final SupabaseAccountInfo account;

  const ExistingAccountScreen({
    super.key,
    required this.email,
    required this.account,
  });

  @override
  ConsumerState<ExistingAccountScreen> createState() =>
      _ExistingAccountScreenState();
}

class _ExistingAccountScreenState extends ConsumerState<ExistingAccountScreen> {
  bool _loading = false;

  String _maskEmail(String email) {
    if (!email.contains('@')) return email;
    final parts = email.split('@');
    final name = parts[0];
    final domain = parts[1];
    if (name.length <= 2) return '${name.substring(0, 1)}**@$domain';
    return '${name.substring(0, 2)}**@$domain';
  }

  Future<void> _onContinue() async {
    if (_loading) return;
    setState(() => _loading = true);
    final auth = ref.read(authProvider);
    try {
      await auth.syncOnLogin(widget.account.businessId);
      final user = await auth.upsertLocalUserFromProfile();
      if (!mounted) return;
      if (user == null) {
        setState(() => _loading = false);
        AppNotification.showError(
          context,
          'Could not load your account. Please try again.',
        );
        return;
      }
      // A staff member whose business_members row has no pin_hash hasn't
      // finished onboarding yet (most common cause: the wizard's
      // post-redeem local-seed failed last time and the orchestrator
      // bounced them here). Frame the PIN screen as "set up", not "reset"
      // — same screen, different copy via isJoinFlow.
      final db = ref.read(databaseProvider);
      final member = await (db.select(db.businessMembers)
            ..where((m) => m.userId.equals(user.id))
            ..limit(1))
          .getSingleOrNull();
      final needsInitialSetup =
          member == null || member.pinHash == null;
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CreatePinScreen(
            user: user,
            isJoinFlow: needsInitialSetup,
          ),
        ),
      );
    } catch (e, stack) {
      debugPrint('[ExistingAccountScreen] syncOnLogin failed: $e\n$stack');
      if (!mounted) return;
      setState(() => _loading = false);
      final msg = e.toString().toLowerCase();
      final isNetwork =
          msg.contains('socketexception') ||
          msg.contains('failed host lookup') ||
          msg.contains('clientexception');
      AppNotification.showError(
        context,
        isNetwork
            ? 'Sync failed. Check your connection.'
            : "Couldn't load your business. Please try again.",
      );
    }
  }

  Future<void> _onCreateNew() async {
    if (_loading) return;
    // Capture provider up front — this method awaits a dialog then a
    // fullLogout, and `ref` is invalidated the moment the element is
    // unmounted (BEFORE State.mounted flips). See plan §"Bug fix"
    // Pattern 1.
    final auth = ref.read(authProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create a new business?'),
        content: Text(
          'Your email is already linked to ${widget.account.businessName}. '
          'To set up a new business, you’ll be signed out so you can register '
          'with a different email.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign out & continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _loading = true);
    await auth.fullLogout();
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

    return AuthBackground(
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: Icon(Icons.arrow_back_ios, color: textColor, size: 20),
                  onPressed: _loading
                      ? null
                      : () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Image.asset(
                  'assets/images/reebaplus_logo.png',
                  height: 90,
                  color: isDark ? null : theme.colorScheme.primary,
                  errorBuilder: (_, __, ___) =>
                      Icon(Icons.storefront, size: 90, color: textColor),
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  'Welcome back',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'We found an existing account for ${_maskEmail(widget.email)}.\nSelect a business to continue.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: textColor.withValues(alpha: 0.7),
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 36),

              _buildBusinessCard(context, account: widget.account),

              const SizedBox(height: 28),

              Center(
                child: TextButton(
                  onPressed: _loading ? null : _onCreateNew,
                  child: Text(
                    'Create a new business instead',
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.75),
                      fontSize: 14,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBusinessCard(
    BuildContext context, {
    required SupabaseAccountInfo account,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final primary = theme.colorScheme.primary;

    return Container(
      decoration: AppDecorations.glassCard(context, radius: 20),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _loading ? null : _onContinue,
          borderRadius: BorderRadius.circular(20),
          highlightColor: textColor.withValues(alpha: 0.05),
          splashColor: textColor.withValues(alpha: 0.1),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.business_rounded, color: primary, size: 26),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.businessName,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          account.role,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _loading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: textColor.withValues(alpha: 0.5),
                        ),
                      )
                    : Icon(
                        Icons.chevron_right,
                        color: textColor.withValues(alpha: 0.3),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
