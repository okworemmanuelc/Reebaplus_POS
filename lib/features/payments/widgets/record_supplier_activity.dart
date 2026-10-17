import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/payments/widgets/payments_parts.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';

/// §21.4 — "Record Activity" chooser: Invoice Total or Record Payment for a
/// specific supplier. Opened from the Supplier Details screen.
void showSupplierActivityChooser(
  BuildContext context, {
  required String supplierId,
  required String supplierName,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return PaymentsChooserFrame(
        title: 'Record Activity',
        subtitle: supplierName,
        children: [
          SettingsRow(
            key: PaymentsKeys.chooserInvoice,
            icon: AppIcons.bill,
            tone: IconTileTone.danger,
            title: 'Invoice Total',
            subtitle: 'Goods received — increases what you owe',
            onTap: () {
              Navigator.pop(ctx);
              RecordInvoiceSheet.show(
                context,
                supplierId: supplierId,
                supplierName: supplierName,
              );
            },
          ),
          SizedBox(height: ctx.getRSize(12)),
          SettingsRow(
            key: PaymentsKeys.chooserPayment,
            icon: AppIcons.transfer,
            tone: IconTileTone.green,
            title: 'Record Payment',
            subtitle: 'Money paid — reduces what you owe',
            onTap: () {
              Navigator.pop(ctx);
              RecordPaymentSheet.show(
                context,
                supplierId: supplierId,
                supplierName: supplierName,
              );
            },
          ),
        ],
      );
    },
  );
}

Future<DateTime?> _pickDate(BuildContext context, DateTime initial) {
  return showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
  );
}

