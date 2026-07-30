import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';
import 'stock_adjustment_scenario.dart';

/// Stock-adjustment approval-gate Golden Suite — the DART side (ADR 0009, #50).
///
/// Runs the shared fixtures against the real mobile approval path
/// (StockAdjustmentRequestsDao.requestStockAdjustment / approveRequest /
/// rejectRequest + InventoryDao.adjustStock) on an in-memory Drift DB. Its Tier-2
/// twin (web_stock_adjustment_golden_test) runs the SAME fixtures against the
/// request_stock_adjustment / approve_stock_adjustment RPCs (0141); drift fails
/// the build. This arm also pins the stock-keeper → pending path ('request'),
/// which the CEO-identity RPC arm skips.
void main() {
  final scenarios = loadStockAdjScenarios();
  for (final s in scenarios) {
    test('golden (dart dao): ${s.name}', () async {
      final boot = await bootstrapTestDb();
      final db = boot.db;
      final businessId = boot.businessId;
      addTearDown(db.close);

      // v1 path so approveRequest's adjustStock writes inventory + the movement
      // rows locally (v2 defers those to the cloud RPC response).
      await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);

      final storeId = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
                id: Value(storeId), businessId: businessId, name: 'Main'),
          );
      final requesterId = UuidV7.generate();
      await db.into(db.users).insert(
            UsersCompanion.insert(
                id: Value(requesterId),
                businessId: businessId,
                name: 'Stock Keeper',
                pin: '0000'),
          );
      final approverId = UuidV7.generate();
      await db.into(db.users).insert(
            UsersCompanion.insert(
                id: Value(approverId),
                businessId: businessId,
                name: 'Manager',
                pin: '0001'),
          );

      final productId = UuidV7.generate();
      await db.into(db.products).insert(
            ProductsCompanion.insert(
                id: Value(productId),
                businessId: businessId,
                name: 'Widget',
                // #189: the cost basis an approved increase falls back to when
                // the request captured none. Absent → no cost on file either, so
                // the increase's batch is genuinely Uncosted.
                buyingPriceKobo: Value(s.productBuyingPriceKobo ?? 0)),
          );
      await db.into(db.inventory).insert(
            InventoryCompanion.insert(
              businessId: businessId,
              productId: productId,
              storeId: storeId,
              quantity: Value(s.startQty),
            ),
          );

      // #7a: seed a costed batch so an approved decrease has real cost to draw.
      if (s.inflowCostKobo != null && s.startQty > 0) {
        await db.costBatchesDao.recordInflowBatch(
          productId: productId,
          storeId: storeId,
          quantity: s.startQty,
          costKobo: s.inflowCostKobo!,
        );
      }

      // A stock keeper files the request — a pending row, no inventory change.
      final reqDao = db.stockAdjustmentRequestsDao;
      await reqDao.requestStockAdjustment(
        productId: productId,
        storeId: storeId,
        quantityDiff: s.quantityDiff,
        reason: s.reason,
        summary: s.reason,
        requestedBy: requesterId,
        // #197 (US 22): what the goods cost, captured ON the request. Null → the
        // request states nothing and the approval falls back to #189.
        unitCostKobo: s.requestUnitCostKobo,
      );

      final pending = await (db.select(db.stockAdjustmentRequests)
            ..where((r) => r.productId.equals(productId)))
          .getSingle();
      // #197: the cost survives the pending round-trip — an approval days later
      // (on another device, off another pull) still knows what was paid.
      if (s.requestUnitCostKobo != null && s.quantityDiff > 0) {
        expect(pending.unitCostKobo, s.requestUnitCostKobo,
            reason: '${s.name}: cost captured on the pending request');
      }

      if (s.operation == 'approve') {
        await reqDao.approveRequest(
            requestId: pending.id, approverId: approverId);
      } else if (s.operation == 'reject') {
        await reqDao.rejectRequest(
            requestId: pending.id, approverId: approverId);
      }

      final finalReq = await (db.select(db.stockAdjustmentRequests)
            ..where((r) => r.id.equals(pending.id)))
          .getSingle();
      final inv = await (db.select(db.inventory)
            ..where(
                (i) => i.productId.equals(productId) & i.storeId.equals(storeId)))
          .getSingleOrNull();

      // #7a cost outcomes: the value snapshotted onto an applied decrease, and
      // the cost of the batch an applied increase created (the newest batch) —
      // the cost the request captured (#197), else the product's recorded cost
      // (#189), else 0.
      int? snapshotValueKobo;
      if (finalReq.status == 'approved' && s.quantityDiff < 0) {
        final adj = await (db.select(db.stockAdjustments)
              ..where((a) =>
                  a.productId.equals(productId) &
                  a.quantityDiff.equals(s.quantityDiff)))
            .getSingleOrNull();
        snapshotValueKobo = adj?.valueKobo;
      }
      int? newBatchCostKobo;
      if (finalReq.status == 'approved' && s.quantityDiff > 0) {
        final batch = await (db.select(db.costBatches)
              ..where((b) => b.productId.equals(productId))
              ..orderBy([(b) => OrderingTerm.desc(b.receivedAt)])
              ..limit(1))
            .getSingleOrNull();
        newBatchCostKobo = batch?.costKobo;
      }

      expectStockAdjGolden(
        s,
        StockAdjOutcome(
          status: finalReq.status,
          inventoryAfter: inv?.quantity ?? 0,
          snapshotValueKobo: snapshotValueKobo,
          newBatchCostKobo: newBatchCostKobo,
        ),
      );
    });
  }
}
