import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// Invoice / checkout screen for the Receive Stock flow (spec Sections 7–9).
/// Picks ONE supplier, shows a read-only Invoice Total, captures the receipt
/// date + an optional note + empties returned per bottle line, then commits
/// atomically via [receiveStockServiceProvider]. Optionally captures an
/// "Amount Paid Now" + payment method, recorded against the supplier ledger
/// (that payment section is gated on `suppliers.manage`). This is a purchase,
/// not a sale.
class ReceiveCheckoutScreen extends ConsumerStatefulWidget {
  const ReceiveCheckoutScreen({super.key});

  @override
  ConsumerState<ReceiveCheckoutScreen> createState() =>
      _ReceiveCheckoutScreenState();
}

class _ReceiveCheckoutScreenState extends ConsumerState<ReceiveCheckoutScreen> {
  final _noteCtrl = TextEditingController();
  final _amountPaidCtrl = TextEditingController();
  String _paymentMethod = 'cash';
  bool _isLoading = true;
  bool _isSaving = false;

  List<SupplierData> _suppliers = [];
  SupplierData? _selectedSupplier;
  DateTime _dateReceived = DateTime.now();

  /// Store captured when the checkout opened (§15.7). The receipt is committed
  /// against THIS store; if the active store changes before confirm we abort
  /// rather than silently re-stamp.
  String? _flowStoreId;

