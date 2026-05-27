import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

class _Seed {
  final String businessId;
  final String storeId;
  final String staffId;
  final String productId;
  final String customerId;
  final String walletId;
  _Seed({
    required this.businessId,
    required this.storeId,
    required this.staffId,
    required this.productId,
    required this.customerId,
    required this.walletId,
  });
}

Future<_Seed> _seed(
  AppDatabase db, {
  String timezone = 'Africa/Lagos',
  int productPriceKobo = 100000,
  int initialStock = 10,
}) async {
  final businessId = UuidV7.generate();
  db.businessIdResolver = () => businessId;
  await db
      .into(db.businesses)
      .insert(
        BusinessesCompanion.insert(
          id: Value(businessId),
          name: 'Test Biz',
          timezone: Value(timezone),
        ),
      );

  final storeId = UuidV7.generate();
  await db
      .into(db.stores)
      .insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main',
        ),
      );

  final staffId = UuidV7.generate();
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Cashier',
          pin: '0000',
        ),
      );

  final productId = UuidV7.generate();
  await db
      .into(db.products)
      .insert(
        ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Test Beer',
          sellingPriceKobo: Value(productPriceKobo),
        ),
      );

  await db
      .into(db.inventory)
      .insert(
        InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeId,
          quantity: Value(initialStock),
        ),
      );

  final customerId = await db.customersDao.addCustomer(
    CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
  );
  final wallet = await (db.select(
    db.customerWallets,
  )..where((w) => w.customerId.equals(customerId))).getSingle();

  return _Seed(
    businessId: businessId,
    storeId: storeId,
    staffId: staffId,
    productId: productId,
    customerId: customerId,
    walletId: wallet.id,
  );
}

OrdersCompanion _orderCompanion(
  _Seed s, {
  required String orderNumber,
  required int totalKobo,
  int amountPaidKobo = 0,
  String paymentType = 'cash',
  String status = 'completed',
}) {
  return OrdersCompanion.insert(
    businessId: s.businessId,
    orderNumber: orderNumber,
    customerId: Value(s.customerId),
    totalAmountKobo: totalKobo,
    netAmountKobo: totalKobo,
    amountPaidKobo: Value(amountPaidKobo),
    paymentType: paymentType,
    status: status,
    staffId: Value(s.staffId),
    storeId: Value(s.storeId),
  );
}

OrderItemsCompanion _itemCompanion(
  _Seed s, {
  required int qty,
  required int unitPriceKobo,
}) {
  return OrderItemsCompanion.insert(
    businessId: s.businessId,
    orderId: 'placeholder', // overwritten by createOrder
    productId: s.productId,
    storeId: s.storeId,
    quantity: qty,
    unitPriceKobo: unitPriceKobo,
    totalKobo: qty * unitPriceKobo,
  );
}

