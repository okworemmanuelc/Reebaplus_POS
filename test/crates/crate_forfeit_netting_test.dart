// crate_forfeit_netting_test.dart
//
// #217 / PRD #203 slice 8/8, ADR 0023 finding #4 and rule 5 — the slice that
// makes profit honest.
//
// A kept customer crate deposit has booked as income since #176. But the crate
// belonged to a manufacturer, and the app charges the customer the SAME
// `manufacturers.deposit_amount_kobo` it owes that manufacturer's depot. So on a
// brand where a deposit was genuinely placed, a forfeit nets to ZERO — and on a
// `none` brand, where nobody was ever paid a deposit, it stays PURE INCOME
// because there the gain is real.
//
// Four things are pinned here, and the third is the one that matters most:
//
//   1. Netting: a forfeit on an opted-in brand raises a matching Crate
//      Shortfall write-off, of the crates KEPT, at the depot rate — and profit
//      does not move.
//   2. `none`: no row is written at all, and the income stands exactly as it did
//      before PRD #203 existed.
//   3. NO RESTATEMENT ACROSS A SWITCH-ON BOUNDARY. A setting flipped on a
//      Tuesday must not change last March's profit. The guarantee is structural,
//      not arithmetic: the netting is decided ONCE, inside the settling
//      transaction, and persisted. Nothing re-derives it from today's setting,
//      so a forfeit settled before switch-on has no netting row and never grows
//      one. A report spanning the switch-on date therefore shows BOTH
//      treatments, by design, without double-counting either.
//   4. The netting is in the deposit's own family: never a `refund`, never a
//      void, never a `payment_transactions` row at all — the defect #190 and
//      #201 fixed on the customer side, and the one ADR 0023's spine forbids
//      ("a book entry appears only when money genuinely moved").

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/crates/crate_shortfall.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String staffId;
  late String customerId;
  late String starId;
  var orderSeq = 0;

  // ₦3,500 a crate — the ONE canonical rate, `manufacturers.deposit_amount_kobo`
  // (ADR 0023 rule 2). The customer is charged this and the depot holds this,
  // which is the whole reason a forfeit nets.
  const rate = 350000;

  setUp(() async {
    orderSeq = 0;
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    await (db.update(db.businesses)..where((b) => b.id.equals(businessId)))
        .write(const BusinessesCompanion(type: Value('Bar')));

    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
      StoresCompanion.insert(
        id: Value(storeId),
        businessId: businessId,
        name: 'Main',
      ),
    );
    staffId = UuidV7.generate();
    await db.into(db.users).insert(
      UsersCompanion.insert(
        id: Value(staffId),
        businessId: businessId,
        name: 'Cashier',
        pin: '0000',
      ),
    );
    customerId = await db.customersDao.addCustomer(
      CustomersCompanion.insert(businessId: businessId, name: 'Buyer'),
    );
    starId = UuidV7.generate();
    await db.into(db.manufacturers).insert(
      ManufacturersCompanion.insert(
        id: Value(starId),
        businessId: businessId,
        name: 'Star Lager',
        depositAmountKobo: const Value(rate),
      ),
    );
  });

  tearDown(() => db.close());

  Future<void> switchOn([
    CrateMoneyArrangement a = CrateMoneyArrangement.perDelivery,
  ]) => db.catalogDao.updateManufacturerCrateMoneyArrangement(starId, a);

  /// A completed order, so the settlement's wallet legs have a parent to hang
  /// off (`wallet_transactions.order_id` is a real FK).
  Future<String> anOrder(String number) async {
    final id = UuidV7.generate();
    await db
        .into(db.orders)
        .insert(
          OrdersCompanion.insert(
            id: Value(id),
            businessId: businessId,
            orderNumber: number,
            customerId: Value(customerId),
            totalAmountKobo: 0,
            netAmountKobo: 0,
            paymentType: 'cash',
            status: 'completed',
            staffId: Value(staffId),
            storeId: Value(storeId),
          ),
        );
    return id;
  }

  /// Settle a deposit for [crates] with NONE of them returned — i.e. the
  /// customer kept the lot and forfeited the deposit.
  Future<String> forfeit(int crates) async {
    final orderId = await anOrder('ORD-${++orderSeq}');
    final paid = crates * rate;
    await db.ordersDao.settleCrateDepositReturn(
      customerId: customerId,
      manufacturerId: starId,
      orderId: orderId,
      takenCrates: crates,
      returnedCrates: 0,
      rateKobo: rate,
      paidKobo: paid,
      refundAsCash: false,
      performedBy: staffId,
    );
    return orderId;
  }

  /// Back-date every row a forfeit wrote, so a fixture can place one BEFORE a
  /// brand was switched on without waiting a month.
  ///
  /// These ledgers are append-only and their immutability triggers refuse an
  /// UPDATE — correctly, and that refusal is pinned by their own suites. This
  /// is a **test-only time machine**: it drops the guards on a throwaway
  /// in-memory database to place a forfeit in March. Nothing in `lib/` may ever
  /// do this; a real correction is a new compensating row.
  Future<void> backdate(String orderId, DateTime to) async {
    for (final t in ['wallet_transactions', 'crate_shortfall_writeoffs']) {
      await db.customStatement('DROP TRIGGER IF EXISTS ${t}_immutable');
    }
    final secs = to.millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
      'UPDATE wallet_transactions SET created_at = ? WHERE order_id = ?',
      [secs, orderId],
    );
    await db.customStatement(
      'UPDATE crate_shortfall_writeoffs SET created_at = ? WHERE id = ?',
      [secs, UuidV7.deterministic('crate_forfeit_netting:$orderId:$starId')],
    );
  }

  Future<List<CrateShortfallWriteoffData>> writeOffs() =>
      db.select(db.crateShortfallWriteoffs).get();

  /// The reconciliation for `[start, endExclusive)`, built from the rows the
  /// database actually holds — so the DAO's write and the report's arithmetic
  /// are exercised as one chain.
  Future<ReconData> recon({DateTime? start, DateTime? endExclusive}) async {
    return reconDataFrom(
      ReconInputs(
        manufacturers: await db.select(db.manufacturers).get(),
        showCrates: true,
        crateForfeitRows: await (db.select(
          db.walletTransactions,
        )..where((t) => t.referenceType.equals('crate_deposit_forfeited'))).get(),
        crateShortfallWriteOffs: await writeOffs(),
        payments: await db.select(db.paymentTransactions).get(),
        isCeo: true,
        start: start,
        endExclusive: endExclusive,
      ),
    );
  }

  // ── 1. The gate, as a pure function ──────────────────────────────────────
  group('the netting gate is pure arithmetic', () {
    test('a money-moving brand nets the crates the customer kept; `none` nets '
        'nothing', () {
      for (final a in CrateMoneyArrangement.values) {
        expect(
          crateForfeitShortfallCrates(arrangement: a, keptCrates: 3),
          a.movesMoney ? 3 : 0,
          reason:
              '${a.wire}: a deposit was ${a.movesMoney ? '' : 'never '}placed '
              'for these crates',
        );
      }
      // A float brand nets too (#214: a float brand's losses raise a Shortfall,
      // they just move no money doing it).
      expect(
        crateForfeitShortfallCrates(
          arrangement: CrateMoneyArrangement.standingFloat,
          keptCrates: 7,
        ),
        7,
      );
      // Nothing kept, nothing lost — and a negative can never book a GAIN.
      for (final kept in [0, -4]) {
        expect(
          crateForfeitShortfallCrates(
            arrangement: CrateMoneyArrangement.perDelivery,
            keptCrates: kept,
          ),
          0,
        );
      }
    });
  });

  // ── 2. Netting on an opted-in brand ──────────────────────────────────────
  group('an opted-in brand: the forfeit nets to zero', () {
    test('a forfeit raises a matching Crate Shortfall write-off, and profit '
        'does not move', () async {
      await switchOn();
      await forfeit(4);

      final rows = await writeOffs();
      expect(rows, hasLength(1));
      expect(rows.single.manufacturerId, starId);
      expect(rows.single.crateCount, 4, reason: 'the crates the customer kept');
      expect(
        rows.single.ratePerCrateKobo,
        rate,
        reason: 'the depot rate SNAPSHOTTED now — never today\'s rate later',
      );
      expect(rows.single.source, kCrateWriteOffSourceCustomerForfeit);
      expect(rows.single.performedBy, staffId);

      final d = await recon();
      expect(d.forfeitIncomeKobo, 4 * rate, reason: 'the deposit was kept');
      expect(
        d.crateForfeitNettedKobo,
        4 * rate,
        reason: 'and the crate behind it costs exactly the same',
      );
      expect(d.crateShortfallWrittenOffKobo, 4 * rate);
      expect(
        d.netProfitKobo,
        0,
        reason: 'THE SLICE: a transaction that gained nothing reports nothing',
      );
    });

    test('the netting is never a refund and never a void — no payment row at '
        'all', () async {
      await switchOn();
      await forfeit(4);

      final payments = await db.select(db.paymentTransactions).get();
      expect(
        payments.where((p) => p.type == 'refund'),
        isEmpty,
        reason: 'the #190/#201 defect must not be reintroduced on this side',
      );
      final d = await recon();
      // No cash moved when the crate stopped being expected back — the money
      // left, or never arrived, long ago (ADR 0023's spine).
      expect(d.refundsKobo, 0);
      expect(d.expensesKobo, 0);
      expect(d.cashInKobo, 0);
      expect(d.cashOutKobo, 0);
      expect(d.netCashMovementKobo, 0);
    });

    test('the netted crates count against the derived shortfall, so nobody is '
        'asked to accept the same missing crates twice', () async {
      await switchOn();
      await forfeit(4);

      final shortfall = computeCrateShortfall(
        manufacturerId: starId,
        manufacturerName: 'Star Lager',
        arrangement: CrateMoneyArrangement.perDelivery,
        ratePerCrateKobo: rate,
        // Four crates owed to the depot that are not in the yard — the exact
        // gap the four kept crates opened.
        cratesOwed: 4,
        emptiesOnHand: 0,
        writtenOffCrates: (await writeOffs()).single.crateCount,
      );
      expect(shortfall.rawShortfallCrates, 4);
      expect(shortfall.writtenOffCrates, 4);
      expect(
        shortfall.openShortfallCrates,
        0,
        reason: 'already accepted — the card must not ask for it again',
      );
    });

    test('two offline tills settling the same order book ONE loss, not two',
        () async {
      // #188's trick, applied to the netting: the id is DERIVED from
      // (order, brand), so the second device's push is a no-op UPSERT of the
      // row the first delivered rather than a second booked loss. Without it
      // the forfeit would net once and the crate would be lost twice.
      await switchOn();
      final orderId = await forfeit(2);
      final rows = await writeOffs();
      expect(rows, hasLength(1));
      expect(
        rows.single.id,
        UuidV7.deterministic('crate_forfeit_netting:$orderId:$starId'),
      );

      // And the seam itself is idempotent, so a local re-entry (a retried
      // settlement, a converged offline claim) cannot double-book either.
      await db.cratePoolDao.recordCustomerForfeitShortfall(
        manufacturerId: starId,
        orderId: orderId,
        keptCrates: 2,
        performedBy: staffId,
      );
      expect(await writeOffs(), hasLength(1));
      expect((await recon()).crateForfeitNettedKobo, 2 * rate);
    });

    test('a partial deposit still books the whole crate: the customer paid less '
        'than the depot holds, and the shortfall is the depot\'s rate',
        () async {
      await switchOn();
      final orderId = await anOrder('ORD-PART');
      // Two crates taken, only ONE crate's deposit ever collected.
      await db.ordersDao.settleCrateDepositReturn(
        customerId: customerId,
        manufacturerId: starId,
        orderId: orderId,
        takenCrates: 2,
        returnedCrates: 0,
        rateKobo: rate,
        paidKobo: rate,
        refundAsCash: false,
        performedBy: staffId,
      );

      final d = await recon();
      expect(d.forfeitIncomeKobo, rate, reason: 'only one crate was paid for');
      expect(
        d.crateForfeitNettedKobo,
        2 * rate,
        reason: 'but TWO crates are not coming back to the depot',
      );
      expect(
        d.netProfitKobo,
        -rate,
        reason:
            'an honest loss, not a fake gain: the business is a crate down and '
            'was only ever paid for one',
      );
    });
  });

  // ── 3. A `none` brand is untouched ───────────────────────────────────────
  group('a `none` brand: the forfeit stays pure income', () {
    test('nothing is written, and the income reads exactly as it did before '
        'PRD #203', () async {
      await forfeit(4); // arrangement left at its default `none`

      expect(
        await writeOffs(),
        isEmpty,
        reason:
            'nobody was ever paid a deposit for these crates — they were the '
            'business\'s own to lose, so keeping the money is a REAL gain',
      );
      final d = await recon();
      expect(d.forfeitIncomeKobo, 4 * rate);
      expect(d.crateForfeitNettedKobo, 0);
      expect(d.crateShortfallWrittenOffKobo, 0);
      expect(d.netProfitKobo, 4 * rate, reason: 'pure income, unchanged');
    });

    test('a brand switched on, forfeited against, then switched back OFF stops '
        'netting — the owner\'s stated arrangement beats the residue',
        () async {
      await switchOn();
      await forfeit(4);
      expect(await writeOffs(), hasLength(1));

      await switchOn(CrateMoneyArrangement.none);
      final d = await recon();
      expect(
        d.crateForfeitNettedKobo,
        0,
        reason: '#216\'s release gate: a `none` brand books nothing, ever',
      );
      expect(d.netProfitKobo, 4 * rate, reason: 'back to pure income');
    });
  });

  // ── 4. THE PROPERTY THAT MATTERS MOST ────────────────────────────────────
  group('history is never restated', () {
    // March: the brand is `none`, a customer keeps 4 crates, the deposit is
    // pure income. July: the owner switches the brand on. March must not move.
    final march = DateTime(2026, 3, 10, 12);
    final marchStart = DateTime(2026, 3);
    final aprilStart = DateTime(2026, 4);

    test('switching a brand on in July does not change March\'s profit',
        () async {
      final marchOrder = await forfeit(4);
      await backdate(marchOrder, march);

      final before = await recon(
        start: marchStart,
        endExclusive: aprilStart,
      );
      expect(before.netProfitKobo, 4 * rate);
      expect(before.crateForfeitNettedKobo, 0);

      // The Tuesday flip.
      await switchOn();

      final after = await recon(start: marchStart, endExclusive: aprilStart);
      expect(
        await writeOffs(),
        isEmpty,
        reason:
            'THE GUARANTEE: the netting is settled once, in the settling '
            'transaction. Flipping a switch writes March no row, because '
            'nothing re-asks the question later.',
      );
      expect(after.netProfitKobo, before.netProfitKobo);
      expect(after.forfeitIncomeKobo, before.forfeitIncomeKobo);
      expect(after.crateForfeitNettedKobo, 0);
      expect(after.crateShortfallWrittenOffKobo, 0);
    });

    test('a day already closed keeps every figure the owner signed off',
        () async {
      final marchOrder = await forfeit(4);
      await backdate(marchOrder, march);

      final reviewed = dailyClosingFiguresFrom(
        await recon(start: marchStart, endExclusive: aprilStart),
      );
      await switchOn();
      final live = dailyClosingFiguresFrom(
        await recon(start: marchStart, endExclusive: aprilStart),
      );

      expect(live.netProfitKobo, reviewed.netProfitKobo);
      expect(live.grossProfitKobo, reviewed.grossProfitKobo);
      expect(live.cashInKobo, reviewed.cashInKobo);
      expect(live.cashOutKobo, reviewed.cashOutKobo);
      expect(live.netCashMovementKobo, reviewed.netCashMovementKobo);
    });

    test('a report spanning the switch-on date shows BOTH treatments, and '
        'counts each forfeit exactly once', () async {
      // March, brand off: 4 crates kept → pure income.
      final marchOrder = await forfeit(4);
      await backdate(marchOrder, march);
      // July, brand on: 3 crates kept → netted to zero.
      await switchOn();
      await forfeit(3);

      final d = await recon(
        start: marchStart,
        endExclusive: DateTime(2027),
      );
      expect(
        d.forfeitIncomeKobo,
        (4 + 3) * rate,
        reason: 'both forfeits kept their money — that fact never changes',
      );
      expect(
        d.crateForfeitNettedKobo,
        3 * rate,
        reason: 'only the July one has a crate the depot is owed',
      );
      expect(d.crateShortfallWrittenOffKobo, 3 * rate);
      expect(
        d.netProfitKobo,
        4 * rate,
        reason:
            'the March gain, whole; the July pair, zero. Neither is counted '
            'twice and neither is restated.',
      );
      expect(
        await writeOffs(),
        hasLength(1),
        reason: 'exactly one netting row: the one settled after switch-on',
      );
    });

    test('a deposit rate raised after the fact cannot move a booked netting',
        () async {
      await switchOn();
      await forfeit(4);

      await (db.update(db.manufacturers)..where((t) => t.id.equals(starId)))
          .write(const ManufacturersCompanion(depositAmountKobo: Value(900000)));

      final d = await recon();
      expect(
        d.crateForfeitNettedKobo,
        4 * rate,
        reason: 'the rate was snapshotted onto the row (ADR 0021)',
      );
      expect(d.netProfitKobo, 0);
    });
  });

  // ── 5. The write boundary ────────────────────────────────────────────────
  group('the write boundary', () {
    test('the netting row is enqueued for sync, carrying its source', () async {
      await switchOn();
      await forfeit(2);

      final queued = await db
          .customSelect(
            "SELECT payload FROM sync_queue "
            "WHERE action_type LIKE 'crate_shortfall_writeoffs:%'",
          )
          .get();
      expect(queued, hasLength(1));
      final payload = queued.single.read<String>('payload');
      expect(payload, contains('customer_forfeit'));
      expect(payload, contains('rate_per_crate_kobo'));
    });

    test('a manual write-off still reads `manual`, and stays the row the card '
        'attributes', () async {
      await switchOn();
      await forfeit(2);
      await db.cratePoolDao.writeOffCrateShortfall(
        manufacturerId: starId,
        crateCount: 1,
        performedBy: staffId,
      );

      final rows = await writeOffs();
      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r.source).toSet(),
        {kCrateWriteOffSourceManual, kCrateWriteOffSourceCustomerForfeit},
      );

      // Both losses reach profit; only the manual one is attributed on the card.
      final d = await recon();
      expect(d.crateShortfallWrittenOffKobo, 3 * rate);
      expect(d.crateForfeitNettedKobo, 2 * rate);

      final rollup = await db.cratePoolDao.watchCrateShortfallRollup().first;
      for (final brand in rollup.brands) {
        expect(brand.lastWrittenOffBy, staffId);
      }
    });
  });
}
