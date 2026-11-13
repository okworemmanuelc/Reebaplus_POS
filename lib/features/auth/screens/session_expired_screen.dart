import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart'
    show authTextPrimary, authTextMuted;
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/auth/screens/otp_verification_screen.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_form_kit.dart';
import 'package:reebaplus_pos/features/auth/widgets/branded_auth_background.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Opened from `SignInAgainBanner` when a signed-in device has no cloud login
/// (#798). Sends a fresh code to the user's email so the login comes back
/// without wiping anything on the device.
///
/// It never blocks the app: [onNotNow], when given, shows a "Not now" way
/// back to selling. An accepted code returns to the app and catches up.
class SessionExpiredScreen extends ConsumerStatefulWidget {
  final UserData user;
  final VoidCallback? onNotNow;
  const SessionExpiredScreen({super.key, required this.user, this.onNotNow});

  @override
  ConsumerState<SessionExpiredScreen> createState() =>
      _SessionExpiredScreenState();
}

class _SessionExpiredScreenState extends ConsumerState<SessionExpiredScreen> {
  bool _sending = false;

  Future<void> _resendOtp() async {
    final email = widget.user.email;
    if (email == null || email.isEmpty) {
      AppNotification.showError(
        context,
        'No email on file for this account. Please sign out and start over.',
      );
      return;
    }
    setState(() => _sending = true);
    final auth = ref.read(authProvider);
    final error = await auth.sendOtp(email);
    if (!mounted) return;
    setState(() => _sending = false);
    if (error != null) {
      AppNotification.showError(context, error);
      return;
    }
    // The user is already signed in on this device, so an accepted code only
    // has to bring the cloud login back: return to the app and catch up.
    final navigator = Navigator.of(context, rootNavigator: true);
    final sync = ref.read(supabaseSyncServiceProvider);
    final businessId = widget.user.businessId;
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => OtpVerificationScreen(
          user: widget.user,
          email: email,
          onVerified: () {
            navigator.popUntil((route) => route.isFirst);
            unawaited(
              sync.pushThenPull(businessId).catchError((Object e) {
                debugPrint('[SessionExpired] catch-up after sign-in: $e');
              }),
            );
          },
        ),
      ),
    );
  }

  Future<void> _signOut() async {
    await ref.read(authProvider).fullLogout();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = authTextPrimary(context);
    final email = widget.user.email ?? '';

    return Scaffold(
      body: BrandedAuthBackground(
        child: SafeArea(
          // Centred and scrollable: it fits a phone sideways and a big text
          // size by scrolling, never by overflowing.
          child: AuthCenteredScroll(
            padding: context.rPaddingSymmetric(horizontal: 28, vertical: 32),
            children: [
              Icon(
                AppIcons.lockClock,
                size: context.getRSize(72),
                color: theme.colorScheme.primary,
              ),
              SizedBox(height: context.getRSize(20)),
              Text(
                'Session expired',
                textAlign: TextAlign.center,
                style: context.boldStyle(26).copyWith(color: textColor),
              ),
              SizedBox(height: context.getRSize(12)),
              Text(
                email.isEmpty
                    ? "Your sign-in has expired. Verify your email to keep your changes syncing."
                    : "Your sign-in has expired. We'll send a code to $email to restore your session — your local data stays intact.",
                textAlign: TextAlign.center,
                style: context
                    .regularStyle(14)
                    .copyWith(height: 1.4, color: authTextMuted(context, 0.75)),
              ),
              SizedBox(height: context.getRSize(32)),
              AppButton(
                text: _sending ? 'Sending…' : 'Verify email',
                onPressed: _sending ? null : _resendOtp,
              ),
              if (widget.onNotNow != null) ...[
                SizedBox(height: context.getRSize(12)),
                TextButton(
                  key: const Key('session-expired-not-now'),
                  onPressed: _sending ? null : widget.onNotNow,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, kMinInteractiveDimension),
                  ),
                  child: Text(
                    'Not now',
                    style: context
                        .mediumStyle(14)
                        .copyWith(color: authTextMuted(context)),
                  ),
                ),
              ],
              SizedBox(height: context.getRSize(12)),
              TextButton(
                onPressed: _sending ? null : _signOut,
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, kMinInteractiveDimension),
                ),
                child: Text(
                  'Sign out instead',
                  style: context
                      .mediumStyle(14)
                      .copyWith(color: authTextMuted(context)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
