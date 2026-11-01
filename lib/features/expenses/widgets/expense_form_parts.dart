import 'package:flutter/material.dart';

import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/expense_colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/expenses/expense_categories.dart';
import 'package:reebaplus_pos/features/expenses/widgets/expense_parts.dart';

/// The quick-add amounts under "Amount spent", in whole currency units.
const List<int> kExpenseQuickAddAmounts = [500, 1000, 5000];

/// The red summary banner over the form: "Please fix 2 things below…".
class ExpenseErrorBanner extends StatelessWidget {
  const ExpenseErrorBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = AppExpenseColors.of(context);
    return DecoratedBox(
      key: ExpenseKeys.errorBanner,
      decoration: BoxDecoration(
        color: c.bannerFill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
        border: Border.all(color: c.outline.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(16),
          vertical: context.getRSize(16),
        ),
        child: Row(
          children: [
            Icon(
              AppIcons.alertCircle,
              size: context.getRSize(22),
              color: c.ink,
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              child: Text(
                text,
                style: context.semiBoldStyle(15).copyWith(color: c.bannerInk),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The red line under a field that needs fixing.
class ExpenseFieldError extends StatelessWidget {
  const ExpenseFieldError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ink = AppExpenseColors.of(context).ink;
    return Padding(
      padding: EdgeInsets.only(top: context.getRSize(10)),
      child: Row(
        children: [
          Icon(AppIcons.alertCircle, size: context.getRSize(18), color: ink),
          SizedBox(width: context.getRSize(8)),
          Expanded(
            child: Text(
              message,
              style: context.mediumStyle(14).copyWith(color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// A section label: "Paid to" + an optional muted "(optional)".
class ExpenseSectionLabel extends StatelessWidget {
  const ExpenseSectionLabel({
    super.key,
    required this.text,
    this.optional = false,
  });

  final String text;
  final bool optional;

  @override
  Widget build(BuildContext context) {
    final muted = AppExpenseColors.of(context).slate;
    return Padding(
      padding: EdgeInsets.only(bottom: context.getRSize(10)),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: text,
              style: context.semiBoldStyle(15).copyWith(color: muted),
            ),
            if (optional)
              TextSpan(
                text: ' (optional)',
                style: context.regularStyle(15).copyWith(color: muted),
              ),
          ],
        ),
      ),
    );
  }
}

/// The "Amount spent" hero card: a big amount box with the currency symbol,
/// the +500 / +1,000 / +5,000 quick-add chips, and the field error. Locked
/// (no typing, no chips) when [enabled] is false — an edit, where the amount
/// can't change.
class ExpenseAmountCard extends StatelessWidget {
  const ExpenseAmountCard({
    super.key,
    required this.controller,
    required this.currencySymbol,
    required this.enabled,
    required this.onQuickAdd,
    this.error,
    this.lockedNote,
  });

  final TextEditingController controller;
  final String currencySymbol;
  final bool enabled;
  final ValueChanged<int> onQuickAdd;
  final String? error;
  final String? lockedNote;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = AppExpenseColors.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final card = AppDecorations.card(context);
    final bigStyle = context.extraBoldStyle(40);
    return DecoratedBox(
      decoration: error == null
          ? card
          : card.copyWith(border: Border.all(color: c.outline, width: 2)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(18),
          context.getRSize(20),
          context.getRSize(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Amount spent',
              style: context.semiBoldStyle(15).copyWith(color: muted),
            ),
            SizedBox(height: context.getRSize(6)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(currencySymbol, style: bigStyle.copyWith(color: c.ink)),
                SizedBox(width: context.getRSize(10)),
                Expanded(
                  child: TextField(
                    key: ExpenseKeys.amountField,
                    controller: controller,
                    enabled: enabled,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [CurrencyInputFormatter()],
                    style: bigStyle.copyWith(color: t.colorScheme.onSurface),
                    cursorColor: AppExpenseColors.start,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      hintText: '0',
                      hintStyle: bigStyle.copyWith(color: muted),
                      contentPadding: EdgeInsets.symmetric(
                        vertical: context.getRSize(4),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (enabled) ...[
              SizedBox(height: context.getRSize(10)),
              Wrap(
                spacing: context.getRSize(10),
                runSpacing: context.getRSize(4),
                children: [
                  for (final amount in kExpenseQuickAddAmounts)
                    _QuickAddChip(
                      label: '+${formatCurrency(amount)}',
                      onTap: () => onQuickAdd(amount),
                    ),
                ],
              ),
            ],
            if (lockedNote != null) ...[
              SizedBox(height: context.getRSize(8)),
              Text(
                lockedNote!,
                style: context.regularStyle(13).copyWith(color: muted),
              ),
            ],
            if (error != null) ExpenseFieldError(message: error!),
          ],
        ),
      ),
    );
  }
}

class _QuickAddChip extends StatelessWidget {
  const _QuickAddChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return InkWell(
      borderRadius: radius,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: kMinInteractiveDimension,
          minWidth: kMinInteractiveDimension,
        ),
        child: Center(
          widthFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: t.colorScheme.surface,
              borderRadius: radius,
              border: Border.all(color: t.dividerColor),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.getRSize(16),
                vertical: context.getRSize(9),
              ),
              child: Text(
                label,
                style: context
                    .boldStyle(15)
                    .copyWith(color: AppExpenseColors.of(context).ink),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "What was it for?" grid: three tiles a row, each the same width.
/// [extraName] adds a tile for an old category that is not in the grid (an
/// edit of an expense saved under, say, "Maintenance").
class ExpenseCategoryGrid extends StatelessWidget {
  const ExpenseCategoryGrid({
    super.key,
    required this.selected,
    required this.onSelected,
    this.extraName,
  });

  final String? selected;
  final ValueChanged<String> onSelected;
  final String? extraName;

  @override
  Widget build(BuildContext context) {
    final extra = extraName;
    final choices = [
      ...kExpenseCategoryChoices,
      if (extra != null)
        ExpenseCategoryChoice(name: extra, icon: expenseCategoryIcon(extra)),
    ];
    final gap = context.getRSize(12);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - gap * 2) / 3;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final c in choices)
              SizedBox(
                width: width,
                child: _CategoryTile(
                  choice: c,
                  selected: c.name.toLowerCase() == selected?.toLowerCase(),
                  onTap: () => onSelected(c.name),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final ExpenseCategoryChoice choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = AppExpenseColors.of(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final base = AppDecorations.card(
      context,
      radius: AppSpacing.borderRadiusXL,
    );
    final decoration = selected
        ? base.copyWith(
            color: Color.alphaBlend(c.selectedFill, t.colorScheme.surface),
            border: Border.all(color: c.outline, width: 2),
          )
        : base;
    return Semantics(
      button: true,
      selected: selected,
      label: choice.name,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: decoration,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kMinInteractiveDimension,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(6),
                  vertical: context.getRSize(18),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      choice.icon,
                      size: context.getRSize(30),
                      color: selected ? c.ink : c.slate,
                    ),
                    SizedBox(height: context.getRSize(8)),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        choice.name,
                        maxLines: 1,
                        style: context
                            .semiBoldStyle(15)
                            .copyWith(color: t.colorScheme.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sticky footer: "Total" with the money-out figure, and the save button.
class ExpenseSaveFooter extends StatelessWidget {
  const ExpenseSaveFooter({
    super.key,
    required this.amountKobo,
    required this.buttonLabel,
    required this.onSave,
    required this.gutter,
    this.saving = false,
  });

  final int amountKobo;
  final String buttonLabel;
  final VoidCallback onSave;
  final double gutter;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    final hasAmount = amountKobo > 0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          gutter,
          context.getRSize(14),
          gutter,
          context.deviceBottomPadding + context.getRSize(14),
        ),
        child: Row(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Total',
                  style: context.semiBoldStyle(14).copyWith(color: muted),
                ),
                Text(
                  hasAmount
                      ? '−${formatCurrency(amountKobo / 100.0)}'
                      : formatCurrency(0),
                  style: context
                      .extraBoldStyle(22)
                      .copyWith(
                        color: hasAmount
                            ? AppExpenseColors.of(context).ink
                            : muted,
                      ),
                ),
              ],
            ),
            SizedBox(width: context.getRSize(16)),
            Expanded(
              child: ExpenseGradientButton(
                key: ExpenseKeys.saveButton,
                label: buttonLabel,
                busy: saving,
                onPressed: onSave,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
