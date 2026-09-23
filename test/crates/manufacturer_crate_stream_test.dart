import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  const businessId = 'biz-1';
  const storeA = 'store-a';
  const storeB = 'store-b';
  const userId = 'user-1';
  const customerId = 'cust-1';
  const walletId = 'wallet-1';
  const mfrA = 'mfr-a';
  const mfrB = 'mfr-b';
  const crateValueKobo = 100000; // ₦1,000

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => businessId;

    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(
            id: const Value(businessId),
            name: 'Test Business',
          ),
        );
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: businessId,
            name: 'Alice Manager',
            pin: '1234',
          ),
        );
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: const Value(storeA),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: const Value(storeB),
            businessId: businessId,
            name: 'Annex Store',
          ),
        );
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: const Value(mfrA),
            businessId: businessId,
            name: 'Brand Alpha',
            depositAmountKobo: const Value(crateValueKobo),
          ),
        );
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: const Value(mfrB),
            businessId: businessId,
            name: 'Brand Beta',
            depositAmountKobo: const Value(50000),
          ),
        );
    await db
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: const Value(customerId),
            businessId: businessId,
            name: 'John Customer',
          ),
        );
    await db
        .into(db.customerWallets)
        .insert(
          CustomerWalletsCompanion.insert(
            id: const Value(walletId),
            businessId: businessId,
            customerId: customerId,
          ),
        );
  });

  tearDown(() => db.close());

  group('CratePoolDao - Manufacturer streams (#291)', () {
    test(
      'watchManufacturerCratePosition computes six statuses accurately across stores',
      () async {
        // 1. In warehouse: add empties to store A and store B via crate_ledger
        await db
            .into(db.crateLedger)
            .insert(
              CrateLedgerCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                manufacturerId: const Value(mfrA),
                storeId: const Value(storeA),
                quantityDelta: 10,
                movementType: 'transferred_in',
                performedBy: const Value(userId),
              ),
            );
        await db
            .into(db.crateLedger)
            .insert(
              CrateLedgerCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                manufacturerId: const Value(mfrA),
                storeId: const Value(storeB),
                quantityDelta: 5,
                movementType: 'transferred_in',
                performedBy: const Value(userId),
              ),
            );

        // 2. Full crates in stock: Product belonging to mfrA
        const prodA = 'prod-a';
        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: const Value(prodA),
                businessId: businessId,
                manufacturerId: const Value(mfrA),
                name: 'Alpha Beer 60cl',
                size: const Value('big'),
                unit: const Value('Bottle'),
                trackEmpties: const Value(true),
                retailerPriceKobo: const Value(50000),
                wholesalerPriceKobo: const Value(45000),
                buyingPriceKobo: const Value(40000),
              ),
            );
        // Stock: 8 in store A, 4 in store B
        await db
            .into(db.inventory)
            .insert(
              InventoryCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                storeId: storeA,
                productId: prodA,
                quantity: const Value(8),
              ),
            );
        await db
            .into(db.inventory)
            .insert(
              InventoryCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                storeId: storeB,
                productId: prodA,
                quantity: const Value(4),
              ),
            );

        // 3. With customers on deposit: Order with order_crate_lines
        const orderA = 'order-a';
        await db
            .into(db.orders)
            .insert(
              OrdersCompanion.insert(
                id: const Value(orderA),
                businessId: businessId,
                orderNumber: 'ORD-001',
                totalAmountKobo: 100000,
                netAmountKobo: 100000,
                paymentType: 'cash',
                status: 'completed',
                storeId: const Value(storeA),
              ),
            );
        await db
            .into(db.orderCrateLines)
            .insert(
              OrderCrateLinesCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                orderId: orderA,
                manufacturerId: mfrA,
                cratesTaken: 3,
                depositPaidKobo: const Value(300000), // 3 * 100,000
              ),
            );

        // 4. With customers no deposit: customer crate debt via crate_ledger
        await db.cratePoolDao.recordCrateIssueByCustomer(
          customerId: customerId,
          manufacturerId: mfrA,
          quantity: 4,
          performedBy: userId,
          orderId: orderA,
        );

        // 5. Damaged: damage movement in current month
        await db
            .into(db.crateLedger)
            .insert(
              CrateLedgerCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                manufacturerId: const Value(mfrA),
                storeId: const Value(storeA),
                quantityDelta: -2,
                movementType: 'damaged',
                performedBy: const Value(userId),
              ),
            );

        // A) All Stores view:
        final allStoresPos = await db.cratePoolDao
            .watchManufacturerCratePosition(mfrA)
            .first;

        // In warehouse = 10 + 5 - 2 (damage) = 13
        expect(allStoresPos.inWarehouse.count, 13);
        expect(allStoresPos.inWarehouse.moneyKobo, 13 * crateValueKobo);

        // Full crates in stock = 8 + 4 = 12
        expect(allStoresPos.fullCratesInStock.count, 12);
        expect(allStoresPos.fullCratesInStock.moneyKobo, 12 * crateValueKobo);

        // With customers on deposit = 3 crates, ₦300,000
        expect(allStoresPos.withCustomersOnDeposit.count, 3);
        expect(allStoresPos.withCustomersOnDeposit.moneyKobo, 300000);

        // With customers no deposit = 4 crates, ₦400,000
        expect(allStoresPos.withCustomersNoDeposit.count, 4);
        expect(
          allStoresPos.withCustomersNoDeposit.moneyKobo,
          4 * crateValueKobo,
        );

        // Short = 0 (until #293)
        expect(allStoresPos.short.count, 0);
        expect(allStoresPos.short.hasMoney, isFalse);

        // Damaged = 2
        expect(allStoresPos.damaged.count, 2);
        expect(allStoresPos.damaged.moneyKobo, 2 * crateValueKobo);

        // Total crates across brand = 13 + 12 + 3 + 4 = 32
        expect(allStoresPos.totalCrates, 32);

        // B) Store A scoped view:
        final storeAPos = await db.cratePoolDao
            .watchManufacturerCratePosition(mfrA, storeId: storeA)
            .first;
        // In warehouse in store A = 10 - 2 = 8
        expect(storeAPos.inWarehouse.count, 8);
        // Full crates in store A = 8
        expect(storeAPos.fullCratesInStock.count, 8);
        // With customers in store A = 3
        expect(storeAPos.withCustomersOnDeposit.count, 3);
      },
    );

    test(
      'watchCustomerDepositAttribution guarantees invariant and surfaces unattributed deposit',
      () async {
        // Wallet transactions: total business-wide held deposit = ₦500,000 (50,000,000 kobo)
        await db
            .into(db.walletTransactions)
            .insert(
              WalletTransactionsCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                walletId: walletId,
                customerId: customerId,
                amountKobo: 50000000,
                signedAmountKobo: 50000000,
                type: 'credit',
                referenceType: 'crate_deposit',
              ),
            );

        // Order crate line for mfrA with depositPaidKobo = ₦300,000 (30,000,000 kobo)
        const orderA = 'order-attr-a';
        await db
            .into(db.orders)
            .insert(
              OrdersCompanion.insert(
                id: const Value(orderA),
                businessId: businessId,
                orderNumber: 'ORD-ATTR-1',
                totalAmountKobo: 100000,
                netAmountKobo: 100000,
                paymentType: 'cash',
                status: 'completed',
                storeId: const Value(storeA),
              ),
            );
        await db
            .into(db.orderCrateLines)
            .insert(
              OrderCrateLinesCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                orderId: orderA,
                manufacturerId: mfrA,
                cratesTaken: 3,
                depositPaidKobo: const Value(30000000),
              ),
            );

        final attribution = await db.cratePoolDao
            .watchCustomerDepositAttribution()
            .first;

        expect(attribution.businessWideHeldDepositKobo, 50000000);
        expect(attribution.attributedKoboByManufacturer[mfrA], 30000000);
        // Unattributed = 50,000,000 - 30,000,000 = 20,000,000
        expect(attribution.unattributedKobo, 20000000);
        expect(
          attribution.totalAttributedKobo + attribution.unattributedKobo,
          attribution.businessWideHeldDepositKobo,
        );
      },
    );

    test(
      'watchManufacturerCrateMovements orders newest first and labels movement kinds',
      () async {
        final now = DateTime.now();

        await db
            .into(db.crateLedger)
            .insert(
              CrateLedgerCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                manufacturerId: const Value(mfrA),
                storeId: const Value(storeA),
                quantityDelta: 50,
                movementType: 'transferred_in',
                performedBy: const Value(userId),
                createdAt: Value(now.subtract(const Duration(hours: 3))),
              ),
            );

        await db
            .into(db.crateLedger)
            .insert(
              CrateLedgerCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                manufacturerId: const Value(mfrA),
                storeId: const Value(storeA),
                quantityDelta: -5,
                movementType: 'adjusted',
                performedBy: const Value(userId),
                createdAt: Value(now.subtract(const Duration(hours: 2))),
              ),
            );

        await db
            .into(db.crateLedger)
            .insert(
              CrateLedgerCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                manufacturerId: const Value(mfrA),
                storeId: const Value(storeB),
                quantityDelta: 20,
                movementType: 'returned',
                performedBy: const Value(userId),
                createdAt: Value(now.subtract(const Duration(hours: 1))),
              ),
            );

        final movements = await db.cratePoolDao
            .watchManufacturerCrateMovements(mfrA)
            .first;

        expect(movements.length, 3);
        // Newest first: returned, adjusted, transferred_in
        expect(movements[0].movementType, 'returned');
        expect(movements[0].movementLabel, 'Returned');
        expect(movements[0].quantityDelta, 20);
        expect(movements[0].storeName, 'Annex Store');
        expect(movements[0].performedByName, 'Alice Manager');

        expect(movements[1].movementType, 'adjusted');
        expect(movements[1].movementLabel, 'Adjusted');
        expect(movements[1].quantityDelta, -5);

        expect(movements[2].movementType, 'transferred_in');
        expect(movements[2].movementLabel, 'Transferred in');
        expect(movements[2].quantityDelta, 50);
      },
    );

    test(
      'watchManufacturerProducts returns tracked products with stock count',
      () async {
        const prodA = 'prod-alpha-1';
        const prodB = 'prod-alpha-2';

        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: const Value(prodA),
                businessId: businessId,
                manufacturerId: const Value(mfrA),
                name: 'Alpha Stout 33cl',
                size: const Value('small'),
                trackEmpties: const Value(true),
                retailerPriceKobo: const Value(40000),
                wholesalerPriceKobo: const Value(38000),
                buyingPriceKobo: const Value(35000),
              ),
            );

        await db
            .into(db.products)
            .insert(
              ProductsCompanion.insert(
                id: const Value(prodB),
                businessId: businessId,
                manufacturerId: const Value(mfrA),
                name: 'Alpha Lager 60cl',
                size: const Value('big'),
                trackEmpties: const Value(true),
                retailerPriceKobo: const Value(50000),
                wholesalerPriceKobo: const Value(45000),
                buyingPriceKobo: const Value(40000),
              ),
            );

        await db
            .into(db.inventory)
            .insert(
              InventoryCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: businessId,
                storeId: storeA,
                productId: prodA,
                quantity: const Value(14),
              ),
            );

        final items = await db.cratePoolDao
            .watchManufacturerProducts(mfrA)
            .first;
        expect(items.length, 2);
        expect(
          items.map((i) => i.product.name).toList(),
          containsAll(['Alpha Lager 60cl', 'Alpha Stout 33cl']),
        );
        final stout = items.firstWhere((i) => i.product.id == prodA);
        expect(stout.totalStock, 14);
      },
    );
  });
}
