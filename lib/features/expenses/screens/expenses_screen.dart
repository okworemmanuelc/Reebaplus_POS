import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/expense_colors.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/widgets/app_fab.dart';
import 'package:reebaplus_pos/features/expenses/expense_categories.dart';
import 'package:reebaplus_pos/features/expenses/expense_summary.dart';
import 'package:reebaplus_pos/features/expenses/screens/add_expense_screen.dart';
import 'package:reebaplus_pos/features/expenses/widgets/expense_list_parts.dart';
import 'package:reebaplus_pos/features/expenses/widgets/expense_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_drawer.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/app_refresh_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/first_run_empty_state.dart';
import 'package:reebaplus_pos/shared/widgets/menu_button.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// Key prefix on every expense row, so a viewport test can assert a
/// *complete* row is laid out and hit-testable (PRD #239's second assertion —
/// a list starved to zero height reports no overflow at all).
const String kExpenseRowKeyPrefix = 'expense-row-';

/// The list filter under the summary card (#652).
enum _ExpenseFilter { all, waiting }

/// Expenses (#652, from the owner's mockups): the "Spent today" summary with
/// the monthly budget, All / Waiting for approval filters, and one list. Tap a
/// row for its details, edit and delete; approvers approve or reject waiting
/// rows in place.
class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  _ExpenseFilter _filter = _ExpenseFilter.all;

  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;

  /// Resolves a recordedBy user id to a first name; never a raw UUID. Null
  /// when unknown, so the row leaves that part out.
  String? _recorderName(String? userId, Map<String, UserData> users) =>
      _fullName(userId, users)?.split(RegExp(r'\s+')).first;

  String _categoryName(ExpenseWithCategory e, Map<String, String> names) {
    if (e.category != null) return e.category!.name;
    final id = e.expense.categoryId;
    if (id != null && names[id] != null) return names[id]!;
    return 'Uncategorized';
  }

  /// "Today, 9:42 AM" / "Yesterday, 6:30 PM" / "Mon 27 Oct".
  String _whenLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final diff = today.difference(day).inDays;
    final time = DateFormat('h:mm a').format(date);
    if (diff == 0) return 'Today, $time';
    if (diff == 1) return 'Yesterday, $time';
    return DateFormat('EEE d MMM').format(date);
  }

  Widget _page({
    required PreferredSizeWidget appBar,
    required Widget body,
    Widget? fab,
  }) {
    // Expense red whatever the design system (#652): the page fade, the app
    // bar, the body and the FAB are red-themed; the drawer keeps the user's
    // own theme.
    final base = Theme.of(context);
    return ExpenseTheme(
      child: Builder(
        builder: (context) => Container(
          decoration: AppDecorations.pageBackground(context),
          child: Theme(data: base, child: _scaffold(appBar, body, fab)),
        ),
      ),
    );
  }

  Widget _scaffold(PreferredSizeWidget appBar, Widget body, Widget? fab) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      // One line: test/tour/drawer_presence_ban_test.dart reads it line by line.
      // dart format off
        drawer: context.isRailLayout ? null : const AppDrawer(activeRoute: 'expenses'),
        // dart format on
      appBar: appBar,
      body: DrawerHost(
        // Side insets (a cutout, a sideways nav bar) are cleared here; under
        // MainLayout they are already removed, so this is a no-op there.
        child: ExpenseTheme(
          child: SafeArea(top: false, bottom: false, child: body),
        ),
      ),
      floatingActionButton: fab == null ? null : ExpenseTheme(child: fab),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money when currency changes
    // Hard rule #6 (load-bearing): the Expenses screen IS the expense
    // report/list, so it is body-guarded on Gates.viewExpenses
    // (`reports.see_expenses`). Guarded.screen waits for the permission set to
    // resolve first (no denial flash) and keeps the drawer + app bar on the
    // loading/denied surfaces. The Record Expense FAB cites Gates.addExpense.
    return Guarded.screen(
      gate: Gates.viewExpenses,
      loading: _page(
        appBar: _buildAppBar(context),
        body: const SizedBox.shrink(),
      ),
      denied: _page(
        appBar: _buildAppBar(context),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'You don’t have access to Expenses.',
              textAlign: TextAlign.center,
              style: context.regularStyle(14).copyWith(color: _subtext),
            ),
          ),
        ),
      ),
      builder: _buildExpenses,
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return ExpenseTopBar(
      key: ExpenseKeys.topBar,
      height: expenseTopBarHeight(context),
      header: ExpenseListHeader(
        title: 'Expenses',
        subtitle: 'Track what your business spends',
        leading: context.isRailLayout ? null : const MenuButton(),
        actions: const [ExpenseLiveBell()],
      ),
    );
  }

  Widget _buildExpenses(BuildContext context) {
    final canAdd =
        ref.watch(allStoresProvider).valueOrNull?.isNotEmpty == true &&
        !ref.watch(zeroStoresEmptySurfaceProvider) &&
        Gates.addExpense.allows(ref);
    return _page(
      appBar: _buildAppBar(context),
      body: ref.watch(zeroStoresEmptySurfaceProvider)
          ? const FirstRunEmptyState()
          : _buildBody(context),
      fab: canAdd
          ? AppFAB(
              heroTag: 'expenses_fab',
              onPressed: () => AddExpenseScreen.show(context),
              icon: AppIcons.add,
              label: 'Record Expense',
            )
          : null,
    );
  }

  Widget _buildBody(BuildContext context) {
    // §20.8 — scoped to the active store (picker); "All Stores" = aggregate.
    final all = ref.watch(viewerScopedExpensesProvider);
    final categoryNames =
        ref.watch(expenseCategoryNamesProvider).valueOrNull ??
        const <String, String>{};
    final users =
        ref.watch(usersByBusinessProvider).valueOrNull ??
        const <String, UserData>{};
    final scopeStoreId = ref.watch(expenseScopeStoreIdProvider);
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final storeNameById = {for (final s in stores) s.id: s.name};
    final showScope = ref.watch(selectableStoresProvider).length > 1;
    final scopeLabel = scopeStoreId == null
        ? 'All Stores'
        : (storeNameById[scopeStoreId] ?? 'Store');
    final showRowStore = scopeStoreId == null && stores.length > 1;

    // #669 — the combined "Daily allowances" lines (per store per day, no
    // worker named, ADR 0034). Never waiting: they show under "All" only.
    // #671 — and the combined "Salaries" lines per store per payday.
    final allowanceLines = staffPayLinesInScope(
      ref.watch(allStaffPayTotalsProvider).valueOrNull ?? const [],
      scopeStoreId,
    );
    final summary = summarizeExpenses(
      all.map((e) => e.expense),
      allowanceLines: allowanceLines,
    );
    final waiting = all.where((e) => e.expense.status == 'pending').toList();
    final shown = <Object>[
      ...(_filter == _ExpenseFilter.waiting ? waiting : all),
      if (_filter == _ExpenseFilter.all) ...allowanceLines,
    ]..sort((a, b) => _itemDate(b).compareTo(_itemDate(a)));
    final canApprove = Gates.approveExpenses.allows(ref);

    return AppRefreshWrapper(
      child: CustomScrollView(
        slivers: [
          _gutterSliver(
            top: 20,
            child: ExpenseSummaryCard(
              spentTodayKobo: summary.spentTodayKobo,
              spentThisWeekKobo: summary.spentThisWeekKobo,
              waitingCount: summary.waitingCount,
              scopeLabel: showScope ? scopeLabel : null,
              budget: _buildBudget(summary, scopeStoreId),
            ),
          ),
          _gutterSliver(
            top: 12,
            child: Wrap(
              spacing: context.getRSize(10),
              runSpacing: context.getRSize(2),
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ExpensePillChip(
                  key: ExpenseKeys.filterAll,
                  label: 'All',
                  selected: _filter == _ExpenseFilter.all,
                  onTap: () => setState(() => _filter = _ExpenseFilter.all),
                ),
                ExpensePillChip(
                  key: ExpenseKeys.filterWaiting,
                  label: 'Waiting for approval (${waiting.length})',
                  selected: _filter == _ExpenseFilter.waiting,
                  onTap: () => setState(() => _filter = _ExpenseFilter.waiting),
                ),
              ],
            ),
          ),
          if (shown.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: ExpensesEmptyMessage(
                message: _filter == _ExpenseFilter.waiting
                    ? 'Nothing is waiting for approval'
                    : 'No expenses found',
              ),
            )
          else
            SliverLayoutBuilder(
              builder: (context, constraints) {
                final gutter = expenseGutter(
                  context,
                  constraints.crossAxisExtent,
                );
                return SliverPadding(
                  // The bottom clears the FAB and the device's gesture inset
                  // so the last row is never permanently covered.
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    context.getRSize(8),
                    gutter,
                    context.getRSize(100) + context.deviceBottomPadding,
                  ),
                  sliver: SliverList.separated(
                    itemCount: shown.length,
                    separatorBuilder: (_, _) =>
                        SizedBox(height: context.getRSize(12)),
                    itemBuilder: (context, i) => switch (shown[i]) {
                      StaffPayTotalData line => _buildAllowanceRow(
                        line,
                        storeName: showRowStore
                            ? (storeNameById[line.storeId] ?? 'Store')
                            : null,
                      ),
                      final e => _buildRow(
                        e as ExpenseWithCategory,
                        categoryNames: categoryNames,
                        users: users,
                        storeName: showRowStore
                            ? _storeLabel(e, storeNameById)
                            : null,
                        canApprove: canApprove,
                      ),
                    },
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  /// A box sliver capped at 720dp and centred through the side gutter.
  Widget _gutterSliver({required double top, required Widget child}) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final gutter = expenseGutter(context, constraints.crossAxisExtent);
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            context.getRSize(top),
            gutter,
            0,
          ),
          sliver: SliverToBoxAdapter(child: child),
        );
      },
    );
  }

  /// §20.8 — the store that recorded an expense, for the "All Stores" view.
  String _storeLabel(ExpenseWithCategory e, Map<String, String> storeNameById) {
    final id = e.expense.storeId;
    if (id == null) return 'Unassigned';
    return storeNameById[id] ?? 'Store';
  }

  // ─────────────────────────── BUDGET (§20.3) ─────────────────────────────────

  /// The monthly budget section, or null when there is nothing to show (no
  /// goal, and the viewer can't set one).
  Widget? _buildBudget(ExpenseSummary summary, String? scopeStoreId) {
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final budgets = ref.watch(expenseBudgetsProvider).valueOrNull ?? const [];
    // §20.8 — the goal follows the active store (null = business-wide).
    final goalKobo = resolveMonthlyBudgetKobo(budgets, scopeStoreId);
    if (goalKobo == null && !isCeo) return null;
    return ExpenseBudgetSection(
      spentKobo: summary.budgetSpentKobo,
      pendingKobo: summary.budgetPendingKobo,
      goalKobo: goalKobo,
      onEdit: isCeo ? () => _openBudgetDialog(scopeStoreId, goalKobo) : null,
    );
  }

  Future<void> _openBudgetDialog(String? scopeStoreId, int? currentKobo) async {
    final controller = TextEditingController(
      text: currentKobo == null ? '' : koboToInputText(currentKobo),
    );
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) {
        return ExpenseTheme(
          child: AlertDialog(
            scrollable: true,
            backgroundColor: _surface,
            title: Text(
              'Budget this month',
              style: ctx.boldStyle(18).copyWith(color: _text),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'How much do you plan to spend each month?',
                  style: ctx.regularStyle(13).copyWith(color: _subtext),
                ),
                SizedBox(height: context.getRSize(16)),
                AppInput(
                  key: ExpenseKeys.budgetField,
                  controller: controller,
                  autofocus: true,
                  labelText: 'Amount',
                  prefixText: '$activeCurrencySymbol ',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [CurrencyInputFormatter()],
                ),
              ],
            ),
            actions: [
              AppButton(
                text: 'Cancel',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.small,
                onPressed: () => Navigator.pop(ctx),
              ),
              AppButton(
                text: 'Save',
                size: AppButtonSize.small,
                onPressed: () {
                  final v = parseCurrency(controller.text.trim());
                  Navigator.pop(ctx, v > 0 ? v : null);
                },
              ),
            ],
          ),
        );
      },
    );

    if (amount == null) return;
    try {
      await ref
          .read(databaseProvider)
          .expenseBudgetsDao
          .setBudget(storeId: scopeStoreId, amountKobo: (amount * 100).round());
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Monthly budget updated.');
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not update budget. Please try again.',
        );
      }
    }
  }

  // ─────────────────────────── ROWS ───────────────────────────────────────────

  /// The day a list item sorts by: an expense's picked date, or a Daily
  /// allowances line's day.
  DateTime _itemDate(Object item) => switch (item) {
    StaffPayTotalData line => staffPayLineDay(line),
    final e => (e as ExpenseWithCategory).expense.expenseDate,
  };

  /// #669 — one store's combined Daily allowances for one day. Read-only here:
  /// a change or cancel happens in Payroll.
  Widget _buildAllowanceRow(StaffPayTotalData line, {String? storeName}) {
    final day = staffPayLineDay(line);
    final now = DateTime.now();
    final diff = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(day.year, day.month, day.day)).inDays;
    final when = diff == 0
        ? 'Today'
        : diff == 1
        ? 'Yesterday'
        : DateFormat('EEE d MMM').format(day);
    return ExpenseListRow(
      key: ValueKey('$kExpenseRowKeyPrefix${line.id}'),
      icon: AppIcons.payroll,
      title: staffPayLineTitle(line),
      subtitle: ['Payroll', when, ?storeName].join(' · '),
      amountKobo: line.amountKobo,
      status: 'approved',
      onTap: () => AppNotification.showInfo(context, switch (line.kind) {
        kStaffPayKindSalaries => 'Salaries are paid in Payroll.',
        kStaffPayKindBonuses => 'Bonuses are given in Payroll.',
        _ => 'Daily allowances are recorded automatically in Payroll.',
      }),
    );
  }

  Widget _buildRow(
    ExpenseWithCategory e, {
    required Map<String, String> categoryNames,
    required Map<String, UserData> users,
    required String? storeName,
    required bool canApprove,
  }) {
    final exp = e.expense;
    final category = _categoryName(e, categoryNames);
    final who = _recorderName(exp.recordedBy, users);
    final parts = [category, ?who, _whenLabel(exp.expenseDate), ?storeName];
    final pending = exp.status == 'pending';
    return ExpenseListRow(
      key: ValueKey('$kExpenseRowKeyPrefix${exp.id}'),
      icon: expenseCategoryIcon(category),
      title: exp.description.trim().isNotEmpty ? exp.description : category,
      subtitle: parts.join(' · '),
      amountKobo: exp.amountKobo,
      status: exp.status,
      onTap: () => _showDetails(
        e,
        category: category,
        recorder: _fullName(exp.recordedBy, users),
        approver: _fullName(exp.approvedBy, users),
        storeName: storeName,
      ),
      actions: pending && canApprove
          ? Row(
              children: [
                Expanded(
                  child: AppButton(
                    text: 'Reject',
                    icon: AppIcons.close,
                    variant: AppButtonVariant.outline,
                    size: AppButtonSize.small,
                    onPressed: () => _rejectExpense(exp),
                  ),
                ),
                SizedBox(width: context.getRSize(10)),
                Expanded(
                  child: AppButton(
                    text: 'Approve',
                    icon: AppIcons.check,
                    variant: AppButtonVariant.success,
                    size: AppButtonSize.small,
                    onPressed: () => _approveExpense(exp),
                  ),
                ),
              ],
            )
          : null,
    );
  }

  String? _fullName(String? userId, Map<String, UserData> users) {
    final name = userId == null ? null : users[userId]?.name.trim();
    return (name == null || name.isEmpty) ? null : name;
  }

  // ─────────────────────────── DETAILS SHEET ──────────────────────────────────

  Future<void> _showDetails(
    ExpenseWithCategory e, {
    required String category,
    required String? recorder,
    required String? approver,
    required String? storeName,
  }) async {
    final exp = e.expense;
    final canEdit = _canEdit(exp);
    final canDelete = _canDelete();
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) {
        final reason = exp.rejectionReason?.trim();
        final paidTo = exp.reference?.trim();
        return ExpenseTheme(
          child: SingleChildScrollView(
            key: ExpenseKeys.detailSheet,
            padding: EdgeInsets.fromLTRB(
              ctx.getRSize(20),
              ctx.getRSize(20),
              ctx.getRSize(20),
              ctx.getRSize(20) + ctx.deviceBottomPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconTile(
                      icon: expenseCategoryIcon(category),
                      tint: AppExpenseColors.of(ctx).tint,
                      iconColor: AppExpenseColors.of(ctx).ink,
                    ),
                    SizedBox(width: ctx.getRSize(12)),
                    Expanded(
                      child: Text(
                        exp.description.trim().isNotEmpty
                            ? exp.description
                            : category,
                        style: ctx.boldStyle(18).copyWith(color: _text),
                      ),
                    ),
                    ExpenseStatusPill(status: exp.status),
                  ],
                ),
                SizedBox(height: ctx.getRSize(12)),
                Text(
                  '−${formatCurrency(exp.amountKobo / 100.0)}',
                  style: ctx.extraBoldStyle(28).copyWith(color: _text),
                ),
                SizedBox(height: ctx.getRSize(12)),
                ExpenseDetailLine(label: 'For', value: category),
                if (paidTo != null && paidTo.isNotEmpty)
                  ExpenseDetailLine(
                    label: isSalaryExpenseCategory(category)
                        ? 'Staff paid'
                        : 'Paid to',
                    value: paidTo,
                  ),
                ExpenseDetailLine(
                  label: 'Spent on',
                  value: DateFormat('EEE d MMM y').format(exp.expenseDate),
                ),
                ExpenseDetailLine(label: 'Recorded by', value: recorder ?? '—'),
                if (storeName != null)
                  ExpenseDetailLine(label: 'Store', value: storeName),
                if (exp.status != 'pending' && approver != null)
                  ExpenseDetailLine(
                    label: exp.status == 'rejected'
                        ? 'Rejected by'
                        : 'Approved by',
                    value: approver,
                  ),
                if (reason != null && reason.isNotEmpty)
                  ExpenseDetailLine(label: 'Reason', value: reason),
                if (canEdit || canDelete) ...[
                  SizedBox(height: ctx.getRSize(16)),
                  Row(
                    children: [
                      if (canDelete)
                        Expanded(
                          child: AppButton(
                            text: 'Delete',
                            icon: AppIcons.delete,
                            variant: AppButtonVariant.outline,
                            onPressed: () => Navigator.pop(ctx, 'delete'),
                          ),
                        ),
                      if (canEdit && canDelete)
                        SizedBox(width: ctx.getRSize(12)),
                      if (canEdit)
                        Expanded(
                          child: AppButton(
                            text: 'Edit',
                            icon: AppIcons.edit,
                            onPressed: () => Navigator.pop(ctx, 'edit'),
                          ),
                        ),
                    ],
                  ),
                ],
                if (exp.status == 'pending' &&
                    !Gates.approveExpenses.allows(ref))
                  Padding(
                    padding: EdgeInsets.only(top: ctx.getRSize(12)),
                    child: Text(
                      'Waiting for the owner to approve.',
                      style: ctx.semiBoldStyle(13).copyWith(color: f.warning),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    if (action == 'edit') {
      await AddExpenseScreen.show(context, editing: exp);
    } else if (action == 'delete') {
      await _deleteExpense(exp);
    }
  }

  // ─────────────────────── APPROVALS (§20.4) ─────────────────────────────────

  Future<void> _approveExpense(ExpenseData exp) async {
    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;
    try {
      await ref
          .read(databaseProvider)
          .expensesDao
          .approveExpense(expenseId: exp.id, approverId: currentUser.id);
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Expense approved.');
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not approve expense. Please try again.',
        );
      }
    }
  }

  Future<void> _rejectExpense(ExpenseData exp) async {
    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;
    final reasonController = TextEditingController();

    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final r = reasonController.text.trim();
            return ExpenseTheme(
              child: AlertDialog(
                scrollable: true,
                backgroundColor: _surface,
                title: Text(
                  'Reject expense',
                  style: ctx.boldStyle(18).copyWith(color: _text),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'The person who recorded it is told why. No money moves '
                      'when you reject.',
                      style: ctx.regularStyle(13).copyWith(color: _subtext),
                    ),
                    SizedBox(height: context.getRSize(16)),
                    AppInput(
                      key: ExpenseKeys.rejectField,
                      controller: reasonController,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 3,
                      labelText: 'Reason (required)',
                      onChanged: (_) => setDialogState(() {}),
                    ),
                  ],
                ),
                actions: [
                  AppButton(
                    text: 'Back',
                    variant: AppButtonVariant.ghost,
                    size: AppButtonSize.small,
                    onPressed: () => Navigator.pop(ctx),
                  ),
                  AppButton(
                    text: 'Reject',
                    icon: AppIcons.close,
                    variant: AppButtonVariant.danger,
                    size: AppButtonSize.small,
                    onPressed: r.isEmpty ? null : () => Navigator.pop(ctx, r),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (reason == null || reason.isEmpty) return;
    try {
      await ref
          .read(databaseProvider)
          .expensesDao
          .rejectExpense(
            expenseId: exp.id,
            approverId: currentUser.id,
            reason: reason,
          );
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Expense rejected.');
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not reject expense. Please try again.',
        );
      }
    }
  }

  // ─────────────────────────── EDIT / DELETE (§20.3) ──────────────────────────

  bool _canEdit(ExpenseData exp) {
    final slug = ref.read(currentUserRoleProvider)?.slug;
    if (slug == 'ceo') return true;
    final currentUser = ref.read(authProvider).currentUser;
    final within24h =
        DateTime.now().difference(exp.createdAt) < const Duration(hours: 24);
    return exp.recordedBy == currentUser?.id && within24h && slug == 'manager';
  }

  bool _canDelete() => ref.read(currentUserRoleProvider)?.slug == 'ceo';

  Future<void> _deleteExpense(ExpenseData exp) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return ExpenseTheme(
          child: AlertDialog(
            backgroundColor: _surface,
            title: Text(
              'Delete expense',
              style: ctx.boldStyle(18).copyWith(color: _text),
            ),
            content: Text(
              'This removes the expense.',
              style: ctx.regularStyle(13).copyWith(color: _subtext),
            ),
            actions: [
              AppButton(
                text: 'Cancel',
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.small,
                onPressed: () => Navigator.pop(ctx, false),
              ),
              AppButton(
                text: 'Delete',
                icon: AppIcons.delete,
                variant: AppButtonVariant.danger,
                size: AppButtonSize.small,
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true) return;

    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;
    try {
      await ref
          .read(databaseProvider)
          .expensesDao
          .softDeleteExpense(expenseId: exp.id, performedBy: currentUser.id);
      if (!mounted) return;
      AppNotification.showSuccess(context, 'Expense deleted.');
    } catch (_) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not delete expense. Please try again.',
        );
      }
    }
  }
}
