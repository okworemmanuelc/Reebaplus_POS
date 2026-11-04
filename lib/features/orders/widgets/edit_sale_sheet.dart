import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/services/orders/sale_totals.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/crate_deposit_sheet.dart';

/// Keys for tests (#713).
abstract final class EditSaleKeys {
  static const editor = Key('edit-sale-editor');
  static const addItem = Key('edit-sale-add-item');
  static const reason = Key('edit-sale-reason');
  static const continueButton = Key('edit-sale-continue');
  static const moneyDialog = Key('edit-sale-money-dialog');
  static const moneyConfirm = Key('edit-sale-money-confirm');
  static const amountDue = Key('edit-sale-amount-due');
  static const depositSection = Key('edit-sale-deposit-section');
  static const depositSheet = Key('edit-sale-deposit-sheet');
  static const depositNotCovered = Key('edit-sale-deposit-not-covered');
  static const onBalance = Key('edit-sale-on-balance');
  static Key depositRow(String manufacturerId) =>
      Key('edit-sale-deposit-row-$manufacturerId');
}

/// What the editor collected. The editor performs no writes.
class EditSaleInput {
  const EditSaleInput({
    required this.newQtyByLineId,
    required this.addedLines,
    required this.reason,
  });

  /// Sale line id -> the quantity it should end at.
  final Map<String, double> newQtyByLineId;
  final List<EditAddedLine> addedLines;
  final String reason;
}

/// One product as the editor shows it: [current] is what stands today (the
/// original plus what edits added, minus what was already returned).
class EditLineSeed {
  const EditLineSeed({
    required this.lineId,
    required this.name,
    required this.current,
    required this.unitPriceKobo,
    required this.canRaise,
    required this.allowParts,
    this.addedNote,
  });
  final String lineId;
  final String name;
  final double current;
  final int unitPriceKobo;
  final bool canRaise;
  final bool allowParts;

  /// Goods added by an earlier edit in this row, with their price (#732).
  final String? addedNote;
}

/// #713 — the cart-style editor, seeded with the sale's standing quantities.
/// Returns null when dismissed.
Future<EditSaleInput?> showEditSaleEditor(
  BuildContext context, {
  required String orderNumber,
  required String? storeId,
  required String priceTier,
  required List<EditLineSeed> lines,
}) {
  return Navigator.of(context).push<EditSaleInput>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _EditSaleEditor(
        orderNumber: orderNumber,
        storeId: storeId,
        priceTier: priceTier,
        lines: lines,
      ),
    ),
  );
}

class _Added {
  _Added(this.product, this.unitPriceKobo, this.allowParts);
  final ProductData product;
  final int unitPriceKobo;
  final bool allowParts;
  double qty = 1;
}

class _EditSaleEditor extends ConsumerStatefulWidget {
  const _EditSaleEditor({
    required this.orderNumber,
    required this.storeId,
    required this.priceTier,
    required this.lines,
  });
  final String orderNumber;
  final String? storeId;
  final String priceTier;
  final List<EditLineSeed> lines;

  @override
  ConsumerState<_EditSaleEditor> createState() => _EditSaleEditorState();
}

class _EditSaleEditorState extends ConsumerState<_EditSaleEditor> {
  late final Map<String, double> _qty = {
    for (final l in widget.lines) l.lineId: l.current,
  };
  final List<_Added> _added = [];
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  double _step(bool allowParts) => allowParts ? 0.25 : 1;

  bool get _changed =>
      _added.isNotEmpty ||
      widget.lines.any((l) => (_qty[l.lineId]! - l.current).abs() > 1e-9);

