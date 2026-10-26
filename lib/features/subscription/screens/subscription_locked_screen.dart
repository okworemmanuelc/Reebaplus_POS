import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/settings/subscription_screen.dart';
import 'package:reebaplus_pos/features/subscription/widgets/subscription_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
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

  // Opens Settings > Subscription (the Play Billing paywall). Reached from the
  // lock screen so a locked owner can pay without the app shell.
  void _openPlans() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SubscriptionScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fixed = theme.extension<AppFixedColors>() ?? AppFixedColors.light;

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

    return SubscriptionStateFrame(
      hero: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: IconTile(
              icon: AppIcons.lock,
              tone: IconTileTone.danger,
              size: 88,
            ),
          ),
          SizedBox(height: context.getRSize(28)),
          Text(
            title,
            textAlign: TextAlign.center,
            style: context
                .extraBoldStyle(26)
                .copyWith(color: theme.colorScheme.onSurface),
          ),
          SizedBox(height: context.getRSize(10)),
          Text(
            body,
            textAlign: TextAlign.center,
            style: context
                .regularStyle(15)
                .copyWith(
                  height: 1.45,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
          ),
          if (endedLine != null) ...[
            SizedBox(height: context.getRSize(14)),
            Text(
              endedLine,
              textAlign: TextAlign.center,
              style: context.semiBoldStyle(14).copyWith(color: fixed.danger),
            ),
          ],
        ],
      ),
      actions: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppButton(
            text: 'Subscribe',
            icon: AppIcons.premium,
            onPressed: _openPlans,
          ),
          SizedBox(height: context.getRSize(12)),
          AppButton(
            text: 'Sign out',
            variant: AppButtonVariant.ghost,
            onPressed: () => ref.read(authProvider).fullLogout(),
          ),
        ],
      ),
    );
  }
}
