// #551 (PRD #337 slice e) — Return a crate-free Completed sale, tested at the
// Order Module seam against an in-memory Drift database.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/shared/services/credit_ledger_service.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

const _granted = GateContext(
  grantedKeys: {'sales.cancel'},
  roleRank: GateTier.manager,
  isReady: true,
);
const _denied = GateContext(
  grantedKeys: {},
  roleRank: GateTier.cashier,
  isReady: true,
);

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;
  late String ceoId;
  late String managerId;
  late String customerId;
  late String productId;
  late OrderService svc;

  Future<String> insertUser(String name) async {
    final id = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(id), businessId: businessId, name: name, pin: '0'));
    return id;
  }

  Future<void> addMember(String userId, String slug) async {
    final roleId = UuidV7.generate();
    await db.into(db.roles).insert(RolesCompanion.insert(
        id: Value(roleId), businessId: businessId, name: slug, slug: slug));
    await db.into(db.userBusinesses).insert(UserBusinessesCompanion.insert(
        id: Value(UuidV7.generate()),
        businessId: businessId,
        userId: userId,
        roleId: roleId));
  }

  Future<String> seedProduct({
    String unit = 'Piece',
    bool trackEmpties = false,
    int buying = 60000,
  }) async {
    final id = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: Value(id),
          businessId: businessId,
          name: 'P-${id.substring(0, 6)}',
          retailerPriceKobo: const Value(100000),
          buyingPriceKobo: Value(buying),
          unit: Value(unit),
          trackEmpties: Value(trackEmpties),
        ));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: id,
        storeId: storeId,
        quantity: const Value(50)));
    return id;
  }

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    staffId = await insertUser('Cashier');
    ceoId = await insertUser('Owner');
    managerId = await insertUser('Manager');
    await addMember(ceoId, 'ceo');
    await addMember(managerId, 'manager');
    customerId = await db.customersDao
        .addCustomer(CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    productId = await seedProduct();
    svc = OrderService(db);
  });

  tearDown(() => db.close());

  Map<String, dynamic> line(String? pid, int qty, {int price = 100000}) => {
        'id': pid,
        'qty': qty,
        'unitPriceKobo': price,
        'name': pid == null ? 'Odd job' : 'Item',
      };

  Future<String> sell(
    List<Map<String, dynamic>> cart, {
    String? customer,
    int? paid,
    String subType = 'cash',
  }) async {
    final total = cart.fold<int>(
        0, (s, l) => s + (l['unitPriceKobo'] as int) * (l['qty'] as int));
    final number = await svc.addOrder(
      customerId: customer,
      cart: cart,
      totalAmountKobo: total,
      amountPaidKobo: paid ?? total,
      paymentType: customer != null && (paid ?? total) == 0
          ? 'Credit Sale'
          : 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: subType,
    );
    return (await (db.select(db.orders)
              ..where((o) => o.orderNumber.equals(number)))
            .getSingle())
        .id;
  }

  Future<OrderData> order(String id) =>
      (db.select(db.orders)..where((o) => o.id.equals(id))).getSingle();

  Future<int> inv([String? pid]) async => (await (db.select(db.inventory)
            ..where((t) => t.productId.equals(pid ?? productId)))
          .getSingle())
      .quantity;

  Future<int> balance() => db.customersDao.getWalletBalanceKobo(customerId);

  Future<int> queueCount() async =>
      (await db.select(db.syncQueue).get()).length;

  Future<void> doReturn(
    String id, {
    Map<String, int> damaged = const {},
    String key = 'broken',
    GateContext gate = _granted,
  }) =>
      svc.returnCompletedSale(
        orderId: id,
        reason: 'Customer brought it back',
        staffId: managerId,
        gateContext: gate,
        damageReasonKey: key,
        damagedQtyByLine: damaged,
      );

  Future<List<OrderItemData>> itemsOf(String id) =>
      (db.select(db.orderItems)..where((i) => i.orderId.equals(id))).get();

  group('returnability', () {
    test('true for a crate-free completed sale', () async {
      final id = await sell([line(productId, 2)]);
      expect((await order(id)).status, 'completed');
      expect(await svc.isReturnable(id), isTrue);
    });

    test('false for pending and cancelled orders', () async {
      await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
          .write(const BusinessesCompanion(type: Value('Bar')));
      final bottle = await seedProduct(unit: 'Bottle', trackEmpties: true);
      final pending = await sell([line(bottle, 1)]);
      expect((await order(pending)).status, 'pending');
      expect(await svc.isReturnable(pending), isFalse);

      final plain = await sell([line(productId, 1)]);
      await doReturn(plain);
      expect(await svc.isReturnable(plain), isFalse);
    });

    test('false for a confirmed crate sale, even after track empties is '
        'switched off', () async {
      await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
          .write(const BusinessesCompanion(type: Value('Bar')));
      final bottle = await seedProduct(unit: 'Bottle', trackEmpties: true);
      final mfr = UuidV7.generate();
      await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
          id: Value(mfr), businessId: businessId, name: 'Brewery'));
      await (db.update(db.products)..where((p) => p.id.equals(bottle)))
          .write(ProductsCompanion(manufacturerId: Value(mfr)));
      final id = await sell([line(bottle, 1)], customer: customerId);
      expect(await db.select(db.orderCrateLines).get(), isNotEmpty);
      await svc.markAsCompleted(id, staffId, customerId: customerId,
          storeId: storeId);
      expect((await order(id)).status, 'completed');
      expect(await svc.isReturnable(id), isFalse);

      await (db.update(db.products)..where((p) => p.id.equals(bottle)))
          .write(const ProductsCompanion(trackEmpties: Value(false)));
      await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
          .write(const BusinessesCompanion(tracksEmptyCrates: Value(false)));
      expect(await svc.isReturnable(id), isFalse,
          reason: 'recorded crate history keeps it locked');
    });

    test('false for a walk-in crate sale', () async {
      await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
          .write(const BusinessesCompanion(type: Value('Bar')));
      final bottle = await seedProduct(unit: 'Bottle', trackEmpties: true);
      final id = await sell([line(bottle, 1)]);
      await svc.markAsCompleted(id, staffId, storeId: storeId);
      expect(await svc.isReturnable(id), isFalse);
    });
  });

  group('Return', () {
    test('cash sale: stock restored, dated cash refund, order cancelled',
        () async {
      final id = await sell([line(productId, 2)]);
      expect(await inv(), 48);
      await doReturn(id);
      final o = await order(id);
      expect(o.status, 'cancelled');
      expect(o.cancellationReason, 'Customer brought it back');
      expect(await inv(), 50);
      final refund = await (db.select(db.paymentTransactions)
            ..where((p) => p.orderId.equals(id) & p.type.equals('refund')))
          .getSingle();
      expect(refund.amountKobo, 200000);
      expect(refund.method, 'cash');
    });

    test('transfer sale refunds as a transfer', () async {
      final id = await sell([line(productId, 1)], subType: 'transfer');
      await doReturn(id);
      final refund = await (db.select(db.paymentTransactions)
            ..where((p) => p.orderId.equals(id) & p.type.equals('refund')))
          .getSingle();
      expect(refund.method, 'transfer');
    });

    test('credit sale: customer back to their pre-sale balance', () async {
      final before = await balance();
      final id = await sell([line(productId, 2)], customer: customerId, paid: 0);
      expect(await balance(), before - 200000);
      await doReturn(id);
      expect(await balance(), before);
      expect(await inv(), 50);
    });

    test('damaged units restock then write off: net = restocked - damaged',
        () async {
      final id = await sell([line(productId, 3)]);
      final item = (await itemsOf(id)).single;
      await doReturn(id, damaged: {item.id: 1}, key: 'spilled');
      expect(await inv(), 49, reason: '3 restocked, 1 written off');
      final adj = await (db.select(db.stockAdjustments)
            ..where((a) => a.productId.equals(productId)))
          .getSingle();
      expect(adj.quantityDiff, -1);
      expect(adj.reason, 'damage:spilled');
    });

    test('damaged bounds are enforced and nothing is written', () async {
      final id = await sell([line(productId, 3)]);
      final item = (await itemsOf(id)).single;
      final queue = await queueCount();
      for (final bad in [4, -1]) {
        await expectLater(
          doReturn(id, damaged: {item.id: bad}),
          throwsA(isA<ReturnRefusedException>()),
        );
      }
      await expectLater(
        doReturn(id, damaged: {'no-such-line': 1}),
        throwsA(isA<ReturnRefusedException>()),
      );
      expect((await order(id)).status, 'completed');
      expect(await inv(), 47);
      expect(await queueCount(), queue);
    });

    test('Quick Sale line: refunded with no stock movement, no damaged qty',
        () async {
      final id = await sell([line(null, 1, price: 50000)]);
      final item = (await itemsOf(id)).single;
      expect(item.productId, isNull);
      await expectLater(
        doReturn(id, damaged: {item.id: 1}),
        throwsA(isA<ReturnRefusedException>()),
      );
      await doReturn(id);
      expect((await order(id)).status, 'cancelled');
      expect(await inv(), 50);
      expect(await db.select(db.stockAdjustments).get(), isEmpty);
    });

    test('pending and crate-bearing orders are refused with nothing written',
        () async {
      await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
          .write(const BusinessesCompanion(type: Value('Bar')));
      final bottle = await seedProduct(unit: 'Bottle', trackEmpties: true);
      final pending = await sell([line(bottle, 1)]);
      final queue = await queueCount();
      await expectLater(
        doReturn(pending),
        throwsA(isA<ReturnRefusedException>()),
      );
      expect((await order(pending)).status, 'pending');
      expect(await queueCount(), queue);
      expect(await inv(bottle), 49);
    });

    test('a second Return is a no-op', () async {
      final id = await sell([line(productId, 2)]);
      await doReturn(id);
      final queue = await queueCount();
      final stock = await db.select(db.stockTransactions).get();
      await doReturn(id);
      expect(await queueCount(), queue);
      expect((await db.select(db.stockTransactions).get()).length,
          stock.length);
      expect(await inv(), 50);
    });

    test('a missing permission is refused before anything is written',
        () async {
      final id = await sell([line(productId, 1)]);
      final queue = await queueCount();
      await expectLater(
        doReturn(id, gate: _denied),
        throwsA(isA<GateDeniedError>()),
      );
      expect((await order(id)).status, 'completed');
      expect(await queueCount(), queue);
    });

    test('Mark-as-paid money stays as customer credit (no cash refund)',
        () async {
      final before = await balance();
      final id = await sell([line(productId, 2)], customer: customerId, paid: 0);
      await CreditLedgerService(db).topup(
        customerId: customerId,
        amountKobo: 200000,
        method: 'cash',
        staffId: staffId,
        storeId: storeId,
        orderId: id,
      );
      expect(await balance(), before);
      await doReturn(id);
      expect(await balance(), before + 200000,
          reason: 'goods reversed, the collected cash stays as credit');
      final refunds = await (db.select(db.paymentTransactions)
            ..where((p) => p.orderId.equals(id) & p.type.equals('refund')))
          .get();
      expect(refunds, isEmpty, reason: 'nothing was paid at Checkout');
    });

    test("other sales' COGS snapshots are unchanged", () async {
      final first = await sell([line(productId, 2)]);
      final second = await sell([line(productId, 3)]);
      final before = {
        for (final i in await itemsOf(second)) i.id: i.buyingPriceKobo,
      };
      await doReturn(first);
      final after = {
        for (final i in await itemsOf(second)) i.id: i.buyingPriceKobo,
      };
      expect(after, before);
      expect((await order(second)).status, 'completed');
    });

    test('activity log and CEO + Manager alerts are written', () async {
      final id = await sell([line(productId, 3)]);
      final item = (await itemsOf(id)).single;
      await doReturn(id, damaged: {item.id: 2});
      final logs = await (db.select(db.activityLogs)
            ..where((l) => l.action.equals('sale_returned')))
          .get();
      expect(logs, hasLength(1));
      expect(logs.single.userId, managerId);
      expect(logs.single.description, contains('2 unit(s) written off'));
      expect(logs.single.description, contains('3000.00'));
      expect(logs.single.description, contains('Customer brought it back'));
      final alerts = await (db.select(db.notifications)
            ..where((n) => n.type.equals('sale_returned')))
          .get();
      expect(alerts.map((n) => n.recipientUserId).toSet(), {ceoId, managerId});
      expect(alerts.every((n) => n.severity == 'warning'), isTrue);
      expect(alerts.every((n) => n.linkedRecordId == id), isTrue);
    });

    test('a failing side effect never fails the Return', () async {
      await db.customStatement('DROP TABLE notifications');
      final id = await sell([line(productId, 1)]);
      await doReturn(id);
      expect((await order(id)).status, 'cancelled');
    });

    test('every Return row (incl. the damage write-off) is held behind one '
        'reversal claim', () async {
      final id = await sell([line(productId, 2)]);
      final item = (await itemsOf(id)).single;
      await db.delete(db.syncQueue).go();
      await doReturn(id, damaged: {item.id: 1});
      final rows = await db.select(db.syncQueue).get();
      final claims = rows.where((r) => r.actionType == kReversalClaimAction);
      expect(claims, hasLength(1));
      final reversalId = decodePayload(claims.single)['p_reversal_id'];
      // The post-commit audit rows (activity log, alerts) are not part of the
      // reversal and ride the normal queue.
      final others = rows.where((r) =>
          r.actionType != kReversalClaimAction &&
          !r.actionType.startsWith('activity_logs') &&
          !r.actionType.startsWith('notifications'));
      expect(others.map((r) => r.actionType),
          contains('stock_adjustments:upsert'));
      expect(others.every((r) => r.heldByOrderId == reversalId), isTrue);
      final drainable =
          await db.syncDao.getPendingItems(businessId: businessId);
      expect(
        drainable.map((r) => r.actionType).where(
            (a) => !a.startsWith('activity_logs') && !a.startsWith('notifications')),
        [kReversalClaimAction],
      );
    });

    test('a rejected Return undoes its damage write-off too', () async {
      final id = await sell([line(productId, 3)]);
      final item = (await itemsOf(id)).single;
      await db.delete(db.syncQueue).go();
      await doReturn(id, damaged: {item.id: 1});
      final claim = (await db.select(db.syncQueue).get())
          .singleWhere((r) => r.actionType == kReversalClaimAction);
      final reversalId = decodePayload(claim)['p_reversal_id'] as String;
      expect(await inv(), 49);
      expect(
        await db.ordersDao
            .undoRejectedReversal(reversalId: reversalId, orderId: id),
        isTrue,
      );
      expect(await inv(), 47, reason: 'back to the post-sale shelf');
      expect(await db.select(db.stockAdjustments).get(), isEmpty);
    });
  });
}