  Widget _stepper({
    required double value,
    required double step,
    required double min,
    required double? max,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(AppIcons.removeCircle),
          onPressed: value - step < min - 1e-9
              ? null
              : () => onChanged(value - step),
        ),
        Text(formatQty(value), style: context.regularStyle(15)),
        IconButton(
          icon: const Icon(AppIcons.addCircle),
          onPressed: max != null && value + step > max + 1e-9
              ? null
              : () => onChanged(value + step),
        ),
      ],
    );
  }

  Future<void> _pickProduct() async {
    final db = ref.read(databaseProvider);
    final picked = await showModalBottomSheet<ProductData>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ProductSearchSheet(
        stream: widget.storeId == null
            ? db.inventoryDao.watchAllProductDatasWithStock()
            : db.inventoryDao.watchProductsByStore(widget.storeId!),
      ),
    );
    if (picked == null || !mounted) return;
    final existing = _added.where((a) => a.product.id == picked.id);
    setState(() {
      if (existing.isNotEmpty) {
        existing.first.qty += _step(existing.first.allowParts);
      } else {
        _added.add(
          _Added(
            picked,
            widget.priceTier == 'wholesaler'
                ? picked.wholesalerPriceKobo
                : picked.retailerPriceKobo,
            picked.allowFractionalSales,
          ),
        );
      }
    });
  }

  EditSaleInput _input() => EditSaleInput(
    newQtyByLineId: {
      for (final l in widget.lines)
        if ((_qty[l.lineId]! - l.current).abs() > 1e-9)
          l.lineId: _qty[l.lineId]!,
    },
    addedLines: [
      for (final a in _added)
        EditAddedLine(productId: a.product.id, quantity: a.qty),
    ],
    reason: _reason.text.trim(),
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      key: EditSaleKeys.editor,
      appBar: AppBar(title: Text('Edit sale ${widget.orderNumber}')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(context.getRSize(16)),
                children: [
                  Text(
                    'Change how many of each item the customer is keeping, or '
                    'add more items. New items are sold at today\'s price.',
                    style: context.regularStyle(13).copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(height: context.getRSize(12)),
                  for (final l in widget.lines)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.name),
                      subtitle: Text(
                        l.addedNote == null
                            ? formatCurrency(l.unitPriceKobo / 100.0)
                            : '${formatCurrency(l.unitPriceKobo / 100.0)}\n'
                                  '${l.addedNote}',
                      ),
                      trailing: _stepper(
                        value: _qty[l.lineId]!,
                        step: _step(l.allowParts),
                        min: 0,
                        max: l.canRaise ? null : l.current,
                        onChanged: (v) => setState(() => _qty[l.lineId] = v),
                      ),
                    ),
                  if (_added.isNotEmpty) ...[
                    const Divider(),
                    Text('Added today', style: context.regularStyle(13)),
                  ],
                  for (final a in _added)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(a.product.name),
                      subtitle: Text(formatCurrency(a.unitPriceKobo / 100.0)),
                      trailing: _stepper(
                        value: a.qty,
                        step: _step(a.allowParts),
                        min: 0,
                        max: null,
                        onChanged: (v) => setState(() {
                          if (v <= 0) {
                            _added.remove(a);
                          } else {
                            a.qty = v;
                          }
                        }),
                      ),
                    ),
                  SizedBox(height: context.getRSize(8)),
                  AppButton(
                    key: EditSaleKeys.addItem,
                    text: 'Add item',
                    variant: AppButtonVariant.secondary,
                    onPressed: _pickProduct,
                  ),
                  SizedBox(height: context.getRSize(16)),
                  TextField(
                    key: EditSaleKeys.reason,
                    controller: _reason,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Why is this sale being changed?',
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.all(context.getRSize(16)),
              child: AppButton(
                key: EditSaleKeys.continueButton,
                text: 'Continue',
                onAsyncPressed: (_changed && _reason.text.trim().isNotEmpty)
                    ? () async => Navigator.pop(context, _input())
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductSearchSheet extends StatefulWidget {
  const _ProductSearchSheet({required this.stream});
  final Stream<List<ProductDataWithStock>> stream;

  @override
  State<_ProductSearchSheet> createState() => _ProductSearchSheetState();
}

class _ProductSearchSheetState extends State<_ProductSearchSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: context.sheetMaxHeight(0.7),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.all(context.getRSize(12)),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Search items',
                  prefixIcon: Icon(AppIcons.search),
                ),
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
              ),
            ),
            Expanded(
              child: StreamBuilder<List<ProductDataWithStock>>(
                stream: widget.stream,
                builder: (context, snap) {
                  final rows = [
                    for (final r in snap.data ?? const <ProductDataWithStock>[])
                      if (r.totalStock > 0 &&
                          (_q.isEmpty ||
                              r.product.name.toLowerCase().contains(_q)))
                        r,
                  ];
                  if (rows.isEmpty) {
                    return const Center(child: Text('No items found'));
                  }
                  return ListView(
                    children: [
                      for (final r in rows)
                        ListTile(
                          title: Text(r.product.name),
                          subtitle: Text('${formatQty(r.totalStock)} in stock'),
                          onTap: () => Navigator.pop(context, r.product),
                        ),
                    ],
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

/// The added crates that need the deposit section (#732): a registered customer
/// and a crate value set for the brand. A brand with no value has nothing to
/// collect, as at Checkout.
List<EditCrateBrand> editDepositBrands(
  EditSalePlan plan, {
  required bool hasCustomer,
}) => hasCustomer
    ? [
        for (final b in plan.crateBrands)
          if (b.line.rateKobo > 0) b,
      ]
    : const [];

/// What the cashier chose in the money step of an edit.
class EditMoneyChoice {
  const EditMoneyChoice({
    this.method = 'cash',
    this.paidKobo,
    this.depositByManufacturer = const {},
  });
  final String method;

  /// Null = the full amount due.
  final int? paidKobo;

  /// The crate deposit per brand (#732): 0 = crates tracked.
  final Map<String, int> depositByManufacturer;
}

const String _onBalance = 'balance';

/// #713 — the pop-up for money the customer owes after an edit, and (#732) the
/// crate deposit on added crates. Shown for an amount due or for [crateBrands].
/// The deposit starts at the full amount per brand and can go down to zero (zero
/// = crates tracked). It is on top of the goods and nets against any money the
/// edit frees ([settlement], given with no deposit). A walk-in must pay all of
/// it; a named customer may pay less, down to the deposit, and the rest goes on
/// their balance. "Balance" charges it all, so no deposit is taken, as a
/// Credit Sale at Checkout. Returns null when dismissed.
Future<EditMoneyChoice?> showEditMoneyDialog(
  BuildContext context, {
  required EditSettlement settlement,
  required bool hasCustomer,
  List<EditCrateBrand> crateBrands = const [],
}) {
  return showDialog<EditMoneyChoice>(
    context: context,
    builder: (_) => _EditMoneyDialog(
      settlement: settlement,
      hasCustomer: hasCustomer,
      crateBrands: crateBrands,
    ),
  );
}

class _EditMoneyDialog extends StatefulWidget {
  const _EditMoneyDialog({
    required this.settlement,
    required this.hasCustomer,
    required this.crateBrands,
  });
  final EditSettlement settlement;
  final bool hasCustomer;
  final List<EditCrateBrand> crateBrands;

  @override
  State<_EditMoneyDialog> createState() => _EditMoneyDialogState();
}

class _EditMoneyDialogState extends State<_EditMoneyDialog> {
  String _method = 'cash';
  late final Map<String, int> _depositByBrand = {
    for (final b in widget.crateBrands)
      b.line.manufacturerId: b.line.fullDepositKobo,
  };
  late final TextEditingController _paid = TextEditingController(
    text: _amountText(_settle.dueKobo),
  );

  static String _amountText(int kobo) => (kobo / 100).toStringAsFixed(2);

  /// The Checkout rule, not a copy of it.
  SaleTotals get _totals => SaleTotals.compute(
    goodsTotalNaira: widget.settlement.goodsDueKobo / 100.0,
    crateLines: [for (final b in widget.crateBrands) b.line],
    isWalkIn: !widget.hasCustomer,
    isCashTransfer: _method != _onBalance,
    isCrateBusiness: true,
    depositByManufacturer: _depositByBrand,
  );

  EditSettlement get _settle =>
      widget.settlement.withDeposit(_totals.depositKobo);

  bool get _canPutOnBalance =>
      widget.hasCustomer &&
      widget.crateBrands.isNotEmpty &&
      widget.settlement.dueKobo > 0;

  @override
  void dispose() {
    _paid.dispose();
    super.dispose();
  }

  int get _paidKobo {
    if (_method == _onBalance) return 0;
    final v = double.tryParse(_paid.text.replaceAll(',', '')) ?? 0;
    return (v * 100).round().clamp(0, _settle.dueKobo).toInt();
  }

  /// Deposit or tender changed: the amount due moved, so the field follows it.
  void _change(VoidCallback fn) {
    setState(() {
      fn();
      _paid.text = _amountText(_settle.dueKobo);
    });
  }

  Future<void> _editDeposit(EditCrateBrand brand) async {
    final id = brand.line.manufacturerId;
    final kobo = await showCrateDepositSheet(
      context,
      name: brand.name,
      fullKobo: brand.line.fullDepositKobo,
      savedKobo: _depositByBrand[id] ?? 0,
      sheetKey: EditSaleKeys.depositSheet,
      onRootNavigator: true,
    );
    if (kobo == null || !mounted) return;
    _change(() => _depositByBrand[id] = kobo);
  }

  Widget _depositSection() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      key: EditSaleKeys.depositSection,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Crate deposit', style: context.boldStyle(14)),
        SizedBox(height: context.getRSize(4)),
        Text(
          'Refundable, held for the added crates. Tap a brand to change it. '
          '${formatCurrency(0)} means no deposit: the crates are tracked '
          'instead.',
          style: context.regularStyle(12).copyWith(color: cs.onSurfaceVariant),
        ),
        for (final b in widget.crateBrands)
          ListTile(
            key: EditSaleKeys.depositRow(b.line.manufacturerId),
            contentPadding: EdgeInsets.zero,
            title: Text(b.name),
            subtitle: Text(
              '${formatQty(b.line.crates)} '
              'crate${b.line.crates == 1 ? '' : 's'} · '
              'Full ${formatCurrency(b.line.fullDepositKobo / 100.0)}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatCurrency(
                    (_depositByBrand[b.line.manufacturerId] ?? 0) / 100.0,
                  ),
                  style: context.boldStyle(14).copyWith(color: cs.primary),
                ),
                SizedBox(width: context.getRSize(6)),
                Icon(
                  AppIcons.edit,
                  size: context.getRSize(16),
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
            onTap: () => _editDeposit(b),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final settle = _settle;
    final deposit = settle.depositKobo;
    final owes = settle.dueKobo > 0;
    final due = formatCurrency(settle.dueKobo / 100.0);
    final rest = settle.dueKobo - _paidKobo;
    final uncovered = owes && _paidKobo < settle.minPayKobo;
    return AlertDialog(
      key: EditSaleKeys.moneyDialog,
      scrollable: true,
      title: Text(owes ? 'Customer owes more' : 'Crate deposit'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            key: EditSaleKeys.amountDue,
            owes
                ? 'After this change the customer owes $due.'
                : settle.handBackKobo > 0
                ? 'After this change the customer gets back '
                      '${formatCurrency(settle.handBackKobo / 100.0)}.'
                : 'After this change nothing more is owed.',
          ),
          if (deposit > 0)
            Text(
              'This includes the ${formatCurrency(deposit / 100.0)} crate '
              'deposit.',
            ),
          if (_totals.depositApplies) ...[
            SizedBox(height: context.getRSize(8)),
            _depositSection(),
          ],
          if (owes || _method == _onBalance) ...[
            SizedBox(height: context.getRSize(8)),
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(value: 'cash', label: Text('Cash')),
                const ButtonSegment(value: 'transfer', label: Text('Transfer')),
                if (_canPutOnBalance)
                  const ButtonSegment(
                    value: _onBalance,
                    label: Text('Balance', key: EditSaleKeys.onBalance),
                  ),
              ],
              selected: {_method},
              onSelectionChanged: (s) => _change(() => _method = s.first),
            ),
          ],
          if (owes) ...[
            SizedBox(height: context.getRSize(8)),
            TextField(
              controller: _paid,
              enabled: widget.hasCustomer && _method != _onBalance,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Customer pays now'),
            ),
          ],
          if (uncovered)
            Padding(
              key: EditSaleKeys.depositNotCovered,
              padding: EdgeInsets.only(top: context.getRSize(8)),
              child: Text(
                'Amount paid must cover the crate deposit of '
                '${formatCurrency(settle.minPayKobo / 100.0)}. '
                'Reduce the deposit or collect more.',
              ),
            )
          else if (widget.hasCustomer && rest > 0)
            Padding(
              padding: EdgeInsets.only(top: context.getRSize(8)),
              child: Text(
                '${formatCurrency(rest / 100.0)} will be added to what the '
                'customer owes.',
              ),
            ),
        ],
      ),
      actions: [
        AppButton(
          text: 'Back',
          variant: AppButtonVariant.ghost,
          isFullWidth: false,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          key: EditSaleKeys.moneyConfirm,
          text: settle.handBackKobo > 0 ? 'Continue' : 'Save changes',
          isFullWidth: false,
          onAsyncPressed: uncovered
              ? null
              : () async => Navigator.pop(
                  context,
                  EditMoneyChoice(
                    method: _method == _onBalance ? 'cash' : _method,
                    paidKobo: widget.hasCustomer ? _paidKobo : settle.dueKobo,
                    depositByManufacturer: _totals.depositApplies
                        ? Map.of(_depositByBrand)
                        : const {},
                  ),
                ),
        ),
      ],
    );
  }
}
