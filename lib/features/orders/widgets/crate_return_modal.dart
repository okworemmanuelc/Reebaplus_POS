import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/app_input.dart';

/// §13.4 reconciliation — split a legacy order's recorded crate deposit
/// ([totalDeposit] kobo) across its brands by [weights] (full value or crate
/// count, one per brand, in brand order). The returned shares sum EXACTLY to
/// [totalDeposit] — the last brand absorbs any rounding remainder — so a held
/// deposit reconstructed from this always resolves to 0 with nothing left over.
/// When all weights are 0 the deposit is split evenly. Visible for testing.
List<int> allocateLegacyDeposit(int totalDeposit, List<int> weights) {
  final n = weights.length;
  if (n == 0 || totalDeposit <= 0) return List<int>.filled(n, 0);
  var w = weights;
  if (w.every((x) => x == 0)) w = List<int>.filled(n, 1); // even split
  final totalWeight = w.fold<int>(0, (s, x) => s + x);
  final out = List<int>.filled(n, 0);
  var allocated = 0;
  for (var i = 0; i < n; i++) {
    out[i] = i == n - 1
        ? totalDeposit -
              allocated // remainder → last brand, exact sum
        : (totalDeposit * w[i]) ~/ totalWeight;
    allocated += out[i];
  }
  return out;
}

class CrateReturnModal extends ConsumerStatefulWidget {
  final OrderWithItems orderWithItems;

  const CrateReturnModal({super.key, required this.orderWithItems});

