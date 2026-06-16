import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/auth/widgets/auth_background.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Full-screen lock shown when a business's subscription has expired (master
/// plan §32): the free trial ended ([SubscriptionAccess.trialExpired]) or the
/// status is [SubscriptionAccess.inactive]. Returned from main.dart's home()
/// gate in place of the app shell, so it replaces the whole app until the
/// subscription is reactivated from the admin console.
///
/// There is no in-app payment yet — reactivation happens in the console. "Check
/// again" re-pulls the businesses row from the cloud (covering the case where a
/// just-made console change hasn't synced to this device), then re-evaluates the
/// gate; once the cloud says `active` the gate unlocks automatically.
class SubscriptionLockedScreen extends ConsumerStatefulWidget {
  final SubscriptionAccess access;

  const SubscriptionLockedScreen({super.key, required this.access});

  @override
  ConsumerState<SubscriptionLockedScreen> createState() =>
      _SubscriptionLockedScreenState();
}

class _SubscriptionLockedScreenState
    extends ConsumerState<SubscriptionLockedScreen> {
  bool get _isTrial => widget.access == SubscriptionAccess.trialExpired;

  // In-app payment isn't built yet (§32.2) — reactivation happens in the admin
  // console and this screen unlocks on its own (realtime + the 60s re-pull in
  // main.dart). Until Paystack lands, "Subscribe" explains that.
  void _showSubscribeInfo() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Subscribe'),
        content: const Text(
          'In-app payment is coming soon. For now, your Reebaplus subscription '
          'is renewed from the admin console — reach out to renew. Once it has '
          'been renewed, this screen unlocks automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final lockColor = theme.colorScheme.error;

    final business = ref.watch(currentBusinessProvider);
    final trialEnded = business?.trialEndsAt;
    final endedLine = (_isTrial && trialEnded != null)
        ? 'Your free trial ended on ${DateFormat('d MMM yyyy').format(trialEnded)}.'
        : null;

    final title = _isTrial
        ? 'Your free trial has ended'
        : 'Subscription inactive';
    final body = _isTrial
        ? 'Subscribe to the Reebaplus monthly plan to keep using the app. '
              'All your data is safe and will be here when you return.'
        : 'This business\'s subscription is currently inactive. Renew to '
              'continue — your data is safe and waiting.';

    return AuthBackground(
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 64,
                ),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Spacer(),
                      Center(
                        child: Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: lockColor.withValues(alpha: 0.12),
                            border: Border.all(
                              color: lockColor.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Icon(
                            Icons.lock_rounded,
                            color: lockColor,
                            size: 46,
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        body,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.45,
                          color: textColor.withValues(alpha: 0.7),
                        ),
                      ),
                      if (endedLine != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          endedLine,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: lockColor,
                          ),
                        ),
                      ],
                      const Spacer(),
                      const SizedBox(height: 28),
                      AppButton(
                        text: 'Subscribe',
                        icon: Icons.workspace_premium_rounded,
                        onPressed: _showSubscribeInfo,
                      ),
                      const SizedBox(height: 12),
                      AppButton(
                        text: 'Sign out',
                        variant: AppButtonVariant.ghost,
                        onPressed: () => ref.read(authProvider).fullLogout(),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
