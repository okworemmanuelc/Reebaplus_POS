import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/settings/screens/subscription_screen.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan_providers.dart';

/// Explains that adding a store / staff account / warehouse is over the plan's
/// limit and offers the plans screen. Shown both from the client pre-check and
/// when the server raises `plan_limit_*`.
Future<void> showPlanLimitDialog(
  BuildContext context,
  PlanLimitKind kind, {
  String? plan,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Plan limit reached'),
      content: Text(planLimitMessage(kind, plan: plan)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SubscriptionScreen(),
              ),
            );
          },
          child: const Text('See plans'),
        ),
      ],
    ),
  );
}

/// In-app trial reminder: shown at 7 days and 1 day before the trial ends,
/// naming the plan that keeps the current setup. Renders nothing otherwise.
class TrialReminderBanner extends ConsumerWidget {
  const TrialReminderBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(trialReminderProvider);
    if (r == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.tertiaryContainer,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const SubscriptionScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            trialReminderText(day: r.day, recommendedPlan: r.plan),
            style: t.textTheme.bodySmall?.copyWith(
              color: t.colorScheme.onTertiaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

/// Pure banner selection (#586). Over-limit beats plan-ended; null = no banner.
/// [hadPlan]: the business once had a trial or a paid period. A business that
/// started on Free (no trials, #587) has nothing that "ended", so no banner.
String? planStatusBannerText({
  required int pausedStaff,
  required int readOnlyShops,
  required SubscriptionAccess access,
  required bool hadPlan,
}) {
  if (pausedStaff > 0 || readOnlyShops > 0) {
    final parts = [
      if (pausedStaff > 0) '$pausedStaff staff paused',
      if (readOnlyShops > 0)
        '$readOnlyShops ${readOnlyShops == 1 ? 'shop' : 'shops'} read-only',
    ];
    return '${parts.join(' · ')} on your plan — Upgrade';
  }
  if (access.isFreeTier && hadPlan) {
    return "Your plan has ended — you're on Free. Upgrade to get more staff "
        'and shops.';
  }
  return null;
}

/// Owner-only banner: plan ended (on Free) or staff/shops over the plan limit.
/// Renders nothing otherwise. Tap opens [SubscriptionScreen].
class PlanStatusBanner extends ConsumerWidget {
  const PlanStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Gates.manageSettings.allows(ref)) return const SizedBox.shrink();
    final business = ref.watch(currentBusinessProvider);
    final text = planStatusBannerText(
      pausedStaff: ref.watch(pausedStaffIdsProvider).length,
      readOnlyShops: ref.watch(readOnlyStoreIdsProvider).length,
      access: ref.watch(currentBusinessSubscriptionProvider),
      hadPlan: business != null &&
          (business.trialEndsAt != null || business.currentPeriodEnd != null),
    );
    if (text == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.tertiaryContainer,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const SubscriptionScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            text,
            style: t.textTheme.bodySmall?.copyWith(
              color: t.colorScheme.onTertiaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}
