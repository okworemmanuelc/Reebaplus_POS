import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/settings/settings_screen.dart'
    show kSettingsMaxContentWidth;
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/notifications_modal.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Keys for the Expenses screens (#412).
abstract final class ExpenseKeys {
  static const Key topBar = ValueKey<String>('expenses-top-bar');
  static const Key addTopBar = ValueKey<String>('add-expense-top-bar');
  static const Key addBack = ValueKey<String>('add-expense-back');
  static const Key totalCard = ValueKey<String>('expenses-total-card');
  static const Key budgetCard = ValueKey<String>('expenses-budget-card');
  static const Key budgetField = ValueKey<String>('expenses-budget-field');
  static const Key rejectField = ValueKey<String>('expenses-reject-field');
  static const Key pendingCard = ValueKey<String>('expenses-pending-card');
  static const Key cardMenu = ValueKey<String>('expenses-card-menu');
  static const Key empty = ValueKey<String>('expenses-empty');
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

/// Centres [child] at no more than [kSettingsMaxContentWidth]. Gives the child
/// no height of its own (width only).
class ExpenseWidthCap extends StatelessWidget {
  const ExpenseWidthCap({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kSettingsMaxContentWidth),
      child: child,
    ),
  );
}

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

/// A 48dp back arrow for the Add Expense top bar.
class ExpenseBackButton extends StatelessWidget {
  const ExpenseBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: ExpenseKeys.addBack,
      tooltip: 'Back',
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      onPressed: () => Navigator.maybePop(context),
      icon: Icon(
        AppIcons.arrowBack,
        color: Theme.of(context).colorScheme.onSurface,
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

/// Maps a category name to its icon (unchanged from the old card).
IconData expenseCategoryIcon(String category) {
  switch (category.toLowerCase()) {
    case 'fuel':
      return AppIcons.fuel;
    case 'salary':
      return AppIcons.customers;
    case 'rent':
      return AppIcons.building;
    case 'maintenance':
      return AppIcons.maintenance;
    case 'utilities':
      return AppIcons.quickSale;
    case 'supplies':
      return AppIcons.box;
    default:
      return AppIcons.invoice;
  }
}

/// The status pill on an expense: approved green, rejected danger, pending
/// warning. Wording is unchanged ("Pending CEO approval").
class ExpenseStatusPill extends StatelessWidget {
  const ExpenseStatusPill({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = switch (status) {
      'approved' => ('Approved', TagPillTone.green),
      'rejected' => ('Rejected', TagPillTone.danger),
      _ => ('Pending CEO approval', TagPillTone.warning),
    };
    // TagPill never wraps; on a 320dp card the long label is clipped by the
    // Flexible parent via FittedBox rather than pushing the date off the edge.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: TagPill(label: label, tone: tone, dense: true),
    );
  }
}

/// The category-breakdown palette, in the same order as before (red, amber,
/// emerald, blue, purple, pink) mapped to the fixed colour set.
List<Color> expenseChartColors(AppFixedColors f) => [
  f.danger,
  f.warning,
  f.greenDot,
  f.info,
  f.purple,
  f.neutralIcon,
];

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
