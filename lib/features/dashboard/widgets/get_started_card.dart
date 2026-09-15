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
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/spotlight_target.dart';

/// The "Get started" checklist card — Home tab only, CEO only (issue #31,
/// ADR 0006, Issue #234). Renders nothing unless [getStartedChecklistProvider] says
/// it is visible, so it can be dropped unconditionally at the top of the Home list;
/// a non-CEO, a fully-set-up store, and a dismissed card all collapse to zero
/// height. Each unticked, unlocked step deep-links to its action; done steps are inert;
/// locked steps cannot be tapped while a store is missing.
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

    final canDismiss = state.steps
        .firstWhere((s) => s.id == GetStartedStepId.createStore)
        .done;

    return SpotlightTarget(
      id: SpotlightTargetId.getStartedCard,
      child: Padding(
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
                  // Dismiss — device-local latch; only permitted once store exists.
                  if (canDismiss)
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
      ),
    );
  }

  Widget _buildStepRow(
    BuildContext context,
    WidgetRef ref,
    GetStartedStep step,
  ) {
    final meta = _metaFor(step.id, ref.watch(industryLexiconProvider).item);
    final theme = Theme.of(context);
    final subtext =
        theme.textTheme.bodySmall?.color ?? theme.iconTheme.color!;
    final title = step.optional ? '${meta.title} (optional)' : meta.title;

    final IconData iconData;
    final Color iconColor;
    if (step.done) {
      iconData = FontAwesomeIcons.circleCheck.data;
      iconColor = success;
    } else if (step.locked) {
      iconData = FontAwesomeIcons.lock.data;
      iconColor = subtext.withValues(alpha: 0.35);
    } else {
      iconData = FontAwesomeIcons.circle.data;
      iconColor = subtext.withValues(alpha: 0.5);
    }

    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
      child: Row(
        children: [
          Icon(
            iconData,
            color: iconColor,
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
                    color: step.locked
                        ? subtext.withValues(alpha: 0.6)
                        : theme.colorScheme.onSurface,
                    decoration: step.done ? TextDecoration.lineThrough : null,
                    decorationColor: subtext,
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  meta.subtitle,
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: step.locked
                        ? subtext.withValues(alpha: 0.45)
                        : subtext.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          if (!step.done && !step.locked)
            Icon(
              FontAwesomeIcons.chevronRight.data,
              color: subtext,
              size: context.getRSize(14),
            ),
        ],
      ),
    );

    // Done steps and locked steps are inert; unticked, unlocked steps deep-link.
    if (step.done || step.locked) return row;
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
      case GetStartedStepId.createStore:
        ref.read(navigationProvider).setIndex(NavigationService.storesTab);
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

  _StepMeta _metaFor(GetStartedStepId id, String item) {
    final itemLower = item.toLowerCase();
    switch (id) {
      case GetStartedStepId.createStore:
        return const _StepMeta(
          title: 'Set up a store',
          subtitle: 'Create a store to manage stock and sales',
        );
      case GetStartedStepId.addProduct:
        return _StepMeta(
          title: 'Add a $itemLower',
          subtitle: "Create a $itemLower and set what's on your shelf",
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
