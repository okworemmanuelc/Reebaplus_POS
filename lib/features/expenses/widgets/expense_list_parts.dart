import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/expense_colors.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/expenses/widgets/expense_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// "1 expense" / "3 expenses".
String expenseCountLabel(int n) => n == 1 ? '1 expense' : '$n expenses';

/// The Expenses summary card (#652): "Spent today" big, then the "This week"
/// and "Waiting for approval" tiles side by side, then the monthly [budget]
/// section when there is one to show.
class ExpenseSummaryCard extends StatelessWidget {
  const ExpenseSummaryCard({
    super.key,
    required this.spentTodayKobo,
    required this.spentThisWeekKobo,
    required this.waitingCount,
    this.scopeLabel,
    this.budget,
  });

  final int spentTodayKobo;
  final int spentThisWeekKobo;
  final int waitingCount;

  /// The store the figures cover, when more than one store is selectable.
  final String? scopeLabel;
  final Widget? budget;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return ExpenseCardShell(
      key: ExpenseKeys.summaryCard,
      padding: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            scopeLabel == null ? 'Spent today' : 'Spent today · $scopeLabel',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.semiBoldStyle(14).copyWith(color: muted),
          ),
          SizedBox(height: context.getRSize(4)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatCurrency(spentTodayKobo / 100.0),
              style: context
                  .extraBoldStyle(36)
                  .copyWith(color: AppExpenseColors.of(context).ink),
            ),
          ),
          SizedBox(height: context.getRSize(14)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _SummaryTile(
                  label: 'This week',
                  value: formatCurrency(spentThisWeekKobo / 100.0),
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: _SummaryTile(
                  label: 'Waiting for approval',
                  value: expenseCountLabel(waitingCount),
                ),
              ),
            ],
          ),
          if (budget != null) ...[
            SizedBox(height: context.getRSize(16)),
            Divider(height: 1, color: t.dividerColor),
            SizedBox(height: context.getRSize(12)),
            budget!,
          ],
        ],
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppExpenseColors.of(context).panelFill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(14),
          vertical: context.getRSize(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.regularStyle(13).copyWith(color: muted),
            ),
            SizedBox(height: context.getRSize(2)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: context
                    .boldStyle(17)
                    .copyWith(color: t.colorScheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The monthly budget, inside the summary card (§20.3, restyled in #652).
/// [goalKobo] null = no budget yet. Only a CEO gets [onEdit]; with no goal and
/// no [onEdit] the caller hides the section altogether.
class ExpenseBudgetSection extends StatelessWidget {
  const ExpenseBudgetSection({
    super.key,
    required this.spentKobo,
    required this.pendingKobo,
    required this.goalKobo,
    this.onEdit,
  });

  final int spentKobo;
  final int pendingKobo;
  final int? goalKobo;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final goal = goalKobo;

    final title = Text(
      'Budget this month',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.boldStyle(14).copyWith(color: t.colorScheme.onSurface),
    );

    if (goal == null) {
      return Row(
        key: ExpenseKeys.budgetCard,
        children: [
          Icon(AppIcons.target, size: context.getRSize(18), color: muted),
          SizedBox(width: context.getRSize(8)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                Text(
                  'Not set yet',
                  style: context.regularStyle(13).copyWith(color: muted),
                ),
              ],
            ),
          ),
          if (onEdit != null)
            AppButton(
              text: 'Set budget',
              variant: AppButtonVariant.outline,
              size: AppButtonSize.xsmall,
              isFullWidth: false,
              onPressed: onEdit,
            ),
        ],
      );
    }

    final ratio = goal == 0 ? 1.0 : spentKobo / goal;
    final isOver = spentKobo > goal;
    final tone = isOver ? f.danger : f.green;
    final leftKobo = (goal - spentKobo).abs();

    return Column(
      key: ExpenseKeys.budgetCard,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(AppIcons.target, size: context.getRSize(18), color: tone),
            SizedBox(width: context.getRSize(8)),
            Expanded(child: title),
            Text(
              '${(ratio * 100).round()}%',
              style: context.boldStyle(14).copyWith(color: tone),
            ),
            if (onEdit != null)
              IconButton(
                tooltip: 'Change budget',
                constraints: const BoxConstraints(
                  minWidth: kMinInteractiveDimension,
                  minHeight: kMinInteractiveDimension,
                ),
                onPressed: onEdit,
                icon: Icon(
                  AppIcons.edit,
                  size: context.getRSize(18),
                  color: muted,
                ),
              ),
          ],
        ),
        SizedBox(height: context.getRSize(8)),
        ExpenseProgressBar(value: ratio.clamp(0.0, 1.0), color: tone),
        SizedBox(height: context.getRSize(8)),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: context.getRSize(8),
          runSpacing: context.getRSize(4),
          children: [
            Text(
              '${formatCurrency(spentKobo / 100.0)} of '
              '${formatCurrency(goal / 100.0)}',
              style: context
                  .semiBoldStyle(13)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
            Text(
              isOver
                  ? '${formatCurrency(leftKobo / 100.0)} over'
                  : '${formatCurrency(leftKobo / 100.0)} left',
              style: context.semiBoldStyle(13).copyWith(color: tone),
            ),
          ],
        ),
        if (pendingKobo > 0) ...[
          SizedBox(height: context.getRSize(4)),
          Text(
            '${formatCurrency(pendingKobo / 100.0)} waiting for approval',
            style: context.semiBoldStyle(12).copyWith(color: f.warning),
          ),
        ],
      ],
    );
  }
}

