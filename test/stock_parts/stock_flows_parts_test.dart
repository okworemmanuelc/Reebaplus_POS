import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// Stock adjustments + approval requests, branch transfers, stock requests and
/// stock counts in parts (#630): quarters work, a product whose parts switch is
/// off takes whole numbers only, and whole numbers behave as they always did.
void main() {
  late AppDatabase db;
  late String businessId;
  late String fromStore;
  late String toStore;
  late String staff;
  late String partsProduct; // switch on
  late String wholeProduct; // switch off

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);

    fromStore = UuidV7.generate();
    toStore = UuidV7.generate();
    staff = UuidV7.generate();
    partsProduct = UuidV7.generate();
    wholeProduct = UuidV7.generate();
    for (final (id, name) in [(fromStore, 'Source'), (toStore, 'Dest')]) {
      await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(id), businessId: businessId, name: name));
    }
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staff), businessId: businessId, name: 'CEO', pin: '0000'));
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(partsProduct),
        businessId: businessId,
        name: 'Rice',
        buyingPriceKobo: const Value(1000),
        allowFractionalSales: const Value(true)));
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(wholeProduct),
        businessId: businessId,
        name: 'Bottle',
        buyingPriceKobo: const Value(1000)));
    for (final p in [partsProduct, wholeProduct]) {
      await db.into(db.inventory).insert(InventoryCompanion.insert(
          businessId: businessId,
          productId: p,
          storeId: fromStore,
          quantity: const Value(10)));
    }
  });

  tearDown(() => db.close());

  Future<double> stockAt(String product, String store) async {
    final row = await (db.select(db.inventory)
          ..where((t) => t.productId.equals(product) & t.storeId.equals(store)))
        .getSingleOrNull();
    return row?.quantity ?? 0;
  }

  group('adjustStock', () {
    test('applies a quarter and records it on the ledger', () async {
      await db.inventoryDao.adjustStock(
          partsProduct, fromStore, 0.25, 'found one', staff);
      expect(await stockAt(partsProduct, fromStore), 10.25);
      final tx = await db.customSelect(
        'SELECT quantity_delta FROM stock_transactions WHERE product_id = ?',
        variables: [Variable(partsProduct)],
      ).getSingle();
      expect(tx.read<double>('quantity_delta'), 0.25);
    });

    test('refuses an off-quarter change', () async {
      expect(
        () => db.inventoryDao
            .adjustStock(partsProduct, fromStore, 0.3, 'x', staff),
        throwsArgumentError,
      );
    });
  });

  group('adjustment requests and approval', () {
    test('a part request is stored, approved and applied', () async {
      await db.stockAdjustmentRequestsDao.requestStockAdjustment(
        productId: partsProduct,
        storeId: fromStore,
        quantityDiff: -1.5,
        reason: 'damage:spilled',
        summary: 'removed 1.5',
        requestedBy: staff,
      );
      final req = await db.select(db.stockAdjustmentRequests).getSingle();
      expect(req.quantityDiff, -1.5);

      await db.stockAdjustmentRequestsDao
          .approveRequest(requestId: req.id, approverId: staff);
      expect(await stockAt(partsProduct, fromStore), 8.5);
    });

    test('a part add carries its cost into a part-sized batch', () async {
      await db.stockAdjustmentRequestsDao.requestStockAdjustment(
        productId: partsProduct,
        storeId: fromStore,
        quantityDiff: 0.5,
        reason: 'found',
        summary: 'added 0.5',
        requestedBy: staff,
        unitCostKobo: 800,
      );
      final req = await db.select(db.stockAdjustmentRequests).getSingle();
      await db.stockAdjustmentRequestsDao
          .approveRequest(requestId: req.id, approverId: staff);
      final batch = await db.customSelect(
        'SELECT qty_original, cost_kobo FROM cost_batches WHERE product_id = ? '
        'AND qty_original = 0.5',
        variables: [Variable(partsProduct)],
      ).getSingle();
      expect(batch.read<int>('cost_kobo'), 800);
    });

    test('a switched-off product rejects a part request', () async {
      expect(
        () => db.stockAdjustmentRequestsDao.requestStockAdjustment(
          productId: wholeProduct,
          storeId: fromStore,
          quantityDiff: 0.5,
          reason: 'x',
          summary: 'x',
          requestedBy: staff,
        ),
        throwsArgumentError,
      );
      expect(await db.select(db.stockAdjustmentRequests).get(), isEmpty);
    });

    test('approval refuses a part once the switch is off, request stays pending',
        () async {
      await db.stockAdjustmentRequestsDao.requestStockAdjustment(
        productId: partsProduct,
        storeId: fromStore,
        quantityDiff: 0.5,
        reason: 'x',
        summary: 'x',
        requestedBy: staff,
      );
      await (db.update(db.products)..where((t) => t.id.equals(partsProduct)))
          .write(const ProductsCompanion(allowFractionalSales: Value(false)));
      final req = await db.select(db.stockAdjustmentRequests).getSingle();
      await expectLater(
        db.stockAdjustmentRequestsDao
            .approveRequest(requestId: req.id, approverId: staff),
        throwsArgumentError,
      );
      final after = await db.select(db.stockAdjustmentRequests).getSingle();
      expect(after.status, 'pending');
      expect(await stockAt(partsProduct, fromStore), 10);
    });

    test('whole requests are unchanged for a switched-off product', () async {
      await db.stockAdjustmentRequestsDao.requestStockAdjustment(
        productId: wholeProduct,
        storeId: fromStore,
        quantityDiff: -3,
        reason: 'x',
        summary: 'x',
        requestedBy: staff,
      );
      final req = await db.select(db.stockAdjustmentRequests).getSingle();
      await db.stockAdjustmentRequestsDao
          .approveRequest(requestId: req.id, approverId: staff);
      expect(await stockAt(wholeProduct, fromStore), 7);
    });
  });

  group('branch transfers', () {
    test('a part moves out, rides its cost and arrives', () async {
      final id = await db.stockTransferDao.createTransfer(
        fromStoreId: fromStore,
        toStoreId: toStore,
        productId: partsProduct,
        quantity: 2.25,
        initiatedBy: staff,
      );
      expect(await stockAt(partsProduct, fromStore), 7.75);
      await db.stockTransferDao.receiveTransfer(transferId: id, receivedBy: staff);
      expect(await stockAt(partsProduct, toStore), 2.25);
      final t = await db.select(db.stockTransfers).getSingle();
      expect(t.quantity, 2.25);
    });

    test('a switched-off product rejects a part transfer', () async {
      expect(
        () => db.stockTransferDao.createTransfer(
          fromStoreId: fromStore,
          toStoreId: toStore,
          productId: wholeProduct,
          quantity: 1.5,
          initiatedBy: staff,
        ),
        throwsArgumentError,
      );
      expect(await stockAt(wholeProduct, fromStore), 10);
    });

    test('whole transfers are unchanged', () async {
      await db.stockTransferDao.createTransfer(
        fromStoreId: fromStore,
        toStoreId: toStore,
        productId: wholeProduct,
        quantity: 4,
        initiatedBy: staff,
      );
      expect(await stockAt(wholeProduct, fromStore), 6);
    });

    test('a request in parts, dispatched at a different part', () async {
      final ids = await db.stockTransferDao.requestTransfers(
        fromStoreId: fromStore,
        toStoreId: toStore,
        lines: [(productId: partsProduct, quantity: 1.5)],
        requestedBy: staff,
      );
      final pending = await db.select(db.stockTransfers).getSingle();
      expect(pending.quantity, 1.5);
      await db.stockTransferDao.dispatchTransfer(
        transferId: ids.single,
        dispatchedBy: staff,
        quantity: 0.75,
      );
      expect(await stockAt(partsProduct, fromStore), 9.25);
    });

    test('a request or dispatch for a switched-off product rejects parts',
        () async {
      expect(
        () => db.stockTransferDao.requestTransfers(
          fromStoreId: fromStore,
          toStoreId: toStore,
          lines: [(productId: wholeProduct, quantity: 0.5)],
          requestedBy: staff,
        ),
        throwsArgumentError,
      );
      final id = await db.stockTransferDao.requestTransfer(
        fromStoreId: fromStore,
        toStoreId: toStore,
        productId: wholeProduct,
        quantity: 2,
        requestedBy: staff,
      );
      await expectLater(
        db.stockTransferDao.dispatchTransfer(
          transferId: id,
          dispatchedBy: staff,
          quantity: 1.5,
        ),
        throwsArgumentError,
      );
      expect(await stockAt(wholeProduct, fromStore), 10);
    });
  });

  group('stock counts', () {
    test('a count lands on a quarter and the session keeps the part', () async {
      // System 10, counted 9.75 -> diff -0.25.
      await db.inventoryDao.adjustStock(
          partsProduct, fromStore, -0.25, 'Daily stock count adjustment', staff);
      await db.stockCountsDao.recordCount(
        storeId: fromStore,
        businessDate: '2026-11-01',
        productsCounted: 1,
        changedLines: [
          {'p': partsProduct, 'n': 'Rice', 's': 10, 'a': 9.75, 'd': -0.25},
        ],
        countedBy: staff,
      );
      expect(await stockAt(partsProduct, fromStore), 9.75);
      final c = await db.select(db.stockCounts).getSingle();
      expect(c.shortageCount, 1);
      expect(c.shortageUnits, 0.25);
      final lines = jsonDecode(c.linesJson) as List;
      expect((lines.single as Map)['d'], -0.25);
      expect((lines.single as Map)['s'], 10); // whole stays an integer
    });
  });

  test('assertQuantityAllowed: zero only when asked, quarters only', () async {
    final dao = db.inventoryDao;
    await expectLater(dao.assertQuantityAllowed(partsProduct, 0),
        throwsArgumentError);
    await dao.assertQuantityAllowed(partsProduct, 0, allowZero: true);
    await expectLater(dao.assertQuantityAllowed(partsProduct, 0.1),
        throwsArgumentError);
    await dao.assertQuantityAllowed(partsProduct, 0.75);
    await expectLater(dao.assertQuantityAllowed(wholeProduct, 0.75),
        throwsArgumentError);
    await dao.assertQuantityAllowed(wholeProduct, 6);
  });
}
