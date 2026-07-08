// exactly_once_stock_integrity_test.dart
//
// Workstream A (#100) — exactly-once stock integrity.
//
// The headline defect: two tills sell the SAME last unit while briefly out of
// sync. Each runs its LOCAL stock guard (both pass against a stale on-hand of
// 1), both decrement to 0, and both push the ABSOLUTE `inventory.quantity = 0`
// row. `inventory` restore is an LWW natural-key cache (sync_registry.dart:
// isCache: true) — last-write-wins keeps a single row at quantity 0, so the
// cloud reads 0 on hand yet TWO units were sold from a stock of 1. No error is
// raised anywhere; the oversell is silent.
//
// A-S1 (this file, RED first): reproduce that silent oversell on the CURRENT v1
// path (flag OFF) — documents the bug. A-S3 flips the fixed behaviour in
// alongside it (the v2 guarded-RPC path rejects the second sale).

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

/// Shared ids so two devices agree on the same business / store / product /
/// inventory row — exactly as they would after pulling them from one cloud.
/// The shared `inventoryId` is load-bearing: the absolute-cache push upserts on
/// the natural key `(business_id, product_id, store_id)`, so both devices'
/// pushes collapse onto the SAME cloud row (LWW), which is the merge that hides
/// the oversell.
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
/// starting on-hand of [startQty] for the shared product.
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
}
