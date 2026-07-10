// exactly_once_stock_integrity_test.dart
//
// Workstream A (#100) — exactly-once stock integrity.
//
// The headline defect: two tills sell the SAME last unit while briefly out of
// sync. Each runs its LOCAL stock guard (both pass against a stale on-hand of
// 1), both decrement to 0, and both push. On the current v1 path both push the
// ABSOLUTE `inventory.quantity = 0` row; the natural-key LWW cache
// (sync_registry.dart: isCache: true) keeps a single row at 0 — so the cloud
// reads 0 on hand yet TWO units were sold from a stock of 1. No error is raised;
// the oversell is silent.
//
// Two groups here, one per path:
//   • A-S1 (v1, flag OFF): reproduces the silent oversell — a documentation +
//     regression guard so the defect cannot come back unnoticed.
//   • A-S3 (v2, flag ON): the FIX — mobile checkout routes through the guarded
//     `pos_record_sale_v2` (server `SELECT … FOR UPDATE` + relative decrement +
//     `quantity >= n` reject + `ON CONFLICT (id) DO NOTHING`). The server
//     serializes the two sales, accepts the first and REJECTS the second; the
//     loser orphans visibly (Invariant #12) and on-hand never goes below 0.

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

/// Shared ids so two devices agree on the same business / store / product /
/// inventory row — exactly as they would after pulling them from one cloud.
/// The shared `inventoryId` is load-bearing on the v1 path: the absolute-cache
/// push upserts on the natural key `(business_id, product_id, store_id)`, so
/// both devices' pushes collapse onto the SAME cloud row (LWW), which is the
/// merge that hides the oversell.
class _Fixture {
  _Fixture()
      : businessId = UuidV7.generate(),
        storeId = UuidV7.generate(),
        staffId = UuidV7.generate(),
        productId = UuidV7.generate(),
        inventoryId = UuidV7.generate();

  final String businessId;
  final String storeId;
  final String staffId;
  final String productId;
  final String inventoryId;
}

/// A device: a fresh in-memory Drift DB seeded with the shared fixtures and a
/// starting on-hand of [startQty] for the shared product. Flag-agnostic — each
/// group sets `feature.domain_rpcs_v2.record_sale` itself.
Future<AppDatabase> _bootDevice(_Fixture f, {required int startQty}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  db.businessIdResolver = () => f.businessId;
  await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(f.businessId), name: 'Biz'),
      );
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(f.storeId),
          businessId: f.businessId,
          name: 'Main',
        ),
      );
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(f.staffId),
          businessId: f.businessId,
          name: 'Cashier',
          pin: '0000',
        ),
      );
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: Value(f.productId),
          businessId: f.businessId,
          name: 'Last Beer',
          retailerPriceKobo: const Value(100000),
        ),
      );
  await db.into(db.inventory).insert(
        InventoryCompanion.insert(
          id: Value(f.inventoryId),
          businessId: f.businessId,
          productId: f.productId,
          storeId: f.storeId,
          quantity: Value(startQty),
        ),
      );
  return db;
}

/// A walk-in (no customer) cash sale of one unit of the shared product. Walk-in
/// keeps the sale a pure stock movement — no wallet legs — so the test isolates
/// the on-hand oversell.
Future<String> _sellOneUnit(
  AppDatabase db,
  _Fixture f, {
  required String orderNumber,
}) {
  return db.ordersDao.createOrder(
    order: OrdersCompanion.insert(
      businessId: f.businessId,
      orderNumber: orderNumber,
      totalAmountKobo: 100000,
      netAmountKobo: 100000,
      amountPaidKobo: const Value(100000),
      paymentType: 'cash',
      status: 'completed',
      staffId: Value(f.staffId),
      storeId: Value(f.storeId),
    ),
    items: [
      OrderItemsCompanion.insert(
        businessId: f.businessId,
        orderId: 'placeholder', // overwritten by createOrder
        productId: Value(f.productId),
        storeId: f.storeId,
        quantity: 1,
        unitPriceKobo: 100000,
        totalKobo: 100000,
      ),
    ],
    amountPaidKobo: 100000,
    totalAmountKobo: 100000,
    staffId: f.staffId,
    storeId: f.storeId,
    paymentMethod: 'cash',
  );
}

