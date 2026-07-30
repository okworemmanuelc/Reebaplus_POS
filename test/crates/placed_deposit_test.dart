// placed_deposit_test.dart
//
// #212 / PRD #203, ADR 0023 rules 1, 2 and 6 — the write boundary of the first
// slice where crate money actually moves.
//
// The pure arithmetic lives in `computeCrateDepositPosition` and is pinned,
// database-free, in crate_deposit_position_test.dart. THIS suite pins what the
// database does around it:
//
//   1. THE RELEASE GATE. A `none` brand — which is every brand on every live
//      tenant until an owner deliberately says otherwise — raises nothing,
//      writes nothing, and leaves the receipt behaving exactly as it did before
//      PRD #203. `standing_float` is the same on an ordinary delivery: that
//      arrangement moves money only on a real top-up or payout (#214).
//   2. A `per_delivery` receipt commits the CRATE COUNT immediately and parks
//      the MONEY as a pending request. The stock keeper is never asked for
//      cash, and the crate record is never stale (ADR 0023 rule 6).
//   3. Confirming writes BOTH legs in one transaction — the Placed Deposit
//      asset and the cash out of the drawer (ADR 0019's both-or-neither rule).
//   4. The approver may adjust the amount before confirming.
//   5. Rejecting moves NO money and — the thing that must never break — leaves
//      the crate counts completely untouched.
//   6. THE MONEY FAMILY. The cash leg is `crate_deposit_out` and never a
//      `refund`, an `expense` or a `void`. That is the defect #190 and #201 had
//      to fix on the customer side; it does not get to happen again here.
//   7. Two devices converge, and a request can only be decided once.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/crates/crate_deposit_ledger_types.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/features/receiving/state/receive_cart.dart';
import 'package:reebaplus_pos/shared/services/receive_stock_service.dart';
import 'package:reebaplus_pos/shared/services/supplier_account_service.dart';

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
  const floatBrand = 'mfr-float';

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
            // The default. Stated explicitly here because it is the whole point.
            crateMoneyArrangement: const Value(kCrateMoneyArrangementNone),
          ),
        );
    await db
        .into(db.manufacturers)
        .insert(
          ManufacturersCompanion.insert(
            id: const Value(floatBrand),
            businessId: businessId,
            name: 'Trophy',
            depositAmountKobo: const Value(rate),
            crateMoneyArrangement: const Value(
              kCrateMoneyArrangementStandingFloat,
            ),
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
    for (final m in [moneyBrand, swapBrand, floatBrand]) {
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
    required int crates,
    String supplierId = supplierA,
  }) => service.confirmReceipt(
    supplierId: supplierId,
    supplierName: supplierId == supplierA ? 'Ade Depot' : 'Bola Depot',
    storeId: storeId,
    dateReceived: DateTime(2026, 7, 30),
    staffId: stockKeeperId,
    lines: [lineFor(manufacturerId)],
    fullCratesReceivedByManufacturer: {manufacturerId: crates},
    emptiesReturnedByManufacturer: const {},
  );

  Future<int> supplierDebt(String supplierId, String manufacturerId) async {
    final rows = await db.cratePoolDao.watchSupplierCrateDebt(supplierId).first;
    final match = rows
        .where((r) => r.manufacturerId == manufacturerId)
        .toList();
    return match.isEmpty ? 0 : match.single.balance;
  }

  Future<List<PaymentTransactionData>> payments() =>
      db.select(db.paymentTransactions).get();

  // ── 1. The release gate ───────────────────────────────────────────────────

  group('THE RELEASE GATE — a `none` brand behaves exactly as it did', () {
    test('a receipt on a `none` brand raises no request, no ledger row and no '
        'payment — while the crate count lands as always', () async {
      await receive(manufacturerId: swapBrand, crates: 12);

      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await payments(), isEmpty);

      // The count is untouched by any of this — it is #210's leg and it stands.
      expect(await supplierDebt(supplierA, swapBrand), 12);
    });

    test('`standing_float` raises nothing on an ordinary delivery either — '
        'that money moves only on a real top-up or payout (#214)', () async {
      await receive(manufacturerId: floatBrand, crates: 12);

      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await payments(), isEmpty);
      expect(await supplierDebt(supplierA, floatBrand), 12);
    });

    test('a `per_delivery` brand with a zero rate raises nothing — there is no '
        'money to ask about', () async {
      await db
          .update(db.manufacturers)
          .replace(
            (await (db.select(
              db.manufacturers,
            )..where((t) => t.id.equals(moneyBrand))).getSingle()).copyWith(
              depositAmountKobo: 0,
            ),
          );

      await receive(manufacturerId: moneyBrand, crates: 12);

      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
      expect(await supplierDebt(supplierA, moneyBrand), 12);
    });

    test('a mixed delivery raises a request for the money brand ONLY', () async {
      await service.confirmReceipt(
        supplierId: supplierA,
        supplierName: 'Ade Depot',
        storeId: storeId,
        dateReceived: DateTime(2026, 7, 30),
        staffId: stockKeeperId,
        lines: [lineFor(moneyBrand), lineFor(swapBrand)],
        fullCratesReceivedByManufacturer: const {
          moneyBrand: 10,
          swapBrand: 10,
        },
        emptiesReturnedByManufacturer: const {},
      );

      final requests = await db.select(db.supplierCrateDepositRequests).get();
      expect(requests, hasLength(1));
      expect(requests.single.manufacturerId, moneyBrand);
      // Both counts landed regardless.
      expect(await supplierDebt(supplierA, moneyBrand), 10);
      expect(await supplierDebt(supplierA, swapBrand), 10);
    });
  });

  // ── 1b. One ledger per brand, whichever door the delivery came through ────

  group('the manual supplier form routes to the SAME ledger', () {
    test('on a `per_delivery` brand it raises a request and writes NOTHING to '
        'the legacy deposit column', () async {
      // The supplier screen's own "receive crates" form types a deposit
      // straight into `supplier_crate_ledger.deposit_paid_kobo`. If that stayed
      // live for a `per_delivery` brand, the same brand's deposit money would
      // sit in TWO ledgers that never agree — ADR 0023 finding #3, recreated
      // inside the slice that exists to fix it. The arrangement decides, not
      // the caller, so this path lands in the queue like any other.
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        quantity: 6,
        performedBy: stockKeeperId,
        storeId: storeId,
        depositPaidKobo: 2100000,
      );

      final crateRow = (await db.select(db.supplierCrateLedger).get()).single;
      expect(crateRow.quantityDelta, 6);
      expect(
        crateRow.depositPaidKobo,
        0,
        reason: 'the legacy column must not move for a per_delivery brand',
      );

      final requests = await db.select(db.supplierCrateDepositRequests).get();
      expect(requests, hasLength(1));
      expect(requests.single.crateCount, 6);
      expect(requests.single.status, kCrateDepositRequestPending);
    });

    test('on a `none` brand the legacy column still works exactly as it did — '
        'and no request is raised', () async {
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: swapBrand,
        quantity: 6,
        performedBy: stockKeeperId,
        storeId: storeId,
        depositPaidKobo: 2100000,
      );
      final crateRow = (await db.select(db.supplierCrateLedger).get()).single;
      expect(crateRow.depositPaidKobo, 2100000);
      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
    });

    test('with no active store there is nowhere to route the money, so the '
        'typed figure is kept rather than silently dropped', () async {
      // The approval queue scopes approvers BY store and `store_id` is NOT
      // NULL, so under "All Stores" there is no queue to raise into. Keeping
      // the legacy column is the pre-existing behaviour and beats discarding a
      // number the user typed.
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        quantity: 6,
        performedBy: stockKeeperId,
        depositPaidKobo: 2100000,
      );
      final crateRow = (await db.select(db.supplierCrateLedger).get()).single;
      expect(crateRow.depositPaidKobo, 2100000);
      expect(await db.select(db.supplierCrateDepositRequests).get(), isEmpty);
    });
  });

  // ── 2. The count commits, the money waits ─────────────────────────────────

  group('the count commits on the stock keeper; the money waits', () {
    test('a `per_delivery` receipt commits the crates and parks the money', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);

      // The crate leg is DONE — no approval, no delay.
      expect(await supplierDebt(supplierA, moneyBrand), 8);

      // The money leg is only a request. Nothing has moved.
      final requests = await db.select(db.supplierCrateDepositRequests).get();
      expect(requests, hasLength(1));
      final r = requests.single;
      expect(r.status, kCrateDepositRequestPending);
      expect(r.kind, kCrateDepositMovementPlacement);
      expect(r.crateCount, 8);
      expect(r.ratePerCrateKobo, rate);
      expect(r.requestedAmountKobo, 8 * rate);
      expect(r.settledAmountKobo, isNull);
      expect(r.requestedBy, stockKeeperId);
      expect(r.storeId, storeId);
      expect(r.supplierId, supplierA);
      expect(r.summary, contains('8 crates of Star Lager'));
      expect(r.summary, contains('Ade Depot'));

      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await payments(), isEmpty);
    });

    test('the request links back to the exact crate-ledger row it answers', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      final crateRow = (await db.select(db.supplierCrateLedger).get()).single;
      final request = (await db.select(db.supplierCrateDepositRequests).get())
          .single;
      expect(request.supplierCrateLedgerId, crateRow.id);
    });

    test('the rate is SNAPSHOTTED — editing it afterwards does not restate the '
        'request', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      await (db.update(db.manufacturers)
            ..where((t) => t.id.equals(moneyBrand)))
          .write(const ManufacturersCompanion(depositAmountKobo: Value(999999)));

      final r = (await db.select(db.supplierCrateDepositRequests).get()).single;
      expect(r.ratePerCrateKobo, rate);
      expect(r.requestedAmountKobo, 8 * rate);
    });

    test('the supplier screen shows the money awaiting confirmation even before '
        'that brand has ever had a deposit placed', () async {
      // The first-delivery case. There is no ledger row for this brand yet, so
      // a ledger-only read would show the owner nothing at all — while ₦28,000
      // of theirs is waiting on their own decision.
      await receive(manufacturerId: moneyBrand, crates: 8);
      final positions = await db.cratePoolDao
          .watchSupplierCrateDepositPositions(supplierA)
          .first;
      expect(positions, hasLength(1));
      expect(positions.single.position.placedDepositKobo, 0);
      expect(positions.single.position.pendingDepositKobo, 8 * rate);
      expect(positions.single.position.pendingCrates, 8);
      expect(positions.single.position.hasPending, isTrue);
    });

    test('the pending request reaches the approvals queue and the outbox', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      final pending = await db.cratePoolDao
          .watchPendingCrateDepositRequests()
          .first;
      expect(pending, hasLength(1));

      final queued = await db.customSelect(
        "SELECT COUNT(*) AS c FROM sync_queue "
        "WHERE action_type = 'supplier_crate_deposit_requests:upsert'",
      ).getSingle();
      expect(queued.read<int>('c'), 1);
    });
  });

  // ── 3 & 4. Confirming — both legs, one transaction, adjustable ────────────

  group('confirming writes BOTH legs, atomically', () {
    Future<SupplierCrateDepositRequestData> raise() async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      return (await db.select(db.supplierCrateDepositRequests).get()).single;
    }

    test('the Placed Deposit asset and the cash leg both appear', () async {
      final r = await raise();
      final ok = await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );
      expect(ok, isTrue);

      final deposits = await db.select(db.supplierCrateDeposits).get();
      expect(deposits, hasLength(1));
      final d = deposits.single;
      expect(d.movementType, kCrateDepositMovementPlacement);
      expect(d.signedAmountKobo, 8 * rate);
      expect(d.crateCount, 8);
      expect(d.ratePerCrateKobo, rate);
      expect(d.supplierId, supplierA);
      expect(d.manufacturerId, moneyBrand);
      expect(d.requestId, r.id);
      expect(d.performedBy, managerId);

      final pays = await payments();
      expect(pays, hasLength(1));
      final p = pays.single;
      expect(p.amountKobo, 8 * rate);
      expect(p.crateDepositId, d.id);
      expect(p.storeId, storeId);
      expect(p.performedBy, managerId);
    });

    test('the position reads what the supplier is holding', () async {
      final r = await raise();
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );
      final positions = await db.cratePoolDao
          .watchSupplierCrateDepositPositions(supplierA)
          .first;
      expect(positions, hasLength(1));
      expect(positions.single.manufacturerName, 'Star Lager');
      expect(positions.single.position.placedDepositKobo, 8 * rate);
      expect(positions.single.position.placedCrates, 8);
      expect(positions.single.position.pendingDepositKobo, 0);
    });

    test('the money is held per (supplier, manufacturer) — supplier B does not '
        'see supplier A\'s deposit', () async {
      final r = await raise();
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );
      final b = await db.cratePoolDao
          .watchSupplierCrateDepositPositions(supplierB)
          .first;
      expect(b, isEmpty);
    });

    test('the approver may ADJUST the amount — a part payment', () async {
      final r = await raise();
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
        amountKobo: 1000000, // ₦10,000 of the ₦28,000 asked for
      );
      final d = (await db.select(db.supplierCrateDeposits).get()).single;
      expect(d.signedAmountKobo, 1000000);
      // The crates the money covers are still the delivery's — the deposit is
      // simply short, which is what the position's own figures then say.
      expect(d.crateCount, 8);
      expect((await payments()).single.amountKobo, 1000000);

      final updated = (await db.select(db.supplierCrateDepositRequests).get())
          .single;
      expect(updated.settledAmountKobo, 1000000);
      expect(updated.status, kCrateDepositRequestConfirmed);
    });

    test('confirming at ZERO — a waived deposit — decides the request and '
        'writes no money at all', () async {
      final r = await raise();
      final ok = await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
        amountKobo: 0,
      );
      expect(ok, isTrue);
      // A book entry appears only when money genuinely moved.
      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await payments(), isEmpty);
      final updated = (await db.select(db.supplierCrateDepositRequests).get())
          .single;
      expect(updated.status, kCrateDepositRequestConfirmed);
      expect(updated.settledAmountKobo, 0);
      // The crates still arrived.
      expect(await supplierDebt(supplierA, moneyBrand), 8);
    });

    test('a confirmation is attributable — who, when, and in the activity log',
        () async {
      final r = await raise();
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );
      final updated = (await db.select(db.supplierCrateDepositRequests).get())
          .single;
      expect(updated.decidedBy, managerId);
      expect(updated.decidedAt, isNotNull);

      final logs = await db.select(db.activityLogs).get();
      final confirmLog = logs
          .where((l) => l.action == 'crate_deposit_confirmed')
          .toList();
      expect(confirmLog, hasLength(1));
      expect(confirmLog.single.userId, managerId);
      expect(confirmLog.single.description, contains('Star Lager'));
    });

    test('a second confirmation is refused — the money cannot move twice', () async {
      final r = await raise();
      expect(
        await db.cratePoolDao.confirmCrateDepositRequest(
          requestId: r.id,
          decidedBy: managerId,
        ),
        isTrue,
      );
      expect(
        await db.cratePoolDao.confirmCrateDepositRequest(
          requestId: r.id,
          decidedBy: managerId,
        ),
        isFalse,
      );
      expect(await db.select(db.supplierCrateDeposits).get(), hasLength(1));
      expect(await payments(), hasLength(1));
    });

    test('both legs are enqueued for the other devices', () async {
      final r = await raise();
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );
      final rows = await db.customSelect(
        "SELECT action_type FROM sync_queue "
        "WHERE action_type IN ('supplier_crate_deposits:upsert',"
        "'payment_transactions:upsert')",
      ).get();
      final types = rows.map((r) => r.read<String>('action_type')).toSet();
      expect(types, {
        'supplier_crate_deposits:upsert',
        'payment_transactions:upsert',
      });
    });
  });

  // ── 5. Rejection never touches the crates ────────────────────────────────

  group('rejecting the money leaves the crates alone', () {
    test('no deposit row, no payment, and the crate count is EXACTLY what it '
        'was before the decision', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      final before = await supplierDebt(supplierA, moneyBrand);
      final crateRowsBefore = await db.select(db.supplierCrateLedger).get();

      final r = (await db.select(db.supplierCrateDepositRequests).get()).single;
      final ok = await db.cratePoolDao.rejectCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
        reason: 'The depot waived it this month',
      );
      expect(ok, isTrue);

      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await payments(), isEmpty);
      expect(await supplierDebt(supplierA, moneyBrand), before);
      expect(await supplierDebt(supplierA, moneyBrand), 8);
      final crateRowsAfter = await db.select(db.supplierCrateLedger).get();
      expect(crateRowsAfter.length, crateRowsBefore.length);
      expect(
        crateRowsAfter.single.quantityDelta,
        crateRowsBefore.single.quantityDelta,
      );
    });

    test('the rejection is attributable and carries the reason', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      final r = (await db.select(db.supplierCrateDepositRequests).get()).single;
      await db.cratePoolDao.rejectCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
        reason: 'No deposit changed hands',
      );
      final updated = (await db.select(db.supplierCrateDepositRequests).get())
          .single;
      expect(updated.status, kCrateDepositRequestRejected);
      expect(updated.decidedBy, managerId);
      expect(updated.decidedAt, isNotNull);
      expect(updated.decisionNote, 'No deposit changed hands');
      expect(updated.settledAmountKobo, isNull);

      final log = (await db.select(db.activityLogs).get())
          .where((l) => l.action == 'crate_deposit_rejected')
          .single;
      expect(log.description, contains('No deposit changed hands'));
      expect(log.description, contains('crates on this delivery are unaffected'));
    });

    test('a rejected request cannot then be confirmed', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      final r = (await db.select(db.supplierCrateDepositRequests).get()).single;
      await db.cratePoolDao.rejectCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );
      expect(
        await db.cratePoolDao.confirmCrateDepositRequest(
          requestId: r.id,
          decidedBy: managerId,
        ),
        isFalse,
      );
      expect(await payments(), isEmpty);
    });
  });

  // ── 6. The money family ──────────────────────────────────────────────────

  group('THE MONEY FAMILY — never a refund, never an expense, never a void', () {
    test('the cash leg is typed `crate_deposit_out` and nothing else', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      final r = (await db.select(db.supplierCrateDepositRequests).get()).single;
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );

      final pays = await payments();
      expect(pays.single.type, kPaymentTypeCrateDepositOut);
      // The three families it must never be confused with. Releasing held money
      // in the wrong one is exactly what #190 and #201 had to undo on the
      // customer side: a `refund` is subtracted from the period result, so a
      // refundable deposit typed that way reads as a flat loss.
      expect(
        pays.map((p) => p.type),
        isNot(contains('refund')),
      );
      expect(
        pays.map((p) => p.type),
        isNot(contains('expense')),
      );
      // Nor the CUSTOMER-side deposit family, which is a different leg of a
      // different relationship and nets against a customer liability.
      expect(
        pays.map((p) => p.type),
        isNot(contains('crate_deposit')),
      );
    });

    test('the cash leg hangs off the deposit row — never off an expense, an '
        'order or any other parent', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      final r = (await db.select(db.supplierCrateDepositRequests).get()).single;
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );
      final p = (await payments()).single;
      expect(p.crateDepositId, isNotNull);
      expect(p.orderId, isNull);
      expect(p.shipmentId, isNull);
      expect(p.expenseId, isNull);
      expect(p.walletTxnId, isNull);
      expect(p.deliveryId, isNull);
      expect(p.vanTripId, isNull);
    });

    test('no expense row is created anywhere by a confirmation, and the '
        'supplier WALLET is untouched', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      // The delivery itself books a goods INVOICE against the supplier — that
      // is #210's/the receipt's business and it is already on the books before
      // anyone decides the deposit. Snapshot it, so what follows measures the
      // CONFIRMATION and nothing else.
      final walletBefore = await db.select(db.supplierLedgerEntries).get();

      final r = (await db.select(db.supplierCrateDepositRequests).get()).single;
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );

      expect(await db.select(db.expenses).get(), isEmpty);
      // A deposit is not a payment toward goods. Booking it on the supplier
      // wallet would say we had paid down the invoice, which we have not, and
      // would misstate what we owe them.
      expect(
        await db.select(db.supplierLedgerEntries).get(),
        hasLength(walletBefore.length),
      );
    });

    test('the deposit ledger is append-only — an edit is refused', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      final r = (await db.select(db.supplierCrateDepositRequests).get()).single;
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );
      await expectLater(
        db.customStatement(
          'UPDATE supplier_crate_deposits SET signed_amount_kobo = 1',
        ),
        throwsA(anything),
      );
      await expectLater(
        db.customStatement('DELETE FROM supplier_crate_deposits'),
        throwsA(anything),
      );
    });
  });

  // ── 7. Convergence ───────────────────────────────────────────────────────

  group('two devices converge', () {
    test('a confirmation applied from a peer snapshot cannot be un-decided by a '
        'stale `pending` row', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      final r = (await db.select(db.supplierCrateDepositRequests).get()).single;
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: r.id,
        decidedBy: managerId,
      );

      // The confirming push drains, so invariant #12 no longer protects the
      // row. Then a slow peer redelivers it as IT saw it: still pending, with a
      // same-second timestamp — the exact tie that triggered #115.
      await db.delete(db.syncQueue).go();
      final resolved = (await db.select(db.supplierCrateDepositRequests).get())
          .single;
      final lua = resolved.lastUpdatedAt.toUtc().toIso8601String();
      final sync = SupabaseSyncService(
        db,
        SupabaseCloudTransport(
          SupabaseClient('https://placeholder.supabase.co', 'anon-key'),
        ),
      );
      await sync.restoreTableDataForTesting('supplier_crate_deposit_requests', [
        {
          'id': resolved.id,
          'business_id': businessId,
          'supplier_id': resolved.supplierId,
          'manufacturer_id': resolved.manufacturerId,
          'store_id': resolved.storeId,
          'kind': resolved.kind,
          'crate_count': resolved.crateCount,
          'rate_per_crate_kobo': resolved.ratePerCrateKobo,
          'requested_amount_kobo': resolved.requestedAmountKobo,
          'settled_amount_kobo': null,
          'payment_method': null,
          'summary': resolved.summary,
          'supplier_crate_ledger_id': resolved.supplierCrateLedgerId,
          'note': null,
          'requested_by': resolved.requestedBy,
          'status': kCrateDepositRequestPending,
          'decided_by': null,
          'decided_at': null,
          'decision_note': null,
          'created_at': lua,
          'last_updated_at': lua,
        },
      ]);

      // The decision is durable. A resurrection here would put a PAID deposit
      // back in the approvals queue and invite a second payment.
      final after = (await db.select(db.supplierCrateDepositRequests).get())
          .single;
      expect(after.status, kCrateDepositRequestConfirmed);
      expect(
        await db.cratePoolDao.watchPendingCrateDepositRequests().first,
        isEmpty,
      );
    });

    test('a re-delivered deposit row is ignored, not re-applied — the ledger is '
        'append-only and has nothing to update', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      final req = (await db.select(db.supplierCrateDepositRequests).get())
          .single;
      await db.cratePoolDao.confirmCrateDepositRequest(
        requestId: req.id,
        decidedBy: managerId,
      );
      final d = (await db.select(db.supplierCrateDeposits).get()).single;

      // Drain the outbox first, so invariant #12 (which protects an un-pushed
      // local row from a cloud overwrite) is NOT what makes this pass — the
      // restore strategy itself has to be the thing that holds.
      await db.delete(db.syncQueue).go();

      // The same row comes back down on the next pull, as it always will. An
      // on-conflict UPDATE here would hit the immutable-columns trigger the
      // moment any value round-tripped differently and abort the whole page,
      // taking every other row in it down with a money row that had nothing to
      // change anyway.
      final sync = SupabaseSyncService(
        db,
        SupabaseCloudTransport(
          SupabaseClient('https://placeholder.supabase.co', 'anon-key'),
        ),
      );
      await sync.restoreTableDataForTesting('supplier_crate_deposits', [
        {
          'id': d.id,
          'business_id': businessId,
          'supplier_id': d.supplierId,
          'manufacturer_id': d.manufacturerId,
          'store_id': d.storeId,
          'movement_type': d.movementType,
          // Deliberately DIFFERENT figures: if the restore ever updated instead
          // of ignoring, this would either corrupt the balance or abort.
          'signed_amount_kobo': 1,
          'crate_count': 999,
          'rate_per_crate_kobo': 1,
          'request_id': d.requestId,
          'supplier_crate_ledger_id': d.supplierCrateLedgerId,
          'note': null,
          'performed_by': d.performedBy,
          'created_at': d.createdAt.toUtc().toIso8601String(),
          'last_updated_at': DateTime.utc(2030).toIso8601String(),
        },
      ]);

      final after = await db.select(db.supplierCrateDeposits).get();
      expect(after, hasLength(1));
      expect(after.single.signedAmountKobo, 8 * rate);
      expect(after.single.crateCount, 8);
    });

    test('deposits from two suppliers for the same brand stay separate', () async {
      await receive(manufacturerId: moneyBrand, crates: 8);
      await receive(
        manufacturerId: moneyBrand,
        crates: 4,
        supplierId: supplierB,
      );
      final requests = await db.select(db.supplierCrateDepositRequests).get();
      expect(requests, hasLength(2));
      for (final r in requests) {
        await db.cratePoolDao.confirmCrateDepositRequest(
          requestId: r.id,
          decidedBy: managerId,
        );
      }
      final a = await db.cratePoolDao
          .watchSupplierCrateDepositPositions(supplierA)
          .first;
      final b = await db.cratePoolDao
          .watchSupplierCrateDepositPositions(supplierB)
          .first;
      expect(a.single.position.placedDepositKobo, 8 * rate);
      expect(b.single.position.placedDepositKobo, 4 * rate);
    });
  });

  // ── 8. The business-wide roll-up (#215) ───────────────────────────────────

  group('the business-wide roll-up the sixth card reads', () {
    Future<void> confirmAll() async {
      for (final r in await db.select(db.supplierCrateDepositRequests).get()) {
        await db.cratePoolDao.confirmCrateDepositRequest(
          requestId: r.id,
          decidedBy: managerId,
        );
      }
    }

    test('a business that never switched a brand on rolls up to EMPTY',
        () async {
      // THE RELEASE GATE at the roll-up. Receiving 30 crates of a `none` brand
      // moves crates and nothing else, so the card never appears.
      await receive(manufacturerId: swapBrand, crates: 30);
      await confirmAll();

      final rollup = await db.cratePoolDao
          .watchBusinessCrateDepositRollup()
          .first;
      expect(rollup.placedDepositKobo, 0);
      expect(rollup.bySupplier, isEmpty);
      expect(rollup.hasMoney, isFalse);
    });

    test('it totals every supplier and names each one', () async {
      await receive(manufacturerId: moneyBrand, crates: 8); // Ade Depot
      await receive(
        manufacturerId: moneyBrand,
        crates: 4,
        supplierId: supplierB, // Bola Depot
      );
      // A `none` brand in the same business contributes nothing at all.
      await receive(manufacturerId: swapBrand, crates: 30);
      await confirmAll();

      final rollup = await db.cratePoolDao
          .watchBusinessCrateDepositRollup()
          .first;

      expect(rollup.placedDepositKobo, 12 * rate);
      expect(rollup.bySupplier, hasLength(2));
      // Biggest holder first — the supplier an owner rings.
      expect(rollup.bySupplier.first.supplierName, 'Ade Depot');
      expect(rollup.bySupplier.first.placedDepositKobo, 8 * rate);
      expect(rollup.bySupplier.last.supplierName, 'Bola Depot');
      expect(rollup.bySupplier.last.placedDepositKobo, 4 * rate);
      // Only the money-moving brand is listed under each supplier.
      expect(
        rollup.bySupplier.first.brands.map((b) => b.manufacturerName),
        ['Star Lager'],
      );
      expect(
        rollup.bySupplier.fold<int>(0, (s, x) => s + x.placedDepositKobo),
        rollup.placedDepositKobo,
      );
    });

    test('a leg still awaiting a manager is reported, and is NOT in the total',
        () async {
      // ADR 0023 rule 6 — a book entry appears only when money genuinely moved.
      await receive(manufacturerId: moneyBrand, crates: 8);

      final rollup = await db.cratePoolDao
          .watchBusinessCrateDepositRollup()
          .first;
      expect(rollup.placedDepositKobo, 0);
      expect(rollup.pendingDepositKobo, 8 * rate);
      expect(rollup.hasPending, isTrue);
      expect(rollup.hasMoney, isTrue, reason: 'the card must show it');
      expect(rollup.bySupplier.single.supplierName, 'Ade Depot');
    });

    test('the crates a deposit does NOT stand behind are disclosed beside it',
        () async {
      // Both legs of one delivery: the receipt leg (#210) raises the crate
      // debt, the money leg the deposit. Confirm only the SECOND delivery's
      // money and the first delivery's crates stand unbacked.
      await receive(manufacturerId: moneyBrand, crates: 10);
      final first = (await db.select(db.supplierCrateDepositRequests).get())
          .single;
      await db.cratePoolDao.rejectCrateDepositRequest(
        requestId: first.id,
        decidedBy: managerId,
      );
      await receive(manufacturerId: moneyBrand, crates: 6);
      await confirmAll();

      final rollup = await db.cratePoolDao
          .watchBusinessCrateDepositRollup()
          .first;
      // 16 crates owed, 6 of them backed by money.
      expect(rollup.placedDepositKobo, 6 * rate);
      expect(rollup.unbackedValueKobo, 10 * rate);
    });
  });
}
