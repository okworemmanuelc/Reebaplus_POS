import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/expense_colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/expenses/expense_categories.dart';
import 'package:reebaplus_pos/features/expenses/expense_form_rules.dart';
import 'package:reebaplus_pos/features/expenses/widgets/expense_form_parts.dart';
import 'package:reebaplus_pos/features/expenses/widgets/expense_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Which day the money went out (#652 "When did you spend it?").
enum _SpendDay { today, yesterday, picked }

/// Add Expense (#652, from the owner's mockups). Optionally prefilled to edit
/// an existing expense — descriptive fields only; the amount can't change
/// after saving (see ExpensesDao.updateExpense).
///
/// "Paid to" is saved in the expense's existing `reference` field and is
/// always optional. New expenses save as paid in cash; there is no payment
/// method or receipt on this form any more.
class AddExpenseScreen extends ConsumerStatefulWidget {
  final ExpenseData? editing;
  const AddExpenseScreen({super.key, this.editing});

  static Future<void> show(BuildContext context, {ExpenseData? editing}) {
    return Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddExpenseScreen(editing: editing)),
    );
  }

  @override
  ConsumerState<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends ConsumerState<AddExpenseScreen> {
  final _amountCtrl = TextEditingController();
  final _paidToCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  String? _category;
  bool _categorySeeded = false;
  _SpendDay _day = _SpendDay.today;
  DateTime _pickedDate = DateTime.now();

  /// Errors show only after the first save attempt, then update live.
  bool _triedToSave = false;
  bool _saving = false;

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      _amountCtrl.text = koboToInputText(e.amountKobo);
      _noteCtrl.text = e.description;
      _paidToCtrl.text = e.reference ?? '';
      _setDayFrom(e.expenseDate);
    }
    _amountCtrl.addListener(_refresh);
    _noteCtrl.addListener(_refresh);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _paidToCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _setDayFrom(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final diff = today.difference(day).inDays;
    _pickedDate = date;
    _day = switch (diff) {
      0 => _SpendDay.today,
      1 => _SpendDay.yesterday,
      _ => _SpendDay.picked,
    };
  }

  int get _amountKobo => (parseCurrency(_amountCtrl.text) * 100).round();

  /// The date saved on the expense. Today / Yesterday keep the current clock
  /// time so the list orders them sensibly.
  DateTime get _expenseDate {
    final now = DateTime.now();
    return switch (_day) {
      _SpendDay.today => now,
      _SpendDay.yesterday => now.subtract(const Duration(days: 1)),
      _SpendDay.picked => _pickedDate,
    };
  }

  Set<ExpenseFormProblem> get _problems => validateExpenseForm(
    amountKobo: _amountKobo,
    category: _category,
    note: _noteCtrl.text,
    amountLocked: _isEditing,
  );

  void _quickAdd(int amount) {
    final text = koboToInputText(_amountKobo + amount * 100);
    _amountCtrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _clear() {
    setState(() {
      _amountCtrl.clear();
      _paidToCtrl.clear();
      _noteCtrl.clear();
      _category = null;
      _day = _SpendDay.today;
      _pickedDate = DateTime.now();
      _triedToSave = false;
    });
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _pickedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      builder: (_, child) => ExpenseTheme(child: child!),
    );
    if (date == null || !mounted) return;
    final now = DateTime.now();
    setState(() {
      _pickedDate = DateTime(
        date.year,
        date.month,
        date.day,
        now.hour,
        now.minute,
      );
      _setDayFrom(_pickedDate);
    });
  }

  String? get _paidTo {
    final v = _paidToCtrl.text.trim();
    return v.isEmpty ? null : v;
  }

  Future<void> _save() async {
    if (_problems.isNotEmpty) {
      setState(() => _triedToSave = true);
      return;
    }
    final currentUser = ref.read(authProvider).currentUser;
    if (currentUser == null) return;
    setState(() => _saving = true);
    try {
      if (_isEditing) {
        await _saveEdit(currentUser.id);
      } else {
        await _saveNew(currentUser.id);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveEdit(String userId) async {
    final e = widget.editing!;
    try {
      await ref
          .read(databaseProvider)
          .expensesDao
          .updateExpense(
            expenseId: e.id,
            performedBy: userId,
            categoryName: _category!,
            description: _noteCtrl.text.trim(),
            reference: _paidTo,
            expenseDate: _expenseDate,
            receiptPath: e.receiptPath,
          );
      if (!mounted) return;
      Navigator.pop(context);
      AppNotification.showSuccess(context, 'Expense updated.');
    } catch (err, st) {
      CrashReporter.record(err, st, context: 'expenses.update');
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not update expense. Please try again.',
      );
    }
  }

  Future<void> _saveNew(String userId) async {
    final amountKobo = _amountKobo;
    // §20.8 — stamp the active store (locked, else first selectable), the
    // same resolution a POS sale uses; not the recorder's home store.
    final storeId = ref.read(activeWriteStoreProvider).id;
    // §20.4 — over a Manager's approval limit waits for approval; CEO is
    // unlimited.
    final limit = ref.read(currentUserMaxExpenseApprovalKoboProvider);
    final status = (limit != null && amountKobo > limit)
        ? 'pending'
        : 'approved';
    try {
      await ref
          .read(databaseProvider)
          .expensesDao
          .addExpense(
            categoryName: _category!,
            amountKobo: amountKobo,
            description: _noteCtrl.text.trim(),
            paymentMethod: 'cash',
            reference: _paidTo,
            storeId: storeId,
            recordedBy: userId,
            expenseDate: _expenseDate,
            status: status,
          );
      if (!mounted) return;
      Navigator.pop(context);
      AppNotification.showSuccess(
        context,
        status == 'pending'
            ? 'Expense saved. It is waiting for approval.'
            : 'Expense saved.',
      );
    } catch (err, st) {
      CrashReporter.record(err, st, context: 'expenses.add');
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not save expense. Please try again.',
      );
    }
  }

  /// Seeds the category once from the saved name (edit only).
  void _seedCategory(Map<String, String> names) {
    if (_categorySeeded) return;
    final e = widget.editing;
    if (e == null) {
      _categorySeeded = true;
      return;
    }
    final id = e.categoryId;
    if (id == null) {
      _categorySeeded = true;
    } else if (names.containsKey(id)) {
      _category = names[id];
      _categorySeeded = true;
    }
  }

  /// An old category not in the grid, so the edit can keep it.
  String? get _extraCategory {
    final c = _category;
    if (!_isEditing || c == null) return null;
    final inGrid = kExpenseCategoryChoices.any(
      (k) => k.name.toLowerCase() == c.toLowerCase(),
    );
    return inGrid ? null : c;
  }

  String get _pickLabel => _day == _SpendDay.picked
      ? DateFormat('EEE d MMM').format(_pickedDate)
      : 'Pick a date';

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider);
    _seedCategory(
      ref.watch(expenseCategoryNamesProvider).valueOrNull ??
          const <String, String>{},
    );

    final problems = _triedToSave ? _problems : const <ExpenseFormProblem>{};
    String? errorFor(ExpenseFormProblem p) =>
        problems.contains(p) ? p.message : null;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.color ?? t.colorScheme.onSurface;

    // Expense red whatever the design system (#652).
    return ExpenseTheme(
      child: Builder(
        builder: (context) => _scaffold(context, problems, errorFor, muted),
      ),
    );
  }

  Widget _scaffold(
    BuildContext context,
    Set<ExpenseFormProblem> problems,
    String? Function(ExpenseFormProblem) errorFor,
    Color muted,
  ) {
    final isSalary = isSalaryExpenseCategory(_category);
    final noteRequired = isOtherExpenseCategory(_category);
    final showStore =
        !_isEditing && ref.watch(selectableStoresProvider).length > 1;
    final storeLabel = ref.watch(activeWriteStoreProvider).label;
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // Footer padding is nav-only (deviceBottomPadding): this screen sits
        // under MainLayout, whose Scaffold already resizes for the keyboard.
        resizeToAvoidBottomInset: false,
        appBar: ExpenseTopBar(
          key: ExpenseKeys.addTopBar,
          height: expenseTopBarHeight(context),
          header: ExpenseFormHeader(
            title: _isEditing ? 'Edit Expense' : 'Add Expense',
            subtitle: 'Record money spent for the business',
            trailing: _isEditing
                ? null
                : TextButton(
                    key: ExpenseKeys.addClear,
                    onPressed: _clear,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(
                        kMinInteractiveDimension,
                        kMinInteractiveDimension,
                      ),
                    ),
                    child: Text(
                      'Clear',
                      style: context
                          .boldStyle(16)
                          .copyWith(color: AppExpenseColors.of(context).ink),
                    ),
                  ),
          ),
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gutter = expenseGutter(context, constraints.maxWidth);
              final gap = SizedBox(height: context.getRSize(24));
              return Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        context.getRSize(20),
                        gutter,
                        context.getRSize(24),
                      ),
                      children: [
                        if (problems.isNotEmpty) ...[
                          ExpenseErrorBanner(
                            text: expenseFormBannerText(problems.length),
                          ),
                          SizedBox(height: context.getRSize(20)),
                        ],
                        if (showStore) ...[
                          Row(
                            children: [
                              Icon(
                                AppIcons.store,
                                size: context.getRSize(16),
                                color: muted,
                              ),
                              SizedBox(width: context.getRSize(6)),
                              Expanded(
                                child: Text(
                                  'Recording for $storeLabel',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context
                                      .semiBoldStyle(13)
                                      .copyWith(color: muted),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: context.getRSize(12)),
                        ],
                        ExpenseAmountCard(
                          controller: _amountCtrl,
                          currencySymbol: activeCurrencySymbol,
                          enabled: !_isEditing,
                          onQuickAdd: _quickAdd,
                          error: errorFor(ExpenseFormProblem.noAmount),
                          lockedNote: _isEditing
                              ? 'The amount can’t be changed. To fix it, '
                                    'delete this expense and record it again.'
                              : null,
                        ),
                        gap,
                        const ExpenseSectionLabel(text: 'What was it for?'),
                        ExpenseCategoryGrid(
                          selected: _category,
                          extraName: _extraCategory,
                          onSelected: (name) =>
                              setState(() => _category = name),
                        ),
                        if (errorFor(ExpenseFormProblem.noCategory)
                            case final msg?)
                          ExpenseFieldError(message: msg),
                        gap,
                        ExpenseSectionLabel(
                          text: isSalary ? 'Staff member paid' : 'Paid to',
                          optional: true,
                        ),
                        AppInput(
                          key: ExpenseKeys.paidToField,
                          controller: _paidToCtrl,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          hintText: isSalary
                              ? 'For example, Musa Bello'
                              : 'For example, mechanic, driver or supplier',
                          prefixIcon: Icon(
                            isSalary ? AppIcons.idBadge : AppIcons.user,
                            size: context.getRSize(22),
                            color: muted,
                          ),
                        ),
                        gap,
                        const ExpenseSectionLabel(
                          text: 'When did you spend it?',
                        ),
                        Wrap(
                          spacing: context.getRSize(10),
                          runSpacing: context.getRSize(4),
                          children: [
                            ExpensePillChip(
                              label: 'Today',
                              selected: _day == _SpendDay.today,
                              onTap: () =>
                                  setState(() => _day = _SpendDay.today),
                            ),
                            ExpensePillChip(
                              label: 'Yesterday',
                              selected: _day == _SpendDay.yesterday,
                              onTap: () =>
                                  setState(() => _day = _SpendDay.yesterday),
                            ),
                            ExpensePillChip(
                              label: _pickLabel,
                              icon: AppIcons.calendar,
                              selected: _day == _SpendDay.picked,
                              onTap: _pickDate,
                            ),
                          ],
                        ),
                        gap,
                        ExpenseSectionLabel(
                          text: 'Note',
                          optional: !noteRequired,
                        ),
                        AppInput(
                          key: ExpenseKeys.noteField,
                          controller: _noteCtrl,
                          minLines: 2,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          hintText: 'For example, diesel for the delivery van',
                        ),
                        if (errorFor(ExpenseFormProblem.noNote) case final msg?)
                          ExpenseFieldError(message: msg),
                      ],
                    ),
                  ),
                  ExpenseSaveFooter(
                    amountKobo: _amountKobo,
                    buttonLabel: _isEditing ? 'Save Changes' : 'Save Expense',
                    onSave: _save,
                    gutter: gutter,
                    saving: _saving,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