  // manufacturerId → empty crates returned to the supplier on this receipt.
  // Empties are a per-manufacturer figure (the manufacturer owns the crate
  // deposit), so one input per manufacturer even when several of its SKUs are
  // on the receipt — never one per product.
  final Map<String, int> _emptiesReturnedByManufacturer = {};
  final Map<String, TextEditingController> _emptiesControllers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadData();
    });
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _amountPaidCtrl.dispose();
    for (final c in _emptiesControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadData() async {
    final db = ref.read(databaseProvider);
    // getAllSuppliers() already excludes soft-deleted suppliers (§17.8).
    final suppliers = await db.catalogDao.getAllSuppliers();

    _flowStoreId = ref.read(lockedStoreProvider).value ??
        ref.read(selectableStoresProvider).firstOrNull?.id;

    if (!mounted) return;
    setState(() {
      _suppliers = suppliers;
      _isLoading = false;
    });

    // One empties controller per distinct manufacturer carrying a bottle +
    // trackEmpties line (not one per product).
    for (final line in ref.read(receiveCartProvider)) {
      final mfrId = line.manufacturerId;
      if (line.trackEmpties &&
          mfrId != null &&
          !_emptiesControllers.containsKey(mfrId)) {
        final c = TextEditingController(text: '0');
        c.addListener(() {
          _emptiesReturnedByManufacturer[mfrId] = int.tryParse(c.text) ?? 0;
        });
        _emptiesControllers[mfrId] = c;
        _emptiesReturnedByManufacturer[mfrId] = 0;
      }
    }
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _storeName() {
    final stores = ref.read(selectableStoresProvider);
    final match = stores.where((s) => s.id == _flowStoreId).firstOrNull;
    return match?.name ?? ref.read(activeStoreLabelProvider);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dateReceived,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
    );
    if (picked != null && mounted) {
      setState(() => _dateReceived = picked);
    }
  }

  Future<void> _pickSupplier() async {
    final selected = await showModalBottomSheet<SupplierData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _SupplierPickerSheet(suppliers: _suppliers),
    );
    if (selected != null && mounted) {
      setState(() => _selectedSupplier = selected);
    }
  }

  Future<void> _confirm() async {
    final supplier = _selectedSupplier;
    if (supplier == null) {
      AppNotification.showError(context, 'Please select a supplier');
      return;
    }

    final cart = ref.read(receiveCartProvider);
    if (cart.isEmpty) {
      AppNotification.showError(context, 'Cart is empty');
      return;
    }

    // §15.7 — the store must not have silently changed since checkout opened.
    final currentStore = ref.read(lockedStoreProvider).value ??
        ref.read(selectableStoresProvider).firstOrNull?.id;
    if (_flowStoreId == null) {
      AppNotification.showError(context, 'No active store to receive into');
      return;
    }
    if (currentStore != _flowStoreId) {
      AppNotification.showError(
        context,
        'The active store changed during this receipt. Please restart the '
        'flow so stock lands in the right store.',
      );
      return;
    }

    final notifier = ref.read(receiveCartProvider.notifier);
    final invoiceTotalKobo = notifier.invoiceTotalKobo;
    final totalUnits = notifier.totalUnits;

    final confirmed = await _showConfirmationDialog(
      supplierName: supplier.name,
      productCount: cart.length,
      totalUnits: totalUnits,
      invoiceTotalKobo: invoiceTotalKobo,
      storeName: _storeName(),
    );
    if (confirmed != true) return;

    setState(() => _isSaving = true);
    final staffId = ref.read(authProvider).currentUser?.id ?? 'unknown';
    final note = _noteCtrl.text.trim();

    try {
      final canManageSuppliers = hasPermission(ref, 'suppliers.manage');
      final amountPaid = (canManageSuppliers && _amountPaidCtrl.text.isNotEmpty)
          ? (double.tryParse(_amountPaidCtrl.text.replaceAll(',', '')) ?? 0)
          : 0;
      final amountPaidKobo = (amountPaid * 100).round();

      await ref.read(receiveStockServiceProvider).confirmReceipt(
            supplierId: supplier.id,
            supplierName: supplier.name,
            storeId: _flowStoreId!,
            dateReceived: _dateReceived,
            staffId: staffId,
            lines: cart,
            emptiesReturnedByManufacturer:
                Map<String, int>.from(_emptiesReturnedByManufacturer),
            note: note.isEmpty ? null : note,
            amountPaidKobo: amountPaidKobo > 0 ? amountPaidKobo : null,
            paymentMethod: amountPaidKobo > 0 ? _paymentMethod : null,
          );

      if (!mounted) return;
      ref.read(receiveCartProvider.notifier).clear();
      AppNotification.showSuccess(
        context,
        'Stock received from ${supplier.name}',
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'receive_stock.confirm');
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not complete the receipt. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<bool?> _showConfirmationDialog({
    required String supplierName,
    required int productCount,
    required int totalUnits,
    required int invoiceTotalKobo,
    required String storeName,
  }) {
    final theme = Theme.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Receipt'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _dialogRow('Supplier', supplierName),
            _dialogRow('Items', '$productCount product(s), $totalUnits unit(s)'),
            _dialogRow('Stocking', storeName),
            _dialogRow(
              'Invoice Total',
              formatCurrency(invoiceTotalKobo / 100),
            ),
            SizedBox(height: context.getRSize(12)),
            Text(
              'This posts ${formatCurrency(invoiceTotalKobo / 100)} to '
              "$supplierName's account and increases stock at $storeName.",
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          AppButton(
            text: 'Confirm',
            size: AppButtonSize.small,
            isFullWidth: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
  }

  Widget _dialogRow(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: context.getRSize(96),
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cart = ref.watch(receiveCartProvider);
    final notifier = ref.read(receiveCartProvider.notifier);
    final bg = theme.colorScheme.surface;
    final cardColor = theme.cardColor;
    final textColor = theme.colorScheme.onSurface;
    final primary = theme.colorScheme.primary;
    final border = theme.dividerColor;
    final subtext = theme.textTheme.bodySmall?.color;

    final totalValueStr = formatCurrency(notifier.invoiceTotalKobo / 100);

    // Empties are grouped by manufacturer: one row per manufacturer, with the
    // full crates received summed across all of its bottle + trackEmpties lines.
    final manufacturers =
        ref.watch(allManufacturersProvider).valueOrNull ??
            const <ManufacturerData>[];
    final mfrNames = {for (final m in manufacturers) m.id: m.name};
    final emptiesGroups =
        <({String manufacturerId, String name, int fullCrates})>[];
    final seenManufacturers = <String>{};
    for (final l in cart) {
      final mfrId = l.manufacturerId;
      if (!l.trackEmpties || mfrId == null) continue;
      if (!seenManufacturers.add(mfrId)) continue;
      final fullCrates = cart
          .where((x) => x.trackEmpties && x.manufacturerId == mfrId)
          .fold<int>(0, (sum, x) => sum + x.qty);
      emptiesGroups.add((
        manufacturerId: mfrId,
        name: mfrNames[mfrId] ?? 'Manufacturer',
        fullCrates: fullCrates,
      ));
    }

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('Invoice'),
        elevation: 0,
        backgroundColor: bg,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(20),
                context.getRSize(16),
                context.getRSize(20),
                context.getRSize(110) + context.deviceBottomPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Invoice Total (read-only)
                  Container(
                    padding: EdgeInsets.all(context.getRSize(16)),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: primary.withValues(alpha: 0.2)),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Invoice Total',
                          style: TextStyle(
                            color: primary,
                            fontWeight: FontWeight.w600,
                            fontSize: context.getRFontSize(13),
                          ),
                        ),
                        SizedBox(height: context.getRSize(4)),
                        Text(
                          totalValueStr,
                          style: TextStyle(
                            fontSize: context.getRFontSize(28),
                            fontWeight: FontWeight.w800,
                            color: primary,
                          ),
                        ),
                        SizedBox(height: context.getRSize(8)),
                        Text(
                          '${notifier.totalUnits} units • ${cart.length} products',
                          style: TextStyle(
                            color: primary.withValues(alpha: 0.8),
                            fontSize: context.getRFontSize(13),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: context.getRSize(12)),

                  // Receiving for: [store] (read-only)
                  Row(
                    children: [
                      Icon(FontAwesomeIcons.store.data,
                          size: context.getRSize(13), color: subtext),
                      SizedBox(width: context.getRSize(8)),
                      Text(
                        'Receiving for: ',
                        style: TextStyle(
                            color: subtext, fontSize: context.getRFontSize(13)),
                      ),
                      Expanded(
                        child: Text(
                          _storeName(),
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w600,
                            fontSize: context.getRFontSize(13),
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.getRSize(24)),

                  // Supplier (required, searchable)
                  _fieldLabel('SUPPLIER *', subtext),
                  SizedBox(height: context.getRSize(8)),
                  _TapField(
                    icon: FontAwesomeIcons.truckField.data,
                    text: _selectedSupplier?.name ?? 'Select supplier',
                    isPlaceholder: _selectedSupplier == null,
                    onTap: _pickSupplier,
                  ),
                  SizedBox(height: context.getRSize(16)),

                  // Date received (default today, backdate allowed)
                  _fieldLabel('DATE RECEIVED', subtext),
                  SizedBox(height: context.getRSize(8)),
                  _TapField(
                    icon: FontAwesomeIcons.calendar.data,
                    text: _formatDate(_dateReceived),
                    isPlaceholder: false,
                    onTap: _pickDate,
                  ),
                  SizedBox(height: context.getRSize(16)),

                  // Note (optional)
                  AppInput(
                    controller: _noteCtrl,
                    labelText: 'Reference Note (Optional)',
                    hintText: 'e.g. Invoice #12345',
                  ),
                  SizedBox(height: context.getRSize(24)),

                  if (hasPermission(ref, 'suppliers.manage')) ...[
                    // Payment (optional)
                    _fieldLabel('PAYMENT', subtext),
                    SizedBox(height: context.getRSize(8)),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: AppInput(
                            controller: _amountPaidCtrl,
                            labelText: 'Amount Paid Now',
                            hintText: '0.00',
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          ),
                        ),
                        SizedBox(width: context.getRSize(12)),
                        Expanded(
                          flex: 1,
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: context.getRSize(12)),
                            decoration: BoxDecoration(
                              color: cardColor,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: border),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _paymentMethod,
                                isExpanded: true,
                                items: const [
                                  DropdownMenuItem(value: 'cash', child: Text('Cash')),
                                  DropdownMenuItem(value: 'transfer', child: Text('Transfer')),
                                  DropdownMenuItem(value: 'pos', child: Text('POS')),
                                ],
                                onChanged: (v) {
                                  if (v != null) setState(() => _paymentMethod = v);
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: context.getRSize(24)),
                  ],

                  // Line items summary
                  _fieldLabel('ITEMS', subtext),
                  SizedBox(height: context.getRSize(8)),
                  Container(
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: border),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < cart.length; i++) ...[
                          if (i > 0) Divider(height: 1, color: border),
                          _lineRow(cart[i], textColor, subtext),
                        ],
                      ],
                    ),
                  ),

                  // Empties returned (grouped by manufacturer)
                  if (emptiesGroups.isNotEmpty) ...[
                    SizedBox(height: context.getRSize(24)),
                    Row(
                      children: [
                        Icon(FontAwesomeIcons.wineBottle.data,
                            size: context.getRSize(14), color: subtext),
                        SizedBox(width: context.getRSize(8)),
                        _fieldLabel('EMPTY CRATES RETURNED TO SUPPLIER', subtext),
                      ],
                    ),
                    SizedBox(height: context.getRSize(12)),
                    Container(
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: border),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < emptiesGroups.length; i++) ...[
                            if (i > 0) Divider(height: 1, color: border),
                            _emptiesRow(emptiesGroups[i], textColor, subtext),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
      bottomSheet: _isLoading
          ? null
          : Container(
              padding: EdgeInsets.fromLTRB(
                context.getRSize(20),
                context.getRSize(16),
                context.getRSize(20),
                context.getRSize(16) + context.deviceBottomPadding,
              ),
              decoration: BoxDecoration(
                color: cardColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    offset: const Offset(0, -4),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: AppButton(
                text: 'Confirm Receipt',
                onPressed:
                    _selectedSupplier == null || _isSaving ? null : _confirm,
                isLoading: _isSaving,
                isFullWidth: true,
              ),
            ),
    );
  }

  Widget _fieldLabel(String text, Color? subtext) => Text(
        text,
        style: TextStyle(
          fontSize: context.getRFontSize(12),
          fontWeight: FontWeight.bold,
          color: subtext,
        ),
      );

  Widget _lineRow(ReceiveCartLine line, Color textColor, Color? subtext) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.productName,
                  style:
                      TextStyle(fontWeight: FontWeight.w600, color: textColor),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  '${line.qty} × ${formatCurrency(line.buyingPriceKobo / 100)}',
                  style: TextStyle(
                      fontSize: context.getRFontSize(12), color: subtext),
                ),
              ],
            ),
          ),
          Text(
            formatCurrency(line.buyingPriceKobo * line.qty / 100),
            style: TextStyle(fontWeight: FontWeight.w600, color: textColor),
          ),
        ],
      ),
    );
  }

  Widget _emptiesRow(
    ({String manufacturerId, String name, int fullCrates}) group,
    Color textColor,
    Color? subtext,
  ) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.name,
                  style:
                      TextStyle(fontWeight: FontWeight.w600, color: textColor),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  'Full crates received: ${group.fullCrates}',
                  style: TextStyle(
                      fontSize: context.getRFontSize(12), color: subtext),
                ),
              ],
            ),
          ),
          SizedBox(
            width: context.getRSize(72),
            child: AppInput(
              controller: _emptiesControllers[group.manufacturerId],
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// Read-only tappable field used for the supplier + date pickers.
class _TapField extends StatelessWidget {
  final IconData? icon;
  final String text;
  final bool isPlaceholder;
  final VoidCallback onTap;

  const _TapField({
    required this.icon,
    required this.text,
    required this.isPlaceholder,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtext = theme.textTheme.bodySmall?.color;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(16),
            vertical: context.getRSize(16),
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.dividerColor),
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: context.getRSize(16), color: subtext),
                SizedBox(width: context.getRSize(12)),
              ],
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    color: isPlaceholder
                        ? subtext
                        : theme.colorScheme.onSurface,
                    fontWeight:
                        isPlaceholder ? FontWeight.normal : FontWeight.w600,
                  ),
                ),
              ),
              Icon(FontAwesomeIcons.chevronDown.data,
                  size: context.getRSize(14), color: subtext),
            ],
          ),
        ),
      ),
    );
  }
}

