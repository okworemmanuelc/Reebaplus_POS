import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/orders/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

/// #176 (Money integrity report-truth, PRD #155 story 32) — the checkout
/// captures the catalogue (tier list) price onto each order line so a
/// custom-price concession (`catalogue − charged`) is derivable in margin
/// review. Exercises the real `OrderCommands._buildOrderItems` path via
/// `OrderService.addOrder`, at the DAO/in-memory-Drift seam.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await setFlag(db, 'feature.domain_rpcs_v2.record_sale', on: false);
  });

  tearDown(() => db.close());

  Future<(String storeId, String staffId)> seedBase() async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId), businessId: businessId, name: 'Cashier', pin: '0'));
    return (storeId, staffId);
  }

  Future<String> seedProduct(String storeId) async {
    final productId = UuidV7.generate();
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId),
        businessId: businessId,
        name: 'Cola',
        retailerPriceKobo: const Value(100000),
        unit: const Value('Piece')));
    await db.into(db.inventory).insert(InventoryCompanion.insert(
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantity: const Value(100)));
    return productId;
  }

  Future<List<OrderItemData>> itemsOfOrderNumber(String number) async {
    final order = await (db.select(db.orders)
          ..where((o) => o.orderNumber.equals(number)))
        .getSingle();
    return (db.select(db.orderItems)
          ..where((i) => i.orderId.equals(order.id)))
        .get();
  }

  test('a custom-priced line records the catalogue price it deviated from',
      () async {
    final (storeId, staffId) = await seedBase();
    final productId = await seedProduct(storeId);
    final svc = OrderService(db);

    // Charged ₦800 against a ₦1,000 catalogue price — a ₦200/unit concession.
    final number = await svc.addOrder(
      customerId: null,
      cart: [
        {
          'id': productId,
          'qty': 2,
          'unitPriceKobo': 80000, // charged (custom)
          'catalogPriceKobo': 100000, // designated tier list price
          'name': 'Cola',
        },
      ],
      totalAmountKobo: 160000,
      amountPaidKobo: 160000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );

    final items = await itemsOfOrderNumber(number);
    expect(items, hasLength(1));
    expect(items.single.unitPriceKobo, 80000);
    expect(items.single.cataloguePriceKobo, 100000);
    // The concession is derivable: catalogue − charged = ₦200/unit.
    expect(
      items.single.cataloguePriceKobo! - items.single.unitPriceKobo,
      20000,
    );
  });

  test('a full-price line records NO catalogue price (no phantom concession)',
      () async {
    final (storeId, staffId) = await seedBase();
    final productId = await seedProduct(storeId);
    final svc = OrderService(db);

    final number = await svc.addOrder(
      customerId: null,
      cart: [
        {
          'id': productId,
          'qty': 1,
          'unitPriceKobo': 100000,
          'catalogPriceKobo': 100000, // charged == catalogue
          'name': 'Cola',
        },
      ],
      totalAmountKobo: 100000,
      amountPaidKobo: 100000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      paymentSubType: 'cash',
    );

    final items = await itemsOfOrderNumber(number);
    expect(items.single.cataloguePriceKobo, isNull);
  });
}
