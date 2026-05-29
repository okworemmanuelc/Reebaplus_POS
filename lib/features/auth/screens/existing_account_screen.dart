import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/shared/services/auth_service.dart';
import 'package:reebaplus_pos/shared/utils/role_display.dart';

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
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CreatePinScreen(user: user),
        ),
      );
    } catch (e, stack) {
      debugPrint('[ExistingAccountScreen] syncOnLogin failed: $e\n$stack');
      if (!mounted) return;
      setState(() => _loading = false);
      final msg = e.toString().toLowerCase();
      final isNetwork = e is PartialPullException ||
          msg.contains('socketexception') ||
          msg.contains('failed host lookup') ||
          msg.contains('clientexception') ||
          msg.contains('timeoutexception');
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
    const textColor = adTextPrimary;

    return Scaffold(
      backgroundColor: adBg,
      body: BrandedAuthBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_ios,
                        color: textColor, size: 20),
                    onPressed: _loading
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Welcome back',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'We found an existing account for ${_maskEmail(widget.email)}.\nSelect a business to continue.',
                  style: TextStyle(
                    fontSize: 15,
                    color: textColor.withValues(alpha: 0.65),
                    height: 1.4,
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
      ),
    );
  }

  Widget _buildBusinessCard(
    BuildContext context, {
    required SupabaseAccountInfo account,
  }) {
    const textColor = adTextPrimary;
    const primary = amberPrimary;

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
                  child: const Icon(Icons.business_rounded,
                      color: primary, size: 26),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.businessName,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Builder(
                        builder: (context) {
                          final tagColor =
                              roleTagColor(widget.account.roleSlug);
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: tagColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              widget.account.roleName ?? 'Member',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: tagColor,
                              ),
                            ),
                          );
                        },
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
