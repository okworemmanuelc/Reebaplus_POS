import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/shared/services/crate_return_approval_service.dart';
import 'package:drift/drift.dart' hide isNull;

void main() {
  late AppDatabase db;
  late CrateReturnApprovalService approvalService;

  const businessId = 'biz-123';
  const userId = 'user-456';
  const customerId = 'cust-789';
  const manufacturerId = 'mfr-001';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    approvalService = CrateReturnApprovalService(db);
    db.businessIdResolver = () => businessId;

    // Seed required data. v29: crate tracking is keyed by MANUFACTURER (§13.4),
    // so no crate_size_groups row is needed for the balance/ledger flows.
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: const Value(businessId), name: 'Test Biz'));
    await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value(userId),
          businessId: businessId,
          name: 'Test User',
          pin: '1234',
        ));
    await db.into(db.customers).insert(CustomersCompanion.insert(
        id: const Value(customerId), businessId: businessId, name: 'Test Customer'));
    await db.into(db.manufacturers).insert(ManufacturersCompanion.insert(
        id: const Value(manufacturerId),
        businessId: businessId,
        name: 'Test Mfr'));
  });

  tearDown(() async {
    await db.close();
  });

  group('recordCrateReturnByManufacturer', () {
    test('does not toggle foreign keys and updates ledger + cache', () async {
      // Assert FKs are ON
      final fkStatus = await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(fkStatus.read<int>('foreign_keys'), 1);

      await db.cratePoolDao.recordCrateReturnByManufacturer(
        manufacturerId: manufacturerId,
        quantity: 10,
        performedBy: userId,
      );

      // Verify FKs still ON
      final fkStatusAfter =
          await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(fkStatusAfter.read<int>('foreign_keys'), 1);

      // Verify ledger (manufacturer-owned: customer_id null)
      final ledger = await db.select(db.crateLedger).get();
      expect(ledger.length, 1);
      expect(ledger.first.quantityDelta, -10);
      expect(ledger.first.manufacturerId, manufacturerId);
      expect(ledger.first.customerId, isNull);

      // Verify cache (one row per manufacturer)
      final balances = await db.select(db.manufacturerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.balance, -10);
    });
  });

  group('recordCrateReturnByCustomer', () {
    test('customer row carries both owner + manufacturer; balance per mfr',
        () async {
      await db.cratePoolDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerId,
        quantity: 3,
        performedBy: userId,
      );

      final ledger = await db.select(db.crateLedger).get();
      expect(ledger.length, 1);
      expect(ledger.first.quantityDelta, -3);
      expect(ledger.first.customerId, customerId);
      expect(ledger.first.manufacturerId, manufacturerId);

      final balances = await db.select(db.customerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.customerId, customerId);
      expect(balances.first.manufacturerId, manufacturerId);
      expect(balances.first.balance, -3);
    });
  });

  // Regression for the "crate return doesn't show in the Crates tab" bug:
  // the balance cache was upserted with a raw customStatement, which Drift's
  // stream tracker does not observe, so watchCrateBalancesWithGroups never
  // re-emitted live. The fix routes the upsert through customInsert with an
  // explicit `updates: {customerCrateBalances}` set. This asserts the stream
  // emits the new balance after a return without re-subscribing.
  group('Crates tab live refresh (watch-stream regression)', () {
    test('watchCrateBalancesWithGroups emits the new balance after a return',
        () async {
      final emissions = <List<int>>[];
      final sub = db.customersDao
          .watchCrateBalancesWithGroups(customerId)
          .map((rows) => rows.map((e) => e.balance).toList())
          .listen(emissions.add);

      await pumpEventQueue();
      expect(emissions.last, isEmpty, reason: 'no crate activity yet');

      await db.cratePoolDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerId,
        quantity: 4,
        performedBy: userId,
      );
      await pumpEventQueue();

      expect(emissions.last, [-4],
          reason: 'stream must re-emit live with the credited balance');

      await sub.cancel();
    });

    test('watchEmptyCratesByManufacturer emits after addEmptyCrates', () async {
      // #159: the business-wide pool is DERIVED from the store-stamped ledger,
      // so a physical-pool credit carries a store; the derived read re-emits
      // live because the underlying crate_ledger insert invalidates the stream.
      final storeId = UuidV7.generate();
      await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(storeId), businessId: businessId, name: 'Main'));
      final emissions = <int>[];
      final sub = db.inventoryDao
          .watchEmptyCratesByManufacturer()
          .map((m) => m[manufacturerId] ?? 0)
          .listen(emissions.add);

      await pumpEventQueue();
      expect(emissions.last, 0);

      await db.inventoryDao.addEmptyCrates(manufacturerId, 6, storeId: storeId);
      await pumpEventQueue();

      expect(emissions.last, 6);
      await sub.cancel();
    });

    // Regression for "Full says zero" in the inventory Crates tab: the full
    // count must be keyed by manufacturer ID (the screen looks it up by
    // mfr.id), and it must deplete live as inventory is sold down. The stream
    // joins inventory↔products on manufacturer_id and reads inventory.quantity.
    test('watchFullCratesByManufacturer is ID-keyed and depletes on sale',
        () async {
      final storeId = UuidV7.generate();
      await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(storeId), businessId: businessId, name: 'Main'));
      final productId = UuidV7.generate();
      await db.into(db.products).insert(ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Star Bottle',
          unit: const Value('Bottle'),
          trackEmpties: const Value(true),
          manufacturerId: const Value(manufacturerId)));
      await db.into(db.inventory).insert(InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeId,
          quantity: const Value(24)));

      final emissions = <int>[];
      final sub = db.inventoryDao
          .watchFullCratesByManufacturer()
          .map((m) => m[manufacturerId] ?? 0)
          .listen(emissions.add);

      await pumpEventQueue();
      expect(emissions.last, 24, reason: 'keyed by manufacturer ID, not name');

      // Sale-style decrement (same tracked write the order flow uses).
      await db.customUpdate(
        'UPDATE inventory SET quantity = quantity - ? '
        'WHERE business_id = ? AND product_id = ? AND store_id = ?',
        variables: [
          const Variable(5),
          const Variable(businessId),
          Variable(productId),
          Variable(storeId),
        ],
        updates: {db.inventory},
      );
      await pumpEventQueue();

      expect(emissions.last, 19, reason: 'full count must deplete live on sale');
      await sub.cancel();
    });

    test('non-bottle (PET) stock is NOT counted as full crates', () async {
      final storeId = UuidV7.generate();
      await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(storeId), businessId: businessId, name: 'Main'));

      // Bottle product of the manufacturer — IS a crate product.
      final bottleId = UuidV7.generate();
      await db.into(db.products).insert(ProductsCompanion.insert(
          id: Value(bottleId),
          businessId: businessId,
          name: 'Coca-Cola Bottle',
          unit: const Value('Bottle'),
          trackEmpties: const Value(true),
          manufacturerId: const Value(manufacturerId)));
      await db.into(db.inventory).insert(InventoryCompanion.insert(
          businessId: businessId,
          productId: bottleId,
          storeId: storeId,
          quantity: const Value(12)));

      // PET product of the SAME manufacturer — must NOT be tracked as crates,
      // even if trackEmpties was somehow flipped on.
      final petId = UuidV7.generate();
      await db.into(db.products).insert(ProductsCompanion.insert(
          id: Value(petId),
          businessId: businessId,
          name: 'Coca-Cola PET',
          unit: const Value('PET'),
          trackEmpties: const Value(true),
          manufacturerId: const Value(manufacturerId)));
      await db.into(db.inventory).insert(InventoryCompanion.insert(
          businessId: businessId,
          productId: petId,
          storeId: storeId,
          quantity: const Value(48)));

      final full = await db.inventoryDao
          .watchFullCratesByManufacturer()
          .first;
      expect(full[manufacturerId], 12,
          reason: 'only the bottle stock counts; the PET 48 is excluded');
    });
  });

  // §16.8.1 Phase 2 — per-store empty-crate accuracy. The Crates tab shows a
  // single store's empties when a store is locked, and credits manual returns
  // to the store the customer's order was created from.
  group('per-store crate accuracy (§16.8.1)', () {
    test('watchFullCratesByManufacturer(storeId:) confines to one store',
        () async {
      final storeA = UuidV7.generate();
      final storeB = UuidV7.generate();
      await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(storeA), businessId: businessId, name: 'Store A'));
      await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(storeB), businessId: businessId, name: 'Store B'));

      final productId = UuidV7.generate();
      await db.into(db.products).insert(ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Star Bottle',
          unit: const Value('Bottle'),
          trackEmpties: const Value(true),
          manufacturerId: const Value(manufacturerId)));

      // Same brand stocked in both stores: 10 in A, 7 in B.
      await db.into(db.inventory).insert(InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeA,
          quantity: const Value(10)));
      await db.into(db.inventory).insert(InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeB,
          quantity: const Value(7)));

      // All-stores view sums both.
      final allStores = await db.inventoryDao
          .watchFullCratesByManufacturer()
          .first;
      expect(allStores[manufacturerId], 17);

      // Store-scoped views confine to a single store.
      final aOnly = await db.inventoryDao
          .watchFullCratesByManufacturer(storeId: storeA)
          .first;
      expect(aOnly[manufacturerId], 10);

      final bOnly = await db.inventoryDao
          .watchFullCratesByManufacturer(storeId: storeB)
          .first;
      expect(bOnly[manufacturerId], 7);
    });

    test(
        'resolveStoreForCustomerManufacturer returns the most-recent order store',
        () async {
      final storeOld = UuidV7.generate();
      final storeNew = UuidV7.generate();
      await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(storeOld), businessId: businessId, name: 'Old Store'));
      await db.into(db.stores).insert(StoresCompanion.insert(
          id: Value(storeNew), businessId: businessId, name: 'New Store'));

      Future<void> seedOrder(String storeId, DateTime created) async {
        final orderId = UuidV7.generate();
        await db.into(db.orders).insert(OrdersCompanion.insert(
              id: Value(orderId),
              businessId: businessId,
              orderNumber: 'ORD-$storeId',
              customerId: const Value(customerId),
              totalAmountKobo: 0,
              netAmountKobo: 0,
              paymentType: 'cash',
              status: 'completed',
              storeId: Value(storeId),
              createdAt: Value(created),
            ));
        await db.into(db.orderCrateLines).insert(OrderCrateLinesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              orderId: orderId,
              manufacturerId: manufacturerId,
              cratesTaken: 2,
            ));
      }

      await seedOrder(storeOld, DateTime(2026, 1, 1));
      await seedOrder(storeNew, DateTime(2026, 6, 1));

      final resolved = await db.orderCrateLinesDao
          .resolveStoreForCustomerManufacturer(
        customerId: customerId,
        manufacturerId: manufacturerId,
      );
      expect(resolved, storeNew, reason: 'credit the most recent order store');
    });

    test('resolveStoreForCustomerManufacturer returns null with no orders',
        () async {
      final resolved = await db.orderCrateLinesDao
          .resolveStoreForCustomerManufacturer(
        customerId: customerId,
        manufacturerId: manufacturerId,
      );
      expect(resolved, isNull, reason: 'caller falls back to the active store');
    });
  });

  group('CrateReturnApprovalService', () {
    test(
        'approve() appends ledger row and updates cache with explicit field assertions',
        () async {
      final returnId = await db.pendingCrateReturnsDao.createPendingReturn(
        orderId: null,
        customerId: customerId,
        submittedBy: userId,
        manufacturerId: manufacturerId,
        quantity: 5,
      );

      await approvalService.approve(returnId, userId);

      // Verify Pending Return status
      final pending = await db.pendingCrateReturnsDao.getById(returnId);
      expect(pending?.status, 'approved');

      // Verify Ledger row. v29: a customer crate row sets BOTH the customer
      // (owner) and the manufacturer (whose crates).
      final ledgerRows = await db.select(db.crateLedger).get();
      expect(ledgerRows.length, 1);
      final row = ledgerRows.first;
      expect(row.quantityDelta, -5); // Negative as customer returned them
      expect(row.referenceReturnId, returnId);
      expect(row.customerId, customerId);
      expect(row.manufacturerId, manufacturerId);

      // Verify Cache (keyed by customer + manufacturer)
      final balances = await db.select(db.customerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.manufacturerId, manufacturerId);
      expect(balances.first.balance, -5);
    });

    test('reject() updates status but appends zero ledger rows', () async {
      final returnId = await db.pendingCrateReturnsDao.createPendingReturn(
        orderId: null,
        customerId: customerId,
        submittedBy: userId,
        manufacturerId: manufacturerId,
        quantity: 5,
      );

      await approvalService.reject(returnId, userId, 'Too few crates');

      final pending = await db.pendingCrateReturnsDao.getById(returnId);
      expect(pending?.status, 'rejected');
      expect(pending?.rejectionReason, 'Too few crates');

      final ledgerRows = await db.select(db.crateLedger).get();
      expect(ledgerRows.length, 0);
    });
  });

  // Regression: raw-SQL writes must not store SQLite text (CURRENT_TIMESTAMP)
  // into the INTEGER-epoch last_updated_at columns. drift reads those columns
  // via int.parse, so a text value throws `FormatException: Invalid radix-10
  // number` on the next read of the row.
  group('last_updated_at stays integer epoch (FormatException regression)', () {
    test('addEmptyCrates increments stock and re-reads manufacturer cleanly',
        () async {
      await db.inventoryDao.addEmptyCrates(manufacturerId, 7);

      // Before the fix this read threw FormatException because the customUpdate
      // had stored a "YYYY-MM-DD HH:MM:SS" text into last_updated_at.
      final mfr = await (db.select(db.manufacturers)
            ..where((t) => t.id.equals(manufacturerId)))
          .getSingle();
      expect(mfr.emptyCrateStock, 7);

      // Column physically holds an integer, not text.
      final t = await db
          .customSelect(
            "SELECT typeof(last_updated_at) AS t FROM manufacturers WHERE id = ?",
            variables: [const Variable(manufacturerId)],
          )
          .getSingle();
      expect(t.read<String>('t'), 'integer');
    });

    test('second customer return hits ON CONFLICT path and re-reads cleanly',
        () async {
      // First return: INSERT path (uses the integer column default).
      await db.cratePoolDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerId,
        quantity: 2,
        performedBy: userId,
      );
      // Second return for the SAME (customer, manufacturer): the DO UPDATE SET
      // branch ran `last_updated_at = CURRENT_TIMESTAMP` before the fix and
      // corrupted the row; the read-back inside the method threw.
      await db.cratePoolDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerId,
        quantity: 3,
        performedBy: userId,
      );

      final balances = await db.select(db.customerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.balance, -5); // -(2) + -(3)

      final t = await db
          .customSelect(
            "SELECT typeof(last_updated_at) AS t FROM customer_crate_balances",
          )
          .getSingle();
      expect(t.read<String>('t'), 'integer');
    });

    test('second approve hits ON CONFLICT path and re-reads cleanly', () async {
      Future<void> approveOne(int qty) async {
        final id = await db.pendingCrateReturnsDao.createPendingReturn(
          orderId: null,
          customerId: customerId,
          submittedBy: userId,
          manufacturerId: manufacturerId,
          quantity: qty,
        );
        await approvalService.approve(id, userId);
      }

      await approveOne(4); // INSERT path
      await approveOne(6); // ON CONFLICT DO UPDATE SET path

      final balances = await db.select(db.customerCrateBalances).get();
      expect(balances.length, 1);
      expect(balances.first.balance, -10);

      final t = await db
          .customSelect(
            "SELECT typeof(last_updated_at) AS t FROM customer_crate_balances",
          )
          .getSingle();
      expect(t.read<String>('t'), 'integer');
    });
  });

  group('CHECK Constraints', () {
    test('v29: ALLOWS both customer_id and manufacturer_id (relaxed owner CHECK)',
        () async {
      await db.into(db.crateLedger).insert(CrateLedgerCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            customerId: const Value(customerId),
            manufacturerId: const Value(manufacturerId),
            quantityDelta: 10,
            movementType: 'issued',
          ));
      final rows = await db.select(db.crateLedger).get();
      expect(rows.length, 1);
      expect(rows.first.customerId, customerId);
      expect(rows.first.manufacturerId, manufacturerId);
    });

    test('throws when neither customer_id nor manufacturer_id are set',
        () async {
      expect(
        () => db.into(db.crateLedger).insert(CrateLedgerCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              customerId: const Value.absent(),
              manufacturerId: const Value.absent(),
              quantityDelta: 10,
              movementType: 'issued',
            )),
        throwsA(anything),
      );
    });
  });
}
