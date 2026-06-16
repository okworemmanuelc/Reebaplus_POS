import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_widgets.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// CEO Settings → Subscription (master plan §32). A READ-ONLY view of the
/// business's plan, status, and trial-countdown / renewal date. Status is
/// console-controlled (the app is blocked from writing it), so this screen does
/// not edit anything — the "Subscribe / Renew" button is a placeholder until the
/// in-app Paystack flow lands (next task).
class SubscriptionScreen extends ConsumerWidget {
  const SubscriptionScreen({super.key});

  static const _amber = Color(0xFFF59E0B);
  static const _green = Color(0xFF16A34A);
  static const _red = Color(0xFFDC2626);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final canManage = hasPermission(ref, 'settings.manage');

    return Scaffold(
      backgroundColor: t.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Subscription',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: !canManage
          ? const SettingsNoAccess()
          : SettingsFadeIn(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  24,
                  24,
                  24 + context.deviceBottomPadding,
                ),
                children: [
                  const SettingsSectionTitle('PLAN & STATUS'),
                  const SizedBox(height: 16),
                  _statusCard(context, ref),
                  const SizedBox(height: 24),
                  AppButton(
                    text: 'Subscribe / Renew',
                    icon: Icons.workspace_premium_rounded,
                    onPressed: () => _showRenewInfo(context),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Your subscription is managed by Reebaplus. Changes from the '
                    'admin console appear here automatically.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: t.colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _statusCard(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final business = ref.watch(currentBusinessProvider);
    final access = ref.watch(currentBusinessSubscriptionProvider);

    if (business == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: AppDecorations.glassCard(context, radius: 16),
        child: Text(
          'Subscription details will appear once your business has synced.',
          style: TextStyle(
            color: t.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      );
    }

    final (statusLabel, statusColor) = _statusChip(access);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: AppDecorations.glassCard(context, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _planTitle(business.subscriptionPlan),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: t.colorScheme.onSurface,
                  ),
                ),
              ),
              _pill(context, statusLabel, statusColor),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _priceLine(business.subscriptionPlan),
            style: TextStyle(
              fontSize: 14,
              color: t.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          Divider(height: 28, color: t.dividerColor),
          _detailRow(
            context,
            Icons.event_rounded,
            _periodLabel(access),
            _periodValue(business, access),
          ),
        ],
      ),
    );
  }

  // ── helpers ────────────────────────────────────────────────────────────

  (String, Color) _statusChip(SubscriptionAccess access) => switch (access) {
    SubscriptionAccess.active => ('ACTIVE', _green),
    SubscriptionAccess.trialActive => ('FREE TRIAL', _amber),
    SubscriptionAccess.trialExpired => ('TRIAL ENDED', _red),
    SubscriptionAccess.inactive => ('INACTIVE', _red),
    SubscriptionAccess.grace => ('—', _amber),
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
    final subtext = t.colorScheme.onSurface.withValues(alpha: 0.6);
    return Row(
      children: [
        Icon(icon, size: 16, color: subtext),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            color: subtext,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              color: t.colorScheme.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _pill(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
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
