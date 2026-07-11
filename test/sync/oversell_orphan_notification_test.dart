// oversell_orphan_notification_test.dart
//
// Oversell recovery — Slice 1 (notify the cashier). When the guarded
// pos_record_sale_v2 permanently REJECTS a sale (a concurrent till took the
// last unit), the envelope orphans (Invariant #12, visible on Sync Issues) AND
// an alert notification is fired to the cashier who rang it — targeted via
// `recipientUserId` and linked to the order via `linkedRecordId` so the UI can
// offer a one-tap cancel. This test pins that the rejection actively surfaces
// to the cashier, not only on the Sync Issues screen.

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late InMemoryCloudTransport cloud;
  late SupabaseSyncService sync;
  late String storeId;
  late String staffId;
  late String productId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    cloud = InMemoryCloudTransport(authUserId: 'user-1');
    sync = SupabaseSyncService(db, cloud)..isOnline.value = true;

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
            name: 'Last Beer',
            retailerPriceKobo: const Value(100000),
          ),
        );
    // Local on-hand 1 so the LOCAL pre-check passes and the envelope enqueues;
    // the server then rejects (another till already took the unit).
    await db.into(db.inventory).insert(
          InventoryCompanion.insert(
            businessId: businessId,
            productId: productId,
            storeId: storeId,
            quantity: const Value(1),
          ),
        );
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);

    // The server always rejects this sale — insufficient_stock (P0001).
    cloud.stubRpc('pos_record_sale_v2', (_) {
      throw const PostgrestException(
        message: 'insufficient_stock',
        code: 'P0001',
      );
    });
  });

  tearDown(() async {
    await cloud.dispose();
    await db.close();
  });

  Future<String> sellOne() => db.ordersDao.createOrder(
        order: OrdersCompanion.insert(
          businessId: businessId,
          orderNumber: 'ORD-REJ',
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

  test(
      'a server-rejected sale fires an alert notification to the cashier, '
      'linked to the order', () async {
    final orderId = await sellOne();

    // No notification yet — only the local optimistic sale exists.
    expect(await db.select(db.notifications).get(), isEmpty);

    // Flush → the RPC rejects → the envelope orphans → the cashier is notified.
    await expectLater(sync.flushSale(orderId), throwsA(isA<SaleSyncException>()));

    final notes = await db.select(db.notifications).get();
    expect(notes, hasLength(1));
    final n = notes.single;
    expect(n.type, 'sale_rejected');
    expect(n.severity, 'alert');
    expect(n.linkedRecordId, orderId,
        reason: 'links to the order so the UI can offer a cancel');
    expect(n.recipientUserId, staffId,
        reason: 'targeted at the cashier who rang the sale');
    expect(n.message.toLowerCase(), contains('out of stock'));

    // It is enqueued to sync like any other notification.
    final queued = await getPendingQueue(db);
    expect(
      queued.where((r) => r.actionType == 'notifications:upsert'),
      isNotEmpty,
    );
  });
}