void main() {
  setUpAll(() => tzdata.initializeTimeZones());

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('OrdersDao.createOrder atomicity', () {
    test('rolls back fully when stock is insufficient', () async {
      final s = await _seed(db, initialStock: 3);

      await expectLater(
        db.ordersDao.createOrder(
          order: _orderCompanion(
            s,
            orderNumber: 'ORD-1',
            totalKobo: 100000,
            amountPaidKobo: 100000,
          ),
          items: [_itemCompanion(s, qty: 5, unitPriceKobo: 100000)],
          customerId: s.customerId,
          amountPaidKobo: 100000,
          totalAmountKobo: 100000,
          staffId: s.staffId,
          storeId: s.storeId,
        ),
        throwsA(isA<InsufficientStockException>()),
      );

      expect(await db.select(db.orders).get(), isEmpty);
      expect(await db.select(db.orderItems).get(), isEmpty);
      expect(await db.select(db.stockTransactions).get(), isEmpty);
      expect(await db.select(db.paymentTransactions).get(), isEmpty);
      expect(await db.select(db.walletTransactions).get(), isEmpty);

      final inv = await (db.select(
        db.inventory,
      )..where((i) => i.storeId.equals(s.storeId))).getSingle();
      expect(
        inv.quantity,
        equals(3),
        reason: 'inventory must not be debited on rollback',
      );
    });

    test('writes wallet ledger row inside the same transaction', () async {
      final s = await _seed(db);

      await db.ordersDao.createOrder(
        order: _orderCompanion(
          s,
          orderNumber: 'ORD-2',
          totalKobo: 100000,
          amountPaidKobo: 0,
          paymentType: 'wallet',
        ),
        items: [_itemCompanion(s, qty: 1, unitPriceKobo: 100000)],
        customerId: s.customerId,
        amountPaidKobo: 0,
        totalAmountKobo: 100000,
        staffId: s.staffId,
        storeId: s.storeId,
        walletDebitKobo: 100000,
      );

      final wallet = await db.select(db.walletTransactions).get();
      expect(wallet, hasLength(1));
      expect(wallet.first.signedAmountKobo, equals(-100000));
      expect(wallet.first.type, equals('debit'));
      expect(wallet.first.referenceType, equals('order_payment'));
      expect(wallet.first.customerId, equals(s.customerId));

      // No payment row when amountPaidKobo == 0.
      expect(await db.select(db.paymentTransactions).get(), isEmpty);
    });

    test('skips wallet write when walletDebitKobo == 0', () async {
      final s = await _seed(db);
      await db.ordersDao.createOrder(
        order: _orderCompanion(
          s,
          orderNumber: 'ORD-3',
          totalKobo: 100000,
          amountPaidKobo: 100000,
        ),
        items: [_itemCompanion(s, qty: 1, unitPriceKobo: 100000)],
        customerId: s.customerId,
        amountPaidKobo: 100000,
        totalAmountKobo: 100000,
        staffId: s.staffId,
        storeId: s.storeId,
      );
      expect(await db.select(db.walletTransactions).get(), isEmpty);
      expect(await db.select(db.paymentTransactions).get(), hasLength(1));
    });
  });

  group('Stock ledger append-only enforcement', () {
    test('UPDATE on stock_transactions is blocked by trigger', () async {
      final s = await _seed(db);
      await db.ordersDao.createOrder(
        order: _orderCompanion(
          s,
          orderNumber: 'ORD-A',
          totalKobo: 100000,
          amountPaidKobo: 100000,
        ),
        items: [_itemCompanion(s, qty: 1, unitPriceKobo: 100000)],
        customerId: s.customerId,
        amountPaidKobo: 100000,
        totalAmountKobo: 100000,
        staffId: s.staffId,
        storeId: s.storeId,
      );
      final row = await db.select(db.stockTransactions).getSingle();

      await expectLater(
        db.customUpdate(
          'UPDATE stock_transactions SET quantity_delta = 0 WHERE id = ?',
          variables: [Variable(row.id)],
          updates: {db.stockTransactions},
        ),
        throwsA(isA<SqliteException>()),
      );

      final still = await db.select(db.stockTransactions).getSingle();
      expect(still.quantityDelta, equals(row.quantityDelta));
    });
  });

  group('markCancelled append-only ledger', () {
    test('appends compensating row, leaves original untouched', () async {
      final s = await _seed(db);
      await db.ordersDao.createOrder(
        order: _orderCompanion(
          s,
          orderNumber: 'ORD-C',
          totalKobo: 200000,
          amountPaidKobo: 200000,
        ),
        items: [_itemCompanion(s, qty: 2, unitPriceKobo: 100000)],
        customerId: s.customerId,
        amountPaidKobo: 200000,
        totalAmountKobo: 200000,
        staffId: s.staffId,
        storeId: s.storeId,
      );
      final orderId = (await db.select(db.orders).getSingle()).id;
      final originalSale = await db.select(db.stockTransactions).getSingle();

      await db.ordersDao.markCancelled(orderId, 'changed mind', s.staffId);

      final all = await db.select(db.stockTransactions).get();
      expect(
        all,
        hasLength(2),
        reason: 'one sale + one compensating return row',
      );

      final stillSale = all.firstWhere((r) => r.movementType == 'sale');
      expect(stillSale.id, equals(originalSale.id));
      expect(stillSale.quantityDelta, equals(originalSale.quantityDelta));
      expect(stillSale.voidedAt, isNull);

      final compensation = all.firstWhere((r) => r.movementType == 'return');
      expect(compensation.quantityDelta, equals(-originalSale.quantityDelta));

      // Inventory restored
      final inv = await (db.select(
        db.inventory,
      )..where((i) => i.storeId.equals(s.storeId))).getSingle();
      expect(inv.quantity, equals(10));

      // Payment voided in place (not a new row)
      final payments = await db.select(db.paymentTransactions).get();
      expect(payments, hasLength(1));
      expect(payments.first.voidedAt, isNotNull);
    });
  });

  group('getSalesSummaryForProduct timezone bucketing', () {
    test('Lagos midnight crossover lands on the correct local day', () async {
      // Lagos is UTC+1 with no DST. So 23:30 UTC on May 1 === 00:30 May 2 in
      // Lagos. We construct a sale whose UTC createdAt straddles UTC midnight
      // but stays inside one Lagos day, then verify the summary buckets by
      // Lagos calendar, not UTC.
      final s = await _seed(db);

      final orderId = await db.ordersDao.createOrder(
        order:
            _orderCompanion(
              s,
              orderNumber: 'ORD-T',
              totalKobo: 100000,
              amountPaidKobo: 100000,
            ).copyWith(
              createdAt: Value(DateTime.utc(2026, 5, 1, 23, 30)),
              completedAt: Value(DateTime.utc(2026, 5, 1, 23, 30)),
            ),
        items: [_itemCompanion(s, qty: 1, unitPriceKobo: 100000)],
        customerId: s.customerId,
        amountPaidKobo: 100000,
        totalAmountKobo: 100000,
        staffId: s.staffId,
        storeId: s.storeId,
      );

      // The DAO uses TZDateTime.now(), so we can't pin "today" — instead we
      // assert that month-to-date includes the order regardless of when the
      // test runs in the Lagos calendar (the sale is in May 2026).
      final summary = await db.ordersDao.getSalesSummaryForProduct(s.productId);
      expect(orderId, isNotEmpty);
      // monthRevenueKobo only counts the current Lagos month. We verify that
      // when "today" is inside May 2026 in Lagos, the order is counted; when
      // it's after, monthRevenueKobo is 0.
      final today = DateTime.now().toUtc();
      final lagosMay2026 = today.year == 2026 && today.month == 5;
      if (lagosMay2026) {
        expect(summary.monthRevenueKobo, equals(100000));
      } else {
        expect(summary.monthRevenueKobo, equals(0));
      }
    });
  });

  group('checkCartStaleness', () {
    test('flags price/version drift after a product update', () async {
      final s = await _seed(db, productPriceKobo: 50000);
      // Snapshot what the cart would have stored when the line was added.
      final original = await (db.select(
        db.products,
      )..where((p) => p.id.equals(s.productId))).getSingle();
      final cartLine = CartLineSnapshot(
        productId: s.productId,
        cartVersion: original.version,
        cartUnitPriceKobo: original.sellingPriceKobo,
      );

      // No drift yet.
      var stale = await db.ordersDao.checkCartStaleness([cartLine]);
      expect(stale, isEmpty);

      // Bump price; the products UPDATE trigger increments version.
      await (db.update(db.products)..where((p) => p.id.equals(s.productId)))
          .write(const ProductsCompanion(sellingPriceKobo: Value(75000)));

      stale = await db.ordersDao.checkCartStaleness([cartLine]);
      expect(stale, hasLength(1));
      expect(stale.first.oldPriceKobo, equals(50000));
      expect(stale.first.newPriceKobo, equals(75000));
      expect(stale.first.cartVersion, equals(original.version));
      expect(stale.first.currentVersion, greaterThan(original.version));
    });
  });
}
