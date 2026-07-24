import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// Money-integrity #7b (#170, PRD #155): a store transfer moves COST with
/// quantity. Dispatch draws the source's FIFO batches down and the drawn cost
/// RIDES the transfer (`stock_transfers.cost_kobo`); receipt creates the
/// destination's Cost Batch at that cost, so the receiving store sells at real
/// COGS and the source keeps no phantom coverage. In-transit stock
/// (dispatched-not-received) is valued via `cost_kobo`.
///
/// Seam: the DAO transaction boundary against in-memory Drift.
void main() {
  late AppDatabase db;
  late String businessId;
  late String fromStoreId;
  late String toStoreId;
  late String productId;
  late String staffId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);

    fromStoreId = UuidV7.generate();
    toStoreId = UuidV7.generate();
    staffId = UuidV7.generate();
    productId = UuidV7.generate();
    for (final s in [
      ('Source', fromStoreId),
      ('Dest', toStoreId),
    ]) {
      await db.into(db.stores).insert(
            StoresCompanion.insert(
                id: Value(s.$2), businessId: businessId, name: s.$1),
          );
    }
    await db.into(db.users).insert(
          UsersCompanion.insert(
              id: Value(staffId), businessId: businessId, name: 'CEO', pin: '0'),
        );
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Stout',
            retailerPriceKobo: const Value(120000),
          ),
        );
    // 10 units in the source, all covered by a costed batch @ 15000.
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: fromStoreId,
            quantity: const Value(10),
          ),
        );
    await db.costBatchesDao.recordInflowBatch(
      productId: productId, storeId: fromStoreId, quantity: 10, costKobo: 15000,
    );
  });

  tearDown(() => db.close());

  Future<List<CostBatchData>> batchesAt(String storeId) =>
      (db.select(db.costBatches)
            ..where((b) => b.productId.equals(productId) & b.storeId.equals(storeId)))
          .get();

  Future<StockTransferData> transfer(String id) =>
      (db.select(db.stockTransfers)..where((t) => t.id.equals(id))).getSingle();

  test('dispatch draws the source batches down and RIDES the drawn cost on the '
      'transfer', () async {
    final id = await db.stockTransferDao.createTransfer(
      fromStoreId: fromStoreId,
      toStoreId: toStoreId,
      productId: productId,
      quantity: 4,
      initiatedBy: staffId,
    );

    // The drawn cost (4 × 15000) rides the transfer.
    expect((await transfer(id)).costKobo, 60000);

    // Source batch drawn down 10 → 6 (no phantom coverage for the moved units).
    final srcBatches = await batchesAt(fromStoreId);
    expect(srcBatches.fold<int>(0, (s, b) => s + b.qtyRemaining), 6);

    // Nothing at the destination until receipt.
    expect(await batchesAt(toStoreId), isEmpty);
  });

  test('receipt creates the destination batch at the carried cost — the '
      'receiving store then sells at real COGS', () async {
    final id = await db.stockTransferDao.createTransfer(
      fromStoreId: fromStoreId,
      toStoreId: toStoreId,
      productId: productId,
      quantity: 4,
      initiatedBy: staffId,
    );
    await db.stockTransferDao.receiveTransfer(
        transferId: id, receivedBy: staffId);

    final destBatches = await batchesAt(toStoreId);
    expect(destBatches, hasLength(1));
    expect(destBatches.single.qtyRemaining, 4);
    expect(destBatches.single.costKobo, 15000); // per-unit carried cost

    // A sale at the destination draws the real cost, not 0.
    final perUnit = await db.costBatchesDao.drawDownSale([
      SaleCostLine(index: 0, productId: productId, storeId: toStoreId, quantity: 2),
    ]);
    expect(perUnit[0], 15000);
  });

  test('cancel restores the source cost layer (no permanent coverage loss)',
      () async {
    final id = await db.stockTransferDao.createTransfer(
      fromStoreId: fromStoreId,
      toStoreId: toStoreId,
      productId: productId,
      quantity: 4,
      initiatedBy: staffId,
    );
    // Drawn 10 → 6 at dispatch.
    expect((await batchesAt(fromStoreId)).fold<int>(0, (s, b) => s + b.qtyRemaining),
        6);

    await db.stockTransferDao.cancelTransfer(
        transferId: id, cancelledBy: staffId);

    // The 4 units' cost layer is restored to the source (back to 10 covered).
    final src = await batchesAt(fromStoreId);
    expect(src.fold<int>(0, (s, b) => s + b.qtyRemaining), 10);
    // A source sale still draws the real 15000 cost.
    final perUnit = await db.costBatchesDao.drawDownSale([
      SaleCostLine(
          index: 0, productId: productId, storeId: fromStoreId, quantity: 1),
    ]);
    expect(perUnit[0], 15000);
  });

  test('a legacy transfer with no carried cost creates an Uncosted destination '
      'batch on receipt', () async {
    // Simulate a legacy in_transit transfer (cost_kobo NULL) — e.g. dispatched
    // before #170. Insert the header + the source decrement directly.
    final id = UuidV7.generate();
    await db.into(db.stockTransfers).insert(
          StockTransfersCompanion.insert(
            id: Value(id),
            businessId: businessId,
            fromLocationId: fromStoreId,
            toLocationId: toStoreId,
            productId: productId,
            quantity: 3,
            status: const Value('in_transit'),
            initiatedBy: staffId,
          ),
        );

    await db.stockTransferDao.receiveTransfer(
        transferId: id, receivedBy: staffId);

    final destBatches = await batchesAt(toStoreId);
    expect(destBatches, hasLength(1));
    expect(destBatches.single.qtyRemaining, 3);
    expect(destBatches.single.costKobo, 0); // Uncosted — carried no cost
  });

  test('the in-transit value = the sum of carried cost over in_transit '
      'transfers', () async {
    await db.stockTransferDao.createTransfer(
      fromStoreId: fromStoreId,
      toStoreId: toStoreId,
      productId: productId,
      quantity: 4,
      initiatedBy: staffId,
    );
    final inTransit = await db.stockTransferDao.watchAllInTransit().first;
    final inTransitValue = inTransit.fold<int>(
        0, (s, t) => s + (t.costKobo ?? 0));
    expect(inTransitValue, 60000); // 4 × 15000, valued nowhere before #7b
  });
}
