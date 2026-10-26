import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

// #469: reorder point = (units sold / 28 days) * lead time + safety stock,
// derived from real order_items on read.
void main() {
  late AppDatabase db;
  late String biz;
  late String store;
  late String product;

  Future<String> makeStore(String businessId, String name) async {
    final id = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
          ),
        );
    return id;
  }

  Future<void> makeSale({
    required String status,
    required int qty,
    required int daysAgo,
    String? bizId,
    String? storeId,
  }) async {
    final b = bizId ?? biz;
    final st = storeId ?? store;
    final orderId = UuidV7.generate();
    final at = DateTime.now().subtract(Duration(days: daysAgo));
    await db.into(db.orders).insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: b,
            orderNumber: 'ORD-$orderId',
            totalAmountKobo: qty * 500,
            netAmountKobo: qty * 500,
            paymentType: 'cash',
            status: status,
            storeId: Value(st),
            createdAt: Value(at),
          ),
        );
    await db.into(db.orderItems).insert(
          OrderItemsCompanion.insert(
            businessId: b,
            orderId: orderId,
            productId: Value(product),
            storeId: st,
            quantity: qty,
            unitPriceKobo: 500,
            totalKobo: qty * 500,
          ),
        );
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    biz = UuidV7.generate();
    db.businessIdResolver = () => biz;
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(biz), name: 'Biz'),
        );
    store = await makeStore(biz, 'Main');
    product = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(product),
            businessId: biz,
            name: 'Cola',
            retailerPriceKobo: const Value(500),
            leadTimeDays: const Value(7),
            safetyStockQty: const Value(5),
          ),
        );
  });
  tearDown(() => db.close());


  Future<double> rop() async {
    final r = await db.stockLedgerDao.getProductsBelowROP(store);
    return r.firstWhere((p) => p.productId == product).rop;
  }

  test('no sales -> safety stock only', () async {
    expect(await rop(), 5.0);
  });

  test('steady sales -> avg daily * lead time + safety', () async {
    // 56 units in window -> 2/day -> 2*7+5 = 19
    await makeSale(status: 'completed', qty: 30, daysAgo: 3);
    await makeSale(status: 'pending', qty: 26, daysAgo: 20);
    expect(await rop(), 19.0);
  });

  test('cancelled/refunded, old and other-business sales do not count',
      () async {
    await makeSale(status: 'cancelled', qty: 100, daysAgo: 1);
    await makeSale(status: 'refunded', qty: 100, daysAgo: 1);
    await makeSale(status: 'completed', qty: 100, daysAgo: 40);
    final otherBiz = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(otherBiz), name: 'Other'),
        );
    final otherStore = await makeStore(otherBiz, 'Theirs');
    await makeSale(
        status: 'completed',
        qty: 100,
        daysAgo: 1,
        bizId: otherBiz,
        storeId: otherStore);
    expect(await rop(), 5.0);
  });

  test('sales from another store of the same business do not count', () async {
    final s2 = await makeStore(biz, 'Second');
    await makeSale(status: 'completed', qty: 28, daysAgo: 1, storeId: s2);
    expect(await rop(), 5.0);
  });
}
