import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/features/auth/screens/create_pin_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
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
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => CreatePinScreen(user: user)),
      );
    } catch (e, stack) {
      debugPrint('[ExistingAccountScreen] syncOnLogin failed: $e\n$stack');
      if (!mounted) return;
      setState(() => _loading = false);
      final msg = e.toString().toLowerCase();
      final isNetwork =
          e is PartialPullException ||
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

  Future<void> _onUseDifferentEmail() async {
    if (_loading) return;
    // Capture provider up front — this method awaits a dialog then a
    // fullLogout, and `ref` is invalidated the moment the element is
    // unmounted (BEFORE State.mounted flips). See plan §"Bug fix"
    // Pattern 1.
    final auth = ref.read(authProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Sign out?',
          style: ctx.extraBoldStyle(18).copyWith(color: authTextPrimary(ctx)),
        ),
        content: Text(
          'Each email is linked to one business. '
          'To sign in with a different account, you\'ll be signed out.',
          style: ctx
              .regularStyle(14)
              .copyWith(color: authTextPrimary(ctx), height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign out'),
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
    final textColor = authTextPrimary(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: BrandedAuthBackground(
        child: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  icon: Icon(AppIcons.arrowBackIos, color: textColor, size: 20),
                  onPressed: _loading
                      ? null
                      : () => Navigator.of(context).pop(),
                ),
              ),
              AuthCenteredScroll(
                children: [
                  Text(
                    'Welcome back',
                    style: context
                        .extraBoldStyle(28)
                        .copyWith(color: textColor),
                  ),
                  SizedBox(height: context.getRSize(8)),
                  Text(
                    'We found an existing account for ${_maskEmail(widget.email)}. Tap below to continue.',
                    style: context
                        .regularStyle(15)
                        .copyWith(color: authTextMuted(context), height: 1.4),
                  ),
                  SizedBox(height: context.getRSize(32)),

                  _buildBusinessCard(context, account: widget.account),

                  SizedBox(height: context.getRSize(24)),

                  Center(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(
                          kMinInteractiveDimension,
                          kMinInteractiveDimension,
                        ),
                      ),
                      onPressed: _loading ? null : _onUseDifferentEmail,
                      child: Text(
                        'Use a different email instead',
                        style: context
                            .semiBoldStyle(14)
                            .copyWith(
                              color: authTextMuted(context, 0.75),
                              decoration: TextDecoration.underline,
                            ),
                      ),
                    ),
                  ),
                ],
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
    final textColor = authTextPrimary(context);
    final radius = BorderRadius.circular(context.getRSize(16));

    return Container(
      decoration: AppDecorations.card(context, radius: context.getRSize(16)),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _loading ? null : _onContinue,
          borderRadius: radius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(16)),
              child: Row(
                children: [
                  const IconTile(icon: AppIcons.business),
                  SizedBox(width: context.getRSize(14)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          account.businessName,
                          style: context
                              .boldStyle(17)
                              .copyWith(color: textColor),
                        ),
                        SizedBox(height: context.getRSize(6)),
                        TagPill(
                          label: widget.account.roleName ?? 'Member',
                          tone: _roleTone(widget.account.roleSlug),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  _loading
                      ? SizedBox(
                          width: context.getRSize(20),
                          height: context.getRSize(20),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: authTextMuted(context, 0.5),
                          ),
                        )
                      : Icon(
                          AppIcons.chevronRight,
                          color: authTextMuted(context, 0.4),
                        ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Role -> fixed tag tone (replaces the old per-role raw colours).
  TagPillTone _roleTone(String? slug) => switch (slug) {
    'ceo' || 'manager' => TagPillTone.info,
    'cashier' => TagPillTone.green,
    _ => TagPillTone.neutral,
  };
}
