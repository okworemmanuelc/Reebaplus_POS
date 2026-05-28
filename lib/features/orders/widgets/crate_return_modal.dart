
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

class CrateReturnModal extends ConsumerStatefulWidget {
  final OrderWithItems orderWithItems;

  const CrateReturnModal({super.key, required this.orderWithItems});

  /// Opens the modal only when appropriate:
  ///   - There must be bottle-unit items in the order (these are the items
  ///     that generate empty-crate returns).
  ///   - If the deposit already fully covers the expected crate deposit, skip.
  /// Returns `true` if the user confirmed crate returns, `false` if skipped
  /// or if the modal was not shown (guards triggered).
  static Future<bool> show(
    BuildContext context,
    OrderWithItems orderWithItems, {
    required WidgetRef ref,
  }) async {
    // Guard 1: skip if no bottle items with trackEmpties enabled
    final hasBottles = orderWithItems.items.any(
      (i) =>
          i.product.unit.toLowerCase() == 'bottle' && i.product.trackEmpties,
    );
    if (!hasBottles) return true; // no crates to track — proceed

    // Guard 2: skip if full deposit was already paid.
    // Expected deposit = sum over tracked bottle items of (manufacturer.depositAmountKobo * qty).
    final db = ref.read(databaseProvider);
    final manufacturers = await db.inventoryDao.getAllManufacturers();
    final mfrDeposit = {
      for (final m in manufacturers) m.id: m.depositAmountKobo,
    };
    int expectedDepositKobo = 0;
    for (final ri in orderWithItems.items) {
      if (ri.product.unit.toLowerCase() != 'bottle') continue;
      if (!ri.product.trackEmpties) continue;
      final mfrId = ri.product.manufacturerId;
      if (mfrId == null) continue;
      expectedDepositKobo += (mfrDeposit[mfrId] ?? 0) * ri.item.quantity;
    }
    final paidDepositKobo = orderWithItems.order.crateDepositPaidKobo;
    if (expectedDepositKobo > 0 && paidDepositKobo >= expectedDepositKobo) {
      return true; // deposit covered — proceed
    }

    if (!context.mounted) return false;
    final result = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CrateReturnModal(orderWithItems: orderWithItems),
    );
    return result == true;
  }

  @override
  ConsumerState<CrateReturnModal> createState() => _CrateReturnModalState();
}

class _CrateReturnModalState extends ConsumerState<CrateReturnModal> {
  List<_ManufacturerRow> _rows = [];
  bool _loading = true;
  bool _saving = false;

  Color get _text => Theme.of(context).colorScheme.onSurface;
  Color get _subtext =>
      Theme.of(context).textTheme.bodySmall?.color ??
      Theme.of(context).iconTheme.color!;
  Color get _bg => Theme.of(context).scaffoldBackgroundColor;
  Color get _card => Theme.of(context).cardColor;
  Color get _border => Theme.of(context).dividerColor;

  @override
  void initState() {
    super.initState();
    _buildRows();
  }