/// Push a device's enqueued rows for [tables] to the shared [cloud] exactly as
/// `SupabaseSyncService.pushPending` does: one `upsert` per table payload. The
/// fake keys stored rows by `id`, so the two devices' inventory rows (which
/// share `inventoryId`) collapse to one — modelling the natural-key LWW merge
/// the real cloud performs on `onConflict (business_id, product_id, store_id)`.
Future<void> _drainToCloud(
  AppDatabase db,
  InMemoryCloudTransport cloud, {
  required Set<String> tables,
}) async {
  for (final row in await getPendingQueue(db)) {
    final table = row.actionType.split(':').first;
    if (!tables.contains(table)) continue;
    await cloud.upsertRows(table, [decodePayload(row)]);
  }
}

// Deterministic timestamps for the modelled cloud rows.
const String _t0 = '2026-07-08T10:00:00.000Z';
const String _t1 = '2026-07-08T10:00:01.000Z';

void main() {
  // Two devices = two AppDatabase instances by design; silence the shared-executor
  // heuristic (each has its own in-memory executor, so there is no real race).
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('A-S1 — v1 (flag OFF) silently oversells the last unit', () {
    late _Fixture f;
    late AppDatabase deviceA;
    late AppDatabase deviceB;
    late InMemoryCloudTransport cloud;

    setUp(() async {
      f = _Fixture();
      // Both tills booted with the shared, stale on-hand of 1.
      deviceA = await _bootDevice(f, startQty: 1);
      deviceB = await _bootDevice(f, startQty: 1);
      await setFlag(deviceA, 'feature.domain_rpcs_v2.record_sale', on: false);
      await setFlag(deviceB, 'feature.domain_rpcs_v2.record_sale', on: false);
      cloud = InMemoryCloudTransport(authUserId: 'user-1');
    });

    tearDown(() async {
      await cloud.dispose();
      await deviceA.close();
      await deviceB.close();
    });

    test(
        'two offline tills both sell 1, both push quantity=0 → cloud LWW keeps '
        'one row at 0 with TWO orders: 2 sold from a stock of 1, silently',
        () async {
      // Each till's LOCAL guard passes against the stale on-hand of 1.
      final orderA = await _sellOneUnit(deviceA, f, orderNumber: 'ORD-A');
      final orderB = await _sellOneUnit(deviceB, f, orderNumber: 'ORD-B');
      expect(orderA, isNotEmpty);
      expect(orderB, isNotEmpty);

      // Locally each device deducted to 0 with no error.
      expect((await deviceA.select(deviceA.inventory).getSingle()).quantity, 0);
      expect((await deviceB.select(deviceB.inventory).getSingle()).quantity, 0);

      // Both reconnect and push their absolute inventory row + order.
      await _drainToCloud(deviceA, cloud, tables: {'inventory', 'orders'});
      await _drainToCloud(deviceB, cloud, tables: {'inventory', 'orders'});

      // The cloud kept a SINGLE inventory row (natural-key LWW) at quantity 0…
      final cloudInventory = cloud.rowsOf('inventory');
      expect(cloudInventory, hasLength(1));
      expect(
        cloudInventory.single['quantity'],
        0,
        reason: 'LWW collapsed both pushes onto one quantity=0 row',
      );

      // …yet TWO orders were accepted. 2 units sold from a stock of 1, and the
      // cloud has no way to know: the mutable balance simply reads 0. This is
      // the silent oversell A-S3 makes impossible-to-absorb.
      expect(
        cloud.rowsOf('orders'),
        hasLength(2),
        reason: '2 sales committed against 1 unit of stock — the oversell',
      );
    });
  });

  group('A-S3 — v2 guarded RPC rejects the concurrent oversell', () {
    late _Fixture f;
    late AppDatabase deviceA;
    late AppDatabase deviceB;
    late InMemoryCloudTransport cloud;
    late SupabaseSyncService syncA;
    late SupabaseSyncService syncB;

    setUp(() async {
      f = _Fixture();
      deviceA = await _bootDevice(f, startQty: 1);
      deviceB = await _bootDevice(f, startQty: 1);
      await setFlag(deviceA, 'feature.domain_rpcs_v2.record_sale', on: true);
      await setFlag(deviceB, 'feature.domain_rpcs_v2.record_sale', on: true);

      cloud = InMemoryCloudTransport(authUserId: 'user-1');
      // The shared cloud inventory both devices last pulled: on-hand 1.
      cloud.seed('inventory', [
        {
          'id': f.inventoryId,
          'business_id': f.businessId,
          'product_id': f.productId,
          'store_id': f.storeId,
          'quantity': 1,
          'last_updated_at': _t0,
        },
      ]);

      // Faithful model of pos_record_sale_v2's server-authoritative guard
      // against the SHARED cloud inventory: for each line, lock+read the row,
      // reject on shortfall (P0001 insufficient_stock / inventory_row_missing),
      // else relative-decrement. The order is inserted only after every line
      // passes — a rejected sale rolls the whole RPC transaction back, so no
      // order (and no movement) persists. Idempotent on p_order_id. The RPC's
      // own SQL is verified separately at Tier-2 (pos_record_sale_v2_test.dart);
      // here we prove the CLIENT routes through it and handles the rejection.
      cloud.stubRpc('pos_record_sale_v2', (params) {
        final storeId = params['p_store_id'] as String;
        final orderId = params['p_order_id'] as String;
        final items = (params['p_items'] as List).cast<Map<String, dynamic>>();

        // Replay path: order already present → return without re-decrementing.
        final existing = cloud
            .rowsOf('orders')
            .where((o) => o['id'] == orderId)
            .toList();
        if (existing.isNotEmpty) {
          return {'inventory_after': <Map<String, dynamic>>[], 'replayed': true};
        }

        final invAfter = <Map<String, dynamic>>[];
        for (final it in items) {
          final pid = it['product_id'] as String?;
          if (pid == null) continue; // quick-sale line: bypass inventory
          final qty = it['quantity'] as int;
          final match = cloud
              .rowsOf('inventory')
              .where((r) => r['product_id'] == pid && r['store_id'] == storeId)
              .toList();
          if (match.isEmpty) {
            throw const PostgrestException(
              message: 'inventory_row_missing',
              code: 'P0001',
            );
          }
          final available = match.single['quantity'] as int;
          if (available < qty) {
            throw const PostgrestException(
              message: 'insufficient_stock',
              code: 'P0001',
            );
          }
          final newQty = available - qty;
          cloud.seed('inventory', [
            {...match.single, 'quantity': newQty, 'last_updated_at': _t1},
          ]);
          invAfter.add({
            'product_id': pid,
            'store_id': storeId,
            'quantity': newQty,
            'last_updated_at': _t1,
          });
        }
        // ON CONFLICT (id) DO NOTHING — reached only when all lines passed.
        cloud.seed('orders', [
          {
            'id': orderId,
            'business_id': f.businessId,
            'last_updated_at': _t1,
          },
        ]);
        return {'inventory_after': invAfter, 'replayed': false};
      });

      syncA = SupabaseSyncService(deviceA, cloud)..isOnline.value = true;
      syncB = SupabaseSyncService(deviceB, cloud)..isOnline.value = true;
    });

    tearDown(() async {
      await cloud.dispose();
      await deviceA.close();
      await deviceB.close();
    });

    test(
        'two offline tills both sell 1; the server accepts the first and '
        'REJECTS the second → cloud never below 0, the loser orphans visibly',
        () async {
      // Both pass their LOCAL pre-check against the stale on-hand of 1 and
      // enqueue a domain:pos_record_sale_v2 envelope.
      final orderA = await _sellOneUnit(deviceA, f, orderNumber: 'ORD-A');
      final orderB = await _sellOneUnit(deviceB, f, orderNumber: 'ORD-B');

      // Device A reconnects and flushes first — the server accepts it (1 → 0).
      await syncA.flushSale(orderA);

      // Device B flushes — the server's FOR UPDATE + quantity>=qty guard now
      // sees 0 on hand and REJECTS. flushSale surfaces the rejection instead of
      // printing a receipt for a sale the cloud refused.
      Object? caught;
      try {
        await syncB.flushSale(orderB);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<SaleSyncException>());
      expect(
        (caught! as SaleSyncException).errorMessage,
        contains('insufficient_stock'),
      );

      // On-hand went 1 → 0 exactly once and never below zero.
      expect(cloud.rowsOf('inventory').single['quantity'], 0);

      // Exactly ONE order reached the cloud ledger — device A's. Device B's
      // sale created no cloud order (the guarded RPC rolled back).
      final cloudOrders = cloud.rowsOf('orders');
      expect(cloudOrders, hasLength(1));
      expect(cloudOrders.single['id'], orderA);

      // Device B's rejected envelope is ORPHANED — visible + exportable on the
      // Sync Issues screen (Invariant #12), never silently dropped…
      final orphansB = await deviceB.select(deviceB.syncQueueOrphans).get();
      expect(orphansB, hasLength(1));
      expect(orphansB.single.actionType, 'domain:pos_record_sale_v2');
      expect(orphansB.single.reason, contains('insufficient_stock'));

      // …and it left the live queue (moved out, never left as a phantom
      // pending row that could re-push).
      final pendingB = await getPendingQueue(deviceB);
      expect(
        pendingB.where((r) => r.actionType == 'domain:pos_record_sale_v2'),
        isEmpty,
      );
    });

    test(
        'lost-ack replay: re-flushing an already-accepted sale is idempotent — '
        'no second decrement (exactly-once)', () async {
      final orderA = await _sellOneUnit(deviceA, f, orderNumber: 'ORD-A');

      // First flush accepts the sale (1 → 0) and marks the envelope done.
      await syncA.flushSale(orderA);
      expect(cloud.rowsOf('inventory').single['quantity'], 0);

      // Simulate a lost ack: the row is re-enqueued and flushed again. The RPC
      // is idempotent on p_order_id (ON CONFLICT DO NOTHING), so the replay
      // must NOT decrement a second time.
      await deviceA.syncDao.enqueue(
        'domain:pos_record_sale_v2',
        // Rebuild the same envelope shape flushSale looks up by p_order_id.
        _envelopeFor(f, orderId: orderA),
      );
      await syncA.flushSale(orderA);

      expect(
        cloud.rowsOf('inventory').single['quantity'],
        0,
        reason: 'replay is a no-op — on-hand stays 0, never -1',
      );
      expect(cloud.rowsOf('orders'), hasLength(1));
    });
  });
}

/// Minimal `domain:pos_record_sale_v2` payload matching what `createOrder`
/// enqueues, used to re-inject a lost-ack replay in the idempotency test.
String _envelopeFor(_Fixture f, {required String orderId}) {
  return jsonEncode({
    'p_business_id': f.businessId,
    'p_actor_id': f.staffId,
    'p_order_id': orderId,
    'p_order_number': 'ORD-A',
    'p_store_id': f.storeId,
    'p_payment_type': 'cash',
    'p_items': [
      {'product_id': f.productId, 'quantity': 1, 'unit_price_kobo': 100000},
    ],
    'p_status': 'completed',
    'p_amount_paid_kobo': 100000,
    'p_payment_method': 'cash',
  });
}
