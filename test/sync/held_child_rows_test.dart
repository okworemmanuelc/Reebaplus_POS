// held_child_rows_test.dart
//
// Oversell recovery — the HELD-outbox mechanism that stops a rejected v2 sale
// from leaking its non-FK child rows (cost_batches / customer_crate_balances) to
// the cloud. A v2 sale enqueues its child rows HELD by the order id; the drain
// skips them until the pos_record_sale_v2 envelope CONFIRMS (release → push) or
// is REJECTED (discard → never push). `reconcileHeldRows` is the crash-safe
// backstop that decides each held order's fate from durable state.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  Future<String> seedRegisteredSale() async {
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
              name: 'Cashier',
              pin: '0000'),
        );
    final productId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
              id: Value(productId),
              businessId: businessId,
              name: 'Beer',
              retailerPriceKobo: const Value(100000)),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
              businessId: businessId,
              productId: productId,
              storeId: storeId,
              quantity: const Value(5)),
        );
    final customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
    );
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
    await db.delete(db.syncQueue).go(); // clear addCustomer enqueues

    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-1',
        customerId: Value(customerId),
        totalAmountKobo: 200000,
        netAmountKobo: 200000,
        amountPaidKobo: const Value(50000),
        paymentType: 'credit',
        status: 'completed',
        staffId: Value(staffId),
        storeId: Value(storeId),
      ),
      items: [
        OrderItemsCompanion.insert(
          businessId: businessId,
          orderId: 'placeholder',
          productId: Value(productId),
          storeId: storeId,
          quantity: 2,
          unitPriceKobo: 100000,
          totalKobo: 200000,
        ),
      ],
      customerId: customerId,
      amountPaidKobo: 50000,
      totalAmountKobo: 200000,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: 'cash',
    );
  }

  test('a v2 sale holds its child rows — the drain sees the envelope, not the '
      'wallet legs', () async {
    final orderId = await seedRegisteredSale();

    // The DRAIN (getPendingItems) returns the envelope but NOT the held legs.
    final drainable = await db.syncDao.getPendingItems(businessId: businessId);
    final types = drainable.map((r) => r.actionType).toList();
    expect(types, contains('domain:pos_record_sale_v2'));
    expect(
      types.where((t) => t == 'wallet_transactions:upsert'),
      isEmpty,
      reason: 'wallet legs are held until the envelope confirms',
    );

    // They DO exist in the queue, held by this order.
    final held = await (db.select(db.syncQueue)
          ..where((t) => t.heldByOrderId.equals(orderId)))
        .get();
    expect(held, isNotEmpty);
    expect(
      held.map((r) => r.actionType),
      contains('wallet_transactions:upsert'),
    );
    // The envelope itself is NOT held.
    final envelope = await (db.select(db.syncQueue)
          ..where((t) => t.actionType.equals('domain:pos_record_sale_v2')))
        .getSingle();
    expect(envelope.heldByOrderId, isNull);
  });

  test('reconcileHeldRows RELEASES held rows once the envelope confirmed (gone '
      'from queue + orphans)', () async {
    final orderId = await seedRegisteredSale();
    // Simulate the envelope confirming: remove it from the queue (markDone).
    await (db.delete(db.syncQueue)
          ..where((t) => t.actionType.equals('domain:pos_record_sale_v2')))
        .go();

    final result = await db.syncDao.reconcileHeldRows(businessId);
    expect(result.released, 1);
    expect(result.discarded, 0);
    // The formerly-held legs are now drainable.
    final drainable = await db.syncDao.getPendingItems(businessId: businessId);
    expect(
      drainable.where((r) => r.actionType == 'wallet_transactions:upsert'),
      isNotEmpty,
    );
    // No rows remain held for the order.
    final stillHeld = await (db.select(db.syncQueue)
          ..where((t) => t.heldByOrderId.equals(orderId)))
        .get();
    expect(stillHeld, isEmpty);
  });

  test('reconcileHeldRows DISCARDS held rows when the envelope was rejected '
      '(orphaned)', () async {
    final orderId = await seedRegisteredSale();
    // Simulate rejection: move the envelope to sync_queue_orphans.
    final envelope = await (db.select(db.syncQueue)
          ..where((t) => t.actionType.equals('domain:pos_record_sale_v2')))
        .getSingle();
    await db.into(db.syncQueueOrphans).insert(
          SyncQueueOrphansCompanion.insert(
            originalId: envelope.id,
            actionType: envelope.actionType,
            payload: envelope.payload,
            reason: 'pg_P0001: insufficient_stock',
          ),
        );
    await (db.delete(db.syncQueue)..where((t) => t.id.equals(envelope.id))).go();

    final result = await db.syncDao.reconcileHeldRows(businessId);
    expect(result.discarded, greaterThan(0));
    expect(result.released, 0);
    // The held child rows are GONE — they can never leak to the cloud.
    final remaining = await (db.select(db.syncQueue)
          ..where((t) => t.heldByOrderId.equals(orderId)))
        .get();
    expect(remaining, isEmpty);
    final drainable = await db.syncDao.getPendingItems(businessId: businessId);
    expect(
      drainable.where((r) => r.actionType == 'wallet_transactions:upsert'),
      isEmpty,
      reason: 'a rejected sale never pushes its child rows',
    );
  });

  test('reconcileHeldRows KEEPS held rows while the envelope is still pending',
      () async {
    final orderId = await seedRegisteredSale();
    // Envelope is still pending in the queue (default) → keep waiting.
    final result = await db.syncDao.reconcileHeldRows(businessId);
    expect(result.released, 0);
    expect(result.discarded, 0);
    final stillHeld = await (db.select(db.syncQueue)
          ..where((t) => t.heldByOrderId.equals(orderId)))
        .get();
    expect(stillHeld, isNotEmpty);
  });
}
