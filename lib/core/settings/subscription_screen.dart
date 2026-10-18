import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_page_parts.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// CEO Settings → Subscription (master plan §32). A READ-ONLY view of the
/// business's plan, status, and trial-countdown / renewal date. Status is
/// console-controlled (the app is blocked from writing it), so this screen does
/// not edit anything — the "Subscribe / Renew" button is a placeholder until the
/// in-app Paystack flow lands (next task).
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
                  SizedBox(height: context.getRSize(24)),
                  AppButton(
                    text: 'Subscribe / Renew',
                    icon: AppIcons.premium,
                    onPressed: () => _showRenewInfo(context),
                  ),
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
                  _planTitle(business.subscriptionPlan),
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
            _priceLine(business.subscriptionPlan),
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
        SubscriptionAccess.trialActive => ('FREE TRIAL', TagPillTone.warning),
        SubscriptionAccess.trialExpired => ('TRIAL ENDED', TagPillTone.danger),
        SubscriptionAccess.inactive => ('INACTIVE', TagPillTone.danger),
        SubscriptionAccess.grace => ('—', TagPillTone.warning),
      };

  String _planTitle(String? plan) => 'Monthly subscription';

  /// Fixed subscription price (§32) — literal, not a POS amount. ₦5,000/mo for
  /// the local plan, $10/mo for international; default to local.
  String _priceLine(String? plan) =>
      plan == 'international' ? '\$10 per month' : '₦5,000 per month';

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
        return 'Renew to continue';
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

  void _showRenewInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Subscribe / Renew'),
        content: const Text(
          'In-app payment is coming soon. For now, your Reebaplus subscription '
          'is renewed from the admin console — reach out to renew or change '
          'your plan.',
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
}
