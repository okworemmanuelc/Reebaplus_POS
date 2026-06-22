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

  _Seed({
    required this.businessId,
    required this.storeId,
    required this.staffId,
    required this.productId,
    required this.customerId,
  });
}

Future<_Seed> _seed(
  AppDatabase db, {
  String? businessIdInput,
  String timezone = 'Africa/Lagos',
  int productPriceKobo = 100000,
  int initialStock = 10,
}) async {
  final businessId = businessIdInput ?? UuidV7.generate();
  db.businessIdResolver = () => businessId;
  await db.into(db.businesses).insert(
        BusinessesCompanion.insert(
          id: Value(businessId),
          name: 'Test Biz',
          timezone: Value(timezone),
        ),
      );

  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main',
        ),
      );

  final staffId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Cashier',
          pin: '0000',
        ),
      );

  final productId = UuidV7.generate();
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Test Beer',
          retailerPriceKobo: Value(productPriceKobo),
        ),
      );

  await db.into(db.inventory).insert(
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

  return _Seed(
    businessId: businessId,
    storeId: storeId,
    staffId: staffId,
    productId: productId,
    customerId: customerId,
  );
}

Future<void> _insertOrder(
  AppDatabase db,
  _Seed s, {
  required String id,
  required String orderNumber,
  required String status,
  required DateTime createdAt,
  String? storeId,
  String? customerId,
  String? customerName,
  String? businessId,
}) async {
  String resolvedCustomerId = customerId ?? s.customerId;
  if (customerName != null) {
    resolvedCustomerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId ?? s.businessId, name: customerName),
    );
  }

  await db.into(db.orders).insert(
        OrdersCompanion.insert(
          id: Value(id),
          businessId: businessId ?? s.businessId,
          orderNumber: orderNumber,
          customerId: Value(resolvedCustomerId),
          totalAmountKobo: 1000,
          netAmountKobo: 1000,
          amountPaidKobo: const Value(1000),
          paymentType: 'cash',
          status: status,
          storeId: Value(storeId ?? s.storeId),
          createdAt: Value(createdAt),
        ),
      );
}

Future<void> _insertOrderItem(
  AppDatabase db,
  _Seed s, {
  required String orderId,
  required String productId,
  required int quantity,
  required int unitPriceKobo,
  String? businessId,
}) async {
  await db.into(db.orderItems).insert(
        OrderItemsCompanion.insert(
          businessId: businessId ?? s.businessId,
          orderId: orderId,
          productId: Value(productId),
          storeId: s.storeId,
          quantity: quantity,
          unitPriceKobo: unitPriceKobo,
          totalKobo: quantity * unitPriceKobo,
        ),
      );
}

