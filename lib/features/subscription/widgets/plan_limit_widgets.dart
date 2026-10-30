import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
