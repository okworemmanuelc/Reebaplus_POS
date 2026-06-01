import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

import 'package:reebaplus_pos/features/payments/data/models/payment.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/features/inventory/data/models/supplier.dart';
import 'package:reebaplus_pos/features/inventory/data/models/crate_group.dart';

class AddPaymentSheet extends ConsumerStatefulWidget {
  const AddPaymentSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AddPaymentSheet(),
    );
  }

  @override
  ConsumerState<AddPaymentSheet> createState() => _AddPaymentSheetState();
}

class _AddPaymentSheetState extends ConsumerState<AddPaymentSheet> {
  final _amountCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _supplierCtrl = TextEditingController(); // To hold the typed name
  final _formKey = GlobalKey<FormState>();

  String _paymentMethod = 'Cash';
  DateTime _selectedDate = DateTime.now();
  String? _selectedDeliveryId;
  Supplier? _selectedSupplier;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext => Theme.of(context).textTheme.bodySmall?.color ?? Theme.of(context).iconTheme.color!;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _refCtrl.dispose();
    _notesCtrl.dispose();
    _supplierCtrl.dispose();
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
                ? ColorScheme.dark(primary: Theme.of(context).colorScheme.primary, surface: dSurface)
                : ColorScheme.light(primary: Theme.of(context).colorScheme.primary, surface: lSurface),
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

    final typedName = _supplierCtrl.text.trim();
    if (typedName.isEmpty) return;

    // Check if supplier exists.
    final suppliers = ref.read(supplierServiceProvider);
    Supplier? finalSupplier = _selectedSupplier;
    if (finalSupplier == null ||
        finalSupplier.name.toLowerCase() != typedName.toLowerCase()) {
      final existing = suppliers.getAll().where(
        (s) => s.name.toLowerCase() == typedName.toLowerCase(),
      );
      if (existing.isNotEmpty) {
        finalSupplier = existing.first;
      } else {
        // Show dialog
        final create = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: _surface,
            title: Text(
              'New Supplier',
              style: TextStyle(color: _text, fontWeight: FontWeight.bold),
            ),
            content: Text(
              '$typedName is not an existing supplier. Do you want to add them and record this payment?',
              style: TextStyle(color: _subtext),
            ),
            actions: [
              AppButton(
                text: 'Cancel',
                variant: AppButtonVariant.ghost,
                onPressed: () => Navigator.pop(ctx, false),
              ),
              AppButton(
                text: 'Confirm',
                onPressed: () => Navigator.pop(ctx, true),
                size: AppButtonSize.small,
              ),
            ],
          ),
        );
        if (create != true) return; // User cancelled

