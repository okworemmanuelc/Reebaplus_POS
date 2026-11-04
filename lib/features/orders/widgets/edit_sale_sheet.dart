import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

/// Keys for tests (#713).
abstract final class EditSaleKeys {
  static const editor = Key('edit-sale-editor');
  static const addItem = Key('edit-sale-add-item');
  static const reason = Key('edit-sale-reason');
  static const continueButton = Key('edit-sale-continue');
  static const moneyDialog = Key('edit-sale-money-dialog');
  static const moneyConfirm = Key('edit-sale-money-confirm');
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

/// One sale line as the editor shows it: [current] is what stands today (the
/// original minus what was already returned).
class EditLineSeed {
  const EditLineSeed({
    required this.lineId,
    required this.name,
    required this.current,
    required this.unitPriceKobo,
    required this.canRaise,
    required this.allowParts,
  });
  final String lineId;
  final String name;
  final double current;
  final int unitPriceKobo;
  final bool canRaise;
  final bool allowParts;
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
                      subtitle: Text(formatCurrency(l.unitPriceKobo / 100.0)),
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

/// What the cashier chose in the money step of an edit.
class EditMoneyChoice {
  const EditMoneyChoice({this.method = 'cash', this.paidKobo});
  final String method;

  /// Null = the full amount due.
  final int? paidKobo;
}

/// #713 — the pop-up for money the customer owes after an edit. Only shown for
/// a net amount due. A walk-in must pay all of it; a named customer may pay
/// less and the rest goes on their balance. Returns null when dismissed.
Future<EditMoneyChoice?> showEditMoneyDialog(
  BuildContext context, {
  required int dueKobo,
  required bool hasCustomer,
}) {
  return showDialog<EditMoneyChoice>(
    context: context,
    builder: (_) => _EditMoneyDialog(dueKobo: dueKobo, hasCustomer: hasCustomer),
  );
}

class _EditMoneyDialog extends StatefulWidget {
  const _EditMoneyDialog({required this.dueKobo, required this.hasCustomer});
  final int dueKobo;
  final bool hasCustomer;

  @override
  State<_EditMoneyDialog> createState() => _EditMoneyDialogState();
}

class _EditMoneyDialogState extends State<_EditMoneyDialog> {
  String _method = 'cash';
  late final TextEditingController _paid = TextEditingController(
    text: (widget.dueKobo / 100).toStringAsFixed(2),
  );

  @override
  void dispose() {
    _paid.dispose();
    super.dispose();
  }

  int get _paidKobo {
    final v = double.tryParse(_paid.text.replaceAll(',', '')) ?? 0;
    return (v * 100).round().clamp(0, widget.dueKobo).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final due = formatCurrency(widget.dueKobo / 100.0);
    final rest = widget.dueKobo - _paidKobo;
    return AlertDialog(
      key: EditSaleKeys.moneyDialog,
      scrollable: true,
      title: const Text('Customer owes more'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('After this change the customer owes $due.'),
          SizedBox(height: context.getRSize(8)),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'cash', label: Text('Cash')),
              ButtonSegment(value: 'transfer', label: Text('Transfer')),
            ],
            selected: {_method},
            onSelectionChanged: (s) => setState(() => _method = s.first),
          ),
          SizedBox(height: context.getRSize(8)),
          TextField(
            controller: _paid,
            enabled: widget.hasCustomer,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Customer pays now'),
          ),
          if (widget.hasCustomer && rest > 0)
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
          text: 'Save changes',
          isFullWidth: false,
          onAsyncPressed: () async => Navigator.pop(
            context,
            EditMoneyChoice(
              method: _method,
              paidKobo: widget.hasCustomer ? _paidKobo : widget.dueKobo,
            ),
          ),
        ),
      ],
    );
  }
}
