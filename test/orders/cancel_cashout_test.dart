import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// #172 (Money integrity #3, PRD #155) — **Cancel writes a compensating
/// cash-out row.** Cancelling a paid sale must record the money leaving on the
/// day it leaves, so a reviewed/banked sale day never changes behind the
/// owner's back:
///   1. the ORIGINAL sale payment row is left intact (never voided) — the sale
///      day's cash figure is unchanged;
///   2. a dated `refund` cash-out row lands on the CANCEL day, linked to the
///      order, for the goods actually paid;
///   3. the refund is derived from a real payment row (not a dead order status)
///      so reconciliation's Refunds figure is no longer ₦0.
///
/// Drives the full Checkout → Cancel path through `OrdersDao` on the v1 (live)
/// sync path — the A1 regression named in the PRD's Testing Decisions.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // v1 per-table path (the v2 cancel envelope is held off until it mints the
    // reversal); createOrder + markCancelled both post rows locally.
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
    await setFlag(db, 'feature.domain_rpcs_v2.cancel_order', on: false);
  });

  tearDown(() => db.close());

  Future<(String storeId, String staffId, String customerId)> seedBase() async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId), businessId: businessId, name: 'Cashier', pin: '0000'));
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    return (storeId, staffId, customerId);
  }

  Future<String> seedProduct(String storeId) async {
    final productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Beer',
        retailerPriceKobo: const Value(100000)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(100)));
    return productId;
  }

  // A cash sale of [qty] @ ₦1000, fully paid. Returns the order id.
  Future<String> sell(
    String storeId,
    String staffId,
    String customerId,
    String productId,
    int qty,
  ) async {
    final goodsKobo = qty * 100000;
    return db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: goodsKobo,
        netAmountKobo: goodsKobo,
        amountPaidKobo: Value(goodsKobo),
        paymentType: 'cash',
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
          quantity: qty,
          unitPriceKobo: 100000,
          totalKobo: goodsKobo,
        ),
      ],
      customerId: customerId,
      amountPaidKobo: goodsKobo,
      totalAmountKobo: goodsKobo,
      staffId: staffId,
      storeId: storeId,
    );
  }

  // Cash counted for a payment [type] within [day, day+1) — mirrors the
  // reconciliation's cash-flow bucketing (each row on its OWN created_at day,
  // voided rows excluded).
  Future<int> cashOnDay(String type, DateTime day) async {
    final next = day.add(const Duration(days: 1));
    final rows = await (db.select(db.paymentTransactions)
          ..where((p) =>
              p.type.equals(type) &
              p.voidedAt.isNull() &
              p.createdAt.isBiggerOrEqualValue(day) &
              p.createdAt.isSmallerThanValue(next)))
        .get();
    return rows.fold<int>(0, (s, r) => s + r.amountKobo);
  }

  test(
      'cancel leaves the sale day cash unchanged and posts a refund on the '
      'cancel day', () async {
    final (storeId, staffId, customerId) = await seedBase();
    final productId = await seedProduct(storeId);

    // A ₦2,000 paid sale, then backdate its rows to a prior day so the sale day
    // and the cancel day are distinct buckets.
    final orderId = await sell(storeId, staffId, customerId, productId, 2);
    // Whole-second precision: Drift stores DateTime as unix seconds, so a
    // microsecond-bearing value would not round-trip equal.
    final n = DateTime.now().subtract(const Duration(days: 4));
    final saleDay =
        DateTime(n.year, n.month, n.day, n.hour, n.minute, n.second);
    // The payment ledger is append-only (created_at is immutable) — production
    // never backdates a row. Drop the guard for this test-only backdate so the
    // sale day and cancel day fall in distinct buckets.
    await db.customStatement(
        'DROP TRIGGER IF EXISTS payment_transactions_immutable');
    await (db.update(db.paymentTransactions)
          ..where((p) => p.orderId.equals(orderId)))
        .write(PaymentTransactionsCompanion(createdAt: Value(saleDay)));
    await (db.update(db.orders)..where((o) => o.id.equals(orderId)))
        .write(OrdersCompanion(createdAt: Value(saleDay)));

    // Sale day cash before the cancel: the full ₦2,000.
    expect(await cashOnDay('sale', saleDay), 200000);

    // Floor to the second: stored createdAt round-trips at unix-second
    // granularity, so a microsecond-bearing bound would spuriously read as
    // "after" the refund row.
    final nowSec = DateTime.now();
    final beforeCancel =
        DateTime(nowSec.year, nowSec.month, nowSec.day, nowSec.hour,
            nowSec.minute, nowSec.second);
    await db.ordersDao.markCancelled(orderId, 'customer changed mind', staffId);

    // 1. The original sale row is untouched — never voided, still on the sale
    //    day. The sale day's cash figure is unchanged.
    final sale = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('sale')))
        .getSingle();
    expect(sale.voidedAt, isNull, reason: 'the sale row is never voided');
    expect(sale.createdAt, saleDay, reason: 'the sale stays on the sale day');
    expect(await cashOnDay('sale', saleDay), 200000,
        reason: 'a reviewed/banked sale day never shrinks behind the owner');

    // 2. A dated refund cash-out row lands on the CANCEL day (today), linked to
    //    the order, for the goods paid, with the sale tender's method.
    final refund = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('refund')))
        .getSingle();
    expect(refund.amountKobo, 200000);
    expect(refund.orderId, orderId);
    expect(refund.method, sale.method);
    expect(refund.voidedAt, isNull);
    expect(refund.createdAt.isBefore(beforeCancel), isFalse,
        reason: 'the refund lands on the cancel day, not the sale day');
    expect(refund.createdAt.difference(saleDay).inDays, greaterThan(1),
        reason: 'the refund is on the cancel day, distinct from the sale day');

    // 3. Net cash over the two days is zero (money in on the sale day, out on
    //    the cancel day) — but visibly, on the day each movement happened.
    expect(await cashOnDay('refund', refund.createdAt), 200000);
  });

  test('the refund row syncs so peers converge', () async {
    final (storeId, staffId, customerId) = await seedBase();
    final productId = await seedProduct(storeId);
    final orderId = await sell(storeId, staffId, customerId, productId, 1);

    await db.ordersDao.markCancelled(orderId, 'refund', staffId);

    final refund = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('refund')))
        .getSingle();
    final pending = await getPendingQueue(db);
    final enqueued = pending
        .where((r) => r.actionType == 'payment_transactions:upsert')
        .map(decodePayload)
        .where((p) => p['id'] == refund.id)
        .toList();
    expect(enqueued, hasLength(1),
        reason: 'the compensating refund row must push (a cancel reverses a '
            'sale the cloud accepted)');
    expect(enqueued.single['type'], 'refund');
  });

  test(
      'a deposit sale refunds only the goods portion — the deposit is released '
      'on the crate/wallet side', () async {
    // A money-track deposit sale: ₦1,000 goods + ₦500 deposit = ₦1,500 paid.
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
    final (storeId, staffId, customerId) = await seedBase();
    final mfrId = UuidV7.generate();
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: Value(mfrId),
        businessId: businessId,
        name: 'Star',
        depositAmountKobo: const Value(50000)));
    final productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Star Bottle',
        retailerPriceKobo: const Value(100000),
        manufacturerId: Value(mfrId),
        unit: const Value('Bottle'),
        trackEmpties: const Value(true)));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(100)));

    final orderId = await db.ordersDao.createOrder(
      order: OrdersCompanion.insert(
        businessId: businessId,
        orderNumber: 'ORD-${UuidV7.generate()}',
        customerId: Value(customerId),
        totalAmountKobo: 150000,
        netAmountKobo: 150000,
        amountPaidKobo: const Value(150000),
        paymentType: 'cash',
        status: 'pending',
        staffId: Value(staffId),
        storeId: Value(storeId),
        crateDepositPaidKobo: const Value(50000),
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
      customerId: customerId,
      amountPaidKobo: 150000,
      totalAmountKobo: 150000,
      staffId: staffId,
      storeId: storeId,
      crateDepositPaidByManufacturer: {mfrId: 50000},
    );

    // The sale row records the full ₦1,500 tendered (goods + deposit bundled).
    final sale = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('sale')))
        .getSingle();
    expect(sale.amountKobo, 150000);

    await db.ordersDao.markCancelled(orderId, 'refund', staffId);

    // The refund cash-out reverses only the ₦1,000 goods portion — the ₦500
    // deposit is released on the crate/wallet side (#162), not double-refunded.
    final refund = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('refund')))
        .getSingle();
    expect(refund.amountKobo, 100000,
        reason: 'goods paid = amountPaid − crateDepositPaid');
    // #162 still deflates deposits-held to 0 on the wallet side.
    expect(await db.walletTransactionsDao.getDepositsHeldKobo(customerId), 0);
  });
}
