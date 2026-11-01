import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/features/settings/screens/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/expense_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Keys for the Expenses screens (#412, remade in #652).
abstract final class ExpenseKeys {
  static const Key topBar = ValueKey<String>('expenses-top-bar');
  static const Key addTopBar = ValueKey<String>('add-expense-top-bar');
  static const Key addClose = ValueKey<String>('add-expense-close');
  static const Key addClear = ValueKey<String>('add-expense-clear');
  static const Key summaryCard = ValueKey<String>('expenses-summary-card');
  static const Key budgetCard = ValueKey<String>('expenses-budget-card');
  static const Key budgetField = ValueKey<String>('expenses-budget-field');
  static const Key rejectField = ValueKey<String>('expenses-reject-field');
  static const Key filterAll = ValueKey<String>('expenses-filter-all');
  static const Key filterWaiting = ValueKey<String>('expenses-filter-waiting');
  static const Key detailSheet = ValueKey<String>('expenses-detail-sheet');
  static const Key empty = ValueKey<String>('expenses-empty');
  static const Key amountField = ValueKey<String>('add-expense-amount');
  static const Key paidToField = ValueKey<String>('add-expense-paid-to');
  static const Key noteField = ValueKey<String>('add-expense-note');
  static const Key errorBanner = ValueKey<String>('add-expense-error-banner');
  static const Key saveButton = ValueKey<String>('add-expense-save');
}

/// The top bar's height: CEO Settings' rule (#369). Repeated here because a
/// feature never reaches into another feature's widgets; shared-part
/// candidate (with `customerTopBarHeight`).
double expenseTopBarHeight(BuildContext context) => math.max(
  kToolbarHeight + 12,
  math.max(context.getRSize(44), kMinInteractiveDimension) +
      context.getRSize(16),
);

/// Side gutter that caps content at [kSettingsMaxContentWidth] (720, raw, not
/// scaled) and centres it, never less than `getRSize(16)`.
double expenseGutter(BuildContext context, double width) =>
    math.max(context.getRSize(16), (width - kSettingsMaxContentWidth) / 2);

/// The solid top bar of the Expenses screens (#412): Surface, a hairline and
/// the soft `topBarShadow`, never changing on scroll.
class ExpenseTopBar extends StatelessWidget implements PreferredSizeWidget {
  const ExpenseTopBar({super.key, required this.height, required this.header});

  final double height;
  final Widget header;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    return ExpenseTheme(child: Builder(builder: _bar));
  }

  Widget _bar(BuildContext context) {
    final t = Theme.of(context);
    final topBarShadow =
        t.extension<AppSchemeColors>()?.topBarShadow ?? Colors.transparent;
    return AppBar(
      automaticallyImplyLeading: false,
      toolbarHeight: preferredSize.height,
      titleSpacing: context.getRSize(8),
      centerTitle: false,
      backgroundColor: t.colorScheme.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: Container(
        decoration: BoxDecoration(
          color: t.colorScheme.surface,
          border: Border(bottom: BorderSide(color: t.dividerColor, width: 1)),
          boxShadow: [
            BoxShadow(
              color: topBarShadow,
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
      title: header,
    );
  }
}

/// The live notification bell (a copy of Home's; shared-part candidate).
class ExpenseLiveBell extends ConsumerWidget {
  const ExpenseLiveBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifService = ref.read(notificationProvider);
    return ValueListenableBuilder(
      valueListenable: notifService,
      builder: (context, _, _) => HeaderBell(
        count: notifService.unreadCount,
        onPressed: () => NotificationsModal.show(context),
      ),
    );
  }
}

/// Add Expense's header (#652 mockup): a pale rounded close button, the title
/// and a primary subtitle, then an optional trailing action (Clear).
class ExpenseFormHeader extends StatelessWidget {
  const ExpenseFormHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tile = math.max(context.getRSize(48), kMinInteractiveDimension);
    return Row(
      children: [
        Material(
          color: t.colorScheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
          child: InkWell(
            key: ExpenseKeys.addClose,
            borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
            onTap: () => Navigator.maybePop(context),
            child: SizedBox.square(
              dimension: tile,
              child: Semantics(
                label: 'Close',
                button: true,
                child: Icon(
                  AppIcons.close,
                  size: context.getRSize(24),
                  color: t.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: context.getRSize(12)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.screenTitleStyle.copyWith(
                  color: t.colorScheme.onSurface,
                ),
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context
                    .semiBoldStyle(13)
                    .copyWith(color: AppExpenseColors.of(context).ink),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// The Expenses list header (#652 mockup): the drawer button (phones), the
/// red gradient receipt tile, "Expenses" and a red subtitle that may wrap to
/// two lines, then [actions].
class ExpenseListHeader extends StatelessWidget {
  const ExpenseListHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.leading,
    this.actions = const [],
  });

  final String title;
  final String subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final colors = AppExpenseColors.of(context);
    final tile = context.getRSize(44);
    return Row(
      children: [
        if (leading != null) ...[
          leading!,
          SizedBox(width: context.getRSize(4)),
        ],
        Container(
          width: tile,
          height: tile,
          alignment: Alignment.center,
          decoration: colors.gradientBox(radius: AppSpacing.borderRadiusL),
          child: AppIcon(
            AppIcons.receipt,
            filled: true,
            size: tile * 0.5,
            color: Colors.white,
          ),
        ),
        SizedBox(width: context.getRSize(12)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.screenTitleStyle.copyWith(
                  color: t.colorScheme.onSurface,
                ),
              ),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context
                    .semiBoldStyle(13)
                    .copyWith(color: colors.ink, height: 1.2),
              ),
            ],
          ),
        ),
        ...actions,
      ],
    );
  }
}

/// The red gradient action button (#652 "Save Expense"): white check + label.
class ExpenseGradientButton extends StatelessWidget {
  const ExpenseGradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = AppIcons.check,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = AppExpenseColors.of(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    final height = math.max(context.getRSize(56), kMinInteractiveDimension);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: colors.gradientBox(radius: AppSpacing.borderRadiusL),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: busy ? null : onPressed,
            child: SizedBox(
              height: height,
              child: Center(
                child: busy
                    ? SizedBox.square(
                        dimension: context.getRSize(22),
                        child: const CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            icon,
                            size: context.getRSize(22),
                            color: Colors.white,
                          ),
                          SizedBox(width: context.getRSize(10)),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context
                                  .boldStyle(17)
                                  .copyWith(color: Colors.white),
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

/// A flat card shell: [AppDecorations.card] with the standard inner padding.
class ExpenseCardShell extends StatelessWidget {
  const ExpenseCardShell({
    super.key,
    required this.child,
    this.padding = 16,
    this.decoration,
  });

  final Widget child;
  final double padding;
  final BoxDecoration? decoration;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: decoration ?? AppDecorations.card(context),
    child: Padding(
      padding: EdgeInsets.all(context.getRSize(padding)),
      child: child,
    ),
  );
}

/// A pill chip (#652): the list filters (All / Waiting for approval) and the
/// form's date choices (Today / Yesterday / Pick a date). Selected = the
/// primary button gradient with white text; idle = an outlined surface pill.
/// The visible pill is compact, but the tap area is at least 48dp tall.
class ExpensePillChip extends StatelessWidget {
  const ExpensePillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.trailingIcon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ink = selected ? Colors.white : t.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    final decoration = selected
        ? AppExpenseColors.of(
            context,
          ).gradientBox(radius: AppSpacing.borderRadiusXL, glow: false)
        : BoxDecoration(
            color: t.colorScheme.surface,
            borderRadius: radius,
            border: Border.all(color: t.dividerColor),
          );
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
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
              decoration: decoration,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.getRSize(16),
                  vertical: context.getRSize(9),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: context.getRSize(16), color: ink),
                      SizedBox(width: context.getRSize(6)),
                    ],
                    Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      style: context.semiBoldStyle(15).copyWith(color: ink),
                    ),
                    if (trailingIcon != null) ...[
                      SizedBox(width: context.getRSize(4)),
                      Icon(
                        trailingIcon,
                        size: context.getRSize(18),
                        color: ink,
                      ),
                    ],
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

/// The empty-list message: a neutral tile over the text.
class ExpensesEmptyMessage extends StatelessWidget {
  const ExpensesEmptyMessage({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;
    return Center(
      key: ExpenseKeys.empty,
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(24)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IconTile(icon: AppIcons.receipt, tone: IconTileTone.neutral),
            SizedBox(height: context.getRSize(16)),
            Text(
              message,
              textAlign: TextAlign.center,
              style: context.semiBoldStyle(16).copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// A progress bar track + fill in fixed colours.
class ExpenseProgressBar extends StatelessWidget {
  const ExpenseProgressBar({
    super.key,
    required this.value,
    required this.color,
  });

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusS),
      child: LinearProgressIndicator(
        value: value,
        backgroundColor: Theme.of(context).dividerColor,
        valueColor: AlwaysStoppedAnimation<Color>(color),
        minHeight: context.getRSize(6),
      ),
    );
  }
}
