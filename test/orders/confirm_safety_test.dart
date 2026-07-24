// #171 Confirm safety — idempotency + seller attribution, at the Order module's
// DAO/service transaction boundary against in-memory Drift (the seam the PRD
// names; prior art: order_module_test.dart's Confirm settlement test).
//
// Asserts external behaviour only — resulting rows, derived balances, and the
// order header — never internal call order:
//   * Double-Confirm across two "devices" (two Confirm calls on the converged
//     DB, by two different confirmers) settles the crate deposit exactly ONCE.
//   * Confirm records `confirmed_by` and leaves the seller's `staff_id`
//     untouched (the sale stays credited to who sold it).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/orders/crate_return_input.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // A crate-tracking business, and the local (v1) record-sale path so
    // createOrder writes order_crate_lines itself.
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
  });

  tearDown(() => db.close());

  // Seeds a money-track (deposit-held) order for `crates` crates of one brand
  // and returns (orderId, mfrId, sellerId, confirmerId, customerId, storeId).
  Future<
      ({
        String orderId,
        String mfrId,
        String sellerId,
        String confirmerId,
        String customerId,
        String storeId,
        int depositKobo,
      })> seedMoneyTrackOrder({int crates = 5, int rateKobo = 50000}) async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
              id: Value(storeId), businessId: businessId, name: 'Main'),
        );
    final sellerId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(sellerId),
        businessId: businessId,
        name: 'Seller',
        pin: '0000'));
    final confirmerId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(confirmerId),
        businessId: businessId,
        name: 'Confirmer',
        pin: '0000'));
    final customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
    );

    final mfrId = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
          id: Value(mfrId),
          businessId: businessId,
          name: 'Star',
          depositAmountKobo: Value(rateKobo),
        ));
    final productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Star Bottle',
          retailerPriceKobo: const Value(100000),
          manufacturerId: Value(mfrId),
          unit: const Value('Bottle'),
          trackEmpties: const Value(true),
        ));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeId,
          quantity: const Value(100),
        ));

    final depositKobo = rateKobo * crates;
    final goodsKobo = 100000 * crates;
    final orderId = await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: goodsKobo + depositKobo,
        netAmountKobo: goodsKobo + depositKobo,
        amountPaidKobo: Value(goodsKobo + depositKobo),
        paymentType: 'cash',
        status: 'pending',
        staffId: Value(sellerId), // the SELLER
        storeId: Value(storeId),
      ),
      items: [
        OrderItemsCompanion.insert(
          businessId: businessId,
          orderId: 'placeholder',
          productId: Value(productId),
          storeId: storeId,
          quantity: crates,
          unitPriceKobo: 100000,
          totalKobo: goodsKobo,
        ),
      ],
      customerId: customerId,
      amountPaidKobo: goodsKobo + depositKobo,
      totalAmountKobo: goodsKobo + depositKobo,
      staffId: sellerId,
      storeId: storeId,
      crateDepositPaidByManufacturer: {mfrId: depositKobo},
    );

    return (
      orderId: orderId,
      mfrId: mfrId,
      sellerId: sellerId,
      confirmerId: confirmerId,
      customerId: customerId,
      storeId: storeId,
      depositKobo: depositKobo,
    );
  }

  Future<int> countRefundRows(String orderId) async {
    final rows = await (db.select(db.walletTransactions)
          ..where((t) =>
              t.orderId.equals(orderId) &
              t.referenceType.equals('crate_refund')))
        .get();
    return rows.length;
  }

  Future<int> emptyStock(String mfrId) async {
    final m = await (db.select(db.manufacturers)..where((x) => x.id.equals(mfrId)))
        .getSingle();
    return m.emptyCrateStock;
  }

  group('Idempotency — double Confirm settles the deposit once', () {
    test('two devices confirming the same order refund + restock exactly once',
        () async {
      final s = await seedMoneyTrackOrder(crates: 5, rateKobo: 50000);
      final svc = OrderService(db);
      final fullReturn = [
        CrateReturnLine(
          manufacturerId: s.mfrId,
          takenCrates: 5,
          returnedCrates: 5,
          rateKobo: 50000,
          paidKobo: s.depositKobo,
        ),
      ];

      // Device A confirms.
      await svc.markAsCompleted(s.orderId, s.confirmerId,
          customerId: s.customerId,
          storeId: s.storeId,
          crateReturns: fullReturn);

      expect(await countRefundRows(s.orderId), 1);
      expect(await emptyStock(s.mfrId), 5);
      final balAfterFirst =
          await db.walletTransactionsDao.getBalanceKobo(s.customerId);

      // Device B confirms the SAME (now-completed) order — must be a no-op.
      await svc.markAsCompleted(s.orderId, s.confirmerId,
          customerId: s.customerId,
          storeId: s.storeId,
          crateReturns: fullReturn);

      expect(await countRefundRows(s.orderId), 1,
          reason: 'deposit refunded once, not twice');
      expect(await emptyStock(s.mfrId), 5,
          reason: 'physical empties credited once, not twice');
      expect(await db.walletTransactionsDao.getBalanceKobo(s.customerId),
          balAfterFirst,
          reason: 'the second Confirm posts no wallet legs');

      final order = await db.ordersDao.findById(s.orderId);
      expect(order!.status, 'completed');
    });

    test('markCompleted alone is idempotent (status re-read aborts a re-run)',
        () async {
      final s = await seedMoneyTrackOrder();
      await db.ordersDao.markCompleted(s.orderId, s.confirmerId);
      final first = await db.ordersDao.findById(s.orderId);
      expect(first!.status, 'completed');
      final firstCompletedAt = first.completedAt;

      // A second markCompleted with a different confirmer must not touch it.
      await db.ordersDao.markCompleted(s.orderId, s.sellerId);
      final second = await db.ordersDao.findById(s.orderId);
      expect(second!.confirmedBy, s.confirmerId,
          reason: 'confirmedBy is stamped by the FIRST confirm only');
      expect(second.completedAt, firstCompletedAt,
          reason: 'the second call was a no-op');
    });
  });

  group('Seller attribution — staff_id preserved, confirmed_by recorded', () {
    test('Confirm keeps the seller and records the confirmer separately',
        () async {
      final s = await seedMoneyTrackOrder();
      expect((await db.ordersDao.findById(s.orderId))!.staffId, s.sellerId);

      await OrderService(db).markAsCompleted(s.orderId, s.confirmerId,
          customerId: s.customerId,
          storeId: s.storeId,
          crateReturns: [
            CrateReturnLine(
              manufacturerId: s.mfrId,
              takenCrates: 5,
              returnedCrates: 5,
              rateKobo: 50000,
              paidKobo: s.depositKobo,
            ),
          ]);

      final order = await db.ordersDao.findById(s.orderId);
      expect(order!.staffId, s.sellerId,
          reason: 'the sale stays credited to who sold it (#171)');
      expect(order.confirmedBy, s.confirmerId,
          reason: 'the confirmer is recorded separately on confirmed_by');
    });
  });
}
