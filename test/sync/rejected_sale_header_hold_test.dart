// rejected_sale_header_hold_test.dart
//
// Issue #149 — a rejected v2 oversell must NOT leave a phantom `completed`
// order in the cloud. The order *header* is pushed at Confirm time by
// `OrdersDao.markCompleted` → `_enqueueFullOrder` (a plain LWW `orders` upsert).
// On the guarded v2 path (`feature.domain_rpcs_v2.record_sale`) the cloud order
// exists ONLY once the `pos_record_sale_v2` envelope confirms, so that header
// push must be HELD by the order — exactly like the #121 child rows — until the
// envelope resolves: released to push on CONFIRM, discarded on REJECT. A v1 sale
// (no envelope) and an already-CONFIRMED v2 sale push the header immediately,
// unchanged, so a completed status never lags behind the cloud.

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

  // Seeds a registered sale rung at status 'pending' (as real checkout does)
  // and returns its order id + cashier. On the v2 path the pos_record_sale_v2
  // envelope is left PENDING in the queue and NO header row is enqueued yet —
  // v2 defers the header to Confirm (markCompleted). With [domainV2] off it is a
  // plain v1 sale (never any envelope).
  Future<({String orderId, String staffId})> seedPendingSale({
    bool domainV2 = true,
  }) async {
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
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: domainV2);
    await db.delete(db.syncQueue).go(); // clear addCustomer enqueues

    final orderId = await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-1',
        customerId: Value(customerId),
        totalAmountKobo: 200000,
        netAmountKobo: 200000,
        amountPaidKobo: const Value(50000),
        paymentType: 'credit',
        status: 'pending',
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
    return (orderId: orderId, staffId: staffId);
  }

  // The `orders:upsert` queue row for [orderId], or null if the header was
  // never enqueued (payload carries the order id under 'id').
  Future<SyncQueueData?> headerRow(String orderId) async {
    final rows = await (db.select(db.syncQueue)
          ..where((t) => t.actionType.equals('orders:upsert')))
        .get();
    for (final r in rows) {
      if (decodePayload(r)['id'] == orderId) return r;
    }
    return null;
  }

  Future<SyncQueueData> envelope() => (db.select(db.syncQueue)
        ..where((t) => t.actionType.equals('domain:pos_record_sale_v2')))
      .getSingle();

  Future<void> orphanTheEnvelope() async {
    final env = await envelope();
    await db.into(db.syncQueueOrphans).insert(
          SyncQueueOrphansCompanion.insert(
            originalId: env.id,
            actionType: env.actionType,
            payload: env.payload,
            reason: 'pg_P0001: insufficient_stock',
          ),
        );
    await (db.delete(db.syncQueue)..where((t) => t.id.equals(env.id))).go();
  }

  group('saleEnvelopeState classifies the pos_record_sale_v2 envelope', () {
    test('an un-synced envelope still in the queue → pending', () async {
      final sale = await seedPendingSale();
      expect(await db.syncDao.saleEnvelopeState(sale.orderId),
          SaleEnvelopeState.pending);
    });

    test('a synced (markDone) envelope lingering in the queue → confirmed',
        () async {
      final sale = await seedPendingSale();
      await db.syncDao.markDone((await envelope()).id);
      expect(await db.syncDao.saleEnvelopeState(sale.orderId),
          SaleEnvelopeState.confirmed);
    });

    test('an envelope purged from the queue (not orphaned) → confirmed',
        () async {
      final sale = await seedPendingSale();
      await (db.delete(db.syncQueue)
            ..where((t) => t.actionType.equals('domain:pos_record_sale_v2')))
          .go();
      expect(await db.syncDao.saleEnvelopeState(sale.orderId),
          SaleEnvelopeState.confirmed);
    });

    test('an envelope archived to orphans → rejected', () async {
      final sale = await seedPendingSale();
      await orphanTheEnvelope();
      expect(await db.syncDao.saleEnvelopeState(sale.orderId),
          SaleEnvelopeState.rejected);
    });

    test('an order that never had an envelope (v1 sale) → confirmed', () async {
      final sale = await seedPendingSale(domainV2: false);
      expect(await db.syncDao.saleEnvelopeState(sale.orderId),
          SaleEnvelopeState.confirmed);
    });
  });

  group('markCompleted holds the order header behind the v2 envelope (#149)',
      () {
    test('while the envelope is PENDING the header is HELD (never drains)',
        () async {
      final sale = await seedPendingSale();
      await db.ordersDao.markCompleted(sale.orderId, sale.staffId);

      final header = await headerRow(sale.orderId);
      expect(header, isNotNull, reason: 'markCompleted enqueues the header');
      expect(header!.heldByOrderId, sale.orderId,
          reason: 'the header must be held by the order until the envelope '
              'confirms — otherwise a rejected sale leaks a phantom order');

      final drainable =
          await db.syncDao.getPendingItems(businessId: businessId);
      expect(drainable.where((r) => r.actionType == 'orders:upsert'), isEmpty,
          reason: 'the held header is invisible to the drain');
    });

    test('a REJECTED sale discards the held header — no phantom cloud order',
        () async {
      final sale = await seedPendingSale();
      await db.ordersDao.markCompleted(sale.orderId, sale.staffId);

      // The server rejects the oversell; the drain calls discardHeldByOrder
      // for the order (SupabaseSyncService._pushDomainItems, reject path).
      await db.syncDao.discardHeldByOrder(sale.orderId);

      expect(await headerRow(sale.orderId), isNull,
          reason: 'the phantom header is discarded with the child rows');
      final drainable =
          await db.syncDao.getPendingItems(businessId: businessId);
      expect(drainable.where((r) => r.actionType == 'orders:upsert'), isEmpty,
          reason: 'a rejected sale never pushes its order header');
    });

    test('a CONFIRMED sale releases the held header — it may push as completed',
        () async {
      final sale = await seedPendingSale();
      await db.ordersDao.markCompleted(sale.orderId, sale.staffId);

      // The envelope confirms; the drain calls releaseHeldByOrder
      // (SupabaseSyncService._pushDomainItems, confirm path).
      await db.syncDao.releaseHeldByOrder(sale.orderId);

      final drainable =
          await db.syncDao.getPendingItems(businessId: businessId);
      expect(drainable.where((r) => r.actionType == 'orders:upsert'),
          isNotEmpty,
          reason: 'once the cloud order exists the completed header may push');
    });

    test('reconcileHeldRows DISCARDS a held header for a rejected envelope',
        () async {
      final sale = await seedPendingSale();
      await db.ordersDao.markCompleted(sale.orderId, sale.staffId);
      await orphanTheEnvelope(); // rejected, but the inline discard was missed

      final result = await db.syncDao.reconcileHeldRows(businessId);
      expect(result.discarded, greaterThan(0));
      expect(await headerRow(sale.orderId), isNull,
          reason: 'the crash-safe backstop also removes the phantom header');
    });
  });

  group('markCompleted pushes the header immediately when safe (no regression)',
      () {
    test('an already-CONFIRMED v2 sale pushes the header UNHELD', () async {
      final sale = await seedPendingSale();
      // Online sale: the envelope confirmed before Confirm was tapped.
      await db.syncDao.markDone((await envelope()).id);

      await db.ordersDao.markCompleted(sale.orderId, sale.staffId);

      final header = await headerRow(sale.orderId);
      expect(header, isNotNull);
      expect(header!.heldByOrderId, isNull,
          reason: 'a confirmed sale need not hold — no completion-sync delay');
      final drainable =
          await db.syncDao.getPendingItems(businessId: businessId);
      expect(drainable.where((r) => r.actionType == 'orders:upsert'),
          isNotEmpty);
    });

    test('a v1 sale (flag off) pushes the header UNHELD', () async {
      final sale = await seedPendingSale(domainV2: false);
      await db.ordersDao.markCompleted(sale.orderId, sale.staffId);

      final header = await headerRow(sale.orderId);
      expect(header, isNotNull);
      expect(header!.heldByOrderId, isNull);
      final drainable =
          await db.syncDao.getPendingItems(businessId: businessId);
      expect(drainable.where((r) => r.actionType == 'orders:upsert'),
          isNotEmpty);
    });

    test('a sale already REJECTED before Confirm never enqueues a header',
        () async {
      final sale = await seedPendingSale();
      await orphanTheEnvelope();

      await db.ordersDao.markCompleted(sale.orderId, sale.staffId);

      expect(await headerRow(sale.orderId), isNull,
          reason: 'completing a rolled-back sale must not resurrect a header');
    });
  });
}