/// The muted ink of hints and suffix icons.
Color _muted(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.color ??
    Theme.of(context).iconTheme.color!;

// ── Invoice Total ────────────────────────────────────────────────────────────

class RecordInvoiceSheet extends ConsumerStatefulWidget {
  final String supplierId;
  final String supplierName;

  /// The date the sheet opens on. Null (every app caller) = today; goldens
  /// pass a fixed date so they don't change with the calendar.
  final DateTime? initialDate;

  const RecordInvoiceSheet({
    super.key,
    required this.supplierId,
    required this.supplierName,
    this.initialDate,
  });

  static void show(
    BuildContext context, {
    required String supplierId,
    required String supplierName,
    DateTime? initialDate,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RecordInvoiceSheet(
        supplierId: supplierId,
        supplierName: supplierName,
        initialDate: initialDate,
      ),
    );
  }

  @override
  ConsumerState<RecordInvoiceSheet> createState() => _RecordInvoiceSheetState();
}

class _RecordInvoiceSheetState extends ConsumerState<RecordInvoiceSheet> {
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  late DateTime _dateReceived = widget.initialDate ?? DateTime.now();
  bool _saving = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _saving) return;
    if (!ref
        .read(currentUserPermissionsProvider)
        .contains('suppliers.manage')) {
      Navigator.pop(context);
      return;
    }
    final amountKobo = (parseCurrency(_amountCtrl.text) * 100).round();
    if (amountKobo <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an amount greater than 0')),
      );
      return;
    }
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cannot record: account not fully loaded yet. Try again in a moment.',
          ),
        ),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final fixed =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final store = _resolveRecordStore(ref);
    // Section 4 — confirmation gate before the entry is written.
    final confirmed = await confirmSupplierActivity(
      context,
      title: 'Confirm Invoice Total',
      accent: fixed.danger,
      entryType: 'Invoice Total',
      supplierName: widget.supplierName,
      amountKobo: amountKobo,
      date: _dateReceived,
      storeLabel: store.label,
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(supplierAccountServiceProvider)
          .recordInvoice(
            supplierId: widget.supplierId,
            amountKobo: amountKobo,
            dateReceived: _dateReceived,
            staffId: staffId,
            storeId: store.id,
            note: _noteCtrl.text,
          );
      if (mounted) Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Invoice of ${formatCurrency(amountKobo / 100)} recorded',
          ),
          backgroundColor: fixed.danger,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not record invoice')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      PaymentsStoreBanner(label: _resolveRecordStore(ref).label),
      SizedBox(height: context.getRSize(16)),
      AppInput(
        labelText: 'Invoice Amount',
        controller: _amountCtrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [CurrencyInputFormatter()],
        hintText: '0.00',
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Amount is required' : null,
      ),
      SizedBox(height: context.getRSize(16)),
      AppInput(
        labelText: 'Date Received',
        readOnly: true,
        onTap: () async {
          final d = await _pickDate(context, _dateReceived);
          if (d != null) setState(() => _dateReceived = d);
        },
        controller: TextEditingController(
          text: DateFormat('MMM d, y').format(_dateReceived),
        ),
        suffixIcon: Icon(
          AppIcons.calendar,
          size: context.getRSize(16),
          color: _muted(context),
        ),
      ),
      SizedBox(height: context.getRSize(16)),
      AppInput(
        labelText: 'Note (Optional)',
        controller: _noteCtrl,
        maxLines: 3,
        hintText: 'e.g. what was delivered',
      ),
      SizedBox(height: context.getRSize(20)),
    ];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context),
      // Open at full size (initial == max) so the keyboard has no room to grow
      // the sheet — avoids the "form jumps up" bug (matches add_customer_sheet
      // and the Session 109 sweep).
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.7,
        snap: true,
        snapSizes: const [0.5, 0.7],
        builder: (context, scrollController) {
          return GestureDetector(
            onTap: () {},
            child: Container(
              key: PaymentsKeys.invoiceSheet,
              decoration: paymentsSheetDecoration(context),
              child: Form(
                key: _formKey,
                child: PaymentsFormSheetLayout(
                  scrollController: scrollController,
                  header: PaymentsSheetHeader(
                    icon: AppIcons.bill,
                    title: 'Invoice Total',
                    subtitle: widget.supplierName,
                    subtitleColor:
                        Theme.of(context).extension<AppFixedColors>()?.danger ??
                        AppFixedColors.light.danger,
                  ),
                  fields: fields,
                  footer: PaymentsSheetFooter(
                    child: AppButton(
                      text: 'Record Invoice',
                      onPressed: _submit,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Record Payment ───────────────────────────────────────────────────────────

class RecordPaymentSheet extends ConsumerStatefulWidget {
  /// When null, the sheet shows a supplier picker (Payments-tab FAB entry).
  final String? supplierId;
  final String? supplierName;

  /// The date the sheet opens on. Null (every app caller) = today; goldens
  /// pass a fixed date so they don't change with the calendar.
  final DateTime? initialDate;

  const RecordPaymentSheet({
    super.key,
    this.supplierId,
    this.supplierName,
    this.initialDate,
  });

  static void show(
    BuildContext context, {
    String? supplierId,
    String? supplierName,
    DateTime? initialDate,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RecordPaymentSheet(
        supplierId: supplierId,
        supplierName: supplierName,
        initialDate: initialDate,
      ),
    );
  }

  @override
  ConsumerState<RecordPaymentSheet> createState() => _RecordPaymentSheetState();
}

class _RecordPaymentSheetState extends ConsumerState<RecordPaymentSheet> {
  final _amountCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String _method = 'cash'; // cash | transfer | pos | other
  late DateTime _paidOn = widget.initialDate ?? DateTime.now();
  PlatformFile? _receipt;
  String? _selectedSupplierId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedSupplierId = widget.supplierId;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }

  bool get _hasProof => _receipt != null || _refCtrl.text.trim().isNotEmpty;

  Future<void> _pickReceipt() async {
    AutoLockWrapper.suppressNextResume = true;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'png', 'pdf'],
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() => _receipt = result.files.first);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _saving) return;
    final supplierId = _selectedSupplierId;
    if (supplierId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!_hasProof) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Attach a receipt or enter a reference / explanation'),
        ),
      );
      return;
    }
    if (!ref
        .read(currentUserPermissionsProvider)
        .contains('suppliers.manage')) {
      Navigator.pop(context);
      return;
    }
    final amountKobo = (parseCurrency(_amountCtrl.text) * 100).round();
    if (amountKobo <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an amount greater than 0')),
      );
      return;
    }
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null) return;
    final fixed =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final store = _resolveRecordStore(ref);
    final supplierLabel =
        widget.supplierName ??
        (ref.read(allSuppliersProvider).valueOrNull ?? const <SupplierData>[])
            .where((s) => s.id == supplierId)
            .map((s) => s.name)
            .firstOrNull ??
        'Supplier';
    // Section 4 — confirmation gate before the entry is written.
    final confirmed = await confirmSupplierActivity(
      context,
      title: 'Confirm Payment',
      accent: fixed.green,
      entryType: 'Payment',
      supplierName: supplierLabel,
      amountKobo: amountKobo,
      date: _paidOn,
      storeLabel: store.label,
      paymentMethod: _methodLabel(_method),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(supplierAccountServiceProvider)
          .recordPayment(
            supplierId: supplierId,
            amountKobo: amountKobo,
            method: _method,
            paidOn: _paidOn,
            staffId: staffId,
            storeId: store.id,
            receiptPath: _receipt?.path,
            referenceNote: _refCtrl.text,
          );
      if (mounted) Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Payment of ${formatCurrency(amountKobo / 100)} recorded',
          ),
          backgroundColor: fixed.green,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not record payment')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliers =
        ref.watch(allSuppliersProvider).valueOrNull ?? const <SupplierData>[];
    final itemStyle = context
        .mediumStyle(14)
        .copyWith(color: Theme.of(context).colorScheme.onSurface);
    final fixed =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final fields = <Widget>[
      PaymentsStoreBanner(label: _resolveRecordStore(ref).label),
      SizedBox(height: context.getRSize(16)),
      if (widget.supplierId == null) ...[
        AppDropdown<String>(
          labelText: 'Supplier',
          value: _selectedSupplierId,
          hintText: 'Select supplier',
          items: suppliers
              .map(
                (s) => DropdownMenuItem(
                  value: s.id,
                  child: Text(s.name, style: itemStyle),
                ),
              )
              .toList(),
          onChanged: (v) => setState(() => _selectedSupplierId = v),
          validator: (v) => v == null ? 'Select a supplier' : null,
        ),
        SizedBox(height: context.getRSize(16)),
      ],
      AppInput(
        labelText: 'Amount',
        controller: _amountCtrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [CurrencyInputFormatter()],
        hintText: '0.00',
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Amount is required' : null,
      ),
      SizedBox(height: context.getRSize(16)),
      AppDropdown<String>(
        labelText: 'Payment Method',
        value: _method,
        items: [
          DropdownMenuItem(
            value: 'cash',
            child: Text('Cash', style: itemStyle),
          ),
          DropdownMenuItem(
            value: 'transfer',
            child: Text('Bank Transfer', style: itemStyle),
          ),
          DropdownMenuItem(
            value: 'pos',
            child: Text('POS Card', style: itemStyle),
          ),
          DropdownMenuItem(
            value: 'other',
            child: Text('Other', style: itemStyle),
          ),
        ],
        onChanged: (v) {
          if (v != null) setState(() => _method = v);
        },
      ),
      SizedBox(height: context.getRSize(16)),
      AppInput(
        labelText: 'Date Paid',
        readOnly: true,
        onTap: () async {
          final d = await _pickDate(context, _paidOn);
          if (d != null) setState(() => _paidOn = d);
        },
        controller: TextEditingController(
          text: DateFormat('MMM d, y').format(_paidOn),
        ),
        suffixIcon: Icon(
          AppIcons.calendar,
          size: context.getRSize(16),
          color: _muted(context),
        ),
      ),
      SizedBox(height: context.getRSize(20)),
      _buildProofSection(context),
      SizedBox(height: context.getRSize(20)),
    ];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context),
      // Open at full size (initial == max) so the keyboard can't grow the sheet
      // (no "form jumps up" — matches add_customer_sheet / Session 109 sweep).
      child: DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.92,
        snap: true,
        snapSizes: const [0.5, 0.92],
        builder: (context, scrollController) {
          return GestureDetector(
            onTap: () {},
            child: Container(
              key: PaymentsKeys.paymentSheet,
              decoration: paymentsSheetDecoration(context),
              child: Form(
                key: _formKey,
                child: PaymentsFormSheetLayout(
                  scrollController: scrollController,
                  header: PaymentsSheetHeader(
                    icon: AppIcons.transfer,
                    title: 'Record Payment',
                    subtitle: widget.supplierName ?? 'Log outgoing funds',
                    subtitleColor: fixed.green,
                  ),
                  fields: fields,
                  footer: PaymentsSheetFooter(
                    child: AppButton(
                      text: 'Record Payment',
                      onPressed: _submit,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildProofSection(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final muted = _muted(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Proof of payment',
              style: context
                  .boldStyle(13)
                  .copyWith(color: t.colorScheme.onSurface),
            ),
            Text(
              ' *required',
              style: context.semiBoldStyle(12).copyWith(color: f.danger),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(4)),
        Text(
          'Attach a receipt, or enter a reference / explanation below (e.g. a '
          'bank-transfer reference, cheque number, or why there is no receipt).',
          style: context.regularStyle(12).copyWith(color: muted),
        ),
        SizedBox(height: context.getRSize(12)),
        PaymentsReceiptBox(
          fileName: _receipt?.name,
          onPick: _pickReceipt,
          onClear: () => setState(() => _receipt = null),
        ),
        SizedBox(height: context.getRSize(16)),
        AppInput(
          labelText: 'Reference / Note',
          controller: _refCtrl,
          maxLines: 2,
          hintText: 'e.g. TRF-20938 / cheque 0042 / no receipt — cash on site',
          onChanged: (_) => setState(() {}), // refresh proof state
        ),
      ],
    );
  }
}

/// §21.11 — the store a Record Activity write is stamped against: the locked
/// active store, else the user's first selectable store (same fallback as a POS
/// sale, checkout_page.dart). `label` is its display name for the banner.
({String? id, String label}) _resolveRecordStore(WidgetRef ref) {
  final locked = ref.read(lockedStoreProvider).value;
  final selectable = ref.read(selectableStoresProvider);
  final id =
      locked ??
      (selectable.isNotEmpty
          ? selectable.first.id
          : ref.read(authProvider).currentUser?.storeId);
  if (id == null) return (id: null, label: 'No store');
  for (final s in selectable) {
    if (s.id == id) return (id: id, label: s.name);
  }
  final all = ref.read(allStoresProvider).valueOrNull ?? const <StoreData>[];
  for (final s in all) {
    if (s.id == id) return (id: id, label: s.name);
  }
  return (id: id, label: 'Store');
}

/// Maps a payment-method code to its display label (matches the dropdown).
String _methodLabel(String method) {
  switch (method) {
    case 'cash':
      return 'Cash';
    case 'transfer':
      return 'Bank Transfer';
    case 'pos':
      return 'POS Card';
    case 'other':
      return 'Other';
    default:
      return method;
  }
}

/// Section 4 (user-confirmed) — the confirmation gate shown after the form is
/// submitted but BEFORE the ledger entry is written. Spells out the supplier,
/// amount, date, target store, entry type (and payment method) and warns that
/// the entry is permanent and reversible only by a CEO void (§21.7). Returns
/// true only when the user taps Confirm; Cancel returns them to the form with
/// data intact.
Future<bool?> confirmSupplierActivity(
  BuildContext context, {
  required String title,
  required Color accent,
  required String entryType,
  required String supplierName,
  required int amountKobo,
  required DateTime date,
  required String storeLabel,
  String? paymentMethod,
}) {
  final text = Theme.of(context).colorScheme.onSurface;
  final subtext = _muted(context);
  final dangerInk =
      (Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light)
          .danger;

  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: ctx.extraBoldStyle(18).copyWith(color: text)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _confirmRow(ctx, 'Type', entryType, text, subtext),
          _confirmRow(ctx, 'Supplier', supplierName, text, subtext),
          _confirmRow(
            ctx,
            'Amount',
            formatCurrency(amountKobo / 100),
            accent,
            subtext,
            bold: true,
          ),
          _confirmRow(
            ctx,
            'Date',
            DateFormat('MMM d, y').format(date),
            text,
            subtext,
          ),
          if (paymentMethod != null)
            _confirmRow(ctx, 'Method', paymentMethod, text, subtext),
          _confirmRow(ctx, 'Store', storeLabel, text, subtext),
          SizedBox(height: ctx.getRSize(12)),
          Text(
            'This entry is permanent. It can only be reversed by a CEO void.',
            style: ctx.semiBoldStyle(12).copyWith(color: dangerInk),
          ),
        ],
      ),
      actions: [
        AppButton(
          text: 'Cancel',
          variant: AppButtonVariant.ghost,
          size: AppButtonSize.small,
          onPressed: () => Navigator.pop(ctx, false),
        ),
        AppButton(
          text: 'Confirm',
          size: AppButtonSize.small,
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
}

Widget _confirmRow(
  BuildContext context,
  String label,
  String value,
  Color valueColor,
  Color labelColor, {
  bool bold = false,
}) {
  return Padding(
    padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: context.getRSize(76),
          child: Text(
            label,
            style: context.regularStyle(13).copyWith(color: labelColor),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style:
                (bold ? context.extraBoldStyle(13) : context.semiBoldStyle(13))
                    .copyWith(color: valueColor),
          ),
        ),
      ],
    ),
  );
}
