import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/shared/widgets/auto_lock_wrapper.dart';

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
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final surface = Theme.of(ctx).colorScheme.surface;
      final text = Theme.of(ctx).colorScheme.onSurface;
      final border = Theme.of(ctx).dividerColor;
      return Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(
          ctx.getRSize(20),
          ctx.getRSize(12),
          ctx.getRSize(20),
          ctx.deviceBottomPadding + ctx.getRSize(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: ctx.getRSize(40),
                height: ctx.getRSize(4),
                decoration: BoxDecoration(
                  color: border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: ctx.getRSize(20)),
            Text(
              'Record Activity',
              style: TextStyle(
                fontSize: ctx.getRFontSize(18),
                fontWeight: FontWeight.w800,
                color: text,
              ),
            ),
            SizedBox(height: ctx.getRSize(4)),
            Text(
              supplierName,
              style: TextStyle(
                fontSize: ctx.getRFontSize(13),
                color: Theme.of(ctx).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: ctx.getRSize(20)),
            _ChooserTile(
              icon: FontAwesomeIcons.fileInvoiceDollar,
              color: danger,
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
            _ChooserTile(
              icon: FontAwesomeIcons.moneyBillTransfer,
              color: success,
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
        ),
      );
    },
  );
}

class _ChooserTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ChooserTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).colorScheme.onSurface;
    final subtext = Theme.of(context).textTheme.bodySmall?.color ??
        Theme.of(context).iconTheme.color!;
    final border = Theme.of(context).dividerColor;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(context.getRSize(16)),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Container(
              width: context.getRSize(44),
              height: context.getRSize(44),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: context.getRSize(18)),
            ),
            SizedBox(width: context.getRSize(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: context.getRFontSize(15),
                      fontWeight: FontWeight.bold,
                      color: text,
                    ),
                  ),
                  SizedBox(height: context.getRSize(2)),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: context.getRFontSize(12),
                      color: subtext,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: subtext, size: context.getRSize(20)),
          ],
        ),
      ),
    );
  }
}

// ── Shared scaffolding for the two form sheets ───────────────────────────────

mixin _SheetColors<T extends StatefulWidget> on State<T> {
  Color get sSurface => Theme.of(context).colorScheme.surface;
  Color get sText => Theme.of(context).colorScheme.onSurface;
  Color get sSubtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get sBorder => Theme.of(context).dividerColor;
}

Future<DateTime?> _pickDate(BuildContext context, DateTime initial) {
  return showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
    builder: (context, child) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Theme(
        data: Theme.of(context).copyWith(
          colorScheme: isDark
              ? ColorScheme.dark(
                  primary: Theme.of(context).colorScheme.primary,
                  surface: dSurface)
              : ColorScheme.light(
                  primary: Theme.of(context).colorScheme.primary,
                  surface: lSurface),
        ),
        child: child!,
      );
    },
  );
}

