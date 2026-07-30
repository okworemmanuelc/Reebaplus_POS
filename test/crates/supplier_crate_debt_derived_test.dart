import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/services/receive_stock_service.dart';
import 'package:reebaplus_pos/shared/services/supplier_account_service.dart';

/// #160 — supplier crate debt DERIVED from the append-only
/// `supplier_crate_ledger`, and Receive Stock posting BOTH legs (physical pool +
/// supplier balance) in one transaction.
///
/// A supplier's crate debt per manufacturer is `SUM(quantity_delta)` over their
/// `supplier_crate_ledger` rows — never a stored `supplier_crate_balances` total
/// — exactly the way the wallet balance derives from `wallet_transactions`. This
/// suite pins the four properties the slice buys:
///   1. the Empty-Crates tab read (`watchSupplierCrateDebt` /
///      `watchBySupplier`) equals the ledger sum and re-emits live;
///   2. a single Receive Stock delivery that returns empties updates BOTH the
///      physical pool (summed off `crate_ledger` directly — #159's derivation)
///      AND the supplier balance, in one transaction, with no second manual
///      entry (the B3 regression);
///   3. `supplier_crate_balances` is no longer pushed — only append-only ledger
///      rows sync for supplier crates;
///   4. multi-device convergence — two independently-built ledgers (as two
///      offline tills) merge and the derived balance equals the combined sum,
///      with no movement lost (the exact scenario the old absolute-value push
///      clobbered).
void main() {
  const businessId = 'biz-1';
  const userId = 'user-1';
  const storeId = 'store-1';
  const supplierA = 'sup-a';
  const supplierB = 'sup-b';
  const manufacturerX = 'mfr-x';
  const manufacturerY = 'mfr-y';
  const bottleProductId = 'prod-bottle';

  Future<void> seed(AppDatabase db) async {
    db.businessIdResolver = () => businessId;
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: businessId,
            name: 'U',
            pin: '1234',
          ),
        );
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: const Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: const Value(manufacturerX),
            businessId: businessId,
            name: 'Star Lager',
            depositAmountKobo: const Value(50000),
          ),
        );
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: const Value(manufacturerY),
            businessId: businessId,
            name: 'Gulder',
            depositAmountKobo: const Value(30000),
          ),
        );
    for (final s in [supplierA, supplierB]) {
      await db.into(db.suppliers).insert(
            SuppliersCompanion.insert(
              id: Value(s),
              businessId: businessId,
              name: s,
            ),
          );
    }
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: const Value(bottleProductId),
            businessId: businessId,
            name: 'Star 60cl',
            unit: const Value('Bottle'),
            buyingPriceKobo: const Value(10000),
            manufacturerId: const Value(manufacturerX),
            trackEmpties: const Value(true),
          ),
        );
  }

  group('derived read (in-memory)', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(db);
    });

    tearDown(() => db.close());

    Future<Map<String, int>> derived(String supplierId) async {
      final rows =
          await db.cratePoolDao.watchSupplierCrateDebt(supplierId).first;
      return {for (final r in rows) r.manufacturerId: r.balance};
    }

    test('debt per manufacturer == SUM over the supplier ledger', () async {
      // Receive 100 of X (we owe), return 80 of X → net owe 20.
      // Return 5 of Y with no prior receipt → -5 (supplier owes us / credit).
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 100,
        performedBy: userId,
      );
      await db.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 80,
        performedBy: userId,
      );
      await db.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerY,
        quantity: 5,
        performedBy: userId,
      );

      expect(await derived(supplierA), {manufacturerX: 20, manufacturerY: -5});
    });

    test('a fully-settled brand nets to 0 (Clear), not a phantom debt',
        () async {
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 12,
        performedBy: userId,
      );
      await db.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 12,
        performedBy: userId,
      );

      expect(await derived(supplierA), {manufacturerX: 0});
    });

    test('debt is scoped per (supplier, manufacturer)', () async {
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 40,
        performedBy: userId,
      );
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierB,
        manufacturerId: manufacturerX,
        quantity: 7,
        performedBy: userId,
      );

      expect(await derived(supplierA), {manufacturerX: 40});
      expect(await derived(supplierB), {manufacturerX: 7});
    });

    test('watchBySupplier (the Empty-Crates tab read) derives + re-emits live '
        'with the deposit rate carried through', () async {
      final emissions = <List<SupplierCrateBalanceWithManufacturer>>[];
      final sub = db.supplierCrateBalancesDao
          .watchBySupplier(supplierA)
          .listen(emissions.add);

      await pumpEventQueue();
      expect(emissions.last, isEmpty, reason: 'no crate activity yet');

      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 7,
        performedBy: userId,
      );
      await pumpEventQueue();

      expect(emissions.last, hasLength(1),
          reason: 'the ledger-derived read re-emits live on a new movement');
      expect(emissions.last.single.balance, 7);
      expect(emissions.last.single.depositRateKobo, 50000,
          reason: 'the per-manufacturer deposit rate values the crates owed');
      await sub.cancel();
    });
  });

  group('Receive Stock posts both legs in one step (B3 regression)', () {
    late AppDatabase db;
    late ReceiveStockService service;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(db);
      service = ReceiveStockService(db, SupplierAccountService(db));
    });

    tearDown(() => db.close());

    // The physical empties pool (#159's derivation) summed off `crate_ledger`
    // DIRECTLY — a manufacturer-owned, customer-less row is the physical leg.
    Future<int> physicalPool(String manufacturerId) async {
      final row = await db.customSelect(
        'SELECT COALESCE(SUM(quantity_delta), 0) AS s FROM crate_ledger '
        'WHERE business_id = ? AND manufacturer_id = ? AND customer_id IS NULL',
        variables: [const Variable(businessId), Variable(manufacturerId)],
      ).getSingle();
      return row.read<int>('s');
    }

    Future<int> supplierDebt(String supplierId, String manufacturerId) async {
      final rows =
          await db.cratePoolDao.watchSupplierCrateDebt(supplierId).first;
      final match =
          rows.where((r) => r.manufacturerId == manufacturerId).toList();
      return match.isEmpty ? 0 : match.single.balance;
    }

    test('one delivery returning empties updates BOTH the physical pool and the '
        'supplier balance — no second manual entry', () async {
      final lines = <ReceiveCartLine>[
        const ReceiveCartLine(
          productId: bottleProductId,
          productName: 'Star 60cl',
          unit: 'Bottle',
          qty: 5,
          buyingPriceKobo: 10000,
          retailKobo: 12000,
          wholesaleKobo: 11000,
          manufacturerId: manufacturerX,
          trackEmpties: true,
        ),
      ];

      await service.confirmReceipt(
        supplierId: supplierA,
        supplierName: 'Supplier A',
        storeId: storeId,
        dateReceived: DateTime(2026, 6, 1),
        staffId: userId,
        lines: lines,
        fullCratesReceivedByManufacturer: const {},
        emptiesReturnedByManufacturer: const {manufacturerX: 3},
        note: 'Inv #7',
      );

      // Leg 1 — physical pool dropped by the 3 empties handed back.
      expect(await physicalPool(manufacturerX), -3);
      // Leg 2 — the supplier balance dropped by the same 3, off the SAME single
      // confirmReceipt call (no separate SupplierCrateService.recordReturn).
      expect(await supplierDebt(supplierA, manufacturerX), -3);

      // Exactly one supplier ledger row was appended by the delivery.
      final supLedger = await db.select(db.supplierCrateLedger).get();
      expect(supLedger, hasLength(1));
      expect(supLedger.single.quantityDelta, -3);
      expect(supLedger.single.movementType, 'returned');
      expect(supLedger.single.supplierId, supplierA);
      expect(supLedger.single.manufacturerId, manufacturerX);
    });

    test('a delivery with no empties returned posts no supplier crate leg',
        () async {
      final lines = <ReceiveCartLine>[
        const ReceiveCartLine(
          productId: bottleProductId,
          productName: 'Star 60cl',
          unit: 'Bottle',
          qty: 5,
          buyingPriceKobo: 10000,
          retailKobo: 12000,
          wholesaleKobo: 11000,
          manufacturerId: manufacturerX,
          trackEmpties: true,
        ),
      ];

      await service.confirmReceipt(
        supplierId: supplierA,
        supplierName: 'Supplier A',
        storeId: storeId,
        dateReceived: DateTime(2026, 6, 1),
        staffId: userId,
        lines: lines,
        fullCratesReceivedByManufacturer: const {},
        emptiesReturnedByManufacturer: const {},
      );

      expect(await db.select(db.supplierCrateLedger).get(), isEmpty);
      expect(await supplierDebt(supplierA, manufacturerX), 0);
    });
  });

  // #210 / ADR 0023 — Receive Stock records the FULL CRATES RECEIVED.
  //
  // Before this slice only the return leg was automated, so `SUM(quantity_delta)`
  // over `supplier_crate_ledger` could only ever FALL. Normal operation drove
  // supplier crate debt negative, and because `businessNetPositionKobo`
  // SUBTRACTS that debt, a negative debt INFLATED business worth — the longer a
  // shop ran, the more overstated it got. These tests pin the debt moving in
  // BOTH directions off one action.
  group('#210 — Receive Stock records the full crates received', () {
    late AppDatabase db;
    late ReceiveStockService service;

    const petProductId = 'prod-pet';

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(db);
      // A NON-crate line for the same delivery: PET packaging, no empties
      // tracked. It must never reach a crate table.
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: const Value(petProductId),
              businessId: businessId,
              name: 'Gulder 50cl PET',
              unit: const Value('PET'),
              buyingPriceKobo: const Value(8000),
              manufacturerId: const Value(manufacturerY),
              trackEmpties: const Value(false),
            ),
          );
      service = ReceiveStockService(db, SupplierAccountService(db));
    });

    tearDown(() => db.close());

    Future<int> supplierDebt(String supplierId, String manufacturerId) async {
      final rows =
          await db.cratePoolDao.watchSupplierCrateDebt(supplierId).first;
      final match =
          rows.where((r) => r.manufacturerId == manufacturerId).toList();
      return match.isEmpty ? 0 : match.single.balance;
    }

    const bottleLine = ReceiveCartLine(
      productId: bottleProductId,
      productName: 'Star 60cl',
      unit: 'Bottle',
      qty: 240,
      buyingPriceKobo: 10000,
      retailKobo: 12000,
      wholesaleKobo: 11000,
      manufacturerId: manufacturerX,
      trackEmpties: true,
    );

    const petLine = ReceiveCartLine(
      productId: petProductId,
      productName: 'Gulder 50cl PET',
      unit: 'PET',
      qty: 60,
      buyingPriceKobo: 8000,
      retailKobo: 9500,
      wholesaleKobo: 9000,
      manufacturerId: manufacturerY,
      trackEmpties: false,
    );

    Future<void> receive({
      Map<String, int> fullCratesIn = const {},
      Map<String, int> emptiesBack = const {},
      List<ReceiveCartLine> lines = const [bottleLine],
    }) =>
        service.confirmReceipt(
          supplierId: supplierA,
          supplierName: 'Supplier A',
          storeId: storeId,
          dateReceived: DateTime(2026, 6, 1),
          staffId: userId,
          lines: lines,
          fullCratesReceivedByManufacturer: fullCratesIn,
          emptiesReturnedByManufacturer: emptiesBack,
        );

    test('a receipt-only cycle NEVER produces a negative balance — it rises',
        () async {
      // Three deliveries, no empties handed back at all. This is the exact shape
      // that used to drive the balance negative (each delivery posted nothing,
      // and any return posted a bare debit).
      await receive(fullCratesIn: const {manufacturerX: 20});
      await receive(fullCratesIn: const {manufacturerX: 20});
      await receive(fullCratesIn: const {manufacturerX: 8});

      final debt = await supplierDebt(supplierA, manufacturerX);
      expect(debt, 48, reason: 'debt is the sum of the crates that arrived');
      expect(debt, greaterThan(0),
          reason: 'a receipt-only history can never be a crate CREDIT');

      final ledger = await db.select(db.supplierCrateLedger).get();
      expect(ledger, hasLength(3));
      expect(ledger.every((r) => r.movementType == 'received'), isTrue);
      expect(ledger.every((r) => r.quantityDelta > 0), isTrue);
    });

    test('a receive-then-return cycle leaves debt at the correct POSITIVE value',
        () async {
      // 30 full crates arrive; 18 empties go back on a later delivery.
      await receive(fullCratesIn: const {manufacturerX: 30});
      await receive(
        fullCratesIn: const {manufacturerX: 0},
        emptiesBack: const {manufacturerX: 18},
      );

      expect(await supplierDebt(supplierA, manufacturerX), 12,
          reason: '30 received − 18 returned = 12 still owed');
    });

    test('one delivery that both drops crates off and takes empties away nets '
        'correctly in a single action', () async {
      await receive(
        fullCratesIn: const {manufacturerX: 25},
        emptiesBack: const {manufacturerX: 10},
      );

      expect(await supplierDebt(supplierA, manufacturerX), 15);

      // Both legs, appended (never edited) on the one receipt.
      final ledger = await db.select(db.supplierCrateLedger).get();
      expect(ledger, hasLength(2));
      expect(
        ledger.map((r) => (r.movementType, r.quantityDelta)).toSet(),
        {('received', 25), ('returned', -10)},
      );
    });

    test('the debt moves in BOTH directions — it is no longer one-way down',
        () async {
      await receive(fullCratesIn: const {manufacturerX: 10});
      expect(await supplierDebt(supplierA, manufacturerX), 10);

      await receive(emptiesBack: const {manufacturerX: 4});
      expect(await supplierDebt(supplierA, manufacturerX), 6);

      await receive(fullCratesIn: const {manufacturerX: 9});
      expect(await supplierDebt(supplierA, manufacturerX), 15);
    });

    test('a receipt recording no crate movement behaves exactly as before',
        () async {
      await receive();

      expect(await db.select(db.supplierCrateLedger).get(), isEmpty);
      expect(await supplierDebt(supplierA, manufacturerX), 0);
      // The stock still landed — a crate-less receipt is a normal receipt.
      final inv = await db.select(db.inventory).get();
      expect(inv.single.quantity, 240);
    });

    test('only bottle lines that track empties are eligible — a PET line never '
        'reaches the supplier crate ledger', () async {
      // Both manufacturers are on the delivery, and a figure is typed against
      // BOTH. Only manufacturerX (the bottle + trackEmpties line) may post.
      await receive(
        lines: const [bottleLine, petLine],
        fullCratesIn: const {manufacturerX: 12, manufacturerY: 7},
        emptiesBack: const {manufacturerX: 3, manufacturerY: 5},
      );

      final ledger = await db.select(db.supplierCrateLedger).get();
      expect(ledger.every((r) => r.manufacturerId == manufacturerX), isTrue,
          reason: 'PET packaging has no crates to owe');
      expect(await supplierDebt(supplierA, manufacturerX), 9);
      expect(await supplierDebt(supplierA, manufacturerY), 0);
    });

    test('the receipt leg carries no money — this slice is counting only',
        () async {
      await receive(
        fullCratesIn: const {manufacturerX: 30},
        emptiesBack: const {manufacturerX: 10},
      );

      final ledger = await db.select(db.supplierCrateLedger).get();
      expect(ledger.every((r) => r.depositPaidKobo == 0), isTrue,
          reason: 'deposit money is #212\'s job, not this slice\'s');
      // No supplier money moved either: no invoice was paid and no crate
      // payment was invented.
      expect(await db.select(db.paymentTransactions).get(), isEmpty);
    });

    test('the receipt leg is all-or-nothing with the rest of the receipt',
        () async {
      // A trackEmpties line whose manufacturer does not exist forces an FK
      // violation on the RECEIPT write, after the invoice + stock writes.
      const orphanLine = ReceiveCartLine(
        productId: bottleProductId,
        productName: 'Star 60cl',
        unit: 'Bottle',
        qty: 5,
        buyingPriceKobo: 10000,
        retailKobo: 12000,
        wholesaleKobo: 11000,
        manufacturerId: 'mfr-does-not-exist',
        trackEmpties: true,
      );

      await expectLater(
        receive(
          lines: const [orphanLine],
          fullCratesIn: const {'mfr-does-not-exist': 4},
        ),
        throwsA(anything),
      );

      expect(await db.select(db.supplierCrateLedger).get(), isEmpty);
      expect(await db.select(db.inventory).get(), isEmpty);
      expect(await db.supplierLedgerDao.getBalanceKobo(supplierA), 0);
    });

    test('the receipt Activity Log row names the crate movement', () async {
      await receive(
        fullCratesIn: const {manufacturerX: 25},
        emptiesBack: const {manufacturerX: 10},
      );

      final rows = await db.select(db.activityLogs).get();
      final receipt =
          rows.where((r) => r.action == 'stock.received').single;
      expect(receipt.description, contains('25 full crates in'));
      expect(receipt.description, contains('10 empty crates back'));
    });

    test('a crate-less receipt logs no crate clause', () async {
      await receive();

      final rows = await db.select(db.activityLogs).get();
      final receipt =
          rows.where((r) => r.action == 'stock.received').single;
      expect(receipt.description, isNot(contains('crates:')));
    });

    test('the crate figure is typed, never derived from the drinks delivered',
        () async {
      // 240 bottles arrive but only 10 crates are typed. Nothing in the commit
      // may substitute the bottle count for the crate count — crate size is a
      // category (Big/Medium/Small), so the two are unrelated numbers.
      await receive(fullCratesIn: const {manufacturerX: 10});

      expect(await supplierDebt(supplierA, manufacturerX), 10);
      final inv = await db.select(db.inventory).get();
      expect(inv.single.quantity, 240);
    });
  });

  group('no absolute-value push (AC: only ledger rows sync)', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(db);
    });

    tearDown(() => db.close());

    Future<List<String>> queuedActionTypes() async {
      final rows = await db.select(db.syncQueue).get();
      return rows.map((r) => r.actionType).toList()..sort();
    }

    test('a supplier receipt enqueues only the ledger row, never the cache',
        () async {
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 5,
        performedBy: userId,
      );

      final types = await queuedActionTypes();
      expect(types, contains('supplier_crate_ledger:upsert'));
      expect(types, isNot(contains('supplier_crate_balances:upsert')),
          reason: 'the absolute cache value must never cross the wire');
    });

    test('a supplier return enqueues only the ledger row', () async {
      await db.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 3,
        performedBy: userId,
      );

      final types = await queuedActionTypes();
      expect(types, ['supplier_crate_ledger:upsert']);
    });

    test('the cache is still written locally (a local-only projection)',
        () async {
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 9,
        performedBy: userId,
      );

      final balRows = await db.select(db.supplierCrateBalances).get();
      expect(balRows, hasLength(1));
      expect(balRows.single.balance, 9);
    });
  });

  group('business-wide supplier crate debt VALUE (#163 net-position leg)', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(db);
    });

    tearDown(() => db.close());

    Future<int> debtValue() =>
        db.cratePoolDao.watchSupplierCrateDebtValueKobo().first;

    test('no supplier crate activity → 0', () async {
      expect(await debtValue(), 0);
    });

    test('value = net crates owed × deposit rate, summed across all suppliers '
        'and manufacturers', () async {
      // Supplier A: owe 100 X, return 80 X → net 20 X.
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 100,
        performedBy: userId,
      );
      await db.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 80,
        performedBy: userId,
      );
      // Supplier B: owe 10 X.
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierB,
        manufacturerId: manufacturerX,
        quantity: 10,
        performedBy: userId,
      );
      // Supplier A: owe 5 Y.
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerY,
        quantity: 5,
        performedBy: userId,
      );

      // X: (20 + 10) × 50,000 = 1,500,000; Y: 5 × 30,000 = 150,000.
      expect(await debtValue(), 1650000);
    });

    test('a supplier crate credit (negative balance) nets the debt down',
        () async {
      // Owe 4 X, then return 10 X → net −6 X (the supplier owes us a credit).
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 4,
        performedBy: userId,
      );
      await db.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 10,
        performedBy: userId,
      );
      // −6 × 50,000 = −300,000 (a net crate asset, correctly reducing debt).
      expect(await debtValue(), -300000);
    });

    test('a fully-settled brand contributes 0 to the value', () async {
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 12,
        performedBy: userId,
      );
      await db.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 12,
        performedBy: userId,
      );
      expect(await debtValue(), 0);
    });

    test('re-emits live as new supplier crate movements land', () async {
      final emissions = <int>[];
      final sub =
          db.cratePoolDao.watchSupplierCrateDebtValueKobo().listen(emissions.add);
      await pumpEventQueue();
      expect(emissions.last, 0);

      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerY,
        quantity: 3,
        performedBy: userId,
      );
      await pumpEventQueue();
      // 3 × 30,000 = 90,000.
      expect(emissions.last, 90000);
      await sub.cancel();
    });
  });

  group('multi-device convergence (the drift the model removes)', () {
    test('two offline tills merge; derived balance == combined ledger sum',
        () async {
      // Two devices build INDEPENDENT ledgers offline for the SAME supplier +
      // manufacturer. Till 1 receives 10 full crates (we owe 10); Till 2 hands
      // 4 empties back (returned). Under the old absolute-cache push these two
      // would clobber each other (last writer wins → one movement lost). Under
      // ledger-as-truth both rows survive the merge and the derived balance is
      // their sum (10 - 4 = 6).
      final till1 = AppDatabase.forTesting(NativeDatabase.memory());
      final till2 = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(till1);
      await seed(till2);

      await till1.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 10,
        performedBy: userId,
      );
      await till2.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: manufacturerX,
        quantity: 4,
        performedBy: userId,
      );

      // Simulate the cloud converging both append-only ledgers onto one device:
      // copy every supplier_crate_ledger row from each till into a merged
      // database. Rows are id-keyed (UuidV7) so an insert-or-ignore merge keeps
      // both.
      final merged = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(merged);
      for (final source in [till1, till2]) {
        final rows = await source.select(source.supplierCrateLedger).get();
        for (final r in rows) {
          await merged
              .into(merged.supplierCrateLedger)
              .insert(r.toCompanion(true), mode: InsertMode.insertOrIgnore);
        }
      }

      final rows =
          await merged.cratePoolDao.watchSupplierCrateDebt(supplierA).first;
      expect(rows, hasLength(1));
      expect(rows.single.balance, 6,
          reason: 'both movements survive the merge — nothing clobbered');

      // Both ledger rows are physically present on the merged device.
      final ledger = await merged.select(merged.supplierCrateLedger).get();
      expect(ledger, hasLength(2));

      await till1.close();
      await till2.close();
      await merged.close();
    });
  });
}
