import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/constants.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:file_picker/file_picker.dart';
import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

class AddExpenseSheet extends ConsumerStatefulWidget {
  const AddExpenseSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AddExpenseSheet(),
    );
  }

  @override
  ConsumerState<AddExpenseSheet> createState() => _AddExpenseSheetState();
}

class _AddExpenseSheetState extends ConsumerState<AddExpenseSheet> {
  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(_onAmountChanged);
  }

  void _onAmountChanged() {
    final amt = parseCurrency(_amountCtrl.text);
    if (amt != _currentAmount) {
      setState(() => _currentAmount = amt);
    }
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
  final _descCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  late final _recordedByCtrl = TextEditingController(
    text: ref.read(authProvider).currentUser?.name ?? 'Admin',
  );
  final _formKey = GlobalKey<FormState>();

  PlatformFile? _receiptFile;
  double _currentAmount = 0;

  String _paymentMethod = 'Cash';
  DateTime _selectedDate = DateTime.now();
  String _selectedCategory = 'Fuel';

  final List<String> _categories = [
    'Fuel',
    'Salary',
    'Rent',
    'Maintenance',
    'Utilities',
    'Supplies',
    'Others',
  ];
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _cardBg => Theme.of(context).cardColor;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void dispose() {
    _amountCtrl.dispose();
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
      lastDate: DateTime(2100),
      builder: (context, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: isDark
                ? const ColorScheme.dark(primary: danger, surface: dSurface)
                : const ColorScheme.light(primary: danger, surface: lSurface),
          ),
          child: child!,
        );
      },
    );
    if (date != null) {
      setState(() => _selectedDate = date);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final amount = parseCurrency(_amountCtrl.text);
    final isOthers = _selectedCategory == 'Others';
    final desc = _descCtrl.text.trim();

    if (isOthers && desc.isEmpty) {
      AppNotification.showError(context, 'Description is required for "Others" category.');
      return;
    }

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

    await db.expensesDao.addExpense(
      categoryName: _selectedCategory,
      amountKobo: amtKobo,
      description: desc,
      paymentMethod: _paymentMethod,
      reference: _refCtrl.text,
      storeId: currentUser.storeId,
      recordedBy: currentUser.id,
    );

    if (mounted) Navigator.pop(context);
  }



  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context),
      child: DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.5,
        maxChildSize: 0.9,
        snap: true,
        snapSizes: const [0.5, 0.9],
        builder: (context, scrollController) {
          return GestureDetector(
            onTap: () {}, // Prevent tap from reaching the barrier
            child: Container(
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    // Handle & Header
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        context.getRSize(20),
                        context.getRSize(12),
                        context.getRSize(20),
                        0,
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: context.getRSize(40),
                            height: context.getRSize(4),
                            decoration: BoxDecoration(
                              color: _border,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          SizedBox(height: context.getRSize(20)),
                          Row(
                            children: [
                              Container(
                                width: context.getRSize(44),
                                height: context.getRSize(44),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Theme.of(context).colorScheme.error
                                          .withValues(alpha: 0.8),
                                      danger,
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Theme.of(context).colorScheme.error
                                          .withValues(alpha: 0.3),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  FontAwesomeIcons.fileInvoiceDollar,
                                  color: Colors.white,
                                  size: context.getRSize(20),
                                ),
                              ),
                              SizedBox(width: context.getRSize(14)),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Record Expense',
                                    style: TextStyle(
                                      fontSize: context.getRFontSize(18),
                                      fontWeight: FontWeight.w800,
                                      color: _text,
                                    ),
                                  ),
                                  Text(
                                    'Log operating costs',
                                    style: TextStyle(
                                      fontSize: context.getRFontSize(13),
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          SizedBox(height: context.getRSize(10)),
                        ],
                      ),
                    ),

                    // Scrollable Content
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(20),
                          vertical: context.getRSize(10),
                        ),
                        children: [
                          // Categories
                          Padding(
                            padding: EdgeInsets.only(bottom: context.getRSize(8)),
                            child: Text(
                              'Category',
                              style: TextStyle(
                                fontSize: context.getRFontSize(12),
                                fontWeight: FontWeight.w700,
                                color: _subtext,
                              ),
                            ),
                          ),
                          Wrap(
                            spacing: context.getRSize(8),
                            runSpacing: context.getRSize(8),
                            children: _categories.map((cat) {
                              final isSelected = _selectedCategory == cat;
                              return ChoiceChip(
                                label: Text(
                                  cat,
                                  style: TextStyle(
                                    fontSize: context.getRFontSize(12),
                                    color: isSelected ? Colors.white : _text,
                                    fontWeight: isSelected
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                                selected: isSelected,
                                onSelected: (val) {
                                  if (val) {
                                    setState(() => _selectedCategory = cat);
                                  }
                                },
                                selectedColor: Theme.of(
                                  context,
                                ).colorScheme.error,
                                backgroundColor: _cardBg,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  side: BorderSide(
                                    color: isSelected
                                        ? Colors.transparent
                                        : _border,
                                  ),
                                ),
                                showCheckmark: false,
                              );
                            }).toList(),
                          ),
                          SizedBox(height: context.getRSize(20)),

                          // Amount
                          AppInput(
                            labelText: 'Amount',
                            controller: _amountCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [CurrencyInputFormatter()],
                            hintText: '0.00',
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Amount is required'
                                : null,
                          ),
                          SizedBox(height: context.getRSize(16)),

                          // Payment Method
                          AppDropdown<String>(
                            labelText: 'Payment Method',
                            value: _paymentMethod,
                            items: ['Cash', 'Transfer', 'POS', 'Credit']
                                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _paymentMethod = val);
                              }
                            },
                          ),
                          SizedBox(height: context.getRSize(16)),

                          AppInput(
                            labelText: 'Date',
                            readOnly: true,
                            onTap: _pickDate,
                            controller: TextEditingController(
                              text: DateFormat('MMM d, y').format(_selectedDate),
                            ),
                            suffixIcon: Icon(
                              FontAwesomeIcons.calendar,
                              size: context.getRSize(16),
                              color: _subtext,
                            ),
                          ),
                          SizedBox(height: context.getRSize(16)),

                          AppInput(
                            labelText: 'Description ${_selectedCategory == "Others" ? "(Required)" : "(Optional)"}',
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
                              padding: EdgeInsets.only(bottom: context.getRSize(8)),
                              child: Text(
                                'Receipt (Required for large expenses)',
                                style: TextStyle(
                                  fontSize: context.getRFontSize(12),
                                  fontWeight: FontWeight.w700,
                                  color: _subtext,
                                ),
                              ),
                            ),
                            InkWell(
                              onTap: _pickReceipt,
                              child: Container(
                                padding: EdgeInsets.all(context.getRSize(16)),
                                decoration: BoxDecoration(
                                  color: _cardBg,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: _receiptFile == null
                                        ? Theme.of(context).colorScheme.error
                                              .withValues(alpha: 0.5)
                                        : success,
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      _receiptFile == null
                                          ? FontAwesomeIcons.fileArrowUp
                                          : FontAwesomeIcons.fileCircleCheck,
                                      size: context.getRSize(18),
                                      color: _receiptFile == null
                                          ? danger
                                          : success,
                                    ),
                                    SizedBox(width: context.getRSize(12)),
                                    Expanded(
                                      child: Text(
                                        _receiptFile?.name ??
                                            'Upload Receipt (JPG, PNG, PDF)',
                                        style: TextStyle(
                                          fontSize: context.getRFontSize(14),
                                          fontWeight: FontWeight.bold,
                                          color: _receiptFile == null
                                              ? _subtext
                                              : _text,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (_receiptFile != null)
                                      Icon(
                                        FontAwesomeIcons.check,
                                        size: context.getRSize(14),
                                        color: success,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            if (_receiptFile == null)
                              Padding(
                                padding: EdgeInsets.only(
                                  top: context.getRSize(4),
                                  left: context.getRSize(4),
                                ),
                                child: Text(
                                  'Please upload a receipt to continue',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                    fontSize: context.getRFontSize(11),
                                  ),
                                ),
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
                        context.getRSize(20),
                        context.getRSize(16),
                        context.getRSize(20),
                        context.bottomInset + context.getRSize(16),
                      ),
                      child: AppButton(
                        text: 'Save Expense',
                        variant: AppButtonVariant.danger,
                        onPressed: _submit,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
