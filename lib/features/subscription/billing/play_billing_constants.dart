/// Single source of truth for Google Play Billing identifiers and fallback
/// prices (reebaplus-web#90). Product ids / base plans MUST match the Play
/// Console setup in docs/rollouts/0225-play-billing/ and the Edge Function
/// (supabase/functions/play-billing-verify/play.ts) + migration 0225.
library;

enum PlanTier { basic, premium }

enum BillingCycle { monthly, yearly }

const String kProductBasic = 'reebaplus_basic';
const String kProductPremium = 'reebaplus_premium';
const Set<String> kSubscriptionProductIds = {kProductBasic, kProductPremium};

const String kBasePlanMonthly = 'monthly';
const String kBasePlanYearly = 'yearly';

/// WhatsApp number (international format, digits only) for the interim
/// "contact us" path. Empty = hide the button until the owner supplies it.
const String kSupportWhatsAppNumber = '';

/// Name of the Supabase Edge Function that verifies Play purchases.
const String kPlayBillingVerifyFunction = 'play-billing-verify';

String productIdFor(PlanTier t) =>
    t == PlanTier.basic ? kProductBasic : kProductPremium;

String basePlanFor(BillingCycle c) =>
    c == BillingCycle.monthly ? kBasePlanMonthly : kBasePlanYearly;

/// Price shown when the store has not returned ProductDetails (offline, or
/// products not yet live). The store price always wins when present.
/// Nigeria sees naira, everyone else dollars (decided in #90).
String fallbackPrice(PlanTier t, BillingCycle c, {required bool naira}) {
  const ngn = {
    (PlanTier.basic, BillingCycle.monthly): '₦6,500',
    (PlanTier.basic, BillingCycle.yearly): '₦65,000',
    (PlanTier.premium, BillingCycle.monthly): '₦25,000',
    (PlanTier.premium, BillingCycle.yearly): '₦250,000',
  };
  const usd = {
    (PlanTier.basic, BillingCycle.monthly): '\$5',
    (PlanTier.basic, BillingCycle.yearly): '\$50',
    (PlanTier.premium, BillingCycle.monthly): '\$20',
    (PlanTier.premium, BillingCycle.yearly): '\$200',
  };
  return (naira ? ngn : usd)[(t, c)]!;
}
