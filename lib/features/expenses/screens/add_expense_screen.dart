import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/expenses/widgets/expense_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/constants.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// §20.2 Record Expense screen. Optionally prefilled to edit an existing expense
/// (descriptive fields only — amount / method / account are immutable after
/// creation; see ExpensesDao.updateExpense).
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

// UI label → stored payment_method code (§20.2 / DB CHECK).
const _kPaymentMethods = <({String label, String code})>[
  (label: 'Cash', code: 'cash'),
  (label: 'Bank Transfer', code: 'transfer'),
  (label: 'POS card', code: 'pos'),
  (label: 'Other', code: 'other'),
];

const _kSeedCategories = <String>[
  'Fuel',
  'Salary',
  'Rent',
  'Maintenance',
  'Utilities',
  'Supplies',
  'Others',
];

class _AddExpenseScreenState extends ConsumerState<AddExpenseScreen> {
  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(_onAmountChanged);
    _categoryCtrl.addListener(_onCategoryChanged);
    final e = widget.editing;
    if (e != null) {
      _amountCtrl.text = (e.amountKobo / 100).toStringAsFixed(2);
      _currentAmount = e.amountKobo / 100;
      _descCtrl.text = e.description;
      _refCtrl.text = e.reference ?? '';
      _selectedDate = e.expenseDate;
      _paymentMethodCode = e.paymentMethod ?? 'cash';
      _existingReceiptPath = e.receiptPath;
      // Category name is resolved from the id by the parent and passed via the
      // controller below in didChangeDependencies-free way: seed from provider.
    }
  }

  void _onAmountChanged() {
    final amt = parseCurrency(_amountCtrl.text);
    if (amt != _currentAmount) {
      setState(() => _currentAmount = amt);
    }
  }

  void _onCategoryChanged() {
    if (!mounted) return;
    setState(() {}); // refresh suggestion list / Others-requires-desc hint
  }

  Future<void> _pickReceipt() async {
    AutoLockWrapper.suppressNextResume = true;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'png', 'pdf'],
    );

    if (result != null) {
      setState(() => _receiptFile = result.files.first);
    }
  }

  final _amountCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  late final _recordedByCtrl = TextEditingController(
    text: ref.read(authProvider).currentUser?.name ?? 'Admin',
  );
  final _formKey = GlobalKey<FormState>();

  PlatformFile? _receiptFile;
  String? _existingReceiptPath;
  double _currentAmount = 0;
  bool _categorySeeded = false;

  String _paymentMethodCode = 'cash';
  DateTime _selectedDate = DateTime.now();

  Color get _cardBg => Theme.of(context).cardColor;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _categoryCtrl.dispose();
    _descCtrl.dispose();
    _refCtrl.dispose();
    _recordedByCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (date != null) {
      setState(() => _selectedDate = date);
    }
  }

  Future<void> _submitEdit() async {
    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    final currentUser = auth.currentUser;
    if (currentUser == null) return;
    try {
      await db.expensesDao.updateExpense(
        expenseId: widget.editing!.id,
        performedBy: currentUser.id,
        categoryName: _categoryCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        reference: _refCtrl.text.trim().isEmpty ? null : _refCtrl.text.trim(),
        expenseDate: _selectedDate,
        receiptPath: _receiptFile?.path ?? _existingReceiptPath,
      );
      if (mounted) {
        Navigator.pop(context);
        AppNotification.showSuccess(context, 'Expense updated.');
      }
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'expenses.update');
      if (!mounted) return;
      AppNotification.showError(
        context,
        'Could not update expense. Please try again.',
      );
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final category = _categoryCtrl.text.trim();
    if (category.isEmpty) {
      AppNotification.showError(context, 'Pick or type a category.');
      return;
    }

    final desc = _descCtrl.text.trim();
    final isOthers = category.toLowerCase() == 'others';
    if (isOthers && desc.isEmpty) {
      AppNotification.showError(
        context,
        'Description is required for "Others" category.',
      );
      return;
    }

    if (_isEditing) {
      await _submitEdit();
      return;
    }

    final amount = parseCurrency(_amountCtrl.text);
    final needsReceipt = amount >= largeExpenseThreshold;
    if (needsReceipt && _receiptFile == null) {
      AppNotification.showError(
        context,
        'Receipt upload is required for expenses of 20,000 and above.',
      );
      return;
    }
    final amtKobo = (amount * 100).toInt();

    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);
    final currentUser = auth.currentUser;
    if (currentUser == null) return;
    // §20.8 — stamp the active store (locked, else first selectable), the same
    // resolution a POS sale and a supplier activity use; not the recorder's home
    // store. The "Recording for:" banner shows this store in the form.
    final storeId = ref.read(activeWriteStoreProvider).id;

    final method = _paymentMethodCode;

    // §20.4 — over a Manager's approval limit becomes Pending; CEO is unlimited.
    final limit = ref.read(currentUserMaxExpenseApprovalKoboProvider);
    final status = (limit != null && amtKobo > limit) ? 'pending' : 'approved';

    try {
      await db.expensesDao.addExpense(
        categoryName: category,
        amountKobo: amtKobo,
        description: desc,
        paymentMethod: method,
        reference: _refCtrl.text.trim().isEmpty ? null : _refCtrl.text.trim(),
        storeId: storeId,
        recordedBy: currentUser.id,
        expenseDate: _selectedDate,
        receiptPath: _receiptFile?.path,
        status: status,
      );

      if (mounted) {
        Navigator.pop(context);
        AppNotification.showSuccess(
          context,
          status == 'pending'
              ? 'Expense sent for CEO approval.'
              : 'Expense recorded.',
        );
      }
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'expenses.add');
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not record expense. Please try again.',
        );
      }
    }
  }

  String _methodLabel(String code) {
    for (final m in _kPaymentMethods) {
      if (m.code == code) return m.label;
    }
    // Legacy/unknown code (the DB CHECK also allows 'card') — never crash;
    // render a readable fallback.
    if (code.isEmpty) return 'Other';
    return code[0].toUpperCase() + code.substring(1);
  }

  /// §20.8 — read-only "Recording for: <store>" banner so the target store is
  /// explicit. To record against a different store, switch the active store from
  /// the menu (the drawer picker is the single store control).
  Widget _recordingForBanner(BuildContext context, String label) {
    final primary = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color:
            Theme.of(context).extension<AppFixedColors>()?.infoTint ??
            primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
        border: Border.all(color: _border),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.getRSize(14),
          vertical: context.getRSize(12),
        ),
        child: Row(
          children: [
            Icon(AppIcons.store, size: context.getRSize(16), color: primary),
            SizedBox(width: context.getRSize(8)),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Recording for: ',
                      style: context.regularStyle(12).copyWith(color: _subtext),
                    ),
                    TextSpan(
                      text: label,
                      style: context.boldStyle(12).copyWith(color: primary),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Seed the category field once from the (resolved) category name map.
    final catNames = ref.watch(expenseCategoryNamesProvider).valueOrNull ?? {};
    if (!_categorySeeded) {
      final e = widget.editing;
      if (e?.categoryId != null && catNames.containsKey(e!.categoryId)) {
        _categoryCtrl.text = catNames[e.categoryId]!;
        _categorySeeded = true;
      } else if (e == null) {
        _categorySeeded = true; // new expense — start blank
      }
    }

    // Searchable category suggestions: seed defaults ∪ existing categories.
    final allCategories = <String>{..._kSeedCategories, ...catNames.values};
    final query = _categoryCtrl.text.trim().toLowerCase();
    final suggestions =
        allCategories
            .where((c) => query.isEmpty || c.toLowerCase().contains(query))
            .where((c) => c.toLowerCase() != query) // hide exact match
            .take(6)
            .toList()
          ..sort();

    // §20.8 — when more than one store is selectable, show which store this
    // expense will be recorded against (the active store). Store is immutable on
    // edit, so only show it while creating.
    final writeStore = ref.watch(activeWriteStoreProvider);
    final showStoreBanner =
        !_isEditing && ref.watch(selectableStoresProvider).length > 1;

    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // Footer-button padding is nav-only (deviceBottomPadding): this screen is
        // under MainLayout, whose Scaffold already resizes the body for the
        // keyboard, so the inset must not re-add it. resizeToAvoidBottomInset:false
        // is a harmless no-op here (the screen sees viewInsets 0 under MainLayout).
        resizeToAvoidBottomInset: false,
        appBar: ExpenseTopBar(
          key: ExpenseKeys.addTopBar,
          height: expenseTopBarHeight(context),
          header: ScreenHeader(
            icon: AppIcons.expenses,
            title: _isEditing ? 'Edit Expense' : 'Record Expense',
            subtitle: 'Log operating costs',
            leading: const ExpenseBackButton(),
          ),
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Form screen: capped at 720dp and centred through the gutter.
              final gutter = expenseGutter(context, constraints.maxWidth);
              return Form(
                key: _formKey,
                child: Column(
                  children: [
                    // Scrollable Content
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.symmetric(
                          horizontal: gutter,
                          vertical: context.getRSize(10),
                        ),
                        children: [
                          if (showStoreBanner) ...[
                            _recordingForBanner(context, writeStore.label),
                            SizedBox(height: context.getRSize(16)),
                          ],
                          // Category (searchable + create-on-the-fly)
                          AppInput(
                            labelText: 'Category',
                            controller: _categoryCtrl,
                            hintText: 'Search or type a new category',
                            suffixIcon: Icon(
                              AppIcons.search,
                              size: context.getRSize(14),
                              color: _subtext,
                            ),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Category is required'
                                : null,
                          ),
                          if (suggestions.isNotEmpty)
                            Padding(
                              padding: EdgeInsets.only(
                                top: context.getRSize(8),
                              ),
                              child: Wrap(
                                spacing: context.getRSize(8),
                                runSpacing: context.getRSize(8),
                                children: suggestions.map((cat) {
                                  return ActionChip(
                                    label: Text(
                                      cat,
                                      style: context
                                          .semiBoldStyle(12)
                                          .copyWith(color: _text),
                                    ),
                                    backgroundColor: _cardBg,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        AppSpacing.borderRadiusXL,
                                      ),
                                      side: BorderSide(color: _border),
                                    ),
                                    onPressed: () {
                                      _categoryCtrl.text = cat;
                                      _categoryCtrl.selection =
                                          TextSelection.collapsed(
                                            offset: cat.length,
                                          );
                                      setState(() {});
                                    },
                                  );
                                }).toList(),
                              ),
                            ),
                          SizedBox(height: context.getRSize(16)),

                          // Amount (immutable on edit — corrected by delete + re-record)
                          AppInput(
                            labelText: 'Amount',
                            controller: _amountCtrl,
                            enabled: !_isEditing,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [CurrencyInputFormatter()],
                            hintText: '0.00',
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Amount is required'
                                : null,
                          ),
                          if (_isEditing)
                            Padding(
                              padding: EdgeInsets.only(
                                top: context.getRSize(4),
                                left: context.getRSize(4),
                              ),
                              child: Text(
                                'Amount and payment method can\'t be edited. '
                                'To change them, delete and record again.',
                                style: context
                                    .regularStyle(11)
                                    .copyWith(color: _subtext),
                              ),
                            ),
                          SizedBox(height: context.getRSize(16)),

                          // Payment Method — immutable on edit, so show it read-only there.
                          if (_isEditing)
                            AppInput(
                              labelText: 'Payment Method',
                              enabled: false,
                              controller: TextEditingController(
                                text: _methodLabel(_paymentMethodCode),
                              ),
                            )
                          else
                            AppDropdown<String>(
                              labelText: 'Payment Method',
                              value: _paymentMethodCode,
                              items: _kPaymentMethods
                                  .map(
                                    (m) => DropdownMenuItem(
                                      value: m.code,
                                      child: Text(
                                        m.label,
                                        style: context
                                            .mediumStyle(14)
                                            .copyWith(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurface,
                                            ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() {
                                    _paymentMethodCode = val;
                                  });
                                }
                              },
                            ),
                          SizedBox(height: context.getRSize(16)),

                          AppInput(
                            labelText: 'Date',
                            readOnly: true,
                            onTap: _pickDate,
                            controller: TextEditingController(
                              text: DateFormat(
                                'MMM d, y',
                              ).format(_selectedDate),
                            ),
                            suffixIcon: Icon(
                              AppIcons.calendar,
                              size: context.getRSize(16),
                              color: _subtext,
                            ),
                          ),
                          SizedBox(height: context.getRSize(16)),

                          AppInput(
                            labelText:
                                'Description ${_categoryCtrl.text.trim().toLowerCase() == "others" ? "(Required)" : "(Optional)"}',
                            controller: _descCtrl,
                            maxLines: 2,
                            hintText: 'What was this expense for?',
                          ),
                          SizedBox(height: context.getRSize(16)),

                          AppInput(
                            labelText: 'Reference / Receipt No. (Optional)',
                            controller: _refCtrl,
                            hintText: 'e.g. REC-0912...',
                          ),
                          SizedBox(height: context.getRSize(16)),

                          // Receipt Upload (Large Expenses)
                          if (_currentAmount >= largeExpenseThreshold) ...[
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: context.getRSize(8),
                              ),
                              child: Text(
                                'Receipt (Required for large expenses)',
                                style: context
                                    .boldStyle(12)
                                    .copyWith(color: _subtext),
                              ),
                            ),
                            Builder(
                              builder: (context) {
                                final missing =
                                    _receiptFile == null &&
                                    _existingReceiptPath == null;
                                final ink = missing ? f.danger : f.green;
                                final radius = BorderRadius.circular(
                                  AppSpacing.borderRadiusL,
                                );
                                return Material(
                                  color: _cardBg,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: radius,
                                    side: BorderSide(
                                      color: missing
                                          ? f.dangerOutline
                                          : f.green,
                                    ),
                                  ),
                                  child: InkWell(
                                    borderRadius: radius,
                                    onTap: _pickReceipt,
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minHeight: kMinInteractiveDimension,
                                      ),
                                      child: Padding(
                                        padding: EdgeInsets.all(
                                          context.getRSize(16),
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              missing
                                                  ? AppIcons.exportFile
                                                  : AppIcons.fileApproved,
                                              size: context.getRSize(20),
                                              color: ink,
                                            ),
                                            SizedBox(
                                              width: context.getRSize(12),
                                            ),
                                            Expanded(
                                              child: Text(
                                                _receiptFile?.name ??
                                                    (_existingReceiptPath !=
                                                            null
                                                        ? 'Receipt attached'
                                                        : 'Upload Receipt (JPG, PNG, PDF)'),
                                                style: context
                                                    .boldStyle(14)
                                                    .copyWith(
                                                      color: missing
                                                          ? _subtext
                                                          : _text,
                                                    ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                            SizedBox(height: context.getRSize(16)),
                          ],

                          AppInput(
                            labelText: 'Recorded By',
                            controller: _recordedByCtrl,
                            enabled: false,
                            hintText: 'Name of staff',
                          ),
                          SizedBox(height: context.getRSize(24)),
                        ],
                      ),
                    ),

                    // Button
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        context.getRSize(16),
                        gutter,
                        context.deviceBottomPadding + context.getRSize(16),
                      ),
                      child: AppButton(
                        text: _isEditing ? 'Save Changes' : 'Save Expense',
                        variant: AppButtonVariant.danger,
                        onPressed: _submit,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