  /// §13.4 Ring 5 — the modal now ALWAYS opens when the order has crate-tracked
  /// bottles (Guard 2, which skipped when the deposit was "covered", is gone:
  /// crates must be counted back regardless of how the deposit was paid). The
  /// only skip is Guard 1 — nothing crate-tracked in the order.
  /// Returns `true` if the user confirmed crate returns, `false` if skipped.
  static Future<bool> show(
    BuildContext context,
    OrderWithItems orderWithItems, {
    required WidgetRef ref,
  }) async {
    // Guard 1: skip if no bottle items with trackEmpties enabled
    final hasBottles = orderWithItems.items.any((i) {
      final p = i.product; // null for a Quick Sale line — never a crate product
      return p != null && p.unit.toLowerCase() == 'bottle' && p.trackEmpties;
    });
    if (!hasBottles) return true; // no crates to track — proceed

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
  // §13.4 Ring 5 — how to give back a money-track deposit refund. Default to a
  // wallet credit (spendable); the cashier can switch to cash (paid out of the
  // till). Only shown/used when the order has a money-track (deposit-paid) brand.
  bool _refundAsCash = false;

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
    final db = ref.read(databaseProvider);
    final mfrs = await db.inventoryDao.getAllManufacturers();
    final mfrNames = {for (final m in mfrs) m.id: m.name};

    // §13.4 Ring 5 — prefer the authoritative per-brand record written at sale
    // (order_crate_lines): crates taken + deposit rate snapshot + deposit paid.
    // It tells us each brand's track (no-deposit / part / full). Walk-ins and
    // pre-v37 orders have no lines → fall back to grouping the order's bottle
    // items by manufacturer (stock-only return, treated as no-deposit).
    final lines = await db.orderCrateLinesDao.getForOrder(
      widget.orderWithItems.order.id,
    );

    final List<_ManufacturerRow> rows;
    if (lines.isNotEmpty) {
      rows = lines.map((l) {
        final fullKobo = l.depositRateKobo * l.cratesTaken;
        // Pre-fill: full or no deposit → the expected count (we expect them all
        // back); part deposit → blank (the cashier counts what actually came in).
        final isPart = l.depositPaidKobo > 0 && l.depositPaidKobo < fullKobo;
        return _ManufacturerRow(
          manufacturerId: l.manufacturerId,
          name:
              mfrNames[l.manufacturerId] ?? 'Manufacturer ${l.manufacturerId}',
          expectedQty: l.cratesTaken,
          rateKobo: l.depositRateKobo,
          paidKobo: l.depositPaidKobo,
          controller: TextEditingController(
            text: isPart ? '' : l.cratesTaken.toString(),
          ),
        );
      }).toList();
    } else {
      // Fallback for legacy / pre-v37 sales with no order_crate_lines: group the
      // order's bottle items by manufacturer, then RECONCILE the deposit. If the
      // order recorded a crate deposit (`crateDepositPaidKobo`) but the per-brand
      // lines were never written (created on an older build), the held
      // `crate_deposit` wallet credit would otherwise have NO settlement path —
      // the deposit would stay "held" forever and never refund/forfeit. We
      // rebuild per-brand deposit info from the order total + current
      // manufacturer rates so Confirm can settle it and the held nets to 0. With
      // no recorded deposit this stays a stock-only crate-track return as before.
      final mfrRates = {for (final m in mfrs) m.id: m.depositAmountKobo};
      final Map<String, _ManufacturerAccum> accum = {};
      for (final ri in widget.orderWithItems.items) {
        final product = ri.product;
        if (product == null) {
          continue; // Quick Sale line — never a crate product
        }
        if (product.unit.toLowerCase() != 'bottle') continue;
        if (!product.trackEmpties) continue;
        final mfId = product.manufacturerId ?? '';
        if (mfId.isEmpty) continue; // can't track crates without a manufacturer
        accum.putIfAbsent(
          mfId,
          () => _ManufacturerAccum(
            id: mfId,
            name: mfrNames[mfId] ?? 'Manufacturer $mfId',
          ),
        );
        accum[mfId]!.totalQty += ri.item.quantity;
      }

      final brands = accum.values.toList();
      // Allocate the order's recorded deposit across brands. Weight by full
      // value (rate × crates) so a single full-deposit brand gets it all; fall
      // back to crate count when rates are unset. allocateLegacyDeposit sums the
      // shares EXACTLY to the recorded total — the held deposit then resolves to
      // 0 with nothing left over.
      final totalDeposit = widget.orderWithItems.order.crateDepositPaidKobo;
      var weights = brands
          .map((b) => (mfrRates[b.id] ?? 0) * b.totalQty)
          .toList();
      if (weights.every((w) => w == 0)) {
        weights = brands.map((b) => b.totalQty).toList();
      }
      final shares = allocateLegacyDeposit(totalDeposit, weights);
      final paidByBrand = <String, int>{
        for (var i = 0; i < brands.length; i++) brands[i].id: shares[i],
      };

      rows = brands.map((a) {
        final rate = mfrRates[a.id] ?? 0;
        final paid = paidByBrand[a.id] ?? 0;
        final fullKobo = rate * a.totalQty;
        // Same pre-fill rule as the lines path: full/none → expected count,
        // part deposit → blank (cashier counts what actually came back).
        final isPart = paid > 0 && paid < fullKobo;
        return _ManufacturerRow(
          manufacturerId: a.id,
          name: a.name,
          expectedQty: a.totalQty,
          rateKobo: rate,
          paidKobo: paid,
          controller: TextEditingController(
            text: isPart ? '' : a.totalQty.toString(),
          ),
        );
      }).toList();
    }

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

    try {
      // Walk-in customer: just record physical stock returns; lone owner has full
      // authority so no PIN override is needed.
      if (customer == null) {
        for (final row in _rows) {
          final returned = int.tryParse(row.controller.text) ?? row.expectedQty;
          if (row.manufacturerId.isNotEmpty) {
            await db.inventoryDao.addEmptyCrates(
              row.manufacturerId,
              returned,
              storeId: order.storeId,
            );
          }
        }
        if (mounted) Navigator.pop(context, true);
        return;
      }

      // Save directly to ledger — lone owner is always authorised.
      final performedBy = auth.currentUser?.id ?? '';
      await db.transaction(() async {
        for (final row in _rows) {
          final returned = int.tryParse(row.controller.text) ?? row.expectedQty;
          if (row.manufacturerId.isEmpty) continue;

          // 1. Physical crate stock comes back regardless of how it's settled.
          if (returned > 0) {
            await db.inventoryDao.addEmptyCrates(
              row.manufacturerId,
              returned,
              storeId: order.storeId,
            );
          }

          if (row.isMoneyTrack) {
            // §13.4 Ring 5 money-track: the obligation lived in the wallet as a
            // held deposit — settle it in money (refund / forfeit / shortfall).
            // No crate balance was issued for this brand, so DON'T touch the
            // crate ledger (that would create a phantom credit).
            await db.ordersDao.settleCrateDepositReturn(
              customerId: customer.id,
              manufacturerId: row.manufacturerId,
              orderId: order.id,
              takenCrates: row.expectedQty,
              returnedCrates: returned,
              rateKobo: row.rateKobo,
              paidKobo: row.paidKobo,
              refundAsCash: _refundAsCash,
              performedBy: performedBy,
            );
          } else if (returned > 0) {
            // crate-track (no deposit): net the issued balance. Leftover (taken −
            // returned) stays as crate debt on the crates tab. This is the bug-fix
            // path (an 'issued' row was written at the sale).
            await db.crateLedgerDao.recordCrateReturnByCustomer(
              customerId: customer.id,
              manufacturerId: row.manufacturerId,
              quantity: returned,
              performedBy: performedBy,
              orderId: order.id,
            );
          }
        }
      });

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        AppNotification.showError(
          context,
          'Could not record crate returns: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// §13.4 Ring 5 — choose where a money-track deposit refund goes: back to the
  /// customer's wallet (spendable credit) or out of the till as cash.
  Widget _buildRefundModeToggle() {
    Widget chip(
      String label,
      IconData icon,
      bool selected,
      VoidCallback onTap,
    ) {
      final primary = Theme.of(context).colorScheme.primary;
      return Expanded(
        child: GestureDetector(
          onTap: _saving ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: EdgeInsets.symmetric(vertical: context.getRSize(10)),
            decoration: BoxDecoration(
              color: selected ? primary.withValues(alpha: 0.10) : _card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? primary : _border,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: context.getRSize(14),
                  color: selected ? primary : _subtext,
                ),
                SizedBox(width: context.getRSize(8)),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? primary : _subtext,
                    fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                    fontSize: context.getRFontSize(13),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(20),
        context.getRSize(4),
        context.getRSize(20),
        context.getRSize(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Refund deposit to',
            style: TextStyle(
              color: _subtext,
              fontSize: context.getRFontSize(12),
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          Row(
            children: [
              chip(
                'Wallet',
                FontAwesomeIcons.wallet.data,
                !_refundAsCash,
                () => setState(() => _refundAsCash = false),
              ),
              SizedBox(width: context.getRSize(10)),
              chip(
                'Cash',
                FontAwesomeIcons.moneyBill.data,
                _refundAsCash,
                () => setState(() => _refundAsCash = true),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    // amber unused after AppButton migration

    // Height-capped, content-sized sheet (NOT DraggableScrollableSheet): a
    // draggable sheet auto-EXPANDS from initialChildSize toward maxChildSize
    // whenever a descendant is scrolled into view — exactly what the framework
    // does when the keyboard opens to lift a focused crate-count field above it.
    // That expand made the whole form lurch upward "like a second keyboard
    // opened" (only on a physical device, where the soft keyboard actually
    // shows; the emulator's hardware keyboard never triggers it). A min-size
    // Column capped at the old 0.9 max removes the expand entirely — and the
    // footer's nav-only deviceBottomPadding clears the system nav (MainLayout's
    // resize lifts the sheet above the keyboard). Same fix the cart's
    // change-customer sheet uses.
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
                  FontAwesomeIcons.boxOpen.data,
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
          Flexible(
            child: _loading
                ? SizedBox(
                    height: MediaQuery.of(context).size.height * 0.25,
                    child: const Center(child: CircularProgressIndicator()),
                  )
                : ListView(
                    shrinkWrap: true,
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

          // §13.4 Ring 5 — refund destination for money-track deposits.
          if (!_loading && _rows.any((r) => r.isMoneyTrack))
            _buildRefundModeToggle(),

          // Action buttons
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.getRSize(20),
              context.getRSize(12),
              context.getRSize(20),
              context.getRSize(20) + context.deviceBottomPadding,
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
                    icon: FontAwesomeIcons.check.data,
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
              FontAwesomeIcons.industry.data,
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
                  'Took ${row.expectedQty} crate${row.expectedQty == 1 ? '' : 's'} · ${row.trackTag}'
                  '${row.isMoneyTrack ? ' ${formatCurrency(row.paidKobo / 100.0)}' : ''}',
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
  final String name;
  final int expectedQty; // crates taken at the sale
  final int rateKobo; // deposit per crate (snapshot)
  final int paidKobo; // deposit actually paid for this brand
  final TextEditingController controller;

  _ManufacturerRow({
    required this.manufacturerId,
    required this.name,
    required this.expectedQty,
    required this.rateKobo,
    required this.paidKobo,
    required this.controller,
  });

  /// Full deposit value of all crates taken.
  int get fullKobo => rateKobo * expectedQty;

  /// money-track = a deposit was paid (full or part); else crate-track.
  bool get isMoneyTrack => paidKobo > 0;
  bool get isPart => paidKobo > 0 && paidKobo < fullKobo;

  /// Short tag for the tile.
  String get trackTag => paidKobo == 0
      ? 'No deposit'
      : (paidKobo >= fullKobo ? 'Deposit paid' : 'Part deposit');
}

class _ManufacturerAccum {
  final String id;
  final String name;
  int totalQty = 0;

  _ManufacturerAccum({required this.id, required this.name});
}