        finalSupplier = Supplier(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: typedName,
          crateGroup: CrateGroup.nbPlc, // Default or pick based on name?
        );
        suppliers.addSupplier(finalSupplier); // Adds to memory
      }
    }

    final amount = parseCurrency(_amountCtrl.text);

    final payment = Payment(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      supplierId: finalSupplier.id,
      supplierName: finalSupplier.name,
      amount: amount,
      paymentMethod: _paymentMethod,
      referenceNumber: _refCtrl.text.isEmpty ? null : _refCtrl.text,
      notes: _notesCtrl.text.isEmpty ? null : _notesCtrl.text,
      deliveryId: _selectedDeliveryId,
      date: _selectedDate,
      createdAt: DateTime.now(),
    );

    // Write to the payments ledger
    ref.read(paymentServiceProvider).addPayment(payment);

    // Update the specific supplier's balance (no interaction with Customers)
    finalSupplier.amountPaid += amount;
    finalSupplier.supplierWallet -= amount;

    await ref.read(activityLogProvider).logAction(
      'Supplier Payment Recorded',
      'Payment of ${formatCurrency(amount)} to ${finalSupplier.name} via $_paymentMethod',
    );

    if (mounted) Navigator.pop(context);
  }



  @override
  Widget build(BuildContext context) {
    final recentDeliveries = ref.read(deliveryServiceProvider).getAll().take(10).toList();

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
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
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
                                    colors: [Theme.of(context).colorScheme.primary.withValues(alpha: 0.7), Theme.of(context).colorScheme.primary],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  FontAwesomeIcons.moneyBillTransfer,
                                  color: Colors.white,
                                  size: context.getRSize(20),
                                ),
                              ),
                              SizedBox(width: context.getRSize(14)),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Record Payment',
                                    style: TextStyle(
                                      fontSize: context.getRFontSize(18),
                                      fontWeight: FontWeight.w800,
                                      color: _text,
                                    ),
                                  ),
                                  Text(
                                    'Log outgoing funds',
                                    style: TextStyle(
                                      fontSize: context.getRFontSize(13),
                                      color: Theme.of(context).colorScheme.primary,
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
                          // Supplier Autocomplete
                          Padding(
                            padding: EdgeInsets.only(bottom: context.getRSize(8)),
                            child: Text(
                              'Supplier Name',
                              style: TextStyle(
                                fontSize: context.getRFontSize(12),
                                fontWeight: FontWeight.w700,
                                color: _subtext,
                              ),
                            ),
                          ),
                          Autocomplete<Supplier>(
                            displayStringForOption: (item) => item.name,
                            optionsBuilder:
                                (TextEditingValue textEditingValue) {
                              if (textEditingValue.text.isEmpty) {
                                return const Iterable<Supplier>.empty();
                              }
                              return ref.read(supplierServiceProvider)
                                  .getAll()
                                  .where((Supplier s) {
                                    return s.name.toLowerCase().contains(
                                      textEditingValue.text.toLowerCase(),
                                    );
                                  });
                            },
                            onSelected: (Supplier selection) {
                              _selectedSupplier = selection;
                              _supplierCtrl.text = selection.name;
                            },
                            fieldViewBuilder: (
                              context,
                              controller,
                              focusNode,
                              onEditingComplete,
                            ) {
                              // Sync internal controller text to the parameter requested field view
                              if (controller.text != _supplierCtrl.text &&
                                  focusNode.hasFocus == false) {
                                controller.text = _supplierCtrl.text;
                              }
                              controller.addListener(() {
                                _supplierCtrl.text = controller.text;
                              });
                              return AppInput(
                                controller: controller,
                                focusNode: focusNode,
                                onFieldSubmitted: (_) => onEditingComplete(),
                                labelText: 'Supplier Name',
                                hintText: 'Start typing supplier name...',
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? 'Supplier is required'
                                    : null,
                              );
                            },
                          ),
                          SizedBox(height: context.getRSize(16)),

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
                            items: ['Cash', 'Transfer', 'Cheque', 'POS']
                                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                                .toList(),
                            onChanged: (val) {
                              if (val != null) setState(() => _paymentMethod = val);
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

                          // Link to Delivery
                          AppDropdown<String?>(
                            labelText: 'Link to Delivery (Optional)',
                            value: _selectedDeliveryId,
                            hintText: 'None',
                            items: [
                              const DropdownMenuItem<String?>(value: null, child: Text('None')),
                              ...recentDeliveries.map((d) {
                                final label =
                                    '${DateFormat('MMM d').format(d.deliveredAt)} - ${d.supplierName}';
                                return DropdownMenuItem<String?>(value: d.id, child: Text(label));
                              }),
                            ],
                            onChanged: (val) => setState(() => _selectedDeliveryId = val),
                          ),
                          SizedBox(height: context.getRSize(16)),

                          AppInput(
                            labelText: 'Reference Number (Optional)',
                            controller: _refCtrl,
                            hintText: 'e.g. TR-20938...',
                          ),
                          SizedBox(height: context.getRSize(16)),

                          AppInput(
                            labelText: 'Notes (Optional)',
                            controller: _notesCtrl,
                            maxLines: 3,
                            hintText: 'Add remarks',
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
                        context.deviceBottomInset + context.getRSize(16),
                      ),
                      child: AppButton(
                        text: 'Save Payment',
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



