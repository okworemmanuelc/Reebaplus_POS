import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/supplier_account_service.dart';

import '../helpers/dispatch_test_utils.dart';
import 'inventory_scenario.dart';

/// Batch-creation Golden Suite — the DART producer side (ADR 0009, issue #48).
///
/// Runs the shared inventory fixtures against the real mobile producers on an
/// in-memory Drift DB: Add Product's opening stock (inventory + CostBatchesDao.
/// recordInflowBatch) and Receive Stock (InventoryDao.adjustStock + recordInflow
/// Batch + SupplierAccountService). Its Tier-2 twin (web_inventory_golden_test)
/// runs the SAME fixtures against add_product / receive_stock (0140); any drift in
/// the Cost Batch producer rule between the two fails the build.
String _dateKey(DateTime d) {
  final u = d.toUtc();
  return '${u.year.toString().padLeft(4, '0')}-'
      '${u.month.toString().padLeft(2, '0')}-'
      '${u.day.toString().padLeft(2, '0')}';
}

void main() {
  final scenarios = loadInventoryScenarios();
  for (final s in scenarios) {
    test('golden (dart producers): ${s.name}', () async {
      final boot = await bootstrapTestDb();
      final db = boot.db;
      final businessId = boot.businessId;
      addTearDown(db.close);

      // v1 path so adjustStock writes stock_adjustments + stock_transactions
      // locally (the v2 path defers those to the cloud RPC response).
      await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);

      final storeId = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
                id: Value(storeId), businessId: businessId, name: 'Main'),
          );
      final staffId = UuidV7.generate();
      await db.into(db.users).insert(
            UsersCompanion.insert(
                id: Value(staffId),
                businessId: businessId,
                name: 'Manager',
                pin: '0000'),
          );

      final productId = UuidV7.generate();
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: Value(productId),
              businessId: businessId,
              name: s.productName,
              unit: Value(s.unit),
              retailerPriceKobo: Value(s.retailerPriceKobo),
              wholesalerPriceKobo: Value(s.wholesalerPriceKobo),
              buyingPriceKobo: Value(s.buyingPriceKobo),
            ),
          );

      String? supplierId;
      SupplierAccountService? accounts;

      if (s.operation == 'add_product') {
        // Add Product: opening stock straight to inventory + the opening batch.
        if (s.openingStock > 0) {
          await db.into(db.inventory).insert(
                InventoryCompanion.insert(
                  businessId: businessId,
                  productId: productId,
                  storeId: storeId,
                  quantity: Value(s.openingStock),
                ),
              );
          await db.costBatchesDao.recordInflowBatch(
            productId: productId,
            storeId: storeId,
            quantity: s.openingStock,
            costKobo: s.buyingPriceKobo,
          );
        }
      } else {
        // Receive Stock: seed the pre-existing state, then run the receipt.
        if (s.existingStock > 0) {
          await db.into(db.inventory).insert(
                InventoryCompanion.insert(
                  businessId: businessId,
                  productId: productId,
                  storeId: storeId,
                  quantity: Value(s.existingStock),
                ),
              );
        }
        for (final b in s.existingBatches) {
          await db.into(db.costBatches).insert(
                CostBatchesCompanion.insert(
                  id: Value(UuidV7.generate()),
                  businessId: businessId,
                  productId: productId,
                  storeId: storeId,
                  qtyRemaining: b.qty,
                  qtyOriginal: b.qty,
                  costKobo: Value(b.costKobo),
                  receivedAt: Value(b.receivedAtUtc),
                ),
              );
        }
        supplierId = UuidV7.generate();
        await db.into(db.suppliers).insert(
              SuppliersCompanion.insert(
                  id: Value(supplierId), businessId: businessId, name: 'Golden Supplier'),
            );

        final invoiceTotal = s.lines.fold<int>(
            0,
            (sum, l) =>
                sum + l.quantity * (l.buyingPriceKobo < 0 ? 0 : l.buyingPriceKobo));
        final receiptDate = s.lines.first.receivedAtUtc;
        accounts = SupplierAccountService(db);
        if (invoiceTotal > 0) {
          await accounts.recordInvoice(
            supplierId: supplierId,
            amountKobo: invoiceTotal,
            dateReceived: receiptDate,
            staffId: staffId,
            storeId: storeId,
          );
        }
        if (s.amountPaidKobo > 0) {
          await accounts.recordPayment(
            supplierId: supplierId,
            amountKobo: s.amountPaidKobo,
            method: s.paymentMethod,
            paidOn: receiptDate,
            staffId: staffId,
            storeId: storeId,
            referenceNote: 'golden receipt',
          );
        }
        for (final line in s.lines) {
          await db.inventoryDao
              .adjustStock(productId, storeId, line.quantity, 'Stock received', staffId);
          await db.costBatchesDao.recordInflowBatch(
            productId: productId,
            storeId: storeId,
            quantity: line.quantity,
            costKobo: line.buyingPriceKobo,
            receivedAt: line.receivedAtUtc,
          );
        }
      }

      // ── Collect the resulting rows in fixture terms ────────────────────────
      final batchRows = await (db.select(db.costBatches)
            ..where((b) => b.productId.equals(productId)))
          .get();
      final batches = <String, ExpectedInvBatch>{};
      for (final b in batchRows) {
        final key =
            s.operation == 'add_product' ? 'opening' : _dateKey(b.receivedAt);
        batches[key] = ExpectedInvBatch({
          'received_at': key,
          'qty_remaining': b.qtyRemaining,
          'qty_original': b.qtyOriginal,
          'cost_kobo': b.costKobo,
        });
      }

      final invRow = await (db.select(db.inventory)
            ..where((i) => i.productId.equals(productId) & i.storeId.equals(storeId)))
          .getSingleOrNull();

      final supplierBalance = (s.operation == 'receive' && accounts != null)
          ? await accounts.getBalanceKobo(supplierId!)
          : null;

      expectInventoryGolden(
        s,
        InventoryOutcome(
          batches: batches,
          inventoryAfter: invRow?.quantity ?? 0,
          supplierBalanceAfterKobo: supplierBalance,
        ),
      );
    });
  }
}
