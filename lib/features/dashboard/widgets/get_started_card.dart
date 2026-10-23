import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/get_started_checklist.dart';
import 'package:reebaplus_pos/features/inventory/screens/add_product_screen.dart';
import 'package:reebaplus_pos/features/staff/screens/invite_staff_screen.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
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
    final subtext = theme.textTheme.bodySmall?.color ?? theme.iconTheme.color!;

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
                  const IconTile(icon: AppIcons.rocket, size: 44),
                  SizedBox(width: context.spacingM),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Get started',
                          style: context
                              .boldStyle(16)
                              .copyWith(color: theme.colorScheme.onSurface),
                        ),
                        SizedBox(height: context.getRSize(2)),
                        Text(
                          '$doneCount of $total done',
                          style: context
                              .regularStyle(12)
                              .copyWith(color: subtext),
                        ),
                      ],
                    ),
                  ),
                  // Dismiss — device-local latch; only permitted once store exists.
                  if (canDismiss)
                    IconButton(
                      tooltip: 'Dismiss',
                      // A 48dp target (#374); compact density drew it at 40.
                      constraints: const BoxConstraints(
                        minWidth: kMinInteractiveDimension,
                        minHeight: kMinInteractiveDimension,
                      ),
                      onPressed: () => ref
                          .read(getStartedChecklistDismissedProvider.notifier)
                          .dismiss(),
                      icon: Icon(
                        AppIcons.close,
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
    final subtext = theme.textTheme.bodySmall?.color ?? theme.iconTheme.color!;
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final title = step.optional ? '${meta.title} (optional)' : meta.title;

    final IconData iconData;
    final Color iconColor;
    if (step.done) {
      iconData = AppIcons.checkCircle;
      iconColor = f.green;
    } else if (step.locked) {
      iconData = AppIcons.lock;
      iconColor = subtext.withValues(alpha: 0.35);
    } else {
      iconData = AppIcons.circle;
      iconColor = subtext.withValues(alpha: 0.5);
    }

    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: context.getRSize(8)),
        child: Row(
          children: [
            Icon(iconData, color: iconColor, size: context.getRSize(20)),
            SizedBox(width: context.spacingM),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: context
                        .semiBoldStyle(14)
                        .copyWith(
                          color: step.locked
                              ? subtext.withValues(alpha: 0.6)
                              : theme.colorScheme.onSurface,
                          decoration: step.done
                              ? TextDecoration.lineThrough
                              : null,
                          decorationColor: subtext,
                        ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    meta.subtitle,
                    style: context
                        .regularStyle(12)
                        .copyWith(
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
                AppIcons.chevronRight,
                color: subtext,
                size: context.getRSize(14),
              ),
          ],
        ),
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
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AddProductScreen()));
      case GetStartedStepId.makeSale:
        // Jump to the POS tab (index 1) to ring up the first order.
        ref.read(navigationProvider).setIndex(1);
      case GetStartedStepId.inviteTeam:
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const InviteStaffScreen()));
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
