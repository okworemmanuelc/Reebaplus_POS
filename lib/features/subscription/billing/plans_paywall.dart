import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/tag_pill.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan_providers.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';

import 'package:reebaplus_pos/features/subscription/billing/play_billing_constants.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_controller.dart';
import 'package:reebaplus_pos/features/subscription/billing/play_billing_providers.dart';

/// Plan chooser embedded in Settings > Subscription (#90 slice B). Android
/// shows Basic / Premium with a monthly-yearly toggle and a restore link;
/// other platforms show only the current plan and its limits.
class PlansPaywall extends ConsumerStatefulWidget {
  const PlansPaywall({super.key});

  @override
  ConsumerState<PlansPaywall> createState() => _PlansPaywallState();
}

class _PlansPaywallState extends ConsumerState<PlansPaywall> {
  PlayBillingController? _ctl;
  BillingCycle _cycle = BillingCycle.monthly;

  @override
  void initState() {
    super.initState();
    if (!ref.read(billingSupportedProvider)) return;
    final businessId = ref.read(billingBusinessIdProvider);
    if (businessId == null) return;
    _ctl = PlayBillingController(
      port: ref.read(playBillingPortProvider),
      verify: ref.read(purchaseVerifierProvider),
      businessId: businessId,
      currentPlan: () => ref.read(billingCurrentPlanProvider),
      hasPlaySubscription: ref.read(playSubscriptionLookupProvider),
    )..addListener(_onChange)
     ..init();
  }

  BillingPhase? _lastPhase;
  void _onChange() {
    final s = _ctl!.state;
    if (s.phase == BillingPhase.success && _lastPhase != BillingPhase.success) {
      // The businesses row syncs down to this device; nothing else to do.
    }
    _lastPhase = s.phase;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctl?.removeListener(_onChange);
    _ctl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    if (!ref.watch(billingSupportedProvider)) {
      // Apple anti-steering: no buy buttons, no pointer elsewhere; the
      // current plan and its limits only.
      final plan = ref.watch(effectivePlanProvider);
      return Column(
        key: const Key('paywall-non-android'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Current plan: ${planLabel(plan)}',
            key: const Key('paywall-current-plan'),
            textAlign: TextAlign.center,
            style: context.boldStyle(16),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            planSummary(plan),
            textAlign: TextAlign.center,
            style: context.regularStyle(14).copyWith(color: muted),
          ),
        ],
      );
    }

    final ctl = _ctl;
    if (ctl == null) return const SizedBox.shrink();
    ref.watch(billingCurrentPlanProvider); // rebuild when the plan syncs down
    final s = ctl.state;
    final naira = ref.watch(billingUsesNairaProvider);
    final busy = s.phase == BillingPhase.purchasing ||
        s.phase == BillingPhase.verifying ||
        s.phase == BillingPhase.loading;

    if (s.phase == BillingPhase.unavailable) {
      return Text(
        'Google Play is not available on this device, so plans cannot be '
        'purchased here. Contact us on WhatsApp to subscribe.',
        key: const Key('paywall-unavailable'),
        textAlign: TextAlign.center,
        style: context.regularStyle(14).copyWith(color: muted),
      );
    }

    return Column(
      key: const Key('paywall'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<BillingCycle>(
          key: const Key('paywall-cycle'),
          segments: const [
            ButtonSegment(value: BillingCycle.monthly, label: Text('Monthly')),
            ButtonSegment(
              value: BillingCycle.yearly,
              label: Text('Yearly (2 months free)'),
            ),
          ],
          selected: {_cycle},
          onSelectionChanged: (v) => setState(() => _cycle = v.first),
        ),
        SizedBox(height: context.getRSize(16)),
        _planCard(context, ctl, PlanTier.premium, 'Premium',
            'Unlimited stores and staff, plus warehouse', naira, busy,
            highlight: true),
        SizedBox(height: context.getRSize(12)),
        _planCard(context, ctl, PlanTier.basic, 'Basic',
            '1 store, up to 5 staff accounts', naira, busy),
        if (s.message != null) ...[
          SizedBox(height: context.getRSize(12)),
          Text(
            s.message!,
            key: const Key('paywall-message'),
            textAlign: TextAlign.center,
            style: context.regularStyle(13).copyWith(color: muted),
          ),
        ],
        SizedBox(height: context.getRSize(8)),
        TextButton(
          key: const Key('paywall-restore'),
          onPressed: busy ? null : ctl.restore,
          child: const Text('Restore purchases'),
        ),
      ],
    );
  }

  Widget _planCard(BuildContext context, PlayBillingController ctl,
      PlanTier tier, String title, String blurb, bool naira, bool busy,
      {bool highlight = false}) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final price = ctl.priceFor(tier, _cycle, naira: naira);
    final per = _cycle == BillingCycle.monthly ? 'per month' : 'per year';
    return Container(
      padding: EdgeInsets.all(context.getRSize(16)),
      decoration: BoxDecoration(
        color: highlight ? f.infoTint : null,
        border: Border.all(
          color: highlight ? f.info : t.dividerColor,
          width: highlight ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: context.extraBoldStyle(18)),
              if (highlight) ...[
                SizedBox(width: context.getRSize(8)),
                const Flexible(
                  child: TagPill(
                    key: Key('premium-tag'),
                    label: 'Unlimited shops & staff',
                    tone: TagPillTone.solidInfo,
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: context.getRSize(4)),
          Text(blurb, style: context.regularStyle(13)),
          SizedBox(height: context.getRSize(8)),
          Text('$price $per',
              key: Key('price-${tier.name}'), style: context.boldStyle(16)),
          if (_cycle == BillingCycle.yearly)
            Text(
              _saving(tier, naira),
              key: Key('saving-${tier.name}'),
              style: context.boldStyle(13).copyWith(color: f.green),
            ),
          SizedBox(height: context.getRSize(12)),
          if (ctl.isCurrentPlan(tier, _cycle))
            AppButton(
              key: Key('current-${tier.name}'),
              text: 'Current plan',
              onPressed: null,
            )
          else
            AppButton(
              text: 'Choose $title',
              isLoading: busy,
              onPressed: busy ? null : () => ctl.subscribe(tier, _cycle),
            ),
        ],
      ),
    );
  }

  /// Yearly saving vs twelve months: naira shows the amount, USD "2 months
  /// free" (yearly = 10 x monthly).
  String _saving(PlanTier tier, bool naira) {
    if (!naira) return '2 months free';
    return tier == PlanTier.basic ? 'Save ₦3,000' : 'Save ₦13,000';
  }
}
