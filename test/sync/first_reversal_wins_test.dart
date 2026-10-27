// first_reversal_wins_test.dart
//
// #550 (PRD #337 slice d, ADR 0032) — the cloud accepts ONE reversal per Order.
// A Pending-tab Refund (OrdersDao.markCancelled, v1 path) holds every outbox row
// it writes behind one `domain:pos_claim_order_reversal` envelope:
//   • claim lands (or replays)   → the held rows are released, unchanged;
//   • another reversal won first → P0001 `reversal_already_applied`: this phone
//     withdraws its reversal's rows, takes the cloud's header, discards the held
//     rows (none ever uploaded), lists the claim under Sync Issues and alerts the
//     CEO / Managers with `sale_refund_rejected`.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

const _claimRpc = 'pos_claim_order_reversal';

void main() {
  setUpAll(() => tzdata.initializeTimeZones());

  late AppDatabase db;
  late String businessId;
  late InMemoryCloudTransport transport;
  late SupabaseSyncService sync;
  late String storeId;
  late String staffId;
  late String productId;
  late String customerId;
  late String ceoId;
  late String managerId;
  late String otherStoreManagerId;

  Future<String> insertUser(String name) async {
    final id = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            pin: '0000',
          ),
        );
    return id;
  }

  final roleIds = <String, String>{};
  Future<void> addMember(String userId, String roleSlug) async {
    var roleId = roleIds[roleSlug];
    if (roleId == null) {
      roleId = UuidV7.generate();
      roleIds[roleSlug] = roleId;
      await db.into(db.roles).insert(
            RolesCompanion.insert(
              id: Value(roleId),
              businessId: businessId,
              name: roleSlug,
              slug: roleSlug,
            ),
          );
    }
    await db.into(db.userBusinesses).insert(
          UserBusinessesCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            userId: userId,
            roleId: roleId,
          ),
        );
  }

  setUp(() async {
    roleIds.clear();
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    transport = InMemoryCloudTransport(authUserId: 'auth-1');
    sync = SupabaseSyncService(db, transport);

    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main',
          ),
        );
    final otherStoreId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(otherStoreId),
            businessId: businessId,
            name: 'Annex',
          ),
        );
    staffId = await insertUser('Cashier');
    ceoId = await insertUser('Owner');
    managerId = await insertUser('Manager');
    otherStoreManagerId = await insertUser('Annex Manager');
    await addMember(ceoId, 'ceo');
    await addMember(managerId, 'manager');
    await addMember(otherStoreManagerId, 'manager');
    await db.into(db.userStores).insert(
          UserStoresCompanion.insert(
            businessId: businessId,
            userId: managerId,
            storeId: storeId,
          ),
        );
    await db.into(db.userStores).insert(
          UserStoresCompanion.insert(
            businessId: businessId,
            userId: otherStoreManagerId,
            storeId: otherStoreId,
          ),
        );

    productId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Test Beer',
            retailerPriceKobo: const Value(100000),
          ),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            quantity: const Value(10),
          ),
        );
    customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
    );
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
  });

  tearDown(() => db.close());

  /// A completed v1 credit sale (2 × ₦1,000, ₦1,500 paid) whose outbox is then
  /// cleared, so only the refund's rows are in the queue afterwards.
  Future<String> sellAndClearQueue() async {
    final orderId = await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-REV-1',
        customerId: Value(customerId),
        totalAmountKobo: 200000,
        netAmountKobo: 200000,
        amountPaidKobo: const Value(150000),
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
      amountPaidKobo: 150000,
      totalAmountKobo: 200000,
      staffId: staffId,
      storeId: storeId,
    );
    await db.delete(db.syncQueue).go();
    await db.delete(db.notifications).go();
    return orderId;
  }

  Future<SyncQueueData> claimRow() async => (await (db.select(db.syncQueue)
        ..where((t) => t.actionType.equals(kReversalClaimAction)))
      .getSingle());

  Future<int> inventoryQty() async => (await (db.select(db.inventory)
        ..where((t) => t.productId.equals(productId)))
      .getSingle())
      .quantity;

  Future<int> walletBalance() async {
    final rows = await (db.select(db.walletTransactions)
          ..where((t) => t.customerId.equals(customerId)))
        .get();
    return rows.fold<int>(0, (sum, r) => sum + r.signedAmountKobo);
  }

  Future<void> drainClaim() async {
    await sync.pushDomainItemsForTesting(
      [await claimRow()],
      businessId,
      'auth-1',
    );
  }

  test('a refund holds every row it writes behind ONE claim envelope', () async {
    final orderId = await sellAndClearQueue();

    await db.ordersDao.markCancelled(orderId, 'changed mind', staffId);

    final claim = await claimRow();
    final payload = decodePayload(claim);
    expect(payload['p_business_id'], businessId);
    expect(payload['p_actor_id'], staffId);
    expect(payload['p_order_id'], orderId);
    expect(payload['p_cancellation_reason'], 'changed mind');
    expect(payload['p_cancelled_at'], isA<String>());
    final reversalId = payload['p_reversal_id'] as String;

    final others = await (db.select(db.syncQueue)
          ..where((t) => t.actionType.equals(kReversalClaimAction).not()))
        .get();
    expect(
      others.map((r) => r.actionType).toSet(),
      containsAll(<String>[
        'orders:upsert',
        'stock_transactions:upsert',
        'inventory:upsert',
        'payment_transactions:upsert',
        'wallet_transactions:upsert',
        'cost_batches:upsert',
      ]),
    );
    expect(others.every((r) => r.heldByOrderId == reversalId), isTrue,
        reason: 'no reversal row may upload before the claim lands');

    final drainable = await db.syncDao.getPendingItems(businessId: businessId);
    expect(drainable.map((r) => r.actionType), [kReversalClaimAction]);
  });

  test('claim lands → held rows released; the winner retry is idempotent',
      () async {
    final orderId = await sellAndClearQueue();
    await db.ordersDao.markCancelled(orderId, 'changed mind', staffId);
    final reversalId = decodePayload(await claimRow())['p_reversal_id'];

    // First attempt dies in flight (lost response): rows stay held.
    transport.failRpc(_claimRpc, TimeoutException('lost response'));
    await drainClaim();
    expect(
      (await db.syncDao.heldRowsFor(reversalId as String)),
      isNotEmpty,
    );

    // The retry carries the SAME reversal id; the cloud replays it.
    transport.stubRpc(_claimRpc, (_) => {'replayed': true});
    await (db.update(db.syncQueue)
          ..where((t) => t.actionType.equals(kReversalClaimAction)))
        .write(const SyncQueueCompanion(nextAttemptAt: Value(null)));
    await drainClaim();

    expect(transport.rpcCalls.where((c) => c.name == _claimRpc), hasLength(1));
    expect(transport.rpcCalls.single.params['p_reversal_id'], reversalId);
    expect(await db.syncDao.heldRowsFor(reversalId), isEmpty);
    expect((await claimRow()).isSynced, isTrue);
    final drainable = await db.syncDao.getPendingItems(businessId: businessId);
    expect(drainable.map((r) => r.actionType),
        containsAll(['stock_transactions:upsert', 'payment_transactions:upsert']));

    // The local reversal stands untouched.
    final order = await (db.select(db.orders)
          ..where((t) => t.id.equals(orderId)))
        .getSingle();
    expect(order.status, 'cancelled');
    expect(await inventoryQty(), 10);
    expect(await db.select(db.notifications).get(), isEmpty);
  });

  test('another reversal won → this phone undoes its refund, lists a Sync Issue '
      'and alerts the CEO / store Manager', () async {
    final orderId = await sellAndClearQueue();
    final walletAfterSale = await walletBalance();
    final batchesAfterSale = (await db.select(db.costBatches).get()).length;

    await db.ordersDao.markCancelled(orderId, 'my refund', staffId);
    expect(await inventoryQty(), 10);
    expect(await walletBalance(), 0);
    final reversalId =
        decodePayload(await claimRow())['p_reversal_id'] as String;

    final cloudLua = DateTime.utc(2026, 10, 26, 9, 30);
    final cloudCancelledAt = DateTime.utc(2026, 10, 26, 9, 0);
    transport.failRpc(
      _claimRpc,
      PostgrestException(
        message: 'reversal_already_applied',
        code: 'P0001',
        details: jsonEncode({
          'status': 'cancelled',
          'cancelled_at': cloudCancelledAt.toIso8601String(),
          'cancellation_reason': 'winner refund',
          'last_updated_at': cloudLua.toIso8601String(),
        }),
      ),
    );
    await drainClaim();

    // Stock: the return row is withdrawn and its units go back off the shelf.
    final stock = await db.select(db.stockTransactions).get();
    expect(stock.map((r) => r.movementType), ['sale']);
    expect(await inventoryQty(), 8);
    // Money: only the original sale rows remain; wallet back to after-sale.
    final payments = await db.select(db.paymentTransactions).get();
    expect(payments.any((p) => p.type == 'refund'), isFalse);
    expect(await walletBalance(), walletAfterSale);
    expect((await db.select(db.costBatches).get()).length, batchesAfterSale);

    // Header: the cloud's copy.
    final order = await (db.select(db.orders)
          ..where((t) => t.id.equals(orderId)))
        .getSingle();
    expect(order.status, 'cancelled');
    expect(order.cancellationReason, 'winner refund');
    expect(order.cancelledAt!.toUtc(), cloudCancelledAt);
    expect(order.lastUpdatedAt.toUtc(), cloudLua);

    // Outbox: nothing of the refund is left to upload; the claim is an orphan.
    expect(await db.syncDao.heldRowsFor(reversalId), isEmpty);
    expect(await db.select(db.syncQueue).get(),
        everyElement(predicate<SyncQueueData>(
            (r) => r.actionType == 'notifications:upsert')));
    final orphans = await db.select(db.syncQueueOrphans).get();
    expect(orphans, hasLength(1));
    expect(orphans.single.actionType, kReversalClaimAction);
    expect(orphans.single.reason, contains('reversal_already_applied'));

    // Alert: CEO + the Manager of this order's store, warning, linked.
    final alerts = await db.select(db.notifications).get();
    expect(alerts.map((n) => n.recipientUserId).toSet(), {ceoId, managerId});
    for (final n in alerts) {
      expect(n.type, 'sale_refund_rejected');
      expect(n.severity, 'warning');
      expect(n.linkedRecordId, orderId);
    }

    // Idempotent: a replayed undo writes nothing.
    expect(
      await db.ordersDao.undoRejectedReversal(
        reversalId: reversalId,
        orderId: orderId,
      ),
      isFalse,
    );
  });

  test('reconcileHeldRows keeps a reversal held while its claim is queued or '
      'orphaned for another reason, and releases once it confirmed', () async {
    final orderId = await sellAndClearQueue();
    await db.ordersDao.markCancelled(orderId, 'changed mind', staffId);
    final claim = await claimRow();
    final reversalId = decodePayload(claim)['p_reversal_id'] as String;

    await db.syncDao.reconcileHeldRows(businessId);
    expect(await db.syncDao.heldRowsFor(reversalId), isNotEmpty);

    await db.syncDao.markFailed(claim.id, 'pg_P0001: other', permanent: true);
    await db.syncDao.reconcileHeldRows(businessId);
    expect(await db.syncDao.heldRowsFor(reversalId), isNotEmpty,
        reason: 'an unguarded release would upload a reversal the cloud '
            'never accepted');

    await db.delete(db.syncQueueOrphans).go();
    await db.syncDao.reconcileHeldRows(businessId);
    expect(await db.syncDao.heldRowsFor(reversalId), isEmpty);
  });
}
