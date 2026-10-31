import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_constants.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_controller.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_port.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan.dart';

/// True only on the Android app, where Google Play Billing exists.
final billingSupportedProvider = Provider<bool>(
  (_) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
);

final playBillingPortProvider = Provider<PlayBillingPort>(
  (_) => InAppPurchasePort(),
);

final purchaseVerifierProvider = Provider<PurchaseVerifier>(
  (ref) => supabasePurchaseVerifier(ref.watch(supabaseClientProvider)),
);

/// The business a purchase is bound to (sent as the Play obfuscated account id).
final billingBusinessIdProvider = Provider<String?>(
  (ref) => ref.watch(currentBusinessProvider)?.id,
);

/// Naira fallback prices for Nigerian (NGN) businesses, dollars otherwise.
final billingUsesNairaProvider = Provider<bool>(
  (ref) => pricesInNaira(ref.watch(currencyCodeProvider).valueOrNull),
);

/// Whether the business pays through a Play subscription (cloud lookup), so a
/// device without that purchase never starts a second one (#589).
final playSubscriptionLookupProvider = Provider<PlaySubscriptionLookup>(
  (ref) => supabasePlaySubscriptionLookup(ref.watch(supabaseClientProvider)),
);

/// The running paid plan from the synced businesses row; null on free, trial
/// or a lapsed plan.
final billingCurrentPlanProvider = Provider<CurrentPlan?>((ref) {
  final b = ref.watch(currentBusinessProvider);
  if (b == null || b.subscriptionStatus != 'active') return null;
  final end = b.currentPeriodEnd;
  if (end != null && !end.isAfter(DateTime.now())) return null;
  final tier = switch (b.subscriptionPlan) {
    kPlanBasic => PlanTier.basic,
    kPlanPremium => PlanTier.premium,
    _ => null,
  };
  if (tier == null) return null;
  final cycle = b.billingCycle == kBasePlanYearly
      ? BillingCycle.yearly
      : BillingCycle.monthly;
  return CurrentPlan(tier, cycle, periodEnd: end);
});

/// What the thank-you pop-up names (#590): business name and, when the synced
/// row already knows it, the period end.
final billingThankYouInfoProvider =
    Provider<({String name, DateTime? periodEnd})>((ref) {
  final b = ref.watch(currentBusinessProvider);
  return (name: b?.name ?? 'Your business', periodEnd: b?.currentPeriodEnd);
});
