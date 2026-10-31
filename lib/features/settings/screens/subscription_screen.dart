import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_page_parts.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/subscription/billing/plans_paywall.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan.dart';
import 'package:reebaplus_pos/features/subscription/subscription_plan_providers.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// CEO Settings → Subscription (master plan §32). A READ-ONLY view of the
/// business's plan, status, and trial-countdown / renewal date. Status is
/// console-controlled (the app is blocked from writing it), so this screen does
/// not edit anything — purchases go through the Google Play Billing paywall
/// ([PlansPaywall], #90).
class SubscriptionScreen extends ConsumerWidget {
  const SubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final canManage = Gates.manageSettings.allows(ref);

    return SettingsPageScaffold(
      icon: AppIcons.premium,
      title: 'Subscription',
      body: !canManage
          ? const SettingsNoAccess()
          : SettingsFadeIn(
              child: SettingsPageList(
                listKey: const Key('subscription-list'),
                children: [
                  const SectionHeader(
                    title: 'PLAN & STATUS',
                    variant: SectionHeaderVariant.group,
                  ),
                  SizedBox(height: context.getRSize(10)),
                  _statusCard(context, ref),
                  const _OverLimitList(),
                  SizedBox(height: context.getRSize(24)),
                  const PlansPaywall(),
                  SizedBox(height: context.getRSize(12)),
                  Text(
                    'Your subscription is managed by Reebaplus. Changes from the '
                    'admin console appear here automatically.',
                    textAlign: TextAlign.center,
                    style: context.regularStyle(12).copyWith(color: muted),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _statusCard(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final business = ref.watch(currentBusinessProvider);
    final access = ref.watch(currentBusinessSubscriptionProvider);
    final plan = ref.watch(effectivePlanProvider);
    final nigeria = pricesInNaira(ref.watch(currencyCodeProvider).valueOrNull);

    if (business == null) {
      return SettingsCard(
        child: Text(
          'Subscription details will appear once your business has synced.',
          style: context.regularStyle(14).copyWith(color: muted),
        ),
      );
    }

    final (statusLabel, statusTone) = _statusChip(access);

    return SettingsCard(
      padding: EdgeInsets.all(context.getRSize(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _planTitle(plan),
                  style: context
                      .extraBoldStyle(18)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
              ),
              SizedBox(width: context.getRSize(8)),
              TagPill(label: statusLabel, tone: statusTone),
            ],
          ),
          SizedBox(height: context.getRSize(6)),
          Text(
            _priceLine(plan, nigeria),
            style: context.regularStyle(14).copyWith(color: muted),
          ),
          Divider(height: context.getRSize(28), color: t.dividerColor),
          _detailRow(
            context,
            AppIcons.event,
            _periodLabel(access),
            _periodValue(business, access),
          ),
        ],
      ),
    );
  }

  // ── helpers ────────────────────────────────────────────────────────────

  (String, TagPillTone) _statusChip(SubscriptionAccess access) =>
      switch (access) {
        SubscriptionAccess.active => ('ACTIVE', TagPillTone.green),
        // TODO(#584): remove once no legacy trials remain
        SubscriptionAccess.trialActive => ('FREE TRIAL', TagPillTone.warning),
        SubscriptionAccess.trialExpired => ('FREE PLAN', TagPillTone.warning),
        SubscriptionAccess.inactive => ('FREE PLAN', TagPillTone.warning),
        SubscriptionAccess.grace => ('—', TagPillTone.warning),
      };

  String _planTitle(String plan) => '${planLabel(plan)} plan';

  /// Plan price (naira for Nigeria, USD elsewhere) plus what the plan includes.
  String _priceLine(String plan, bool nigeria) =>
      '${planPriceLine(plan, nigeria: nigeria)}  ·  ${planSummary(plan)}';

  String _periodLabel(SubscriptionAccess access) =>
      access == SubscriptionAccess.active ? 'Renews' : 'Trial ends';

  String _periodValue(dynamic business, SubscriptionAccess access) {
    final fmt = DateFormat('d MMM yyyy');
    switch (access) {
      case SubscriptionAccess.active:
        final d = business.currentPeriodEnd as DateTime?;
        return d == null ? '—' : fmt.format(d);
      case SubscriptionAccess.trialActive:
        final d = business.trialEndsAt as DateTime?;
        if (d == null) return '—';
        final days = d.difference(DateTime.now()).inDays;
        final left = days <= 0
            ? 'today'
            : '$days day${days == 1 ? '' : 's'} left';
        return '${fmt.format(d)}  ·  $left';
      case SubscriptionAccess.trialExpired:
        final d = business.trialEndsAt as DateTime?;
        return d == null ? 'Ended' : 'Ended ${fmt.format(d)}';
      case SubscriptionAccess.inactive:
        return 'Upgrade to restore staff and shops';
      case SubscriptionAccess.grace:
        return '—';
    }
  }

  Widget _detailRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Row(
        children: [
          AppIcon(icon, size: context.getRSize(18), color: muted),
          SizedBox(width: context.getRSize(10)),
          Text(label, style: context.semiBoldStyle(13).copyWith(color: muted)),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: context
                  .boldStyle(13)
                  .copyWith(color: t.colorScheme.onSurface),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// #586: names the staff paused and shops made read-only by the plan limits.
class _OverLimitList extends ConsumerWidget {
  const _OverLimitList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pausedIds = ref.watch(pausedStaffIdsProvider);
    final roIds = ref.watch(readOnlyStoreIdsProvider);
    if (pausedIds.isEmpty && roIds.isEmpty) return const SizedBox.shrink();
    final users = ref.watch(usersByBusinessProvider).valueOrNull ?? const {};
    final stores = ref.watch(allStoresProvider).valueOrNull ?? const [];
    final staffNames = [
      for (final id in pausedIds) users[id]?.name ?? 'Staff member',
    ];
    final shopNames = [
      for (final s in stores)
        if (roIds.contains(s.id)) s.name,
    ];
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      key: const Key('over-limit-list'),
      padding: EdgeInsets.only(top: context.getRSize(12)),
      child: SettingsCard(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (staffNames.isNotEmpty) ...[
              Text('Paused staff', style: context.boldStyle(13)),
              SizedBox(height: context.getRSize(4)),
              for (final n in staffNames)
                Text(n, style: context.regularStyle(13).copyWith(color: muted)),
              SizedBox(height: context.getRSize(10)),
            ],
            if (shopNames.isNotEmpty) ...[
              Text('Read-only shops', style: context.boldStyle(13)),
              SizedBox(height: context.getRSize(4)),
              for (final n in shopNames)
                Text(n, style: context.regularStyle(13).copyWith(color: muted)),
              SizedBox(height: context.getRSize(10)),
            ],
            Text(
              'Upgrade to Premium to restore them',
              style: context.semiBoldStyle(13),
            ),
          ],
        ),
      ),
    );
  }
}