/// Searchable single-select supplier picker (§7.4). Soft-deleted suppliers are
/// already excluded upstream by `getAllSuppliers()`.
class _SupplierPickerSheet extends StatefulWidget {
  final List<SupplierData> suppliers;
  const _SupplierPickerSheet({required this.suppliers});

  @override
  State<_SupplierPickerSheet> createState() => _SupplierPickerSheetState();
}

class _SupplierPickerSheetState extends State<_SupplierPickerSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _query.isEmpty
        ? widget.suppliers
        : widget.suppliers
            .where((s) => s.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(12),
          context.getRSize(20),
          context.getRSize(20),
        ),
        child: Column(
          children: [
            Container(
              width: context.getRSize(40),
              height: context.getRSize(4),
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            SizedBox(height: context.getRSize(16)),
            AppInput(
              controller: _searchCtrl,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              hintText: 'Search suppliers...',
              prefixIcon: Icon(FontAwesomeIcons.magnifyingGlass.data,
                  size: context.getRSize(16)),
            ),
            SizedBox(height: context.getRSize(12)),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No suppliers found',
                        style: TextStyle(
                            color: theme.textTheme.bodySmall?.color),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: theme.dividerColor),
                      itemBuilder: (context, index) {
                        final s = filtered[index];
                        return ListTile(
                          title: Text(s.name),
                          onTap: () => Navigator.pop(context, s),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
