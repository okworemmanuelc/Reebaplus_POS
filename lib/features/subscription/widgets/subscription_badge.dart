import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/subscription/subscription_access.dart';

/// A small rounded tag shown next to the current user's name (§32):
/// **PRO** when the business is paid (Active), **FREE TRIAL** during the 30-day
/// free trial. Renders nothing for expired / inactive / unknown states.
///
/// Self-contained: watches [currentBusinessSubscriptionProvider], so it can be
/// dropped straight into any header Row (drawer, etc.). Styled to match the
/// drawer role tag (rounded, tinted, responsive).
class SubscriptionBadge extends ConsumerWidget {
  const SubscriptionBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(currentBusinessSubscriptionProvider);
    final label = access.badgeLabel;
    if (label == null) return const SizedBox.shrink();

    final isPro = access == SubscriptionAccess.active;
    // PRO rides the business accent; FREE TRIAL uses a warm amber so the two
    // read as distinct at a glance.
    final color = isPro
        ? Theme.of(context).colorScheme.primary
        : const Color(0xFFF59E0B);
    final icon = isPro
        ? Icons.workspace_premium_rounded
        : Icons.schedule_rounded;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: context.getRSize(12), color: color),
          SizedBox(width: context.getRSize(5)),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: context.getRFontSize(12),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
