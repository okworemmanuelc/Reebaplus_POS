import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/services/supplier_account_service.dart';

/// Atomic "Receive Stock" commit (Receive Stock spec, Section 9). One run =
/// one supplier. On confirm, ALL of the following happen inside a single Drift
/// transaction so the receipt is all-or-nothing (a mid-write failure rolls the
/// whole thing back — no orphaned invoice without a stock increase):
///
/// 1. One Invoice Total is posted to the supplier ledger (a debit — we now owe
///    the supplier). This is cost of goods, NOT an expense (it lives only on the
///    supplier ledger).
/// 2. Each line increments on-hand stock for the active store (which also appends
///    the `stock_transactions` row that IS the Inventory → History entry).
/// 3. For each bottle line that tracks empties, BOTH directions of the crate
///    movement on this receipt post through the Crate Pool seam, in this
///    transaction: the full crates that arrived (#210 — what we owe THIS
///    supplier RISES) and the empty crates handed back (#160 / B3 — the
///    physical-pool movement, our yard count drops, AND the supplier crate
///    movement, what we owe THIS supplier drops). One physical event → one
///    operation; the stock keeper no longer opens the supplier screen to enter
///    either side a second time.
/// 4. A single summary "stock received" Activity Log row is written, naming the
///    crate movement alongside the goods.
///
/// Every write above goes through a DAO/service that enqueues to the sync outbox,
/// so the whole receipt queues locally when offline and converges on reconnect.
///
/// Crate movements are tracked per-manufacturer on this build (the canonical
/// crate-debt owner is the manufacturer; the deposit rate is
/// `Manufacturers.depositAmountKobo`). The supplier on the receipt owns the
/// invoice; crates moved are attributed to each line's manufacturer AND to the
/// supplier's `supplier_crate_ledger` (§3.13), whose balance is DERIVED from the
/// ledger (ADR 0020).
///
/// #210 / ADR 0023: before this slice only the RETURN leg was automated, so
/// `SUM(quantity_delta)` over `supplier_crate_ledger` could only fall — normal
/// operation drove supplier crate debt negative, and because
/// `businessNetPositionKobo` SUBTRACTS that debt, a negative debt inflated
/// business worth. Recording both legs in the one action is what stops the
/// drift: neither leg can be forgotten without the other.
///
/// This slice is **counting only** — no deposit money moves here (#212 owns the
/// money leg), so both crate calls are made at the seam's default 0 kobo.
class ReceiveStockService {
  final AppDatabase _db;
  final SupplierAccountService _supplierAccounts;

  ReceiveStockService(this._db, this._supplierAccounts);

