import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/features/receiving/widgets/receive_parts.dart';
import 'package:reebaplus_pos/features/receiving/widgets/uncosted_receive_warning.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/icon_tile.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/section_header.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/stat_card.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';
import 'package:reebaplus_pos/features/payments/widgets/supplier_form_sheet.dart';

/// Invoice / checkout screen for the Receive Stock flow (spec Sections 7–9).
/// Picks ONE supplier (optional unless a line moves crates — no supplier is a
/// cash purchase: stock + cost only, no invoice / payment / crates), shows a
/// read-only Invoice Total, captures the receipt
/// date + an optional note + the crates moved with the delivery (full crates in
/// and empty crates back, per manufacturer — #210), then commits atomically via
/// [receiveStockServiceProvider]. Optionally captures an
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

  /// Destination store for this receipt. Defaults to the active store (or the
  /// first selectable store) when the checkout opens, but the user can
  /// re-allocate it via the "Stocking into" dropdown — so stock can be received
  /// into any store the user has access to, independent of the app-wide active
  /// store. (This supersedes the old §15.7 active-store-change abort, which
  /// assumed the destination was implicit.)
  String? _flowStoreId;

  /// Stores the user may receive into (already access-scoped upstream).
  List<StoreData> _stores = const [];

  // manufacturerId → full crates that arrived on this receipt (#210), and
  // manufacturerId → empty crates handed back to the supplier. Both are
  // per-manufacturer figures (the manufacturer owns the crate deposit), so one
  // input per manufacturer per direction even when several of its SKUs are on
  // the receipt — never one per product.
  //
  // Crate size is a CATEGORY here (Big/Medium/Small), never a bottle count, so
  // neither figure can be worked out from the quantity delivered — both are
  // typed by whoever took the delivery (ADR 0023).
  final Map<String, int> _fullCratesReceivedByManufacturer = {};
  final Map<String, TextEditingController> _fullCratesControllers = {};
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
    for (final c in _fullCratesControllers.values) {
      c.dispose();
    }
    for (final c in _emptiesControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadData() async {
    final db = ref.read(databaseProvider);
    // getAllSuppliers() already excludes soft-deleted suppliers (§17.8).
    final suppliers = await db.catalogDao.getAllSuppliers();
    final stores = ref.read(selectableStoresProvider);

    if (!mounted) return;
    setState(() {
      _suppliers = suppliers;
      _stores = stores;
      // Default to the active store, falling back to the first store the user
      // can access. The dropdown lets them change it before confirming.
      _flowStoreId =
          ref.read(lockedStoreProvider).value ?? stores.firstOrNull?.id;
      _isLoading = false;
    });

    // One controller pair (full crates in, empties back) per distinct
    // manufacturer carrying a bottle + trackEmpties line — not one per product.
    // The same gate the commit uses, so PET / Can lines never get a crate box.
    for (final line in ref.read(receiveCartProvider)) {
      final mfrId = line.manufacturerId;
      if (line.movesCrates &&
          mfrId != null &&
          !_emptiesControllers.containsKey(mfrId)) {
        final fullCratesCtrl = TextEditingController(text: '0');
        fullCratesCtrl.addListener(() {
          _fullCratesReceivedByManufacturer[mfrId] =
              int.tryParse(fullCratesCtrl.text) ?? 0;
        });
        _fullCratesControllers[mfrId] = fullCratesCtrl;
        _fullCratesReceivedByManufacturer[mfrId] = 0;

        final emptiesCtrl = TextEditingController(text: '0');
        emptiesCtrl.addListener(() {
          _emptiesReturnedByManufacturer[mfrId] =
              int.tryParse(emptiesCtrl.text) ?? 0;
        });
        _emptiesControllers[mfrId] = emptiesCtrl;
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
      // Centred and at most 640dp wide on tablets and wide screens (#394).
      constraints: const BoxConstraints(maxWidth: kReceiveSheetMaxWidth),
      builder: (ctx) => _SupplierPickerSheet(suppliers: _suppliers),
    );
    if (selected != null && mounted) {
      final db = ref.read(databaseProvider);
      final suppliers = await db.catalogDao.getAllSuppliers();
      if (!mounted) return;
      setState(() {
        _suppliers = suppliers;
        _selectedSupplier = selected;
      });
    }
  }

  Future<void> _confirm() async {
    final supplier = _selectedSupplier;
    final cart = ref.read(receiveCartProvider);
    if (cart.isEmpty) {
      AppNotification.showError(context, 'Cart is empty');
      return;
    }
    // Crate debt needs an owner (#210), so crate products keep the supplier
    // required. Anything else may be a supplier-less cash purchase.
    if (supplier == null && cart.any((l) => l.movesCrates)) {
      AppNotification.showError(context, 'Please select a supplier');
      return;
    }

    // The destination store is chosen explicitly via the "Stocking into"
    // dropdown, so we only need to ensure one is selected (no active-store
    // revalidation — the receipt lands wherever the user allocated it).
    if (_flowStoreId == null) {
      AppNotification.showError(
        context,
        'Please select a store to receive into',
      );
      return;
    }

    final notifier = ref.read(receiveCartProvider.notifier);
    final invoiceTotalKobo = notifier.invoiceTotalKobo;
    final totalUnits = notifier.totalUnits;

    // Only manufacturers still eligible on the current cart count — the same
    // gate the commit applies, so a line removed after the boxes were filled
    // cannot carry a stale crate figure into the dialog.
    final eligibleManufacturerIds = <String>{
      for (final line in cart)
        if (line.movesCrates) line.manufacturerId!,
    };
    int crateTotal(Map<String, int> byManufacturer) => eligibleManufacturerIds
        .fold(0, (sum, id) => sum + (byManufacturer[id] ?? 0));

    final confirmed = await _showConfirmationDialog(
      supplierName: supplier?.name,
      productCount: cart.length,
      totalUnits: totalUnits,
      invoiceTotalKobo: invoiceTotalKobo,
      storeName: _storeName(),
      uncostedItemCount: notifier.uncostedLineCount,
      fullCratesReceived: crateTotal(_fullCratesReceivedByManufacturer),
      emptiesReturned: crateTotal(_emptiesReturnedByManufacturer),
    );
    if (confirmed != true) return;

    setState(() => _isSaving = true);
    final staffId = ref.read(authProvider).currentUser?.id ?? 'unknown';
    final note = _noteCtrl.text.trim();

    try {
      // A payment is posted to the supplier's account, so there is none to
      // record without a supplier (the section is hidden then).
      final canManageSuppliers =
          supplier != null && Gates.manageSuppliers.allowsNow(ref);
      final amountPaid = (canManageSuppliers && _amountPaidCtrl.text.isNotEmpty)
          ? (double.tryParse(_amountPaidCtrl.text.replaceAll(',', '')) ?? 0)
          : 0;
      final amountPaidKobo = (amountPaid * 100).round();

      await ref
          .read(receiveStockServiceProvider)
          .confirmReceipt(
            supplierId: supplier?.id,
            supplierName: supplier?.name,
            storeId: _flowStoreId!,
            dateReceived: _dateReceived,
            staffId: staffId,
            lines: cart,
            fullCratesReceivedByManufacturer: Map<String, int>.from(
              _fullCratesReceivedByManufacturer,
            ),
            emptiesReturnedByManufacturer: Map<String, int>.from(
              _emptiesReturnedByManufacturer,
            ),
            note: note.isEmpty ? null : note,
            amountPaidKobo: amountPaidKobo > 0 ? amountPaidKobo : null,
            paymentMethod: amountPaidKobo > 0 ? _paymentMethod : null,
          );

      if (!mounted) return;
      ref.read(receiveCartProvider.notifier).clear();
      AppNotification.showSuccess(
        context,
        supplier == null
            ? 'Stock received'
            : 'Stock received from ${supplier.name}',
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
    required String? supplierName,
    required int productCount,
    required int totalUnits,
    required int invoiceTotalKobo,
    required String storeName,
    required int uncostedItemCount,
    required int fullCratesReceived,
    required int emptiesReturned,
  }) {
    final theme = Theme.of(context);
    final f = theme.extension<AppFixedColors>() ?? AppFixedColors.light;
    final crateParts = <String>[
      if (fullCratesReceived > 0) '$fullCratesReceived full in',
      if (emptiesReturned > 0) '$emptiesReturned empty back',
    ];
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Receipt'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _dialogRow('Supplier', supplierName ?? 'None (cash purchase)'),
            _dialogRow(
              'Items',
              '$productCount product(s), $totalUnits unit(s)',
            ),
            _dialogRow('Stocking', storeName),
            _dialogRow('Invoice Total', formatCurrency(invoiceTotalKobo / 100)),
            // #210: the crate movement is committed with the goods, so it is
            // disclosed with them — the receipt is all-or-nothing.
            if (crateParts.isNotEmpty)
              _dialogRow('Crates', crateParts.join(', ')),
            SizedBox(height: context.getRSize(12)),
            Text(
              supplierName == null
                  ? 'This increases stock at $storeName. With no supplier, '
                        'nothing is recorded as owed or paid.'
                  : 'This posts ${formatCurrency(invoiceTotalKobo / 100)} to '
                        "$supplierName's account and increases stock at "
                        '$storeName.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // The Uncosted disclosure is repeated at the last moment, next to
            // the total it undermines (#199). Still non-blocking — Confirm is
            // right there.
            if (uncostedItemCount > 0) ...[
              SizedBox(height: context.getRSize(8)),
              Text(
                'It excludes $uncostedItemCount '
                '${uncostedItemCount == 1 ? 'item' : 'items'} with no recorded '
                'buying price, so nothing is owed for '
                '${uncostedItemCount == 1 ? 'it' : 'them'} and '
                '${uncostedItemCount == 1 ? 'it' : 'they'} will show no profit '
                'when sold.',
                style: theme.textTheme.bodySmall?.copyWith(color: f.warning),
              ),
            ],
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
    final subtext = theme.textTheme.bodySmall?.color;

    final totalValueStr = formatCurrency(notifier.invoiceTotalKobo / 100);
    final supplierRequired = cart.any((l) => l.movesCrates);
    final uncostedLineCount = notifier.uncostedLineCount;

    // Crates are grouped by manufacturer: one row per manufacturer carrying a
    // bottle + trackEmpties line, with the units it delivered on this receipt
    // shown for context only. `unitsDelivered` is a BOTTLE count and is never
    // the crate figure — crate size is a category (Big/Medium/Small), so both
    // crate numbers are typed rather than derived (ADR 0023).
    final manufacturers =
        ref.watch(allManufacturersProvider).valueOrNull ??
        const <ManufacturerData>[];
    final mfrNames = {for (final m in manufacturers) m.id: m.name};
    final crateGroups =
        <({String manufacturerId, String name, int unitsDelivered})>[];
    final seenManufacturers = <String>{};
    for (final l in cart) {
      final mfrId = l.manufacturerId;
      if (!l.movesCrates || mfrId == null) continue;
      if (!seenManufacturers.add(mfrId)) continue;
      final unitsDelivered = cart
          .where((x) => x.movesCrates && x.manufacturerId == mfrId)
          .fold<int>(0, (sum, x) => sum + x.qty);
      crateGroups.add((
        manufacturerId: mfrId,
        name: mfrNames[mfrId] ?? 'Manufacturer',
        unitsDelivered: unitsDelivered,
      ));
    }

    final confirmEnabled =
        !((supplierRequired && _selectedSupplier == null) ||
            _flowStoreId == null ||
            _isSaving);

    return DecoratedBox(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: ReceiveTopBar(
          height: receiveTopBarHeight(context),
          icon: AppIcons.invoice,
          title: 'Invoice',
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (context, constraints) {
                  final side = receiveSidePadding(
                    context,
                    constraints.maxWidth,
                  );
                  return Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          key: ReceiveKeys.checkoutScroll,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: EdgeInsets.fromLTRB(
                            side,
                            context.getRSize(16),
                            side,
                            context.getRSize(24),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: _formChildren(
                              context,
                              cart: cart,
                              notifier: notifier,
                              totalValueStr: totalValueStr,
                              supplierRequired: supplierRequired,
                              uncostedLineCount: uncostedLineCount,
                              crateGroups: crateGroups,
                              subtext: subtext,
                            ),
                          ),
                        ),
                      ),
                      _ConfirmFooter(
                        sidePadding: side,
                        isSaving: _isSaving,
                        onPressed: confirmEnabled ? _confirm : null,
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  List<Widget> _formChildren(
    BuildContext context, {
    required List<ReceiveCartLine> cart,
    required ReceiveCartNotifier notifier,
    required String totalValueStr,
    required bool supplierRequired,
    required int uncostedLineCount,
    required List<({String manufacturerId, String name, int unitsDelivered})>
    crateGroups,
    required Color? subtext,
  }) {
    final gap = context.getRSize(16);
    return [
      // Invoice Total (read-only)
      StatCard(
        icon: AppIcons.invoice,
        tone: IconTileTone.info,
        title: 'Invoice Total',
        value: totalValueStr,
        subtitle: '${notifier.totalUnits} units • ${cart.length} products',
      ),
      SizedBox(height: context.getRSize(12)),

      // Uncosted disclosure (#199 / PRD #155 US 37) — sits directly
      // under the Invoice Total because that is the figure it
      // undermines: a line with no buying price contributes nothing
      // to it, so no payable is raised and the units later sell at
      // 0 COGS. Informational only; Confirm Receipt stays enabled.
      if (uncostedLineCount > 0) ...[
        UncostedReceiveWarning(
          itemCount: uncostedLineCount,
          unitCount: notifier.uncostedUnits,
        ),
        SizedBox(height: context.getRSize(12)),
      ],

      // Stocking into: destination store (the receipt commits stock
      // to THIS store). Defaults to the active store; the user can
      // re-allocate to any store they can access.
      _fieldLabel('STOCKING INTO *'),
      AppDropdown<String>(
        value: _flowStoreId,
        hintText: 'Select store',
        prefixIcon: Icon(
          AppIcons.store,
          size: context.getRSize(18),
          color: subtext,
        ),
        items: [
          for (final s in _stores)
            DropdownMenuItem(value: s.id, child: Text(s.name)),
        ],
        onChanged: (v) => setState(() => _flowStoreId = v),
      ),
      SizedBox(height: gap),

      // Supplier (searchable). Required only when a line moves
      // crates; otherwise none = a cash purchase.
      _fieldLabel(supplierRequired ? 'SUPPLIER *' : 'SUPPLIER (optional)'),
      _TapField(
        key: ReceiveKeys.supplierField,
        icon: AppIcons.supplierDelivery,
        text: _selectedSupplier?.name ?? 'Select supplier',
        isPlaceholder: _selectedSupplier == null,
        onTap: _pickSupplier,
        onClear: _selectedSupplier == null
            ? null
            : () => setState(() => _selectedSupplier = null),
        clearKey: ReceiveKeys.supplierClear,
      ),
      if (_selectedSupplier == null) ...[
        SizedBox(height: context.getRSize(6)),
        Text(
          supplierRequired
              ? 'Needed for drinks with crates, so the crates are '
                    'recorded against someone.'
              : 'No supplier? It is saved as a cash purchase: '
                    'stock goes up, nothing is recorded as owed.',
          style: context.regularStyle(12).copyWith(color: subtext),
        ),
      ],
      SizedBox(height: gap),

      // Date received (default today, backdate allowed)
      _fieldLabel('DATE RECEIVED'),
      _TapField(
        key: ReceiveKeys.dateField,
        icon: AppIcons.calendar,
        text: _formatDate(_dateReceived),
        isPlaceholder: false,
        onTap: _pickDate,
      ),
      SizedBox(height: gap),

      // Note (optional)
      AppInput(
        controller: _noteCtrl,
        labelText: 'Reference Note (Optional)',
        hintText: 'e.g. Invoice #12345',
      ),
      SizedBox(height: gap),

      if (_selectedSupplier != null && Gates.manageSuppliers.allows(ref)) ...[
        // Payment (optional)
        _fieldLabel('PAYMENT'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: AppInput(
                controller: _amountPaidCtrl,
                labelText: 'Amount Paid Now',
                hintText: '0.00',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [CurrencyInputFormatter()],
              ),
            ),
            SizedBox(width: context.getRSize(12)),
            Expanded(
              flex: 1,
              child: AppDropdown<String>(
                key: ReceiveKeys.paymentMethod,
                value: _paymentMethod,
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
          ],
        ),
        SizedBox(height: gap),
      ],

      // Line items summary
      _fieldLabel('ITEMS'),
      Container(
        decoration: AppDecorations.card(context),
        child: Column(
          children: [
            for (var i = 0; i < cart.length; i++) ...[
              if (i > 0)
                Divider(height: 1, color: Theme.of(context).dividerColor),
              _lineRow(cart[i], subtext),
            ],
          ],
        ),
      ),

      // Crates moved with this delivery (grouped by manufacturer).
      // Both directions sit together because they happen together:
      // the driver drops full crates off and takes empties away in
      // the same visit, and recording only one side is what drove
      // supplier crate debt negative (#210 / ADR 0023).
      if (crateGroups.isNotEmpty) ...[
        SizedBox(height: gap),
        _fieldLabel('CRATES WITH THIS DELIVERY'),
        Text(
          'Count the crates and type them in. Crate sizes differ, so '
          'the number cannot be worked out from the drinks '
          'delivered. Leave a box at 0 if nothing moved.',
          style: context.regularStyle(12).copyWith(color: subtext),
        ),
        SizedBox(height: context.getRSize(12)),
        Container(
          decoration: AppDecorations.card(context),
          child: Column(
            children: [
              for (var i = 0; i < crateGroups.length; i++) ...[
                if (i > 0)
                  Divider(height: 1, color: Theme.of(context).dividerColor),
                _crateRow(crateGroups[i], subtext),
              ],
            ],
          ),
        ),
      ],
    ];
  }

  /// A group label over a field ("STOCKING INTO *"), wording unchanged.
  Widget _fieldLabel(String text) => Padding(
    padding: EdgeInsets.only(bottom: context.getRSize(8)),
    child: SectionHeader(title: text, variant: SectionHeaderVariant.group),
  );

  Widget _lineRow(ReceiveCartLine line, Color? subtext) {
    final t = Theme.of(context);
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
                  style: context
                      .boldStyle(15)
                      .copyWith(color: t.colorScheme.onSurface),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  '${line.qty} × ${formatCurrency(line.buyingPriceKobo / 100)}',
                  style: context.regularStyle(13).copyWith(color: subtext),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            formatCurrency(line.buyingPriceKobo * line.qty / 100),
            style: context.boldStyle(15).copyWith(color: t.colorScheme.primary),
          ),
        ],
      ),
    );
  }

  /// One manufacturer's crate row: full crates that arrived, and empties handed
  /// back. Both are typed — `unitsDelivered` is shown only as context and is a
  /// bottle count, never a crate count.
  Widget _crateRow(
    ({String manufacturerId, String name, int unitsDelivered}) group,
    Color? subtext,
  ) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconTile(
                icon: AppIcons.crates,
                tone: IconTileTone.warning,
                size: 40,
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.name,
                      style: context
                          .boldStyle(15)
                          .copyWith(color: t.colorScheme.onSurface),
                    ),
                    Text(
                      '${group.unitsDelivered} '
                      '${group.unitsDelivered == 1 ? 'drink' : 'drinks'} on '
                      'this delivery',
                      style: context.regularStyle(12).copyWith(color: subtext),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(10)),
          Row(
            children: [
              Expanded(
                child: AppInput(
                  controller: _fullCratesControllers[group.manufacturerId],
                  labelText: 'Full crates in',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: AppInput(
                  controller: _emptiesControllers[group.manufacturerId],
                  labelText: 'Empty crates back',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Confirm Receipt", pinned under the form on Surface with a hairline; the
/// button keeps to the content width.
class _ConfirmFooter extends StatelessWidget {
  const _ConfirmFooter({
    required this.sidePadding,
    required this.isSaving,
    required this.onPressed,
  });

  final double sidePadding;
  final bool isSaving;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        sidePadding,
        context.getRSize(12),
        sidePadding,
        context.getRSize(12) + context.deviceBottomPadding,
      ),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: AppButton(
        key: ReceiveKeys.confirmButton,
        text: 'Confirm Receipt',
        onPressed: onPressed,
        isLoading: isSaving,
        isFullWidth: true,
      ),
    );
  }
}

/// Read-only tappable field used for the supplier + date pickers: a card-like
/// field (Surface, hairline, `borderRadiusM`), leading icon, the value (or
/// placeholder), and a chevron — or, when [onClear] is set, a 48dp clear ✕.
class _TapField extends StatelessWidget {
  final IconData? icon;
  final String text;
  final bool isPlaceholder;
  final VoidCallback onTap;

  /// When set, a clear (×) button replaces the chevron.
  final VoidCallback? onClear;
  final Key? clearKey;

  const _TapField({
    super.key,
    required this.icon,
    required this.text,
    required this.isPlaceholder,
    required this.onTap,
    this.onClear,
    this.clearKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtext =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusM);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          padding: EdgeInsets.only(
            left: context.getRSize(16),
            right: context.getRSize(4),
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: radius,
            border: Border.all(color: theme.dividerColor),
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                AppIcon(icon!, size: context.getRSize(18), color: subtext),
                SizedBox(width: context.getRSize(12)),
              ],
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: context.getRSize(14)),
                  child: Text(
                    text,
                    style: isPlaceholder
                        ? context.regularStyle(15).copyWith(color: subtext)
                        : context
                              .semiBoldStyle(15)
                              .copyWith(color: theme.colorScheme.onSurface),
                  ),
                ),
              ),
              if (onClear != null)
                IconButton(
                  key: clearKey,
                  tooltip: 'Clear',
                  constraints: const BoxConstraints(
                    minWidth: kMinInteractiveDimension,
                    minHeight: kMinInteractiveDimension,
                  ),
                  onPressed: onClear,
                  icon: AppIcon(
                    AppIcons.close,
                    size: context.getRSize(18),
                    color: subtext,
                  ),
                )
              else
                SizedBox(
                  width: kMinInteractiveDimension,
                  child: AppIcon(
                    AppIcons.chevronDown,
                    size: context.getRSize(18),
                    color: subtext,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Searchable single-select supplier picker (§7.4). Soft-deleted suppliers are
/// already excluded upstream by `getAllSuppliers()`.
class _SupplierPickerSheet extends ConsumerStatefulWidget {
  final List<SupplierData> suppliers;
  const _SupplierPickerSheet({required this.suppliers});

  @override
  ConsumerState<_SupplierPickerSheet> createState() =>
      _SupplierPickerSheetState();
}

class _SupplierPickerSheetState extends ConsumerState<_SupplierPickerSheet> {
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
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
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
        key: ReceiveKeys.supplierSheet,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppSpacing.borderRadiusXL),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          context.getRSize(20),
          context.getRSize(12),
          context.getRSize(20),
          0,
        ),
        child: Column(
          children: [
            const ReceiveSheetHandle(),
            SizedBox(height: context.getRSize(16)),
            AppInput(
              controller: _searchCtrl,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              hintText: 'Search suppliers...',
              prefixIcon: Icon(AppIcons.search, size: context.getRSize(18)),
            ),
            if (Gates.manageSuppliers.allows(ref)) ...[
              SizedBox(height: context.getRSize(12)),
              AppButton(
                text: 'Add Supplier',
                variant: AppButtonVariant.outline,
                size: AppButtonSize.small,
                icon: AppIcons.add,
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  final created = await SupplierFormSheet.show(context);
                  if (created != null) {
                    navigator.pop(created);
                  }
                },
              ),
            ],
            SizedBox(height: context.getRSize(12)),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No suppliers found',
                        style: context.semiBoldStyle(14).copyWith(color: muted),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: EdgeInsets.only(
                        bottom:
                            context.getRSize(16) + context.deviceBottomPadding,
                      ),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) =>
                          SizedBox(height: context.getRSize(8)),
                      itemBuilder: (context, index) {
                        final s = filtered[index];
                        return _SupplierRow(
                          key: receiveSupplierRowKey(s.id),
                          name: s.name,
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

/// One supplier: a card with the supplier tile and the name; the whole card
/// taps (48dp+).
class _SupplierRow extends StatelessWidget {
  const _SupplierRow({super.key, required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final radius = BorderRadius.circular(AppSpacing.borderRadiusL);
    return DecoratedBox(
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusL,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(10)),
              child: Row(
                children: [
                  const IconTile(
                    icon: AppIcons.supplier,
                    tone: IconTileTone.info,
                    size: 40,
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context
                          .boldStyle(15)
                          .copyWith(color: t.colorScheme.onSurface),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
