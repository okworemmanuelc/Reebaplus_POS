import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/settings/screens/subscription_screen.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_constants.dart';
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

// TODO(#584): remove once no legacy trials remain
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

/// `businesses.billing_issue` values (#591, cloud 0235).
const String kBillingIssueGrace = 'grace';
const String kBillingIssueHold = 'hold';

/// Pure banner selection (#586, #591). Priority: a failed Play renewal
/// ([billingIssue] 'grace' / 'hold') beats over-limit, which beats plan-ended.
/// null = no banner. [plan] is the business's stored plan, named in the grace
/// text. [hadPlan]: the business once had a trial or a paid period. A business
/// that started on Free (no trials, #587) has nothing that "ended", so no
/// banner.
String? planStatusBannerText({
  required int pausedStaff,
  required int readOnlyShops,
  required SubscriptionAccess access,
  required bool hadPlan,
  String? billingIssue,
  String? plan,
}) {
  if (billingIssue == kBillingIssueGrace) {
    final keep = (plan == kPlanBasic || plan == kPlanPremium)
        ? planLabel(plan)
        : 'your plan';
    return "Your payment didn't go through — update it in Google Play to "
        'keep $keep.';
  }
  if (billingIssue == kBillingIssueHold) {
    return 'Your shop is on Free until payment is fixed.';
  }
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

/// Whether the banner offers **Fix payment** (a failed Play renewal) instead
/// of opening the plans screen.
bool planStatusBannerFixesPayment(String? billingIssue) =>
    billingIssue == kBillingIssueGrace || billingIssue == kBillingIssueHold;

/// Google Play's manage-subscription page (#591). Names the subscription when
/// the stored [plan] is a paid one (grace keeps it); on hold the plan is Free,
/// so it opens the subscriptions list instead. [packageName] empty = omitted.
String fixPaymentUrl({String? plan, required String packageName}) {
  final productId = switch (plan) {
    kPlanBasic => kProductBasic,
    kPlanPremium => kProductPremium,
    _ => null,
  };
  final query = {
    if (productId != null) 'sku': productId,
    if (packageName.isNotEmpty) 'package': packageName,
  };
  return Uri.https(
    'play.google.com',
    '/store/account/subscriptions',
    query.isEmpty ? null : query,
  ).toString();
}

Future<void> _openFixPayment(String? plan) async {
  var packageName = '';
  try {
    packageName = (await PackageInfo.fromPlatform()).packageName;
  } catch (_) {
    // No package info (tests / unsupported platform): open the general page.
  }
  try {
    await launchUrl(
      Uri.parse(fixPaymentUrl(plan: plan, packageName: packageName)),
      mode: LaunchMode.externalApplication,
    );
  } catch (e) {
    debugPrint('[Billing] open Play subscriptions failed: $e');
  }
}

/// Owner-only banner: failed Play renewal (grace / hold, with **Fix payment**),
/// staff/shops over the plan limit, or plan ended (on Free). Renders nothing
/// otherwise. The plan banners open [SubscriptionScreen] on tap.
class PlanStatusBanner extends ConsumerWidget {
  const PlanStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Gates.manageSettings.allows(ref)) return const SizedBox.shrink();
    final business = ref.watch(currentBusinessProvider);
    final billingIssue = business?.billingIssue;
    final text = planStatusBannerText(
      pausedStaff: ref.watch(pausedStaffIdsProvider).length,
      readOnlyShops: ref.watch(readOnlyStoreIdsProvider).length,
      access: ref.watch(currentBusinessSubscriptionProvider),
      hadPlan: business != null &&
          (business.trialEndsAt != null || business.currentPeriodEnd != null),
      billingIssue: billingIssue,
      plan: business?.subscriptionPlan,
    );
    if (text == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    if (planStatusBannerFixesPayment(billingIssue)) {
      return Material(
        color: t.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.onErrorContainer,
                  ),
                ),
              ),
              TextButton(
                key: const Key('plan-status-fix-payment'),
                onPressed: () =>
                    _openFixPayment(business?.subscriptionPlan),
                style: TextButton.styleFrom(
                  foregroundColor: t.colorScheme.onErrorContainer,
                ),
                child: const Text('Fix payment'),
              ),
            ],
          ),
        ),
      );
    }
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
