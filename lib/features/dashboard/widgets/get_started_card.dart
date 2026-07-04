import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/get_started_checklist.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/invite_staff_screen.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';

/// The "Get started" checklist card — Home tab only, CEO only (issue #31,
/// ADR 0006). Renders nothing unless [getStartedChecklistProvider] says it is
/// visible, so it can be dropped unconditionally at the top of the Home list; a
/// non-CEO, a fully-set-up store, and a dismissed card all collapse to zero
/// height. Each unticked step deep-links to its action; done steps are inert.
class GetStartedCard extends ConsumerWidget {
  const GetStartedCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(getStartedChecklistProvider);
    if (!state.visible) return const SizedBox.shrink();

    final doneCount = state.steps.where((s) => s.done).length;
    final total = state.steps.length;
    final theme = Theme.of(context);
    final subtext =
        theme.textTheme.bodySmall?.color ?? theme.iconTheme.color!;
    final primary = context.primaryColor;

    return Padding(
      padding: EdgeInsets.only(bottom: context.spacingL),
      child: GlassyCard(
        radius: context.radiusL,
        padding: EdgeInsets.all(context.spacingM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: context.getRSize(40),
                  height: context.getRSize(40),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        primary.withValues(alpha: 0.15),
                        primary.withValues(alpha: 0.05),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    FontAwesomeIcons.rocket.data,
                    color: primary,
                    size: context.getRSize(18),
                  ),
                ),
                SizedBox(width: context.spacingM),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Get started',
                        style: context.bodyLarge.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      SizedBox(height: context.getRSize(2)),
                      Text(
                        '$doneCount of $total done',
                        style: TextStyle(
                          fontSize: context.getRFontSize(12),
                          color: subtext,
                        ),
                      ),
                    ],
                  ),
                ),
                // Dismiss — device-local latch; the solo CEO who won't invite
                // staff can silence the optional step for good.
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => ref
                      .read(getStartedChecklistDismissedProvider.notifier)
                      .dismiss(),
                  icon: Icon(
                    FontAwesomeIcons.xmark.data,
                    color: subtext,
                    size: context.getRSize(16),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.spacingS),
            for (final step in state.steps) _buildStepRow(context, ref, step),
          ],
        ),
      ),
    );
  }

  Widget _buildStepRow(
    BuildContext context,
    WidgetRef ref,
    GetStartedStep step,
  ) {
    final meta = _metaFor(step.id);
    final theme = Theme.of(context);
    final subtext =
        theme.textTheme.bodySmall?.color ?? theme.iconTheme.color!;
    final title = step.optional ? '${meta.title} (optional)' : meta.title;

    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
      child: Row(
        children: [
          Icon(
            step.done
                ? FontAwesomeIcons.circleCheck.data
                : FontAwesomeIcons.circle.data,
            color: step.done
                ? success
                : subtext.withValues(alpha: 0.5),
            size: context.getRSize(20),
          ),
          SizedBox(width: context.spacingM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: context.getRFontSize(14),
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                    decoration: step.done ? TextDecoration.lineThrough : null,
                    decorationColor: subtext,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  meta.subtitle,
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: subtext.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          if (!step.done)
            Icon(
              FontAwesomeIcons.chevronRight.data,
              color: subtext,
              size: context.getRSize(14),
            ),
        ],
      ),
    );

    // Done steps are inert; unticked steps deep-link to their action.
    if (step.done) return row;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(context.radiusM),
      child: InkWell(
        borderRadius: BorderRadius.circular(context.radiusM),
        onTap: () => _onTapStep(context, ref, step.id),
        child: row,
      ),
    );
  }

  void _onTapStep(BuildContext context, WidgetRef ref, GetStartedStepId id) {
    switch (id) {
      case GetStartedStepId.addProduct:
        // Add Product opens in direct (non-receive) mode — the fast form.
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AddProductScreen()),
        );
      case GetStartedStepId.makeSale:
        // Jump to the POS tab (index 1) to ring up the first order.
        ref.read(navigationProvider).setIndex(1);
      case GetStartedStepId.inviteTeam:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const InviteStaffScreen()),
        );
    }
  }

  _StepMeta _metaFor(GetStartedStepId id) {
    switch (id) {
      case GetStartedStepId.addProduct:
        return const _StepMeta(
          title: 'Add a product',
          subtitle: "Create a product and set what's on your shelf",
        );
      case GetStartedStepId.makeSale:
        return const _StepMeta(
          title: 'Make a sale',
          subtitle: 'Ring up your first order on the till',
        );
      case GetStartedStepId.inviteTeam:
        return const _StepMeta(
          title: 'Invite your team',
          subtitle: 'Add a teammate so they can help you sell',
        );
    }
  }
}

class _StepMeta {
  const _StepMeta({required this.title, required this.subtitle});
  final String title;
  final String subtitle;
}
