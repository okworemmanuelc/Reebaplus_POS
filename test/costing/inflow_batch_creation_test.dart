import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';
import 'package:reebaplus_pos/shared/services/receive_stock_service.dart';
import 'package:reebaplus_pos/shared/services/supplier_account_service.dart';

import '../helpers/dispatch_test_utils.dart';

/// Batch-creation-on-inflow (Epic 2 / ADR 0005, issue #42): every stock inflow
/// — Add Product's opening stock and Receive Stock — writes a `cost_batches`
/// row, so post-migration new and restocked products are costed instead of
/// selling at 0 COGS. F1 (#37) only seeds opening batches via the migration and
/// F2 (#38) only consumes the queue; this is its producer.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // v1 paths so createOrder / create-product write locally (v2 defers to the
    // cloud RPC response); the v2 create path gets its own explicit test.
    await setFlag(db, 'feature.domain_rpcs_v2.create_product', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);

    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
              id: Value(storeId), businessId: businessId, name: 'Main'),
        );
    staffId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
              id: Value(staffId),
              businessId: businessId,
              name: 'Cashier',
              pin: '0000'),
        );
  });

  tearDown(() => db.close());

  Future<List<CostBatchData>> batchesFor(String productId) =>
      (db.select(db.costBatches)..where((b) => b.productId.equals(productId)))
          .get();

  Future<int> stockOf(String productId) async {
    final row = await db.customSelect(
      'SELECT quantity FROM inventory WHERE product_id = ? AND store_id = ?',
      variables: [Variable(productId), Variable(storeId)],
    ).getSingleOrNull();
    return row?.read<int>('quantity') ?? 0;
  }

  Future<OrderItemData> lineForOrder(String orderNumber) async {
    final order = await (db.select(db.orders)
          ..where((o) => o.orderNumber.equals(orderNumber)))
        .getSingle();
    return (db.select(db.orderItems)..where((i) => i.orderId.equals(order.id)))
        .getSingle();
  }

  Future<String> addProduct({
    required String name,
    required int buyingKobo,
    int? initialStock,
    String? store,
    int retailKobo = 100000,
  }) {
    return db.catalogDao.insertProductWithInitialStock(
      ProductsCompanion.insert(
        name: name,
        businessId: businessId,
        retailerPriceKobo: Value(retailKobo),
        buyingPriceKobo: Value(buyingKobo),
        unit: const Value('Piece'),
      ),
      initialStock: initialStock,
      storeId: store,
      performedBy: staffId,
    );
  }

  Future<String> newSupplier() async {
    final id = UuidV7.generate();
    await db.into(db.suppliers).insert(
          SuppliersCompanion.insert(
              id: Value(id), businessId: businessId, name: 'Acme'),
        );
    return id;
  }

  List<Map<String, dynamic>> cartOf(String productId, int qty, int sellKobo) => [
        {
          'id': productId,
          'qty': qty,
          'unitPriceKobo': sellKobo,
          'buyingPriceKobo': 0,
          'name': 'Item',
        },
      ];

  // ─── Add Product opening stock ─────────────────────────────────────────────

  test('Add Product opening stock inserts exactly one batch: '
      'qty_remaining == qty_original == opening qty, cost = entered price, '
      'received_at ~ now', () async {
    final before = DateTime.now().subtract(const Duration(seconds: 2));
    final productId =
        await addProduct(name: 'Cola', buyingKobo: 15000, initialStock: 40, store: storeId);

    final batches = await batchesFor(productId);
    expect(batches, hasLength(1));
    final b = batches.single;
    expect(b.qtyOriginal, 40);
    expect(b.qtyRemaining, 40);
    expect(b.costKobo, 15000);
    expect(b.storeId, storeId);
    expect(b.productId, productId);
    expect(b.receivedAt.isAfter(before), isTrue);
    // The queue total for the (product, store) equals on-hand.
    expect(await stockOf(productId), 40);
  });

  test('Add Product with a blank buying price creates a valid uncosted (0) '
      'batch that the #41 backfill resolves in place — no double-count', () async {
    final productId =
        await addProduct(name: 'Water', buyingKobo: 0, initialStock: 10, store: storeId);

    final batch = (await batchesFor(productId)).single;
    expect(batch.costKobo, 0); // uncosted
    expect(batch.qtyRemaining, 10);

    // #41: cost becomes real → the uncosted batch is costed once, not cloned.
    await db.costBatchesDao.onCostBecameReal(productId, 22000);
    final after = await batchesFor(productId);
    expect(after, hasLength(1)); // still exactly one — costed in place
    expect(after.single.costKobo, 22000);
  });

  test('Add Product with no opening stock creates no batch', () async {
    final productId = await addProduct(name: 'NoStock', buyingKobo: 5000);
    expect(await batchesFor(productId), isEmpty);
  });

  test('the cost_batches push carries the same id and all defaulted columns '
      '(no second id minted on push)', () async {
    final productId =
        await addProduct(name: 'Cola', buyingKobo: 15000, initialStock: 5, store: storeId);
    final batch = (await batchesFor(productId)).single;

    final queue = await getPendingQueue(db);
    final push =
        queue.firstWhere((r) => r.actionType == 'cost_batches:upsert');
    final payload = decodePayload(push);

    expect(payload['id'], batch.id); // same id the cloud will store
    expect(payload['business_id'], businessId);
    expect(payload['product_id'], productId);
    expect(payload['store_id'], storeId);
    expect(payload['qty_remaining'], 5);
    expect(payload['qty_original'], 5);
    expect(payload['cost_kobo'], 15000);
    expect(payload['received_at'] != null, isTrue);
    expect(payload['created_at'] != null, isTrue);
    expect(payload['last_updated_at'] != null, isTrue);
  });

  test('v2 create-product path also inserts the batch, pushed after the '
      'product-create envelope so its FK-to-product resolves', () async {
    await setFlag(db, 'feature.domain_rpcs_v2.create_product', on: true);
    final productId =
        await addProduct(name: 'Cola', buyingKobo: 9000, initialStock: 12, store: storeId);

    final batch = (await batchesFor(productId)).single;
    expect(batch.qtyRemaining, 12);
    expect(batch.costKobo, 9000);

    final queue = await getPendingQueue(db); // createdAt ascending
    final envelope =
        queue.firstWhere((r) => r.actionType == 'domain:pos_create_product_v2');
    final push =
        queue.firstWhere((r) => r.actionType == 'cost_batches:upsert');
    // Enqueued after the create envelope (never before — the batch FK-references
    // the product the envelope mints on the cloud).
    expect(push.createdAt.isBefore(envelope.createdAt), isFalse);
  });

  // ─── Receive Stock ─────────────────────────────────────────────────────────

  test('Receive Stock adds a NEW FIFO layer at the receipt price and does not '
      'mutate the existing opening batch; queue total tracks on-hand', () async {
    final productId =
        await addProduct(name: 'Star', buyingKobo: 10000, initialStock: 6, store: storeId);
    final opening = (await batchesFor(productId)).single;

    final svc = ReceiveStockService(db, SupplierAccountService(db));
    await svc.confirmReceipt(
      supplierId: await newSupplier(),
      supplierName: 'Acme',
      storeId: storeId,
      dateReceived: DateTime.utc(2026, 7, 4),
      staffId: staffId,
      lines: [
        ReceiveCartLine(
          productId: productId,
          productName: 'Star',
          qty: 20,
          buyingPriceKobo: 13000,
          retailKobo: 20000,
          wholesaleKobo: 18000,
          trackEmpties: false,
        ),
      ],
      emptiesReturnedByManufacturer: const {},
    );

    final batches = await batchesFor(productId);
    expect(batches, hasLength(2)); // opening + this receipt

    final receipt = batches.firstWhere((b) => b.id != opening.id);
    expect(receipt.qtyOriginal, 20);
    expect(receipt.qtyRemaining, 20);
    expect(receipt.costKobo, 13000);
    // Stored as unix seconds → read back in local time; compare the instant.
    expect(receipt.receivedAt.isAtSameMomentAs(DateTime.utc(2026, 7, 4)), isTrue);

    // The opening batch is untouched (each receipt is its own layer).
    final openingAfter = batches.firstWhere((b) => b.id == opening.id);
    expect(openingAfter.qtyRemaining, opening.qtyRemaining);
    expect(openingAfter.costKobo, opening.costKobo);

    final totalRemaining = batches.fold<int>(0, (s, b) => s + b.qtyRemaining);
    expect(totalRemaining, 26);
    expect(totalRemaining, await stockOf(productId));
  });

  // ─── Regression: the 0-COGS gap is closed on both inflow sites ──────────────

  test('regression: a post-migration new product and a post-migration restock '
      'of a previously batchless product both draw NON-ZERO COGS at checkout',
      () async {
    final svc = OrderService(db);

    // (a) A brand-new product created via Add Product opening stock.
    final newProductId =
        await addProduct(name: 'Cola', buyingKobo: 15000, initialStock: 10, store: storeId);
    final n1 = await svc.addOrder(
      customerId: null,
      cart: cartOf(newProductId, 2, 100000),
      totalAmountKobo: 200000,
      amountPaidKobo: 200000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );
    expect((await lineForOrder(n1)).buyingPriceKobo, 15000); // opening batch paid

    // (b) A product that exists with NO batch (out of stock at migration →
    //     restocked later). Receive Stock brings both the first stock and the
    //     first batch.
    final restockId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(restockId),
            businessId: businessId,
            name: 'Water',
            retailerPriceKobo: const Value(50000),
            buyingPriceKobo: const Value(0),
            unit: const Value('Pack'),
          ),
        );
    expect(await batchesFor(restockId), isEmpty); // no batch yet — would sell at 0

    await ReceiveStockService(db, SupplierAccountService(db)).confirmReceipt(
      supplierId: await newSupplier(),
      supplierName: 'Acme',
      storeId: storeId,
      dateReceived: DateTime.utc(2026, 7, 4),
      staffId: staffId,
      lines: [
        ReceiveCartLine(
          productId: restockId,
          productName: 'Water',
          qty: 8,
          buyingPriceKobo: 12000,
          retailKobo: 50000,
          wholesaleKobo: 45000,
          trackEmpties: false,
        ),
      ],
      emptiesReturnedByManufacturer: const {},
    );

    final n2 = await svc.addOrder(
      customerId: null,
      cart: cartOf(restockId, 3, 50000),
      totalAmountKobo: 150000,
      amountPaidKobo: 150000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );
    expect((await lineForOrder(n2)).buyingPriceKobo, 12000); // receipt batch paid
  });
}