  Future<void> _buildRows() async {
    // Accumulate: manufacturerId → {name, total qty}
    // Bottles (unit == 'Bottle') are the only items that generate crate returns.
    final Map<String, _ManufacturerAccum> accum = {};

    final mfrs =
        await ref.read(databaseProvider).inventoryDao.getAllManufacturers();
    final mfrNames = {for (final m in mfrs) m.id: m.name};

    for (final ri in widget.orderWithItems.items) {
      final product = ri.product;
      if (product.unit.toLowerCase() != 'bottle') continue;
      if (!product.trackEmpties) continue;

      final mfId = product.manufacturerId ?? '';
      final mfName = mfrNames[mfId] ??
          (mfId.isEmpty ? 'Unknown Manufacturer' : 'Manufacturer $mfId');
      final cgId = product.crateSizeGroupId ?? '';
      if (cgId.isEmpty) continue; // Skip if no crate group linked

      final qty = ri.item.quantity;
      final key = '$mfId:$cgId';

      accum.putIfAbsent(
        key,
        () => _ManufacturerAccum(id: mfId, name: mfName, crateSizeGroupId: cgId),
      );
      accum[key]!.totalQty += qty;
    }

    final rows = accum.values
        .map(
          (a) => _ManufacturerRow(
            manufacturerId: a.id,
            crateSizeGroupId: a.crateSizeGroupId,
            name: a.name,
            expectedQty: a.totalQty,
            controller: TextEditingController(text: a.totalQty.toString()),
          ),
        )
        .toList();

    if (mounted) {
      setState(() {
        _rows = rows;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_saving) return;
    setState(() => _saving = true);

    final customer = widget.orderWithItems.customer;
    final order = widget.orderWithItems.order;
    final db = ref.read(databaseProvider);
    final auth = ref.read(authProvider);

    // Walk-in customer: just record physical stock returns; lone owner has full
    // authority so no PIN override is needed.
    if (customer == null) {
      for (final row in _rows) {
        final returned = int.tryParse(row.controller.text) ?? row.expectedQty;
        if (row.manufacturerId.isNotEmpty) {
          await db.inventoryDao.addEmptyCrates(
            row.manufacturerId,
            returned,
          );
        }
      }
      if (mounted) Navigator.pop(context, true);
      return;
    }

    // Save directly to ledger — lone owner is always authorised.
    await db.transaction(() async {
      for (final row in _rows) {
        final returned = int.tryParse(row.controller.text) ?? row.expectedQty;

        // 1. Update physical crate stock on the Manufacturers table
        if (returned > 0 && row.manufacturerId.isNotEmpty) {
          await db.inventoryDao.addEmptyCrates(row.manufacturerId, returned);
        }

        // 2. Record in ledger and update customer cache
        if (returned > 0 && row.crateSizeGroupId.isNotEmpty) {
          await db.crateLedgerDao.recordCrateReturnByCustomer(
            customerId: customer.id,
            crateSizeGroupId: row.crateSizeGroupId,
            quantity: returned,
            performedBy: auth.currentUser?.id ?? '',
            orderId: order.id,
          );
        }
      }
    });

    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    // amber unused after AppButton migration

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      builder: (_, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: _bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Title row
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
                child: Row(
                  children: [
                    Icon(
                      FontAwesomeIcons.boxOpen,
                      color: Colors.orange,
                      size: context.getRSize(18),
                    ),
                    SizedBox(width: context.getRSize(10)),
                    Text(
                      'Record Crate Returns',
                      style: TextStyle(
                        color: _text,
                        fontWeight: FontWeight.bold,
                        fontSize: context.getRFontSize(17),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.getRSize(4)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: context.getRSize(20)),
                child: Text(
                  'Enter returned crates per manufacturer.',
                  style: TextStyle(
                    color: _subtext,
                    fontSize: context.getRFontSize(13),
                  ),
                ),
              ),
              SizedBox(height: context.getRSize(14)),
              Divider(height: 1, color: _border),

              // Manufacturer rows
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        controller: scrollController,
                        padding: EdgeInsets.all(context.getRSize(20)),
                        children: [
                          for (final row in _rows)
                            _ManufacturerReturnTile(
                              row: row,
                              card: _card,
                              border: _border,
                              text: _text,
                              subtext: _subtext,
                              primary: primary,
                            ),
                        ],
                      ),
              ),

              // Action buttons
              Padding(
                padding: EdgeInsets.fromLTRB(
                  context.getRSize(20),
                  context.getRSize(12),
                  context.getRSize(20),
                  context.getRSize(20) + context.bottomInset,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        text: 'Skip',
                        variant: AppButtonVariant.ghost,
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context, false),
                      ),
                    ),
                    SizedBox(width: context.getRSize(12)),
                    Expanded(
                      flex: 2,
                      child: AppButton(
                        text: _saving ? 'Saving...' : 'Confirm',
                        icon: FontAwesomeIcons.check,
                        variant: AppButtonVariant.primary,
                        isLoading: _saving,
                        onPressed: _saving ? null : _confirm,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Tile widget ────────────────────────────────────────────────────────────

class _ManufacturerReturnTile extends StatelessWidget {
  final _ManufacturerRow row;
  final Color card, border, text, subtext, primary;

  const _ManufacturerReturnTile({
    required this.row,
    required this.card,
    required this.border,
    required this.text,
    required this.subtext,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          // Manufacturer icon badge
          Container(
            width: context.getRSize(40),
            height: context.getRSize(40),
            decoration: BoxDecoration(
              color: const Color(0xFFF5A623).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              FontAwesomeIcons.industry,
              size: context.getRSize(16),
              color: const Color(0xFFF5A623),
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  style: TextStyle(
                    color: text,
                    fontWeight: FontWeight.bold,
                    fontSize: context.getRFontSize(14),
                  ),
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  'Expected: ${row.expectedQty} crate${row.expectedQty == 1 ? '' : 's'}',
                  style: TextStyle(
                    color: subtext,
                    fontSize: context.getRFontSize(12),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: context.getRSize(80),
            child: AppInput(
              controller: row.controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              contentPadding: EdgeInsets.symmetric(
                vertical: context.getRSize(10),
                horizontal: context.getRSize(8),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: border),
              ),
              fillColor: Colors.transparent,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Data classes ───────────────────────────────────────────────────────────

class _ManufacturerRow {
  final String manufacturerId;
  final String crateSizeGroupId;
  final String name;
  final int expectedQty;
  final TextEditingController controller;

  _ManufacturerRow({
    required this.manufacturerId,
    required this.crateSizeGroupId,
    required this.name,
    required this.expectedQty,
    required this.controller,
  });
}

class _ManufacturerAccum {
  final String id;
  final String name;
  final String crateSizeGroupId;
  int totalQty = 0;

  _ManufacturerAccum({
    required this.id,
    required this.name,
    required this.crateSizeGroupId,
  });
}