void main() {
  setUpAll(() => tzdata.initializeTimeZones());

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('Orders Keysets Pagination Tests', () {
    test('1. Same-second boundary (critical case)', () async {
      final s = await _seed(db);

      // Create orders:
      // identical second boundary has 5 orders: order-3, order-4, order-5, order-6, order-7
      final t1 = DateTime(2026, 6, 22, 12, 0, 0);
      final t2 = DateTime(2026, 6, 22, 12, 0, 1);
      final t3 = DateTime(2026, 6, 22, 12, 0, 2);

      await _insertOrder(db, s, id: 'order-1', orderNumber: 'ORD-1', status: 'completed', createdAt: t1);
      await _insertOrder(db, s, id: 'order-2', orderNumber: 'ORD-2', status: 'completed', createdAt: t1);

      await _insertOrder(db, s, id: 'order-3', orderNumber: 'ORD-3', status: 'completed', createdAt: t2);
      await _insertOrder(db, s, id: 'order-4', orderNumber: 'ORD-4', status: 'completed', createdAt: t2);
      await _insertOrder(db, s, id: 'order-5', orderNumber: 'ORD-5', status: 'completed', createdAt: t2);
      await _insertOrder(db, s, id: 'order-6', orderNumber: 'ORD-6', status: 'completed', createdAt: t2);
      await _insertOrder(db, s, id: 'order-7', orderNumber: 'ORD-7', status: 'completed', createdAt: t2);

      await _insertOrder(db, s, id: 'order-8', orderNumber: 'ORD-8', status: 'completed', createdAt: t3);
      await _insertOrder(db, s, id: 'order-9', orderNumber: 'ORD-9', status: 'completed', createdAt: t3);

      // Page through with limit: 2
      final List<OrderWithItems> allPages = [];
      ({DateTime createdAt, String id})? cursor;

      while (true) {
        final page = await db.ordersDao.getOrdersPage(
          status: 'completed',
          cursor: cursor,
          limit: 2,
        );
        if (page.isEmpty) break;
        allPages.addAll(page);
        final last = page.last;
        cursor = (createdAt: last.order.createdAt, id: last.order.id);
      }

      // Assert global order is created_at DESC, id DESC
      expect(allPages, hasLength(9));
      expect(allPages[0].order.id, equals('order-9'));
      expect(allPages[1].order.id, equals('order-8'));
      expect(allPages[2].order.id, equals('order-7'));
      expect(allPages[3].order.id, equals('order-6'));
      expect(allPages[4].order.id, equals('order-5'));
      expect(allPages[5].order.id, equals('order-4'));
      expect(allPages[6].order.id, equals('order-3'));
      expect(allPages[7].order.id, equals('order-2'));
      expect(allPages[8].order.id, equals('order-1'));
    });

    test('2. Page size / hasMore semantics', () async {
      final s = await _seed(db);
      final t = DateTime(2026, 6, 22, 12, 0, 0);

      // Scenario A: partial last page (5 orders total, limit 2)
      for (int i = 1; i <= 5; i++) {
        await _insertOrder(
          db,
          s,
          id: 'order-$i',
          orderNumber: 'ORD-$i',
          status: 'completed',
          createdAt: t.add(Duration(seconds: i)),
        );
      }

      final page1 = await db.ordersDao.getOrdersPage(status: 'completed', limit: 2);
      expect(page1, hasLength(2));
      final last1 = page1.last;

      final page2 = await db.ordersDao.getOrdersPage(
        status: 'completed',
        limit: 2,
        cursor: (createdAt: last1.order.createdAt, id: last1.order.id),
      );
      expect(page2, hasLength(2));
      final last2 = page2.last;

      final page3 = await db.ordersDao.getOrdersPage(
        status: 'completed',
        limit: 2,
        cursor: (createdAt: last2.order.createdAt, id: last2.order.id),
      );
      expect(page3, hasLength(1)); // Partial last page!

      // Scenario B: exact-multiple count (4 orders total, limit 2)
      // Clean up orders table first
      await db.delete(db.orders).go();

      for (int i = 1; i <= 4; i++) {
        await _insertOrder(
          db,
          s,
          id: 'order-$i',
          orderNumber: 'ORD-$i',
          status: 'completed',
          createdAt: t.add(Duration(seconds: i)),
        );
      }

      final mPage1 = await db.ordersDao.getOrdersPage(status: 'completed', limit: 2);
      expect(mPage1, hasLength(2));
      final mLast1 = mPage1.last;

      final mPage2 = await db.ordersDao.getOrdersPage(
        status: 'completed',
        limit: 2,
        cursor: (createdAt: mLast1.order.createdAt, id: mLast1.order.id),
      );
      expect(mPage2, hasLength(2));
      final mLast2 = mPage2.last;

      final mPage3 = await db.ordersDao.getOrdersPage(
        status: 'completed',
        limit: 2,
        cursor: (createdAt: mLast2.order.createdAt, id: mLast2.order.id),
      );
      expect(mPage3, isEmpty); // Returns empty, no infinite loop
    });

    test('3. Filter push-down', () async {
      final s = await _seed(db);

      // Create custom store
      final otherStoreId = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(otherStoreId),
              businessId: s.businessId,
              name: 'Other Store',
            ),
          );

      final t1 = DateTime(2026, 6, 20, 10, 0, 0);
      final t2 = DateTime(2026, 6, 21, 10, 0, 0);

      await _insertOrder(
        db,
        s,
        id: 'ord-a',
        orderNumber: 'ORD-100',
        status: 'completed',
        createdAt: t2,
        customerName: 'Alice',
        storeId: s.storeId,
      );
      await _insertOrder(
        db,
        s,
        id: 'ord-b',
        orderNumber: 'ORD-200',
        status: 'completed',
        createdAt: t2,
        customerName: 'Bob',
        storeId: otherStoreId,
      );
      await _insertOrder(
        db,
        s,
        id: 'ord-c',
        orderNumber: 'ORD-300',
        status: 'completed',
        createdAt: t1,
        storeId: s.storeId,
      );

      // A. Store lock filter
      final store1Orders = await db.ordersDao.getOrdersPage(status: 'completed', storeId: s.storeId);
      expect(store1Orders, hasLength(2));
      expect(store1Orders.any((o) => o.order.id == 'ord-b'), isFalse);

      // B. Date range filter
      final dateFiltered = await db.ordersDao.getOrdersPage(
        status: 'completed',
        from: DateTime(2026, 6, 21, 0, 0, 0),
        to: DateTime(2026, 6, 21, 23, 59, 59),
      );
      expect(dateFiltered, hasLength(2));
      expect(dateFiltered.any((o) => o.order.id == 'ord-c'), isFalse);

      // C. Search filters
      final searchAlice = await db.ordersDao.getOrdersPage(status: 'completed', search: 'Alice');
      expect(searchAlice, hasLength(1));
      expect(searchAlice.first.order.id, equals('ord-a'));

      final searchOrdNum = await db.ordersDao.getOrdersPage(status: 'completed', search: '200');
      expect(searchOrdNum, hasLength(1));
      expect(searchOrdNum.first.order.id, equals('ord-b'));
    });

    test('4. Business scoping', () async {
      final bizId1 = UuidV7.generate();
      final s1 = await _seed(db, businessIdInput: bizId1);

      final bizId2 = UuidV7.generate();
      db.businessIdResolver = () => bizId2;
      final s2 = await _seed(db, businessIdInput: bizId2);

      final t = DateTime(2026, 6, 22, 12, 0, 0);

      await _insertOrder(db, s1, id: 'ord-biz1', orderNumber: 'ORD-B1', status: 'completed', createdAt: t, businessId: bizId1);
      await _insertOrder(db, s2, id: 'ord-biz2', orderNumber: 'ORD-B2', status: 'completed', createdAt: t, businessId: bizId2);

      // Query under business 1
      db.businessIdResolver = () => bizId1;
      final results1 = await db.ordersDao.getOrdersPage(status: 'completed');
      expect(results1, hasLength(1));
      expect(results1.first.order.id, equals('ord-biz1'));

      // Query under business 2
      db.businessIdResolver = () => bizId2;
      final results2 = await db.ordersDao.getOrdersPage(status: 'completed');
      expect(results2, hasLength(1));
      expect(results2.first.order.id, equals('ord-biz2'));
    });

    test('5. Item folding', () async {
      final s = await _seed(db);
      final t = DateTime(2026, 6, 22, 12, 0, 0);

      // Add extra products
      final p1 = UuidV7.generate();
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: Value(p1),
              businessId: s.businessId,
              name: 'Drink A',
              retailerPriceKobo: const Value(500),
            ),
          );

      final p2 = UuidV7.generate();
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: Value(p2),
              businessId: s.businessId,
              name: 'Drink B',
              retailerPriceKobo: const Value(700),
            ),
          );

      await _insertOrder(db, s, id: 'fold-ord', orderNumber: 'ORD-FOLD', status: 'completed', createdAt: t);

      // Add 3 order items for the same order
      await _insertOrderItem(db, s, orderId: 'fold-ord', productId: s.productId, quantity: 2, unitPriceKobo: 1000);
      await _insertOrderItem(db, s, orderId: 'fold-ord', productId: p1, quantity: 1, unitPriceKobo: 500);
      await _insertOrderItem(db, s, orderId: 'fold-ord', productId: p2, quantity: 3, unitPriceKobo: 700);

      final results = await db.ordersDao.getOrdersPage(status: 'completed');
      expect(results, hasLength(1));
      final orderWithItems = results.first;
      expect(orderWithItems.order.id, equals('fold-ord'));
      expect(orderWithItems.items, hasLength(3));

      final productIds = orderWithItems.items.map((i) => i.product?.id).toSet();
      expect(productIds, contains(s.productId));
      expect(productIds, contains(p1));
      expect(productIds, contains(p2));
    });
  });
}
