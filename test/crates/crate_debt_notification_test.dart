import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/order_service.dart';

import '../helpers/dispatch_test_utils.dart';

/// §12.1 / §26.4 — a sale that leaves a registered customer OWING empty crates
/// (the no-deposit "crate-track" path) must fire a CEO + Manager notification.
/// §12.2 — a sale settled with a full deposit (money-track) must NOT fire it.
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    // Crate tracking only runs for Bar / Beer Distributor businesses.
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));
  });

  tearDown(() => db.close());

  Future<(String storeId, String staffId, String customerId)> seedBase() async {
    final storeId = UuidV7.generate();
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    final staffId = UuidV7.generate();
    await db.into(db.users).insert(UsersCompanion.insert(
        id: Value(staffId),
        businessId: businessId,
        name: 'Cashier',
        pin: '0000'));
    final customerId = await db.customersDao.addCustomer(
        CustomersCompanion.insert(businessId: businessId, name: 'Buyer'));
    return (storeId, staffId, customerId);
  }

  Future<(String mfrId, String productId)> seedCrateProduct(
      String storeId) async {
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
    return (mfrId, productId);
  }

  Future<List<NotificationData>> crateDebtNotifs() async {
    return (db.select(db.notifications)
          ..where((t) => t.type.equals('customer_crate_debt')))
        .get();
  }

  test('owed crate sale fires a customer_crate_debt notification (§12.1)',
      () async {
    final (storeId, staffId, customerId) = await seedBase();
    final (_, productId) = await seedCrateProduct(storeId);
    final service = OrderService(db);

    // No deposit paid → crates issued against the customer's balance (owing).
    await service.addOrder(
      customerId: customerId,
      cart: [
        {'id': productId, 'qty': 3, 'unitPriceKobo': 100000, 'name': 'Star Bottle'},
      ],
      totalAmountKobo: 300000,
      amountPaidKobo: 300000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
    );

    final notifs = await crateDebtNotifs();
    expect(notifs, isNotEmpty);
    expect(notifs.first.message, contains('Star'));
  });

  test('full-deposit crate sale fires NO crate-debt notification (§12.2)',
      () async {
    final (storeId, staffId, customerId) = await seedBase();
    final (mfrId, productId) = await seedCrateProduct(storeId);
    final service = OrderService(db);

    // Full deposit paid (rate 50000 × 3) → money-track, no owing.
    await service.addOrder(
      customerId: customerId,
      cart: [
        {'id': productId, 'qty': 3, 'unitPriceKobo': 100000, 'name': 'Star Bottle'},
      ],
      totalAmountKobo: 450000,
      amountPaidKobo: 450000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
      crateDepositPaidByManufacturer: {mfrId: 150000},
    );

    expect(await crateDebtNotifs(), isEmpty);
  });

  test('walk-in (no customer) fires no crate-debt notification', () async {
    final (storeId, staffId, _) = await seedBase();
    final (_, productId) = await seedCrateProduct(storeId);
    final service = OrderService(db);

    await service.addOrder(
      customerId: null,
      cart: [
        {'id': productId, 'qty': 2, 'unitPriceKobo': 100000, 'name': 'Star Bottle'},
      ],
      totalAmountKobo: 200000,
      amountPaidKobo: 200000,
      paymentType: 'cash',
      staffId: staffId,
      storeId: storeId,
    );

    expect(await crateDebtNotifs(), isEmpty);
  });
}
