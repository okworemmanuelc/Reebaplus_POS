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
/// 3. For each bottle line that tracks empties, any empty crates handed back to
///    the supplier on this receipt post BOTH crate legs through the Crate Pool
///    seam, in this transaction (#160 / B3): the physical-pool movement (our
///    yard count drops) AND the supplier crate movement (what we owe THIS
///    supplier drops). One physical event → one operation; the stock keeper no
///    longer opens the supplier screen to enter the return a second time.
/// 4. A single summary "stock received" Activity Log row is written.
///
/// Every write above goes through a DAO/service that enqueues to the sync outbox,
/// so the whole receipt queues locally when offline and converges on reconnect.
///
/// Crate movements are tracked per-manufacturer on this build (the canonical
/// crate-debt owner is the manufacturer; the deposit rate is
/// `Manufacturers.depositAmountKobo`). The supplier on the receipt owns the
/// invoice; empties returned are attributed to each line's manufacturer AND to
/// the supplier's `supplier_crate_ledger` (§3.13), whose balance is DERIVED from
/// the ledger (ADR 0020). A supplier-side "full crates received increases what
/// we owe" entry is still made separately on the supplier screen (not captured
/// on the receive cart).
class ReceiveStockService {
  final AppDatabase _db;
  final SupplierAccountService _supplierAccounts;

  ReceiveStockService(this._db, this._supplierAccounts);

  /// Commit a receipt. [lines] are the cart lines; [emptiesReturnedByManufacturer]
  /// maps a manufacturerId → empty crates handed back on this receipt. Empties
  /// are a per-manufacturer quantity (the canonical crate-debt owner is the
  /// manufacturer, not the product), so a manufacturer that ships several SKUs
  /// on one receipt has a single empties figure — not one per SKU. Only
  /// manufacturers represented by a bottle + trackEmpties line are consulted.
  Future<void> confirmReceipt({
    required String supplierId,
    required String supplierName,
    required String storeId,
    required DateTime dateReceived,
    required String staffId,
    required List<ReceiveCartLine> lines,
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
        await _db.inventoryDao.adjustStock(
          line.productId,
          storeId,
          line.qty,
          'Stock received',
          staffId,
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

      // 3. Empty crates handed back to the supplier on this receipt, recorded
      //    once per manufacturer (not per product). Only manufacturers carried
      //    by a bottle + trackEmpties line on this receipt are consulted.
      //    #160 (B3): one physical event → BOTH legs, in this transaction,
      //    through the Crate Pool seam — the physical-pool movement (yard count
      //    drops) AND the supplier crate movement (what we owe the supplier
      //    drops). The stock keeper no longer opens the supplier screen to enter
      //    the return a second time; the supplier balance is then DERIVED from
      //    `supplier_crate_ledger` like every other crate balance.
      final eligibleManufacturerIds = <String>{
        for (final line in lines)
          if (line.trackEmpties && line.manufacturerId != null)
            line.manufacturerId!,
      };
      for (final entry in emptiesReturnedByManufacturer.entries) {
        if (entry.value > 0 && eligibleManufacturerIds.contains(entry.key)) {
          // Leg 1 — physical empties pool (manufacturer-owned, store-stamped).
          await _db.cratePoolDao.recordCrateReturnByManufacturer(
            manufacturerId: entry.key,
            quantity: entry.value,
            performedBy: staffId,
            storeId: storeId,
          );
          // Leg 2 — supplier crate debt (what we owe THIS supplier drops).
          await _db.cratePoolDao.recordReturnToSupplier(
            supplierId: supplierId,
            manufacturerId: entry.key,
            quantity: entry.value,
            performedBy: staffId,
            storeId: storeId,
          );
        }
      }

      // 4. Summary activity log for the whole receipt.
      await _db.activityLogDao.logActivity(
        action: 'stock.received',
        description:
            'Received ${lines.length} product(s), $totalUnits unit(s) from '
            '$supplierName — invoice ${formatCurrency(invoiceTotalKobo / 100)}'
            '${amountPaidKobo != null && amountPaidKobo > 0 ? ' (Paid: ${formatCurrency(amountPaidKobo / 100)})' : ''}',
        staffId: staffId,
        storeId: storeId,
        entityType: 'supplier',
        entityId: supplierId,
      );
    });
  }
}