Widget _sheetHandle(BuildContext context, Color border) => Center(
      child: Container(
        width: context.getRSize(40),
        height: context.getRSize(4),
        decoration: BoxDecoration(
          color: border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );

// ── Invoice Total ────────────────────────────────────────────────────────────

class RecordInvoiceSheet extends ConsumerStatefulWidget {
  final String supplierId;
  final String supplierName;

  const RecordInvoiceSheet({
    super.key,
    required this.supplierId,
    required this.supplierName,
  });

  static void show(
    BuildContext context, {
    required String supplierId,
    required String supplierName,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RecordInvoiceSheet(
        supplierId: supplierId,
        supplierName: supplierName,
      ),
    );
  }

  @override
  ConsumerState<RecordInvoiceSheet> createState() => _RecordInvoiceSheetState();
}

class _RecordInvoiceSheetState extends ConsumerState<RecordInvoiceSheet>
    with _SheetColors {
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  DateTime _dateReceived = DateTime.now();
  bool _saving = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _saving) return;
    if (!ref.read(currentUserPermissionsProvider).contains('suppliers.manage')) {
      Navigator.pop(context);
      return;
    }
    final amountKobo = (parseCurrency(_amountCtrl.text) * 100).round();
    if (amountKobo <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter an amount greater than 0'))); return; }
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot record: account not fully loaded yet. Try again in a moment.'))); return; }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(supplierAccountServiceProvider).recordInvoice(
            supplierId: widget.supplierId,
            amountKobo: amountKobo,
            dateReceived: _dateReceived,
            staffId: staffId,
            storeId: _resolveRecordStore(ref).id,
            note: _noteCtrl.text,
          );
      if (mounted) Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
        content: Text('Invoice of ${formatCurrency(amountKobo / 100)} recorded'),
        backgroundColor: danger,
      ));
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not record invoice')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
              decoration: BoxDecoration(
                color: sSurface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(context.getRSize(20),
                          context.getRSize(12), context.getRSize(20), 0),
                      child: Column(
                        children: [
                          _sheetHandle(context, sBorder),
                          SizedBox(height: context.getRSize(16)),
                          _formHeader(
                            context,
                            icon: FontAwesomeIcons.fileInvoiceDollar,
                            color: danger,
                            title: 'Invoice Total',
                            subtitle: widget.supplierName,
                            text: sText,
                          ),
                          SizedBox(height: context.getRSize(10)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(20),
                          vertical: context.getRSize(10),
                        ),
                        children: [
                          _recordStoreBanner(
                              context, _resolveRecordStore(ref).label),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Invoice Amount',
                            controller: _amountCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            inputFormatters: [CurrencyInputFormatter()],
                            hintText: '0.00',
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Amount is required'
                                : null,
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
                            suffixIcon: Icon(FontAwesomeIcons.calendar,
                                size: context.getRSize(16), color: sSubtext),
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppInput(
                            labelText: 'Note (Optional)',
                            controller: _noteCtrl,
                            maxLines: 3,
                            hintText: 'e.g. what was delivered',
                          ),
                          SizedBox(height: context.getRSize(20)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        context.getRSize(20),
                        context.getRSize(16),
                        context.getRSize(20),
                        context.deviceBottomPadding + context.getRSize(16),
                      ),
                      child: AppButton(
                        text: 'Record Invoice',
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

// ── Record Payment ───────────────────────────────────────────────────────────

class RecordPaymentSheet extends ConsumerStatefulWidget {
  /// When null, the sheet shows a supplier picker (Payments-tab FAB entry).
  final String? supplierId;
  final String? supplierName;

  const RecordPaymentSheet({super.key, this.supplierId, this.supplierName});

  static void show(
    BuildContext context, {
    String? supplierId,
    String? supplierName,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RecordPaymentSheet(
        supplierId: supplierId,
        supplierName: supplierName,
      ),
    );
  }

  @override
  ConsumerState<RecordPaymentSheet> createState() => _RecordPaymentSheetState();
}

class _RecordPaymentSheetState extends ConsumerState<RecordPaymentSheet>
    with _SheetColors {
  final _amountCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String _method = 'cash'; // cash | transfer | pos | other
  DateTime _paidOn = DateTime.now();
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

  bool get _hasProof =>
      _receipt != null || _refCtrl.text.trim().isNotEmpty;

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
      messenger.showSnackBar(const SnackBar(
        content: Text('Attach a receipt or enter a reference / explanation'),
      ));
      return;
    }
    if (!ref.read(currentUserPermissionsProvider).contains('suppliers.manage')) {
      Navigator.pop(context);
      return;
    }
    final amountKobo = (parseCurrency(_amountCtrl.text) * 100).round();
    if (amountKobo <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter an amount greater than 0'))); return; }
    final staffId = ref.read(authProvider).currentUser?.id;
    if (staffId == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(supplierAccountServiceProvider).recordPayment(
            supplierId: supplierId,
            amountKobo: amountKobo,
            method: _method,
            paidOn: _paidOn,
            staffId: staffId,
            storeId: _resolveRecordStore(ref).id,
            receiptPath: _receipt?.path,
            referenceNote: _refCtrl.text,
          );
      if (mounted) Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
        content: Text('Payment of ${formatCurrency(amountKobo / 100)} recorded'),
        backgroundColor: success,
      ));
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
              decoration: BoxDecoration(
                color: sSurface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(context.getRSize(20),
                          context.getRSize(12), context.getRSize(20), 0),
                      child: Column(
                        children: [
                          _sheetHandle(context, sBorder),
                          SizedBox(height: context.getRSize(16)),
                          _formHeader(
                            context,
                            icon: FontAwesomeIcons.moneyBillTransfer,
                            color: success,
                            title: 'Record Payment',
                            subtitle: widget.supplierName ?? 'Log outgoing funds',
                            text: sText,
                          ),
                          SizedBox(height: context.getRSize(10)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: EdgeInsets.symmetric(
                          horizontal: context.getRSize(20),
                          vertical: context.getRSize(10),
                        ),
                        children: [
                          _recordStoreBanner(
                              context, _resolveRecordStore(ref).label),
                          SizedBox(height: context.getRSize(16)),
                          if (widget.supplierId == null) ...[
                            AppDropdown<String>(
                              labelText: 'Supplier',
                              value: _selectedSupplierId,
                              hintText: 'Select supplier',
                              items: suppliers
                                  .map((s) => DropdownMenuItem(
                                        value: s.id,
                                        child: Text(s.name),
                                      ))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _selectedSupplierId = v),
                              validator: (v) =>
                                  v == null ? 'Select a supplier' : null,
                            ),
                            SizedBox(height: context.getRSize(16)),
                          ],
                          AppInput(
                            labelText: 'Amount',
                            controller: _amountCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            inputFormatters: [CurrencyInputFormatter()],
                            hintText: '0.00',
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Amount is required'
                                : null,
                          ),
                          SizedBox(height: context.getRSize(16)),
                          AppDropdown<String>(
                            labelText: 'Payment Method',
                            value: _method,
                            items: const [
                              DropdownMenuItem(
                                  value: 'cash', child: Text('Cash')),
                              DropdownMenuItem(
                                  value: 'transfer', child: Text('Bank Transfer')),
                              DropdownMenuItem(
                                  value: 'pos', child: Text('POS Card')),
                              DropdownMenuItem(
                                  value: 'other', child: Text('Other')),
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
                            suffixIcon: Icon(FontAwesomeIcons.calendar,
                                size: context.getRSize(16), color: sSubtext),
                          ),
                          SizedBox(height: context.getRSize(20)),
                          _buildProofSection(context),
                          SizedBox(height: context.getRSize(20)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        context.getRSize(20),
                        context.getRSize(16),
                        context.getRSize(20),
                        context.deviceBottomPadding + context.getRSize(16),
                      ),
                      child: AppButton(
                        text: 'Record Payment',
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

  Widget _buildProofSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Proof of payment',
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                fontWeight: FontWeight.w700,
                color: sText,
              ),
            ),
            Text(
              ' *required',
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                color: danger,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(4)),
        Text(
          'Attach a receipt, or enter a reference / explanation below (e.g. a '
          'bank-transfer reference, cheque number, or why there is no receipt).',
          style: TextStyle(
            fontSize: context.getRFontSize(12),
            color: sSubtext,
          ),
        ),
        SizedBox(height: context.getRSize(12)),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _pickReceipt,
          child: Container(
            padding: EdgeInsets.all(context.getRSize(14)),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sBorder),
            ),
            child: Row(
              children: [
                Icon(
                  _receipt == null
                      ? FontAwesomeIcons.paperclip
                      : FontAwesomeIcons.solidFileLines,
                  size: context.getRSize(16),
                  color: _receipt == null
                      ? sSubtext
                      : Theme.of(context).colorScheme.primary,
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: Text(
                    _receipt?.name ?? 'Attach receipt (photo or file)',
                    style: TextStyle(
                      fontSize: context.getRFontSize(13),
                      color: _receipt == null ? sSubtext : sText,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_receipt != null)
                  GestureDetector(
                    onTap: () => setState(() => _receipt = null),
                    child: Icon(Icons.close,
                        size: context.getRSize(18), color: sSubtext),
                  ),
              ],
            ),
          ),
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
  final id = locked ??
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

/// Read-only "Recording for: <store>" banner shown in the Record Activity sheets
/// (§21.11) so the target store is explicit. Switch stores via the menu picker.
Widget _recordStoreBanner(BuildContext context, String label) {
  final subtext = Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  final border = Theme.of(context).dividerColor;
  final primary = Theme.of(context).colorScheme.primary;
  return Container(
    padding: EdgeInsets.symmetric(
      horizontal: context.getRSize(12),
      vertical: context.getRSize(10),
    ),
    decoration: BoxDecoration(
      color: primary.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: border),
    ),
    child: Row(
      children: [
        Icon(FontAwesomeIcons.store, size: context.getRSize(13), color: primary),
        SizedBox(width: context.getRSize(8)),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Recording for: ',
                  style: TextStyle(
                    color: subtext,
                    fontSize: context.getRFontSize(12),
                  ),
                ),
                TextSpan(
                  text: label,
                  style: TextStyle(
                    color: primary,
                    fontSize: context.getRFontSize(12),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

Widget _formHeader(
  BuildContext context, {
  required IconData icon,
  required Color color,
  required String title,
  required String subtitle,
  required Color text,
}) {
  return Row(
    children: [
      Container(
        width: context.getRSize(44),
        height: context.getRSize(44),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: color, size: context.getRSize(20)),
      ),
      SizedBox(width: context.getRSize(14)),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: context.getRFontSize(18),
                fontWeight: FontWeight.w800,
                color: text,
              ),
            ),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                color: color,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ],
  );
}
