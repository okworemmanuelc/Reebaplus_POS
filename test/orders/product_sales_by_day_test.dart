// #487 PR 5: OrdersDao.getProductSalesByDay feeds the Sales card on Product
// Details: per local day, recognized sales only, profit from the per-line cost
// snapshot, business-scoped.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

void main() {
  setUpAll(() => tzdata.initializeTimeZones());

  late AppDatabase db;
  late String biz;
  late String storeId;
  late String productId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    biz = UuidV7.generate();
    db.businessIdResolver = () => biz;
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(
            id: Value(biz),
            name: 'Test Biz',
            timezone: const Value('Africa/Lagos'),
          ),
        );
    storeId = UuidV7.generate();
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: biz,
            name: 'Main',
          ),
        );
    productId = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: biz,
            name: 'Beer',
          ),
        );
  });
  tearDown(() => db.close());

  Future<void> sale({
    required DateTime at,
    required int qty,
    int unit = 1000,
    int cost = 0,
    String status = 'pending',
    String? businessId,
  }) async {
    final b = businessId ?? biz;
    final orderId = UuidV7.generate();
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: b,
            orderNumber: 'ORD-$orderId',
            totalAmountKobo: qty * unit,
            netAmountKobo: qty * unit,
            paymentType: 'cash',
            status: status,
            storeId: Value(storeId),
            createdAt: Value(at),
          ),
        );
    await db
        .into(db.orderItems)
        .insert(
          OrderItemsCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: b,
            orderId: orderId,
            productId: Value(productId),
            storeId: storeId,
            quantity: qty,
            unitPriceKobo: unit,
            totalKobo: qty * unit,
            buyingPriceKobo: Value(cost),
          ),
        );
  }

  final now = DateTime.utc(2026, 10, 22, 12); // 13:00 in Lagos

  test('groups by the business-local day, zeros included', () async {
    await sale(at: DateTime.utc(2026, 10, 22, 9), qty: 2);
    // 23:30 UTC on the 21st is 00:30 on the 22nd in Lagos: today.
    await sale(at: DateTime.utc(2026, 10, 21, 23, 30), qty: 1);
    await sale(at: DateTime.utc(2026, 10, 20, 9), qty: 3);
    await sale(at: DateTime.utc(2026, 9, 30, 9), qty: 9); // last month

    final days = await db.ordersDao.getProductSalesByDay(productId, now: now);
    expect(days.length, 22); // 1 Oct .. 22 Oct
    expect(days.first.date, DateTime(2026, 10, 1));
    expect(days.last.date, DateTime(2026, 10, 22));
    expect(days.last.units, 3);
    expect(days.last.revenueKobo, 3000);
    expect(days.firstWhere((d) => d.date.day == 20).units, 3);
    expect(days.firstWhere((d) => d.date.day == 21).units, 0);
  });

  test('early in the month the window still reaches 6 days back', () async {
    await sale(at: DateTime.utc(2026, 9, 28, 9), qty: 4);
    final days = await db.ordersDao.getProductSalesByDay(
      productId,
      now: DateTime.utc(2026, 10, 3, 12),
    );
    expect(days.first.date, DateTime(2026, 9, 27));
    expect(days.length, 7);
    expect(days.firstWhere((d) => d.date.day == 28).units, 4);
  });

  test('only recognized sales count: cancelled is excluded', () async {
    await sale(at: DateTime.utc(2026, 10, 22, 9), qty: 2, status: 'pending');
    await sale(at: DateTime.utc(2026, 10, 22, 9), qty: 1, status: 'completed');
    await sale(at: DateTime.utc(2026, 10, 22, 9), qty: 7, status: 'cancelled');
    await sale(at: DateTime.utc(2026, 10, 22, 9), qty: 5, status: 'refunded');
    final days = await db.ordersDao.getProductSalesByDay(productId, now: now);
    expect(days.last.units, 3);
    expect(days.last.revenueKobo, 3000);
  });

  test('profit uses the per-line cost; an uncosted line adds none', () async {
    await sale(
      at: DateTime.utc(2026, 10, 22, 9),
      qty: 2,
      unit: 1000,
      cost: 800,
    );
    var days = await db.ordersDao.getProductSalesByDay(productId, now: now);
    expect(days.last.profitKobo, 400);
    expect(days.last.hasUncosted, isFalse);

    await sale(at: DateTime.utc(2026, 10, 22, 10), qty: 3, unit: 1000, cost: 0);
    days = await db.ordersDao.getProductSalesByDay(productId, now: now);
    expect(days.last.revenueKobo, 5000);
    expect(days.last.profitKobo, 400);
    expect(days.last.hasUncosted, isTrue);
  });

  test('is business-scoped', () async {
    final other = UuidV7.generate();
    await db
        .into(db.businesses)
        .insert(BusinessesCompanion.insert(id: Value(other), name: 'Other'));
    await sale(at: DateTime.utc(2026, 10, 22, 9), qty: 6, businessId: other);
    await sale(at: DateTime.utc(2026, 10, 22, 9), qty: 1);
    final days = await db.ordersDao.getProductSalesByDay(productId, now: now);
    expect(days.last.units, 1);
  });
}
