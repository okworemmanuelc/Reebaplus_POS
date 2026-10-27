import 'package:reebaplus_pos/features/subscription/subscription_plan.dart';

/// Shown when the business's plan has no free staff seat at invite redeem
/// (server trigger `plan_limit_staff`, migration 0224). Written for the new
/// staff member, who is not the owner and cannot upgrade themselves.
const kStaffPlanLimitMessage =
    "This business has reached its staff limit on its current plan, so you "
    "can't join yet. Ask the owner to upgrade to Premium (or free a staff "
    "seat), then try again.";

/// The friendly message for a redeem / hydrate failure caused by the plan's
/// staff cap, or null when [error] is anything else.
String? staffRedeemPlanLimitMessage(Object? error) =>
    planLimitKindOf(error) == PlanLimitKind.staff
    ? kStaffPlanLimitMessage
    : null;
