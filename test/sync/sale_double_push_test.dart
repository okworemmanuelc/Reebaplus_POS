// sale_double_push_test.dart
//
// #835 — a long-cart checkout falsely failed at ccokwor. Checkout's foreground
// flushSale and the background drain (woken by the sale's own enqueue) each
// read the sale envelope as `pending` and BOTH called pos_record_sale_v2 at the
// same moment. The first call saved the sale; the duplicate hit 23505 on the
// order number, the till took that as a rejection and cancelled a sale the
// cloud had kept.
//
// Pins: a queue row is CLAIMED before its RPC, so overlapping pushers send it
// once; and flushSale waits for a background drain that holds the sale, so a
// real rejection still reaches the cashier before the receipt prints.

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';
import '../helpers/screen_harness.dart' show initTestSupabase;

const _saleAction = 'domain:pos_record_sale_v2';

void main() {
  late AppDatabase db;
  late String businessId;
  late InMemoryCloudTransport cloud;
  late SupabaseSyncService sync;
  late String storeId;
  late String staffId;
  late String productId;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (call) async => call.method == 'check' ? <String>['wifi'] : null,
        );
    await initTestSupabase();
  });

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
            name: 'Beer',
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
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: true);
  });

  tearDown(() async {
    await cloud.dispose();
    await db.close();
  });

  Future<String> sellOne() => db.ordersDao.createOrder(
        order: OrdersCompanion.insert(
          businessId: businessId,
          orderNumber: 'ORD-835',
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

  int saleCalls() =>
      cloud.rpcCalls.where((c) => c.name == 'pos_record_sale_v2').length;

  test('two overlapping pushers send the sale envelope exactly once', () async {
    final entered = Completer<void>();
    final gate = Completer<void>();
    cloud.stubRpc('pos_record_sale_v2', (_) async {
      if (!entered.isCompleted) entered.complete();
      await gate.future; // a long cart: the server is still saving
      return <String, dynamic>{};
    });

    final orderId = await sellOne();
    final row = (await getPendingQueue(db))
        .singleWhere((r) => r.actionType == _saleAction);

    // Pusher 1 (the background drain) is mid-call.
    final first = sync.pushDomainItemsForTesting([row], businessId, 'user-1');
    await entered.future;

    // Pusher 2 (checkout's flushSale) arrives while it is still in flight, and
    // a second drain holding the same stale snapshot tries too.
    await sync.flushSale(orderId);
    await sync.pushDomainItemsForTesting([row], businessId, 'user-1');

    gate.complete();
    await first;

    expect(saleCalls(), 1, reason: 'the row is claimed before its RPC');
    final after = await db.syncDao.getQueueItem(row.id);
    expect(after?.status, 'completed');
  });

  test('flushSale waits for the background drain holding the sale and still '
      'surfaces a real rejection', () async {
    final entered = Completer<void>();
    final gate = Completer<void>();
    cloud.stubRpc('pos_record_sale_v2', (_) async {
      if (!entered.isCompleted) entered.complete();
      await gate.future;
      throw const PostgrestException(
        message: 'insufficient_stock',
        code: 'P0001',
      );
    });

    final orderId = await sellOne();

    final drain = sync.runPushOnceForTesting();
    await entered.future;

    Object? error;
    var settled = false;
    final flush = sync.flushSale(orderId).then<void>(
      (_) => settled = true,
      onError: (Object e) {
        error = e;
        settled = true;
      },
    );

    await pumpEventQueue();
    expect(settled, isFalse, reason: 'waits while the drain holds the sale');

    gate.complete();
    await drain;
    await flush;

    expect(error, isA<SaleSyncException>());
    expect(saleCalls(), 1);
  });
}
