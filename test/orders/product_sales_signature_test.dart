// #686: Product Details refreshes from a narrow watch of its own product's
// sales (not the whole orders history). Fires for a sale of this product (also
// one synced in), on a status change, and stays silent for another product.

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
  late String otherId;

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
  setUp(() async {
    otherId = UuidV7.generate();
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(otherId),
            businessId: biz,
            name: 'Stout',
          ),
        );
  });
  tearDown(() => db.close());

  Future<void> sale({
    required DateTime at,
    required int qty,
    int unit = 1000,
    int cost = 0,
    String? product,
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
            productId: Value(product ?? productId),
            storeId: storeId,
            quantity: qty.toDouble(),
            unitPriceKobo: unit,
            totalKobo: qty * unit,
            buyingPriceKobo: Value(cost),
          ),
        );
  }

  final now = DateTime.utc(2026, 10, 22, 12);

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test(
    'fires for a sale of this product, silent for another product',
    () async {
      final seen = <List<String>>[];
      final sub = db.ordersDao
          .watchProductSalesSignature(productId, now: now)
          .listen(seen.add);
      await settle();
      expect(seen.length, 1); // initial

      await sale(at: DateTime.utc(2026, 10, 22, 9), qty: 2, product: otherId);
      await settle();
      expect(seen.length, 1, reason: 'another product must not reload');

      await sale(at: DateTime.utc(2026, 10, 22, 10), qty: 1);
      await settle();
      expect(seen.length, 2, reason: 'a sale of this product reloads');
      await sub.cancel();
    },
  );

  test(
    'a synced-in sale (written the same way) fires; status change fires',
    () async {
      await sale(at: DateTime.utc(2026, 10, 22, 9), qty: 1);
      final seen = <List<String>>[];
      final sub = db.ordersDao
          .watchProductSalesSignature(productId, now: now)
          .listen(seen.add);
      await settle();
      expect(seen.length, 1);

      await sale(
        at: DateTime.utc(2026, 10, 22, 11),
        qty: 4,
        status: 'completed',
      );
      await settle();
      expect(seen.length, 2);

      await (db.update(
        db.orders,
      )).write(const OrdersCompanion(status: Value('cancelled')));
      await settle();
      expect(seen.length, 3, reason: 'cancel changes the card figures');
      await sub.cancel();
    },
  );

  test('figures are unchanged: card still reads the same sums', () async {
    await sale(at: DateTime.utc(2026, 10, 22, 9), qty: 2);
    final days = await db.ordersDao.getProductSalesByDay(productId, now: now);
    expect(days.last.units, 2);
    expect(days.last.revenueKobo, 2000);
  });
}
