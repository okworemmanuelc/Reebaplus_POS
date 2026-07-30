// crate_standing_float_test.dart
//
// #214 / PRD #203, ADR 0023 rules 1 and 4 — the standing float.
//
// A float is a lump sum placed once with a supplier for the right to hold their
// crates. The governing rule decides everything here: **a book entry appears
// only when money genuinely moved**.
//
//   1. TRADING MOVES NOTHING. Deliveries and hand-backs on a float brand leave
//      every money figure exactly where it was. The owner's cash is not
//      disturbed by a lorry arriving.
//   2. LOSSES MOVE NOTHING EITHER. This is the arrangement most likely to be
//      mis-modelled by charging a loss the moment a crate goes missing. The
//      supplier has not deducted anything, so booking one would show money
//      leaving that nobody took. Missing crates eat float headroom and raise
//      the brand-level Shortfall (#216) instead.
//   3. A TOP-UP IS THE PAYMENT IT IS. Cash out of the drawer, the Placed
//      Deposit asset up by the same amount, worth unchanged.
//   4. A PAYOUT IS THE MONEY COMING HOME. Cash back, asset down.
//   5. THE FAMILY. Both are `crate_deposit_out` — never an expense, never a
//      refund. That is the #190/#201 defect and it does not get to happen here.
//   6. NO RESTATEMENT. Switching a brand between `per_delivery` and
//      `standing_float` leaves every past figure exactly as it was (ADR 0021).
//   7. THE RELEASE GATE. `none` brands are untouched, and `per_delivery` brands
//      behave exactly as #212/#213 left them.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/crates/crate_deposit_position.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/services/receive_stock_service.dart';
import 'package:reebaplus_pos/shared/services/supplier_account_service.dart';
import 'package:reebaplus_pos/shared/services/supplier_crate_service.dart';

