// crate_deposit_settlement_test.dart
//
// #213 / PRD #203, ADR 0023 rules 1 and 4 — the money coming home.
//
// #212 proved money can leave the drawer and become an asset. This suite pins
// the other end: handing empties back reduces what the supplier holds of the
// owner's money, and the refund raises cash by the amount ACTUALLY received.
//
//   1. TWO DOORS, ONE LEDGER. Empties handed back on a delivery and a
//      settlement trip that delivered nothing land in exactly the same two
//      ledgers, by the same code. A settlement never invents a fake delivery.
//   2. WHAT WAS ACTUALLY REFUNDED. A depot that short-pays is a fact to
//      record, not a figure to assume — and the difference stays visible as
//      Placed Deposit still held, rather than being quietly cleared.
//   3. WORTH DOES NOT MOVE. Cash rises and the asset falls by the same amount,
//      so money simply coming home cannot make the business look richer.
//   4. THE FAMILY. A release is `crate_deposit_out` with a negative sign —
//      never a `refund`, never income. That is the #190/#201 defect on the
//      customer side and it does not get to happen on the supplier side.
//   5. THE RELEASE GATE. A `none` brand is untouched by every line of this.
//   6. Two offline devices converge, and a correction is a new row.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
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
  const supplierB = 'sup-b';
  // ₦3,500 a crate.
  const rate = 350000;
  const moneyBrand = 'mfr-money';
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
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: const Value(moneyBrand),
            businessId: businessId,
            name: 'Star Lager',
            depositAmountKobo: const Value(rate),
            crateMoneyArrangement: const Value(
              kCrateMoneyArrangementPerDelivery,
            ),
          ),
        );
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: const Value(swapBrand),
            businessId: businessId,
            name: 'Gulder',
            depositAmountKobo: const Value(rate),
            crateMoneyArrangement: const Value(kCrateMoneyArrangementNone),
          ),
        );
    for (final s in [supplierA, supplierB]) {
      await db
          .into(db.suppliers)
          .insert(
            SuppliersCompanion.insert(
              id: Value(s),
              businessId: businessId,
              name: s == supplierA ? 'Ade Depot' : 'Bola Depot',
            ),
          );
    }
    for (final m in [moneyBrand, swapBrand]) {
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: Value('prod-$m'),
              businessId: businessId,
              name: 'Bottle of $m',
              unit: const Value('Bottle'),
              buyingPriceKobo: const Value(10000),
              manufacturerId: Value(m),
              trackEmpties: const Value(true),
            ),
          );
    }
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
    String supplierId = supplierA,
  }) => service.confirmReceipt(
    supplierId: supplierId,
    supplierName: supplierId == supplierA ? 'Ade Depot' : 'Bola Depot',
    storeId: storeId,
    dateReceived: DateTime(2026, 7, 30),
    staffId: stockKeeperId,
    lines: [lineFor(manufacturerId)],
    fullCratesReceivedByManufacturer: {manufacturerId: crates},
    emptiesReturnedByManufacturer: {manufacturerId: empties},
  );

  /// Confirm every still-pending money leg, at the amount asked for unless
  /// [amountKobo] says otherwise. Returns how many were decided.
  Future<int> confirmAllPending({int? amountKobo}) async {
    final pending = await (db.select(
      db.supplierCrateDepositRequests,
    )..where((t) => t.status.equals(kCrateDepositRequestPending))).get();
    for (final r in pending) {
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
        amountKobo: amountKobo,
      );
    }
    return pending.length;
  }

  Future<SupplierCrateDepositRequestData> onlyPending() async {
    final pending = await (db.select(
      db.supplierCrateDepositRequests,
    )..where((t) => t.status.equals(kCrateDepositRequestPending))).get();
    expect(pending, hasLength(1));
    return pending.single;
  }

  /// The Placed Deposit this supplier holds, read through the ONE seam.
  Future<int> placed(String supplierId, [String brand = moneyBrand]) async {
    final rows = await db.cratePoolDao
        .watchSupplierCrateDepositPositions(supplierId)
        .first;
    final match = rows.where((r) => r.manufacturerId == brand).toList();
    return match.isEmpty ? 0 : match.single.position.placedDepositKobo;
  }

  Future<int> supplierDebt(String supplierId, String manufacturerId) async {
    final rows = await db.cratePoolDao.watchSupplierCrateDebt(supplierId).first;
    final match = rows.where((r) => r.manufacturerId == manufacturerId).toList();
    return match.isEmpty ? 0 : match.single.balance;
  }

  Future<List<PaymentTransactionData>> payments() =>
      db.select(db.paymentTransactions).get();

  /// Net cash that has gone OUT of the drawer on crate deposits. Positive =
  /// money is still out there.
  Future<int> netCashOut() async {
    final rows = await payments();
    return rows
        .where((p) => p.type == kPaymentTypeCrateDepositOut)
        .fold<int>(0, (s, p) => s + p.amountKobo);
  }

  // Place ₦28,000 with Ade Depot for 8 crates of Star, and confirm it.
  Future<void> placeDeposit({int crates = 8, String supplier = supplierA}) async {
    await receive(
      manufacturerId: moneyBrand,
      crates: crates,
      supplierId: supplier,
    );
    await confirmAllPending();
  }

  // ── 1. Two doors, one ledger ──────────────────────────────────────────────

  group('empties handed back on a DELIVERY settle the deposit', () {
    test('a receipt that also carries empties raises a `release` beside the '
        'placement, and confirming it brings the money home', () async {
      await placeDeposit(crates: 8);
      expect(await placed(supplierA), 8 * rate);

      // A later delivery: 2 fresh crates in, 5 empties back.
      await receive(manufacturerId: moneyBrand, crates: 2, empties: 5);

      final pending = await (db.select(
        db.supplierCrateDepositRequests,
      )..where((t) => t.status.equals(kCrateDepositRequestPending))).get();
      expect(pending, hasLength(2));
      final release = pending
          .firstWhere((r) => r.kind == kCrateDepositMovementRelease);
      expect(release.crateCount, 5);
      expect(release.requestedAmountKobo, 5 * rate);
      expect(release.summary, contains('returned to Ade Depot'));

      await confirmAllPending();

      // 8 placed + 2 placed − 5 released = 5 crates' worth still with them.
      expect(await placed(supplierA), 5 * rate);
      // The crate count agrees: 8 + 2 − 5 = 5 empties still owed.
      expect(await supplierDebt(supplierA, moneyBrand), 5);
    });

    test('the release row is signed the other way — the asset FALLS and the '
        'crate count it covers falls with it', () async {
      await placeDeposit(crates: 8);
      await receive(manufacturerId: moneyBrand, empties: 3);
      await confirmAllPending();

      final rows = await db.select(db.supplierCrateDeposits).get();
      final release = rows
          .firstWhere((r) => r.movementType == kCrateDepositMovementRelease);
      expect(release.signedAmountKobo, -3 * rate);
      expect(release.crateCount, -3);
      expect(release.ratePerCrateKobo, rate);
    });
  });

  group('a STANDALONE settlement needs no delivery at all', () {
    test('a return trip carrying no goods settles the deposit without writing '
        'a single received crate, invoice line or stock movement', () async {
      await placeDeposit(crates: 8);
      final invoicesBefore = await db.select(db.supplierLedgerEntries).get();

      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 6,
        performedBy: stockKeeperId,
      );
      await confirmAllPending();

      expect(await placed(supplierA), 2 * rate);
      expect(await supplierDebt(supplierA, moneyBrand), 2);

      // Nothing was invented to hang the settlement on: no phantom delivery of
      // full crates, and not a naira of goods owed.
      final crateRows = await db.select(db.supplierCrateLedger).get();
      expect(
        crateRows.where((r) => r.quantityDelta > 0).length,
        1,
        reason: 'only the ORIGINAL receipt put crates on the ledger',
      );
      expect(
        await db.select(db.supplierLedgerEntries).get(),
        hasLength(invoicesBefore.length),
      );
    });

    test('a money-only settlement — the supplier simply pays a balance back, '
        'with nothing on the truck', () async {
      await placeDeposit(crates: 8);

      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 0,
        performedBy: managerId,
        refundAmountKobo: 1000000,
      );
      final r = await onlyPending();
      expect(r.kind, kCrateDepositMovementRelease);
      expect(r.crateCount, 0);
      expect(r.requestedAmountKobo, 1000000);

      await confirmAllPending();

      expect(await placed(supplierA), 8 * rate - 1000000);
      // The crates are a separate fact and did not move.
      expect(await supplierDebt(supplierA, moneyBrand), 8);
    });

    test('a money-only settlement with no amount is refused — there is nothing '
        'to derive one from, and guessing is the whole defect', () async {
      await placeDeposit(crates: 8);
      final id = await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 0,
        performedBy: managerId,
      );
      expect(id, isNull);
      expect(
        await (db.select(db.supplierCrateDepositRequests)
              ..where((t) => t.status.equals(kCrateDepositRequestPending)))
            .get(),
        isEmpty,
      );
    });

    test('the service wrapper records it in the activity log', () async {
      await placeDeposit(crates: 8);
      await SupplierCrateService(db).recordSettlement(
        supplierId: supplierA,
        supplierName: 'Ade Depot',
        manufacturerId: moneyBrand,
        manufacturerName: 'Star Lager',
        crateCount: 6,
        staffId: stockKeeperId,
        storeId: storeId,
      );
      final logs = await db.select(db.activityLogs).get();
      expect(
        logs.where((l) => l.action == 'supplier.crate_settled'),
        hasLength(1),
      );

      await confirmAllPending();
      expect(
        logs.length + 1,
        lessThanOrEqualTo((await db.select(db.activityLogs).get()).length),
        reason: 'the confirmation is logged too',
      );
      final confirmed = (await db.select(db.activityLogs).get())
          .where((l) => l.action == 'crate_deposit_confirmed')
          .map((l) => l.description)
          .toList();
      expect(confirmed.last, contains('refund'));
    });
  });

  // ── 2. What was ACTUALLY refunded ─────────────────────────────────────────

  group('a short refund is visible, not assumed away', () {
    test('the depot pays back less than the deposit — the difference stays as '
        'Placed Deposit still held', () async {
      await placeDeposit(crates: 8); // ₦28,000 with them.

      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 8,
        performedBy: stockKeeperId,
      );
      final release = await onlyPending();
      expect(release.requestedAmountKobo, 8 * rate);

      // They handed back ₦20,000 of the ₦28,000.
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: release.id,
        decidedBy: managerId,
        amountKobo: 2000000,
      );

      expect(
        await placed(supplierA),
        8 * rate - 2000000,
        reason: 'the ₦8,000 they kept is still ours and still visible',
      );
      // And it did NOT silently clear: the position is not settled.
      final pos = (await db.cratePoolDao
              .watchSupplierCrateDepositPositions(supplierA)
              .first)
          .single
          .position;
      expect(pos.isSettled, isFalse);
      expect(pos.placedDepositKobo, 800000);
    });

    test('the request records what was ASKED and the decision what was PAID — '
        'both survive, so the shortfall is auditable', () async {
      await placeDeposit(crates: 8);
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 8,
        performedBy: stockKeeperId,
      );
      final release = await onlyPending();
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: release.id,
        decidedBy: managerId,
        amountKobo: 2000000,
      );

      final after = await (db.select(
        db.supplierCrateDepositRequests,
      )..where((t) => t.id.equals(release.id))).getSingle();
      expect(after.requestedAmountKobo, 8 * rate);
      expect(after.settledAmountKobo, 2000000);
      expect(after.status, kCrateDepositRequestConfirmed);

      final log = (await db.select(db.activityLogs).get())
          .where((l) => l.action == 'crate_deposit_confirmed')
          .last;
      expect(log.description, contains('short of'));
      expect(log.description, contains('stays held'));
    });

    test('the person on the trip can state the refund up front, and it is NOT '
        'capped — a depot may hand back more than the rate implies', () async {
      await placeDeposit(crates: 8);
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 2,
        performedBy: stockKeeperId,
        refundAmountKobo: 1500000,
      );
      expect((await onlyPending()).requestedAmountKobo, 1500000);
    });

    test('a settlement never SUGGESTS more than the supplier is holding — a '
        'brand switched on today owes crates no money was ever placed on',
        () async {
      // 20 crates received while the brand was still `none`.
      await db
          .update(db.manufacturers)
          .replace(
            (await (db.select(
              db.manufacturers,
            )..where((t) => t.id.equals(moneyBrand))).getSingle()).copyWith(
              crateMoneyArrangement: kCrateMoneyArrangementNone,
            ),
          );
      await receive(manufacturerId: moneyBrand, crates: 20);
      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);

      // The owner switches the brand on today. ADR 0021: history is NOT
      // restated, so nothing is held for those 20 crates.
      await db
          .update(db.manufacturers)
          .replace(
            (await (db.select(
              db.manufacturers,
            )..where((t) => t.id.equals(moneyBrand))).getSingle()).copyWith(
              crateMoneyArrangement: kCrateMoneyArrangementPerDelivery,
            ),
          );

      // Handing 5 of them back must not invent a ₦17,500 refund from a depot
      // that was never paid a naira.
      final id = await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 5,
        performedBy: stockKeeperId,
      );
      expect(id, isNull);
      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
      // The crate count still moved — the empties really did go home.
      expect(await supplierDebt(supplierA, moneyBrand), 15);
    });

    test('the suggestion is capped at what is held when only part of the debt '
        'carries money', () async {
      await placeDeposit(crates: 3); // ₦10,500 held.
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 10,
        performedBy: stockKeeperId,
      );
      expect((await onlyPending()).requestedAmountKobo, 3 * rate);
    });
  });

  // ── 3. Worth does not move ────────────────────────────────────────────────

  group('money coming home does not make the business richer', () {
    test('cash and the asset move together — net cash out always equals the '
        'Placed Deposit', () async {
      await placeDeposit(crates: 8);
      expect(await netCashOut(), 8 * rate);
      expect(await placed(supplierA), await netCashOut());

      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 8,
        performedBy: stockKeeperId,
      );
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: (await onlyPending()).id,
        decidedBy: managerId,
        amountKobo: 2000000,
      );

      // ₦28,000 went out, ₦20,000 came back: ₦8,000 is still out there, and
      // the asset says exactly the same thing. Nothing appeared from nowhere.
      expect(await netCashOut(), 800000);
      expect(await placed(supplierA), 800000);
    });

    test('the refund is a NEGATIVE `crate_deposit_out` — never a refund, never '
        'income, never an expense', () async {
      await placeDeposit(crates: 8);
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 8,
        performedBy: stockKeeperId,
      );
      await confirmAllPending();

      final rows = await payments();
      expect(rows.map((p) => p.type).toSet(), {kPaymentTypeCrateDepositOut});
      final back = rows.where((p) => p.amountKobo < 0).toList();
      expect(back, hasLength(1));
      expect(back.single.amountKobo, -8 * rate);
      expect(back.single.crateDepositId, isNotNull);

      // Not a cost, and not a payment against the goods invoice.
      expect(await db.select(db.expenses).get(), isEmpty);
    });

    test('a `crate_refund` or `refund` type is never minted by this path',
        () async {
      await placeDeposit(crates: 8);
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 8,
        performedBy: stockKeeperId,
      );
      await confirmAllPending();
      final types = (await payments()).map((p) => p.type).toSet();
      expect(types, isNot(contains('refund')));
      expect(types, isNot(contains('crate_refund')));
      expect(types, isNot(contains('expense')));
    });
  });

  // ── 4. Held per (supplier, manufacturer) ──────────────────────────────────

  test('only the supplier you actually paid can pay you back', () async {
    await placeDeposit(crates: 8, supplier: supplierA);
    await placeDeposit(crates: 4, supplier: supplierB);

    await db.cratePoolDao.recordCrateSettlement(
      supplierId: supplierB,
      manufacturerId: moneyBrand,
      storeId: storeId,
      crateCount: 4,
      performedBy: stockKeeperId,
    );
    await confirmAllPending();

    expect(await placed(supplierB), 0);
    expect(
      await placed(supplierA),
      8 * rate,
      reason: "settling with Bola cannot touch Ade's money",
    );
  });

  // ── 5. The release gate ───────────────────────────────────────────────────

  group('THE RELEASE GATE — a `none` brand is untouched by all of this', () {
    test('returning empties on a `none` brand raises nothing, writes no money '
        'row, and keeps the legacy hand-typed column working', () async {
      await db.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: swapBrand,
        quantity: 6,
        performedBy: stockKeeperId,
        storeId: storeId,
        depositRefundedKobo: 2100000,
      );

      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await payments(), isEmpty);

      final row = (await db.select(db.supplierCrateLedger).get()).single;
      expect(row.quantityDelta, -6);
      expect(row.depositPaidKobo, 2100000);
    });

    test('a receipt carrying empties on a `none` brand behaves exactly as it '
        'did before PRD #203', () async {
      await receive(manufacturerId: swapBrand, crates: 10, empties: 4);
      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
      expect(await payments(), isEmpty);
      expect(await supplierDebt(supplierA, swapBrand), 6);
    });

    test('on a `per_delivery` brand the legacy deposit column stays at 0 — the '
        'money is in ONE ledger, not two that never meet', () async {
      await placeDeposit(crates: 8);
      await db.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        quantity: 4,
        performedBy: stockKeeperId,
        storeId: storeId,
        depositRefundedKobo: 1400000,
      );
      final returned = (await db.select(db.supplierCrateLedger).get())
          .firstWhere((r) => r.quantityDelta < 0);
      expect(returned.depositPaidKobo, 0);
      expect((await onlyPending()).kind, kCrateDepositMovementRelease);
    });

    test('under "All Stores" there is no queue to raise into, so the typed '
        'figure is kept rather than silently dropped', () async {
      await placeDeposit(crates: 8);
      await db.cratePoolDao.recordReturnToSupplier(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        quantity: 4,
        performedBy: stockKeeperId,
        depositRefundedKobo: 1400000,
      );
      final returned = (await db.select(db.supplierCrateLedger).get())
          .firstWhere((r) => r.quantityDelta < 0);
      expect(returned.depositPaidKobo, 1400000);
      expect(
        await (db.select(db.supplierCrateDepositRequests)
              ..where((t) => t.status.equals(kCrateDepositRequestPending)))
            .get(),
        isEmpty,
      );
    });

    test('rejecting a refund leaves the empties exactly where they are — they '
        'physically went back whatever anyone decides about the cash',
        () async {
      await placeDeposit(crates: 8);
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 5,
        performedBy: stockKeeperId,
      );
      await db.cratePoolDao.rejectCrateDepositRequest(
        requestId: (await onlyPending()).id,
        decidedBy: managerId,
        reason: 'they will pay next week',
      );

      expect(await supplierDebt(supplierA, moneyBrand), 3);
      expect(
        await placed(supplierA),
        8 * rate,
        reason: 'no money came back, so the asset is untouched',
      );
    });
  });

  // ── 6. Append-only corrections ────────────────────────────────────────────

  group('a correction is a NEW row, never an edit', () {
    test('a release recorded at the wrong figure is fixed by a compensating '
        '`adjustment`, and both rows survive', () async {
      await placeDeposit(crates: 8);
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 8,
        performedBy: stockKeeperId,
      );
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: (await onlyPending()).id,
        decidedBy: managerId,
        amountKobo: 2000000,
      );
      expect(await placed(supplierA), 800000);

      // It was ₦18,000, not ₦20,000: the asset was cut ₦2,000 too far, so the
      // correction RAISES it by ₦2,000 and the cash leg falls with it.
      final id = await db.cratePoolDao.postCrateDepositAdjustment(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        signedAmountKobo: 200000,
        performedBy: managerId,
        storeId: storeId,
        note: 'Miscounted the refund at the depot',
      );
      expect(id, isNotNull);

      expect(await placed(supplierA), 1000000);
      expect(await netCashOut(), 1000000);

      final rows = await db.select(db.supplierCrateDeposits).get();
      expect(rows, hasLength(3));
      expect(
        rows.where((r) => r.movementType == kCrateDepositMovementRelease),
        hasLength(1),
        reason: 'the original release is still there, unedited',
      );
      expect(
        rows
            .firstWhere(
              (r) => r.movementType == kCrateDepositMovementAdjustment,
            )
            .signedAmountKobo,
        200000,
      );
      final log = (await db.select(db.activityLogs).get())
          .where((l) => l.action == 'crate_deposit_adjusted')
          .single;
      expect(log.description, contains('Miscounted'));
    });

    test('editing or deleting a settlement row is refused outright', () async {
      await placeDeposit(crates: 8);
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 8,
        performedBy: stockKeeperId,
      );
      await confirmAllPending();

      await expectLater(
        db.customStatement(
          "UPDATE supplier_crate_deposits SET signed_amount_kobo = 0 "
          "WHERE movement_type = 'release'",
        ),
        throwsA(anything),
      );
      await expectLater(
        db.customStatement(
          "DELETE FROM supplier_crate_deposits WHERE movement_type = 'release'",
        ),
        throwsA(anything),
      );
    });

    test('a `none` brand cannot be corrected into moving money', () async {
      final id = await db.cratePoolDao.postCrateDepositAdjustment(
        supplierId: supplierA,
        manufacturerId: swapBrand,
        signedAmountKobo: 500000,
        performedBy: managerId,
        storeId: storeId,
      );
      expect(id, isNull);
      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await payments(), isEmpty);
    });
  });

  // ── 7. Convergence ────────────────────────────────────────────────────────

  group('two offline devices converge', () {
    test('two tills each settle part of the same deposit offline; both '
        'releases survive the merge', () async {
      final till1 = AppDatabase.forTesting(NativeDatabase.memory());
      final till2 = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(till1);
      await seed(till2);

      // Till 1 takes the delivery and the manager confirms the deposit.
      final s1 = ReceiveStockService(till1, SupplierAccountService(till1));
      await s1.confirmReceipt(
        supplierId: supplierA,
        supplierName: 'Ade Depot',
        storeId: storeId,
        dateReceived: DateTime(2026, 7, 30),
        staffId: stockKeeperId,
        lines: [lineFor(moneyBrand)],
        fullCratesReceivedByManufacturer: const {moneyBrand: 8},
        emptiesReturnedByManufacturer: const {},
      );
      final placement = (await till1
              .select(till1.supplierCrateDepositRequests)
              .get())
          .single;
      await till1.cratePoolDao.confirmCrateDepositRequest(
        requestId: placement.id,
        decidedBy: managerId,
      );

      // Till 2 pulls that state down before going offline again.
      Future<void> copyTo(AppDatabase from, AppDatabase to) async {
        for (final r in await from.select(from.supplierCrateLedger).get()) {
          await to
              .into(to.supplierCrateLedger)
              .insert(r.toCompanion(true), mode: InsertMode.insertOrIgnore);
        }
        for (final r
            in await from.select(from.supplierCrateDepositRequests).get()) {
          await to
              .into(to.supplierCrateDepositRequests)
              .insert(r.toCompanion(true), mode: InsertMode.insertOrIgnore);
        }
        for (final r in await from.select(from.supplierCrateDeposits).get()) {
          await to
              .into(to.supplierCrateDeposits)
              .insert(r.toCompanion(true), mode: InsertMode.insertOrIgnore);
        }
      }

      await copyTo(till1, till2);

      // Now both go offline and each hands part of the empties back.
      Future<void> settleOn(AppDatabase d, int crates) async {
        await d.cratePoolDao.recordCrateSettlement(
          supplierId: supplierA,
          manufacturerId: moneyBrand,
          storeId: storeId,
          crateCount: crates,
          performedBy: stockKeeperId,
        );
        final p = await (d.select(
          d.supplierCrateDepositRequests,
        )..where((t) => t.status.equals(kCrateDepositRequestPending))).get();
        await d.cratePoolDao.confirmCrateDepositRequest(
          requestId: p.single.id,
          decidedBy: managerId,
        );
      }

      await settleOn(till1, 3);
      await settleOn(till2, 5);

      // The cloud converges both append-only ledgers onto one device. Rows are
      // id-keyed, so an insert-or-ignore merge keeps every movement — nothing
      // is clobbered the way an absolute balance cache would be.
      final merged = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(merged);
      await copyTo(till1, merged);
      await copyTo(till2, merged);

      final pos = (await merged.cratePoolDao
              .watchSupplierCrateDepositPositions(supplierA)
              .first)
          .single
          .position;
      // ₦28,000 placed, ₦10,500 + ₦17,500 released — square.
      expect(pos.placedDepositKobo, 0);
      expect(pos.isSettled, isTrue);
      final deposits = await merged.select(merged.supplierCrateDeposits).get();
      expect(
        deposits
            .where((r) => r.movementType == kCrateDepositMovementRelease)
            .length,
        2,
        reason: 'both tills\' settlements survive',
      );
      // And the crate counts agree: 8 received − 3 − 5 = 0 still owed.
      final debt = await merged.cratePoolDao
          .watchSupplierCrateDebt(supplierA)
          .first;
      expect(debt.single.balance, 0);

      await till1.close();
      await till2.close();
      await merged.close();
    });

    test('a settlement can only be confirmed once — the second device loses '
        'the race and no second refund is booked', () async {
      await placeDeposit(crates: 8);
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 8,
        performedBy: stockKeeperId,
      );
      final release = await onlyPending();

      final first = await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: release.id,
        decidedBy: managerId,
      );
      final second = await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: release.id,
        decidedBy: managerId,
      );
      expect(first, isTrue);
      expect(second, isFalse);

      expect(
        (await db.select(db.supplierCrateDeposits).get())
            .where((r) => r.movementType == kCrateDepositMovementRelease)
            .length,
        1,
      );
      expect(await placed(supplierA), 0);
      expect(await netCashOut(), 0);
    });
  });
}