/// The status pill on an expense row (#652 wording): Waiting (amber),
/// Approved (green), Rejected (grey).
class ExpenseStatusPill extends StatelessWidget {
  const ExpenseStatusPill({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final c = AppExpenseColors.of(context);
    final (label, fill, ink) = switch (status) {
      'approved' => ('Approved', c.approvedFill, c.approvedInk),
      'rejected' => ('Rejected', c.rejectedFill, c.rejectedInk),
      _ => ('Waiting', c.waitingFill, c.waitingInk),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(10),
          vertical: context.getRSize(3),
        ),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          style: context.semiBoldStyle(13).copyWith(color: ink),
        ),
      ),
    );
  }
}

/// One expense in the list (#652): category tile, title, "Category · Who ·
/// When", the amount as money out (struck through when rejected) and the
/// status pill. [actions] (Approve / Reject) sit under the row when given.
class ExpenseListRow extends StatelessWidget {
  const ExpenseListRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.amountKobo,
    required this.status,
    required this.onTap,
    this.actions,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final int amountKobo;
  final String status;
  final VoidCallback onTap;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final rejected = status == 'rejected';
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final amountStyle = context
        .boldStyle(16)
        .copyWith(
          color: rejected ? muted : t.colorScheme.onSurface,
          decoration: rejected ? TextDecoration.lineThrough : null,
          decorationColor: muted,
        );
    return DecoratedBox(
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusXL,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(14)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconTile(
                      icon: icon,
                      tint: AppExpenseColors.of(context).tint,
                      iconColor: AppExpenseColors.of(context).ink,
                    ),
                    SizedBox(width: context.getRSize(12)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .boldStyle(16)
                                .copyWith(color: t.colorScheme.onSurface),
                          ),
                          SizedBox(height: context.getRSize(2)),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context
                                .regularStyle(13)
                                .copyWith(color: muted),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '−${formatCurrency(amountKobo / 100.0)}',
                          style: amountStyle,
                        ),
                        SizedBox(height: context.getRSize(4)),
                        ExpenseStatusPill(status: status),
                      ],
                    ),
                  ],
                ),
                if (actions != null) ...[
                  SizedBox(height: context.getRSize(12)),
                  actions!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A label / value line in the expense detail sheet.
class ExpenseDetailLine extends StatelessWidget {
  const ExpenseDetailLine({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(6)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: context.getRSize(110),
            child: Text(
              label,
              style: context.regularStyle(14).copyWith(color: muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: context
                  .semiBoldStyle(14)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