void main() {
  const businessId = 'biz-1';
  const stockKeeperId = 'user-keeper';
  const managerId = 'user-manager';
  const storeId = 'store-1';
  const supplierA = 'sup-a';
  // ₦3,500 a crate.
  const rate = 350000;
  const floatBrand = 'mfr-float';
  const perDeliveryBrand = 'mfr-per-delivery';
  const swapBrand = 'mfr-swap';

  Future<void> seed(AppDatabase db) async {
    db.businessIdResolver = () => businessId;
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
        );
    for (final u in [stockKeeperId, managerId]) {
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: Value(u),
              businessId: businessId,
              name: u,
              pin: '1234',
            ),
          );
    }
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: const Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    const brands = {
      floatBrand: (
        'Star Lager',
        kCrateMoneyArrangementStandingFloat,
      ),
      perDeliveryBrand: ('Gulder', kCrateMoneyArrangementPerDelivery),
      swapBrand: ('Trophy', kCrateMoneyArrangementNone),
    };
    for (final entry in brands.entries) {
      await db
          .into(db.manufacturers)
          .insert(
            ManufacturersCompanion.insert(
              id: Value(entry.key),
              businessId: businessId,
              name: entry.value.$1,
              depositAmountKobo: const Value(rate),
              crateMoneyArrangement: Value(entry.value.$2),
            ),
          );
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: Value('prod-${entry.key}'),
              businessId: businessId,
              name: 'Bottle of ${entry.value.$1}',
              unit: const Value('Bottle'),
              buyingPriceKobo: const Value(10000),
              manufacturerId: Value(entry.key),
              trackEmpties: const Value(true),
            ),
          );
    }
    await db
        .into(db.suppliers)
        .insert(
          SuppliersCompanion.insert(
            id: const Value(supplierA),
            businessId: businessId,
            name: 'Ade Depot',
          ),
        );
  }

  ReceiveCartLine lineFor(String manufacturerId) => ReceiveCartLine(
    productId: 'prod-$manufacturerId',
    productName: 'Bottle of $manufacturerId',
    unit: 'Bottle',
    qty: 24,
    buyingPriceKobo: 10000,
    retailKobo: 12000,
    wholesaleKobo: 11000,
    manufacturerId: manufacturerId,
    trackEmpties: true,
  );

  late AppDatabase db;
  late ReceiveStockService service;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await seed(db);
    service = ReceiveStockService(db, SupplierAccountService(db));
  });

  tearDown(() => db.close());

  Future<void> receive({
    required String manufacturerId,
    int crates = 0,
    int empties = 0,
  }) => service.confirmReceipt(
    supplierId: supplierA,
    supplierName: 'Ade Depot',
    storeId: storeId,
    dateReceived: DateTime(2026, 7, 30),
    staffId: stockKeeperId,
    lines: [lineFor(manufacturerId)],
    fullCratesReceivedByManufacturer: {manufacturerId: crates},
    emptiesReturnedByManufacturer: {manufacturerId: empties},
  );

  Future<List<PaymentTransactionData>> payments() =>
      db.select(db.paymentTransactions).get();

  /// Net cash that has gone OUT of the drawer on crate deposits. Positive =
  /// money is still out there with a supplier.
  Future<int> netCashOut() async {
    final rows = await payments();
    return rows
        .where((p) => p.type == kPaymentTypeCrateDepositOut)
        .fold<int>(0, (s, p) => s + p.amountKobo);
  }

  /// The Placed Deposit this supplier holds for a brand, read through the ONE
  /// seam — never re-derived here.
  Future<int> placed(String brand, {String supplierId = supplierA}) async {
    final rows = await db.cratePoolDao
        .watchSupplierCrateDepositPositions(supplierId)
        .first;
    final match = rows.where((r) => r.manufacturerId == brand).toList();
    return match.isEmpty ? 0 : match.single.position.placedDepositKobo;
  }

  Future<int> supplierDebt(String manufacturerId) async {
    final rows = await db.cratePoolDao.watchSupplierCrateDebt(supplierA).first;
    final match = rows.where((r) => r.manufacturerId == manufacturerId).toList();
    return match.isEmpty ? 0 : match.single.balance;
  }

  Future<void> setArrangement(String manufacturerId, String arrangement) async {
    await (db.update(
      db.manufacturers,
    )..where((t) => t.id.equals(manufacturerId))).write(
      ManufacturersCompanion(crateMoneyArrangement: Value(arrangement)),
    );
  }

  Future<String?> topUp(int amountKobo, {String brand = floatBrand}) =>
      db.cratePoolDao.recordCrateFloatMovement(
        supplierId: supplierA,
        manufacturerId: brand,
        amountKobo: amountKobo,
        isTopUp: true,
        performedBy: managerId,
      );

  Future<String?> payout(int amountKobo, {String brand = floatBrand}) =>
      db.cratePoolDao.recordCrateFloatMovement(
        supplierId: supplierA,
        manufacturerId: brand,
        amountKobo: amountKobo,
        isTopUp: false,
        performedBy: managerId,
      );

  // ── 1. Ordinary trading moves no money ────────────────────────────────────

  group('a float brand trades without money moving', () {
    test('an ordinary delivery moves no money at all — the crates land, the '
        'drawer does not notice', () async {
      await receive(manufacturerId: floatBrand, crates: 12);

      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await payments(), isEmpty);
      // #210's counting leg is untouched by any of this and still stands.
      expect(await supplierDebt(floatBrand), 12);
    });

    test('handing empties back moves no money either — the float stays where '
        'it is', () async {
      await topUp(5000000); // ₦50,000 float placed with the depot.
      await receive(manufacturerId: floatBrand, crates: 12);
      final before = await netCashOut();

      await SupplierCrateService(db).recordReturn(
        supplierId: supplierA,
        supplierName: 'Ade Depot',
        manufacturerId: floatBrand,
        manufacturerName: 'Star Lager',
        quantity: 12,
        staffId: stockKeeperId,
        storeId: storeId,
      );

      expect(await netCashOut(), before);
      expect(await placed(floatBrand), 5000000);
      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
      // The count still came home.
      expect(await supplierDebt(floatBrand), 0);
    });

    test('a receipt that also carries empties raises nothing on either leg',
        () async {
      await receive(manufacturerId: floatBrand, crates: 10, empties: 6);

      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
      expect(await payments(), isEmpty);
      expect(await supplierDebt(floatBrand), 4);
    });
  });

  // ── 2. Losses move no money ───────────────────────────────────────────────

  group('crates going missing on a float brand move NO money', () {
    test('damaged crates leave the float and the drawer exactly as they were',
        () async {
      await topUp(5000000);
      await receive(manufacturerId: floatBrand, crates: 20);
      await db.cratePoolDao.addEmptiesToPool(floatBrand, 20, storeId: storeId);
      final cashBefore = await netCashOut();
      final placedBefore = await placed(floatBrand);

      await db.cratePoolDao.recordDamage(floatBrand, 7, storeId: storeId);

      expect(await netCashOut(), cashBefore);
      expect(await placed(floatBrand), placedBefore);
      expect(
        await db.select(db.supplierCrateDepositRequests).get(),
        isEmpty,
        reason: 'a loss is a Shortfall (#216), never a money leg',
      );
    });

    test('a stock count that finds crates missing moves no money', () async {
      await topUp(5000000);
      await receive(manufacturerId: floatBrand, crates: 20);
      await db.cratePoolDao.addEmptiesToPool(floatBrand, 20, storeId: storeId);
      final cashBefore = await netCashOut();

      // The yard is counted and comes up 5 short of what the pool believed.
      final pool = await db.cratePoolDao
          .watchEmptiesPoolByManufacturer()
          .first;
      await db.cratePoolDao.recordManualCountCorrection(
        floatBrand,
        (pool[floatBrand] ?? 0) - 5,
      );

      expect(await netCashOut(), cashBefore);
      expect(await placed(floatBrand), 5000000);
    });

    test('the missing crates DO show as a shortfall through the seam — the '
        'warning exists, the money entry does not', () async {
      await topUp(5000000);
      await receive(manufacturerId: floatBrand, crates: 20);
      await db.cratePoolDao.addEmptiesToPool(floatBrand, 20, storeId: storeId);
      await db.cratePoolDao.recordDamage(floatBrand, 7, storeId: storeId);

      final manufacturer =
          await (db.select(db.manufacturers)
                ..where((t) => t.id.equals(floatBrand)))
              .getSingle();
      final pool = await db.cratePoolDao
          .watchEmptiesPoolByManufacturer()
          .first;
      final position = computeCrateDepositPosition(
        arrangement: crateMoneyArrangementOf(
          manufacturer.crateMoneyArrangement,
        ),
        ratePerCrateKobo: manufacturer.depositAmountKobo,
        cratesOwed: 20,
        emptiesOnHand: pool[floatBrand] ?? 0,
      );

      expect(position.shortfallCrates, 7);
      expect(position.shortfallValueKobo, 7 * rate);
      // …and none of it is money that has left anybody's hands.
      expect(await netCashOut(), 5000000);
    });
  });

  // ── 3. A top-up is the payment it is ──────────────────────────────────────

  group('a top-up', () {
    test('raises the cash outflow and the Placed Deposit by the same amount',
        () async {
      final id = await topUp(5000000);
      expect(id, isNotNull);

      expect(await netCashOut(), 5000000);
      expect(await placed(floatBrand), 5000000);

      final rows = await db.select(db.supplierCrateDeposits).get();
      expect(rows, hasLength(1));
      expect(rows.single.movementType, kCrateDepositMovementFloatTopup);
      expect(rows.single.signedAmountKobo, 5000000);
      // A float backs the RELATIONSHIP, not a numbered set of crates.
      expect(rows.single.crateCount, 0);
    });

    test('is in the deposit family — never an expense, never a refund',
        () async {
      await topUp(5000000);

      final cash = await payments();
      expect(cash, hasLength(1));
      expect(cash.single.type, kPaymentTypeCrateDepositOut);
      expect(cash.single.amountKobo, 5000000);
      expect(await db.select(db.expenses).get(), isEmpty);
    });

    test('is attributable — who recorded it, and which way the money went',
        () async {
      await topUp(5000000);

      final logs = await db.select(db.activityLogs).get();
      final entry = logs.singleWhere(
        (l) => l.action == 'crate_float_topped_up',
      );
      expect(entry.userId, managerId);
      expect(entry.description, contains('Star Lager'));
      expect(entry.description, contains('Ade Depot'));
    });

    test('accumulates — a second top-up adds to the float, it does not '
        'replace it', () async {
      await topUp(5000000);
      await topUp(2000000);

      expect(await placed(floatBrand), 7000000);
      expect(await netCashOut(), 7000000);
    });

    test('is refused on a `none` brand and on a `per_delivery` brand', () async {
      expect(await topUp(5000000, brand: swapBrand), isNull);
      expect(await topUp(5000000, brand: perDeliveryBrand), isNull);

      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await payments(), isEmpty);
    });

    test('a zero or negative amount posts nothing', () async {
      expect(await topUp(0), isNull);
      expect(await topUp(-5000), isNull);
      expect(await payments(), isEmpty);
    });
  });

  // ── 4. A payout is the money coming home ──────────────────────────────────

  group('a payout', () {
    test('returns the money and lowers the Placed Deposit', () async {
      await topUp(5000000);

      final id = await payout(3000000);
      expect(id, isNotNull);

      expect(await netCashOut(), 2000000);
      expect(await placed(floatBrand), 2000000);

      final row = (await db.select(db.supplierCrateDeposits).get()).singleWhere(
        (r) => r.movementType == kCrateDepositMovementFloatPayout,
      );
      expect(row.signedAmountKobo, -3000000);
      expect(row.crateCount, 0);
    });

    test('winding the relationship down empties the float to nothing',
        () async {
      await topUp(5000000);
      await payout(5000000);

      expect(await placed(floatBrand), 0);
      expect(await netCashOut(), 0);
    });

    test('is a NEGATIVE row in the deposit family, never a refund', () async {
      await topUp(5000000);
      await payout(3000000);

      final cash = await payments();
      expect(cash, hasLength(2));
      expect(
        cash.every((p) => p.type == kPaymentTypeCrateDepositOut),
        isTrue,
      );
      expect(
        cash.map((p) => p.amountKobo).toList()..sort(),
        [-3000000, 5000000],
      );
    });

    test('recording more than the books say is held is NOT swallowed — the '
        'disagreement is surfaced', () async {
      await topUp(1000000);
      await payout(1500000);

      expect(
        await placed(floatBrand),
        -500000,
        reason:
            'clamping would hide a real disagreement with the depot; the seam '
            'surfaces a negative rather than lying',
      );
    });

    test('is attributable', () async {
      await topUp(5000000);
      await payout(3000000);

      final logs = await db.select(db.activityLogs).get();
      expect(
        logs.where((l) => l.action == 'crate_float_paid_out'),
        hasLength(1),
      );
    });
  });

  // ── 5. Worth does not move ────────────────────────────────────────────────

  test('a top-up does not change what the business is worth — cash falls and '
      'an asset of the same size appears', () async {
    await topUp(5000000);

    final cashDelta = await netCashOut(); // money out of the drawer
    final asset = await placed(floatBrand); // money sitting with the depot
    expect(cashDelta, asset);
  });

  // ── 6. The approval queue carries a float leg too ─────────────────────────

  group('a float leg raised for a money-permitted role', () {
    test('a top-up can be queued and confirmed, landing the same two legs',
        () async {
      final requestId = await db.cratePoolDao.raiseCrateDepositRequest(
        supplierId: supplierA,
        manufacturerId: floatBrand,
        storeId: storeId,
        crateCount: 0,
        requestedBy: stockKeeperId,
        kind: kCrateDepositMovementFloatTopup,
        requestedAmountKobo: 5000000,
      );
      expect(requestId, isNotNull);

      // Nothing has moved yet — a request is not a book entry.
      expect(await payments(), isEmpty);
      expect(await placed(floatBrand), 0);

      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: requestId!,
        decidedBy: managerId,
      );

      expect(await netCashOut(), 5000000);
      expect(await placed(floatBrand), 5000000);
    });

    test('a queued top-up with no amount raises nothing — how much you chose '
        'to add is a fact only the payer knows', () async {
      final requestId = await db.cratePoolDao.raiseCrateDepositRequest(
        supplierId: supplierA,
        manufacturerId: floatBrand,
        storeId: storeId,
        crateCount: 0,
        requestedBy: stockKeeperId,
        kind: kCrateDepositMovementFloatTopup,
      );
      expect(requestId, isNull);
    });

    test('a queued payout with no amount suggests the whole float, capped at '
        'what is actually held', () async {
      await topUp(5000000);

      final requestId = await db.cratePoolDao.raiseCrateDepositRequest(
        supplierId: supplierA,
        manufacturerId: floatBrand,
        storeId: storeId,
        crateCount: 0,
        requestedBy: stockKeeperId,
        kind: kCrateDepositMovementFloatPayout,
      );
      final request =
          await (db.select(db.supplierCrateDepositRequests)
                ..where((t) => t.id.equals(requestId!)))
              .getSingle();
      expect(request.requestedAmountKobo, 5000000);

      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: requestId!,
        decidedBy: managerId,
        amountKobo: 4000000, // the depot handed back a little less
      );
      expect(await placed(floatBrand), 1000000);
    });

    test('a float brand with NO rate can still take a top-up — a lump sum '
        'needs no per-crate price', () async {
      await (db.update(
        db.manufacturers,
      )..where((t) => t.id.equals(floatBrand))).write(
        const ManufacturersCompanion(depositAmountKobo: Value(0)),
      );

      expect(await topUp(5000000), isNotNull);
      expect(await placed(floatBrand), 5000000);
    });

    test('a `per_delivery` kind is refused on a float brand and a float kind '
        'is refused on a `per_delivery` brand', () async {
      expect(
        await db.cratePoolDao.raiseCrateDepositRequest(
          supplierId: supplierA,
          manufacturerId: floatBrand,
          storeId: storeId,
          crateCount: 8,
          requestedBy: stockKeeperId,
          kind: kCrateDepositMovementPlacement,
        ),
        isNull,
      );
      expect(
        await db.cratePoolDao.raiseCrateDepositRequest(
          supplierId: supplierA,
          manufacturerId: perDeliveryBrand,
          storeId: storeId,
          crateCount: 0,
          requestedBy: stockKeeperId,
          kind: kCrateDepositMovementFloatTopup,
          requestedAmountKobo: 5000000,
        ),
        isNull,
      );
      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
    });
  });

  // ── 7. `per_delivery` still behaves exactly as #212/#213 left it ──────────

  group('the other two arrangements are untouched', () {
    test('a `per_delivery` delivery still raises its placement, and confirming '
        'it still moves the money', () async {
      await receive(manufacturerId: perDeliveryBrand, crates: 8);

      final pending = await db.select(db.supplierCrateDepositRequests).get();
      expect(pending, hasLength(1));
      expect(pending.single.kind, kCrateDepositMovementPlacement);
      expect(pending.single.requestedAmountKobo, 8 * rate);

      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: pending.single.id,
        decidedBy: managerId,
      );
      expect(await placed(perDeliveryBrand), 8 * rate);
      expect(await netCashOut(), 8 * rate);
    });

    test('a `per_delivery` brand with a zero rate still raises nothing',
        () async {
      await (db.update(
        db.manufacturers,
      )..where((t) => t.id.equals(perDeliveryBrand))).write(
        const ManufacturersCompanion(depositAmountKobo: Value(0)),
      );

      await receive(manufacturerId: perDeliveryBrand, crates: 8);
      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
    });

    test('a `none` brand records crates and nothing else', () async {
      await receive(manufacturerId: swapBrand, crates: 12);

      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
      expect(await payments(), isEmpty);
      expect(await supplierDebt(swapBrand), 12);
    });
  });

  // ── 8. Switching an arrangement never restates history ────────────────────

  group('switching a brand between arrangements restates nothing', () {
    test('`per_delivery` → `standing_float`: every deposit already placed is '
        'still there, at the same figure', () async {
      await receive(manufacturerId: perDeliveryBrand, crates: 8);
      final pending = await db.select(db.supplierCrateDepositRequests).get();
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: pending.single.id,
        decidedBy: managerId,
      );

      final placedBefore = await placed(perDeliveryBrand);
      final cashBefore = await netCashOut();
      final rowsBefore = await db.select(db.supplierCrateDeposits).get();

      await setArrangement(perDeliveryBrand, kCrateMoneyArrangementStandingFloat);

      expect(await placed(perDeliveryBrand), placedBefore);
      expect(await netCashOut(), cashBefore);
      final rowsAfter = await db.select(db.supplierCrateDeposits).get();
      expect(rowsAfter.length, rowsBefore.length);
      expect(
        rowsAfter.map((r) => r.signedAmountKobo).toList(),
        rowsBefore.map((r) => r.signedAmountKobo).toList(),
      );
    });

    test('and from then on it behaves as a float — the next delivery moves no '
        'money, while the old placement stays on the books', () async {
      await receive(manufacturerId: perDeliveryBrand, crates: 8);
      final pending = await db.select(db.supplierCrateDepositRequests).get();
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: pending.single.id,
        decidedBy: managerId,
      );

      await setArrangement(perDeliveryBrand, kCrateMoneyArrangementStandingFloat);
      await receive(manufacturerId: perDeliveryBrand, crates: 8);

      expect(
        await (db.select(db.supplierCrateDepositRequests)
              ..where((t) => t.status.equals(kCrateDepositRequestPending)))
            .get(),
        isEmpty,
      );
      expect(await placed(perDeliveryBrand), 8 * rate);
      expect(await netCashOut(), 8 * rate);
    });

    test('`standing_float` → `per_delivery`: the float stays exactly where it '
        'is and the next delivery starts asking per delivery', () async {
      await topUp(5000000);
      final floatBefore = await placed(floatBrand);

      await setArrangement(floatBrand, kCrateMoneyArrangementPerDelivery);

      expect(await placed(floatBrand), floatBefore);

      await receive(manufacturerId: floatBrand, crates: 4);
      final pending = await db.select(db.supplierCrateDepositRequests).get();
      expect(pending, hasLength(1));
      expect(pending.single.kind, kCrateDepositMovementPlacement);
      // …and the float is still there beside it, unrestated.
      expect(await placed(floatBrand), floatBefore);
    });

    test('switching a brand to `none` hides the money without deleting it — '
        'switching back reads exactly the same figure', () async {
      await topUp(5000000);

      await setArrangement(floatBrand, kCrateMoneyArrangementNone);
      expect(await placed(floatBrand), 0);
      expect(
        await db.select(db.supplierCrateDeposits).get(),
        hasLength(1),
        reason: 'the rows are suppressed by the read seam, never destroyed',
      );

      await setArrangement(floatBrand, kCrateMoneyArrangementStandingFloat);
      expect(await placed(floatBrand), 5000000);
    });
  });

  // ── 9. The kind/arrangement rule as a pure predicate ──────────────────────

  group('crateDepositKindAllowedFor', () {
    test('`none` admits nothing at all', () {
      for (final kind in kCrateDepositRequestKinds) {
        expect(
          crateDepositKindAllowedFor(CrateMoneyArrangement.none, kind),
          isFalse,
          reason: '$kind must not be raisable on a swap-only brand',
        );
      }
    });

    test('`per_delivery` admits a placement and a release only', () {
      expect(
        crateDepositKindAllowedFor(
          CrateMoneyArrangement.perDelivery,
          kCrateDepositMovementPlacement,
        ),
        isTrue,
      );
      expect(
        crateDepositKindAllowedFor(
          CrateMoneyArrangement.perDelivery,
          kCrateDepositMovementRelease,
        ),
        isTrue,
      );
      expect(
        crateDepositKindAllowedFor(
          CrateMoneyArrangement.perDelivery,
          kCrateDepositMovementFloatTopup,
        ),
        isFalse,
      );
    });

    test('`standing_float` admits a top-up and a payout only', () {
      expect(
        crateDepositKindAllowedFor(
          CrateMoneyArrangement.standingFloat,
          kCrateDepositMovementFloatTopup,
        ),
        isTrue,
      );
      expect(
        crateDepositKindAllowedFor(
          CrateMoneyArrangement.standingFloat,
          kCrateDepositMovementFloatPayout,
        ),
        isTrue,
      );
      expect(
        crateDepositKindAllowedFor(
          CrateMoneyArrangement.standingFloat,
          kCrateDepositMovementPlacement,
        ),
        isFalse,
      );
      expect(
        crateDepositKindAllowedFor(
          CrateMoneyArrangement.standingFloat,
          kCrateDepositMovementRelease,
        ),
        isFalse,
      );
    });
  });
}