  /// Commit a receipt. [lines] are the cart lines;
  /// [fullCratesReceivedByManufacturer] maps a manufacturerId → full crates that
  /// arrived on this receipt, and [emptiesReturnedByManufacturer] maps a
  /// manufacturerId → empty crates handed back. Both are per-manufacturer
  /// quantities (the canonical crate-debt owner is the manufacturer, not the
  /// product), so a manufacturer that ships several SKUs on one receipt has a
  /// single figure per direction — not one per SKU. Only manufacturers
  /// represented by a bottle + trackEmpties line are consulted.
  ///
  /// Both maps are **required** rather than defaulted: the defect #210 fixes was
  /// a leg nobody remembered to post, so omitting one is a compile error, not a
  /// silent zero. Pass `const {}` for a receipt that moves no crates — that
  /// receipt then behaves exactly as it always has.
  ///
  /// Crate size is a CATEGORY in this app (Big/Medium/Small), never a bottle
  /// count, so a crate figure can never be derived from `line.qty` — it is
  /// always typed by whoever took the delivery (ADR 0023).
  Future<void> confirmReceipt({
    required String supplierId,
    required String supplierName,
    required String storeId,
    required DateTime dateReceived,
    required String staffId,
    required List<ReceiveCartLine> lines,
    required Map<String, int> fullCratesReceivedByManufacturer,
    required Map<String, int> emptiesReturnedByManufacturer,
    String? note,
    int? amountPaidKobo,
    String? paymentMethod,
  }) async {
    if (lines.isEmpty) {
      throw ArgumentError('Cannot receive stock with an empty cart');
    }

    final invoiceTotalKobo = lines.fold<int>(
      0,
      (sum, l) => sum + l.buyingPriceKobo * l.qty,
    );
    final totalUnits = lines.fold<int>(0, (sum, l) => sum + l.qty);

    await _db.transaction(() async {
      // 1. Supplier invoice (skip a zero-value invoice — stock/crates still post).
      if (invoiceTotalKobo > 0) {
        await _supplierAccounts.recordInvoice(
          supplierId: supplierId,
          amountKobo: invoiceTotalKobo,
          dateReceived: dateReceived,
          staffId: staffId,
          storeId: storeId,
          note: note,
        );
      }

      if (amountPaidKobo != null && amountPaidKobo > 0) {
        await _supplierAccounts.recordPayment(
          supplierId: supplierId,
          amountKobo: amountPaidKobo,
          method: paymentMethod ?? 'cash',
          paidOn: dateReceived,
          staffId: staffId,
          storeId: storeId,
          referenceNote: note ?? 'Payment for received stock',
        );
      }

      // 2. Per-line stock increment and price persistence.
      for (final line in lines) {
        // trackCost:false — Receive Stock owns its own receipt-dated Cost Batch
        // below (recordInflowBatch with the precise `receivedAt`). Letting
        // adjustStock ALSO create an inflow batch (#170 #7a) would double the
        // FIFO layer and drift the queue from on-hand.
        await _db.inventoryDao.adjustStock(
          line.productId,
          storeId,
          line.qty,
          'Stock received',
          staffId,
          trackCost: false,
        );

        // Update product prices in the database to persist edited prices
        await _db.catalogDao.updateProductPrices(
          line.productId,
          buyingPriceKobo: line.buyingPriceKobo,
          retailerPriceKobo: line.retailKobo,
          wholesalerPriceKobo: line.wholesaleKobo,
        );

        // Epic 2 / #42: each receipt is its own FIFO Cost Batch, at this
        // line's buying price (0 → an uncosted batch), stamped with the receipt
        // date so it sorts by when the stock actually arrived. Same transaction
        // as the stock increment above → the queue can't drift from on-hand.
        await _db.costBatchesDao.recordInflowBatch(
          productId: line.productId,
          storeId: storeId,
          quantity: line.qty,
          costKobo: line.buyingPriceKobo,
          receivedAt: dateReceived,
        );
      }

      // 3. Crates moved on this receipt, recorded once per manufacturer (not per
      //    product), through the Crate Pool seam in THIS transaction so the
      //    crate record is as all-or-nothing as the stock and the invoice.
      //
      //    The eligibility gate is the existing one and is deliberately shared
      //    by both directions: only a manufacturer carried by a bottle +
      //    trackEmpties line on this receipt is consulted, so PET / Can / any
      //    non-crate packaging can never reach a crate table.
      final eligibleManufacturerIds = <String>{
        for (final line in lines)
          if (line.trackEmpties && line.manufacturerId != null)
            line.manufacturerId!,
      };
      var totalCratesReceived = 0;
      var totalEmptiesReturned = 0;
      for (final manufacturerId in eligibleManufacturerIds) {
        // Leg 1 — #210: the full crates that ARRIVED. What we owe this supplier
        // RISES. Without this leg `SUM(quantity_delta)` could only ever fall,
        // which drove supplier crate debt negative and inflated business worth.
        // No physical-pool counterpart: a full crate is not an empty, and it
        // only joins the empties pool once the drink leaves it.
        final cratesReceived = fullCratesReceivedByManufacturer[manufacturerId] ?? 0;
        if (cratesReceived > 0) {
          await _db.cratePoolDao.recordReceiveFromSupplier(
            supplierId: supplierId,
            manufacturerId: manufacturerId,
            quantity: cratesReceived,
            performedBy: staffId,
            storeId: storeId,
            // #212, ADR 0023 rule 6 — the MONEY half of the same event. The
            // seam raises a pending deposit for a money-permitted role when
            // (and only when) this brand's Crate Money Arrangement is
            // `per_delivery`; a `none` brand raises nothing and this receipt
            // behaves exactly as it did before PRD #203. The count above is
            // already committed either way: whoever is standing at the
            // delivery may record crates, and may never move cash.
            raiseDepositRequest: true,
          );
          totalCratesReceived += cratesReceived;
        }

        // Legs 2 & 3 — #160 (B3): the empties handed back. One physical event →
        // BOTH legs — the physical-pool movement (yard count drops) AND the
        // supplier crate movement (what we owe the supplier drops). The stock
        // keeper no longer opens the supplier screen to enter the return a
        // second time; the supplier balance is then DERIVED from
        // `supplier_crate_ledger` like every other crate balance.
        final emptiesReturned = emptiesReturnedByManufacturer[manufacturerId] ?? 0;
        if (emptiesReturned > 0) {
          await _db.cratePoolDao.recordCrateReturnByManufacturer(
            manufacturerId: manufacturerId,
            quantity: emptiesReturned,
            performedBy: staffId,
            storeId: storeId,
          );
          await _db.cratePoolDao.recordReturnToSupplier(
            supplierId: supplierId,
            manufacturerId: manufacturerId,
            quantity: emptiesReturned,
            performedBy: staffId,
            storeId: storeId,
          );
          totalEmptiesReturned += emptiesReturned;
        }
      }

      // 4. Summary activity log for the whole receipt, naming the crate movement
      //    beside the goods so the audit trail shows both halves of one event.
      final crateSummary = _crateSummary(
        cratesReceived: totalCratesReceived,
        emptiesReturned: totalEmptiesReturned,
      );
      await _db.activityLogDao.logActivity(
        action: 'stock.received',
        description:
            'Received ${lines.length} product(s), $totalUnits unit(s) from '
            '$supplierName — invoice ${formatCurrency(invoiceTotalKobo / 100)}'
            '${amountPaidKobo != null && amountPaidKobo > 0 ? ' (Paid: ${formatCurrency(amountPaidKobo / 100)})' : ''}'
            '$crateSummary',
        staffId: staffId,
        storeId: storeId,
        entityType: 'supplier',
        entityId: supplierId,
      );
    });
  }

  /// The crate clause appended to the receipt's Activity Log line. Empty when
  /// the receipt moved no crates, so a receipt without crate activity reads
  /// exactly as it always did.
  String _crateSummary({
    required int cratesReceived,
    required int emptiesReturned,
  }) {
    final parts = <String>[
      if (cratesReceived > 0)
        '$cratesReceived full crate${cratesReceived == 1 ? '' : 's'} in',
      if (emptiesReturned > 0)
        '$emptiesReturned empty crate${emptiesReturned == 1 ? '' : 's'} back',
    ];
    return parts.isEmpty ? '' : ' — crates: ${parts.join(', ')}';
  }
}
