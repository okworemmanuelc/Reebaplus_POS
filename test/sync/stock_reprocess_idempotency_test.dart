// stock_reprocess_idempotency_test.dart
//
// Workstream A (#100), A-S5(c): the append-only ledgers are the truth and the
// balances they feed (`inventory`, `*_crate_balances`) are caches. Reprocessing
// an already-applied economic event — the pull that reflects the till's OWN
// just-pushed sale, or a retry, or a broadcast-triggered re-pull — must be a
// NO-OP, never a second decrement.
//
// This pins the property the whole exactly-once story leans on: because the
// stock ledger row is id-keyed (append-only) and the inventory cache is pushed
// as an ABSOLUTE value (not a delta), restoring the same rows again cannot move
// the balance. (A-S3's lost-ack test pins the same idempotency on the PUSH
// side, via the RPC's `ON CONFLICT (id) DO NOTHING`; this pins the PULL side.)

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late InMemoryCloudTransport transport;
  late SupabaseSyncService sync;
  late String storeId;
  late String productId;
  late String staffId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    transport = InMemoryCloudTransport(authUserId: 'user-1');
    sync = SupabaseSyncService(db, transport);

    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main',
          ),
        );
    staffId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(staffId),
            businessId: businessId,
            name: 'Cashier',
            pin: '0000',
          ),
        );
    productId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Beer',
            retailerPriceKobo: const Value(100000),
          ),
        );
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            quantity: const Value(5),
          ),
        );
    // v1 path so the sale writes local order_items / stock_transactions /
    // inventory rows that a pull would later bring back to the same device.
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
  });

  tearDown(() async {
    await transport.dispose();
    await db.close();
  });

  test(
      "reprocessing the till's own just-pushed sale (inventory cache + stock "
      'ledger) does not double-decrement', () async {
    // Sell 1 → inventory 5 → 4, one append-only stock_transactions row (−1).
    final orderId = await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-1',
        totalAmountKobo: 100000,
        netAmountKobo: 100000,
        amountPaidKobo: const Value(100000),
        paymentType: 'cash',
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
          quantity: 1,
          unitPriceKobo: 100000,
          totalKobo: 100000,
        ),
      ],
      amountPaidKobo: 100000,
      totalAmountKobo: 100000,
      staffId: staffId,
      storeId: storeId,
      paymentMethod: 'cash',
    );
    expect((await db.select(db.inventory).getSingle()).quantity, 4);
    final stockRow = (await db.select(db.stockTransactions).get()).single;
    final inv = await db.select(db.inventory).getSingle();

    // Simulate "already pushed": drain the outbox so the Invariant #12
    // clobber-guard no longer shields these rows (it protects only UNconfirmed
    // rows) — the pull that follows a confirmed push is what we're modelling.
    await db.delete(db.syncQueue).go();

    // The pull brings the device's OWN rows back (identical ids + values), just
    // as `_restoreTableData` applies a page. The inventory cache is absolute,
    // the ledger row is id-keyed.
    Map<String, dynamic> stockCloudRow() => {
          'id': stockRow.id,
          'business_id': businessId,
          'product_id': productId,
          'location_id': storeId,
          'quantity_delta': -1,
          'movement_type': 'sale',
          'order_id': orderId,
          'performed_by': staffId,
          'created_at': stockRow.createdAt.toIso8601String(),
          'last_updated_at': stockRow.lastUpdatedAt.toIso8601String(),
        };
    await sync.restoreTableDataForTesting('inventory', [
      {
        'id': inv.id,
        'business_id': businessId,
        'product_id': productId,
        'store_id': storeId,
        'quantity': 4,
        'created_at': inv.createdAt.toIso8601String(),
        'last_updated_at': inv.lastUpdatedAt.toIso8601String(),
      },
    ]);
    await sync.restoreTableDataForTesting('stock_transactions', [
      stockCloudRow(),
    ]);

    // No second decrement: on-hand stays 4, the ledger stays one row.
    expect(
      (await db.select(db.inventory).getSingle()).quantity,
      4,
      reason: 'reprocessing the pushed inventory cache is a no-op',
    );
    expect(
      await db.select(db.stockTransactions).get(),
      hasLength(1),
      reason: 'the id-keyed ledger row re-restores without a duplicate',
    );

    // Reprocess AGAIN (a second pull / a broadcast-triggered re-pull) — still
    // idempotent: the event is applied exactly once.
    await sync.restoreTableDataForTesting('stock_transactions', [
      stockCloudRow(),
    ]);
    expect(await db.select(db.stockTransactions).get(), hasLength(1));
    expect((await db.select(db.inventory).getSingle()).quantity, 4);

    // And the on-hand equals opening + SUM(ledger deltas) — the balance is a
    // faithful projection of the append-only ledger, not an independent counter
    // that can drift under reprocessing.
    final deltaSum = (await db.select(db.stockTransactions).get())
        .fold<int>(0, (s, r) => s + r.quantityDelta);
    expect(5 + deltaSum, 4);
  });
}
