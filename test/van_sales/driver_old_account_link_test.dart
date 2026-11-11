// driver_old_account_link_test.dart
//
// #783 / ADR 0036 — "Bring in old customer account". A driver is linked once to
// the customer account the shop sold to before Van Sales. A debt moves as ONE
// wallet credit + ONE driver-ledger debit of the same kobo; nothing existing is
// edited; no sale / payment / cash / expense figure moves.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';


import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String van;
  late String driver;
  late String driver2;
  late String shop;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    van = UuidV7.generate();
    shop = UuidV7.generate();
    await db.into(db.stores).insert(
      StoresCompanion.insert(id: Value(shop), businessId: businessId, name: 'Shop'),
    );
    driver = UuidV7.generate();
    driver2 = UuidV7.generate();
    for (final (id, name) in [(driver, 'Johnson Kim'), (driver2, 'Boniface')]) {
      await db.into(db.vanDrivers).insert(
        VanDriversCompanion.insert(
          id: Value(id),
          businessId: businessId,
          name: name,
        ),
      );
    }
    // The van is inserted AFTER the drivers exist (FK), pointing at driver 1.
    await db.into(db.stores).insert(
      StoresCompanion.insert(
        id: Value(van),
        businessId: businessId,
        name: 'Beer Van',
        kind: const Value(kStoreKindVan),
        vanDriverId: Value(driver),
      ),
    );
  });
  tearDown(() => db.close());

  /// A customer with a wallet, one credit sale 2 days ago (net 100,000 kobo:
  /// 40,000 cash now, 60,000 on the wallet) and one cash top-up of [topUp].
  Future<String> seedCustomer({
    required String name,
    int sale = 100000,
    int cashPaid = 40000,
    int topUp = 0,
    DateTime? when,
  }) async {
    final cid = UuidV7.generate();
    final at = when ?? DateTime.now().subtract(const Duration(days: 2));
    await db.into(db.customers).insert(
      CustomersCompanion.insert(
        id: Value(cid),
        businessId: businessId,
        name: name,
      ),
    );
    final walletId = UuidV7.generate();
    await db.into(db.customerWallets).insert(
      CustomerWalletsCompanion.insert(
        id: Value(walletId),
        businessId: businessId,
        customerId: cid,
      ),
    );
    if (sale > 0) {
      final oid = UuidV7.generate();
      await db.into(db.orders).insert(
        OrdersCompanion.insert(
          id: Value(oid),
          businessId: businessId,
          orderNumber: 'ORD-$oid',
          customerId: Value(cid),
          totalAmountKobo: sale,
          netAmountKobo: sale,
          amountPaidKobo: Value(cashPaid),
          paymentType: 'mixed',
          status: 'completed',
          createdAt: Value(at),
          lastUpdatedAt: Value(at),
        ),
      );
      await db.into(db.orderItems).insert(
        OrderItemsCompanion.insert(
          businessId: businessId,
          orderId: oid,
          storeId: shop,
          quantity: 1.0,
          unitPriceKobo: sale,
          totalKobo: sale,
          createdAt: Value(at),
          lastUpdatedAt: Value(at),
        ),
      );
      if (cashPaid > 0) {
        await db.into(db.paymentTransactions).insert(
          PaymentTransactionsCompanion.insert(
            businessId: businessId,
            amountKobo: cashPaid,
            method: 'cash',
            type: 'sale',
            orderId: Value(oid),
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
      }
      if (sale - cashPaid > 0) {
        await db.into(db.walletTransactions).insert(
          WalletTransactionsCompanion.insert(
            businessId: businessId,
            walletId: walletId,
            customerId: cid,
            type: 'debit',
            amountKobo: sale - cashPaid,
            signedAmountKobo: -(sale - cashPaid),
            referenceType: 'order_payment',
            orderId: Value(oid),
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
      }
    }
    if (topUp > 0) {
      final wid = UuidV7.generate();
      await db.into(db.walletTransactions).insert(
        WalletTransactionsCompanion.insert(
          id: Value(wid),
          businessId: businessId,
          walletId: walletId,
          customerId: cid,
          type: 'credit',
          amountKobo: topUp,
          signedAmountKobo: topUp,
          referenceType: 'topup_cash',
          createdAt: Value(at),
          lastUpdatedAt: Value(at),
        ),
      );
      await db.into(db.paymentTransactions).insert(
        PaymentTransactionsCompanion.insert(
          businessId: businessId,
          amountKobo: topUp,
          method: 'cash',
          type: 'wallet_topup',
          walletTxnId: Value(wid),
          createdAt: Value(at),
          lastUpdatedAt: Value(at),
        ),
      );
    }
    return cid;
  }

  Future<int> custBalance(String cid) =>
      db.walletTransactionsDao.getBalanceKobo(cid);
  Future<int> driverBalance(String did) =>
      db.driverLedgerDao.getBalanceKobo(did);
  Future<int> count(String table) async => (await db
          .customSelect('SELECT COUNT(*) AS c FROM $table')
          .getSingle())
      .read<int>('c');

  group('link with a debt', () {
    test('customer ends at exactly 0, driver owes the same kobo, once', () async {
      // sale 100,000 - cash 40,000 = 60,000 on wallet, top-up 10,000 => owes 50,000
      final cid = await seedCustomer(name: 'Johnson Kim (Beer Van Driver)', topUp: 10000);
      expect(await custBalance(cid), -50000);
      expect(await driverBalance(driver), 0);

      final moved = await db.vanDriversDao.linkOldCustomerAccount(
        vanDriverId: driver,
        customerId: cid,
      );

      expect(moved, 50000);
      expect(await custBalance(cid), 0);
      expect(await driverBalance(driver), -50000);

      final d = await db.vanDriversDao.getDriver(driver);
      expect(d!.customerId, cid);

      // Exactly ONE wallet entry and ONE driver entry came from the move.
      final wallet = await (db.select(db.walletTransactions)
            ..where((t) => t.referenceType.equals('adjustment')))
          .get();
      expect(wallet, hasLength(1));
      expect(wallet.single.type, 'credit');
      expect(wallet.single.signedAmountKobo, 50000);
      expect(wallet.single.orderId, isNull);
      final ledger = await db.select(db.driverLedgerEntries).get();
      expect(ledger, hasLength(1));
      expect(ledger.single.type, kDriverLedgerTypeRestatement);
      expect(ledger.single.signedAmountKobo, -50000);
      expect(ledger.single.amountKobo, 50000);
      expect(ledger.single.tripId, isNull);
      expect(ledger.single.vanStoreId, isNull);
      expect(ledger.single.vanDriverId, driver);
      expect(ledger.single.referenceNote, contains('old customer account'));
    });

    test('a second attempt (same driver, or same customer) writes nothing',
        () async {
      final cid = await seedCustomer(name: 'Johnson Kim');
      final other = await seedCustomer(name: 'Someone Else');
      await db.vanDriversDao
          .linkOldCustomerAccount(vanDriverId: driver, customerId: cid);

      final walletRows = await count('wallet_transactions');
      final ledgerRows = await count('driver_ledger_entries');
      final queued = (await getPendingQueue(db)).length;

      // Same driver again, with the same customer.
      await expectLater(
        db.vanDriversDao
            .linkOldCustomerAccount(vanDriverId: driver, customerId: cid),
        throwsA(isA<OldAccountLinkException>()),
      );
      // Same driver, a different customer.
      await expectLater(
        db.vanDriversDao
            .linkOldCustomerAccount(vanDriverId: driver, customerId: other),
        throwsA(isA<OldAccountLinkException>()),
      );
      // A different driver, the already-linked customer.
      await expectLater(
        db.vanDriversDao
            .linkOldCustomerAccount(vanDriverId: driver2, customerId: cid),
        throwsA(isA<OldAccountLinkException>()),
      );

      expect(await count('wallet_transactions'), walletRows);
      expect(await count('driver_ledger_entries'), ledgerRows);
      expect((await getPendingQueue(db)).length, queued);
      expect((await db.vanDriversDao.getDriver(driver2))!.customerId, isNull);
      expect(await custBalance(cid), 0);
      expect(await driverBalance(driver), -60000);
    });

    test('a driver with no van and no trip still takes the debt: it sits '
        'with the driver, on no van', () async {
      final cid = await seedCustomer(name: 'Boniface (Drinks Van Driver)');
      // driver2 has no assigned van and no trip.
      final moved = await db.vanDriversDao
          .linkOldCustomerAccount(vanDriverId: driver2, customerId: cid);
      expect(moved, 60000);
      expect((await db.vanDriversDao.getDriver(driver2))!.customerId, cid);
      expect(await custBalance(cid), 0);
      expect(await driverBalance(driver2), -60000);
      final row = await (db.select(db.driverLedgerEntries)
            ..where((e) => e.vanDriverId.equals(driver2)))
          .getSingle();
      expect(row.vanStoreId, isNull);
      expect(row.tripId, isNull);
    });

    test('the move is queued for sync: driver row, wallet row, ledger row',
        () async {
      final cid = await seedCustomer(name: 'Johnson Kim');
      await db.vanDriversDao
          .linkOldCustomerAccount(vanDriverId: driver, customerId: cid);
      final q = await getPendingQueue(db);
      final types = q.map((r) => r.actionType).toSet();
      expect(types, containsAll([
        'van_drivers:upsert',
        'wallet_transactions:upsert',
        'driver_ledger_entries:upsert',
      ]));
      final vd = decodePayload(
        q.lastWhere((r) => r.actionType == 'van_drivers:upsert'),
      );
      expect(vd['customer_id'], cid);
    });
  });

  group('link with no debt', () {
    test('zero balance: link only, no money entry', () async {
      final cid = await seedCustomer(name: 'Paid Up', sale: 100000, cashPaid: 100000);
      expect(await custBalance(cid), 0);
      final moved = await db.vanDriversDao
          .linkOldCustomerAccount(vanDriverId: driver, customerId: cid);
      expect(moved, 0);
      expect((await db.vanDriversDao.getDriver(driver))!.customerId, cid);
      expect(await count('driver_ledger_entries'), 0);
      final adj = await (db.select(db.walletTransactions)
            ..where((t) => t.referenceType.equals('adjustment')))
          .get();
      expect(adj, isEmpty);
    });

    test('in credit: link only, no money entry, balance untouched', () async {
      final cid = await seedCustomer(
        name: 'In Credit',
        sale: 100000,
        cashPaid: 100000,
        topUp: 25000,
      );
      expect(await custBalance(cid), 25000);
      final moved = await db.vanDriversDao
          .linkOldCustomerAccount(vanDriverId: driver, customerId: cid);
      expect(moved, 0);
      expect(await custBalance(cid), 25000);
      expect(await count('driver_ledger_entries'), 0);
      expect(await driverBalance(driver), 0);
    });
  });

  group('uniqueness', () {
    test('the cloud/local unique index refuses two drivers on one customer',
        () async {
      final cid = await seedCustomer(name: 'Shared');
      await (db.update(db.vanDrivers)..where((d) => d.id.equals(driver)))
          .write(VanDriversCompanion(customerId: Value(cid)));
      await expectLater(
        (db.update(db.vanDrivers)..where((d) => d.id.equals(driver2)))
            .write(VanDriversCompanion(customerId: Value(cid))),
        throwsA(anything),
      );
    });

    test('two drivers can both be unlinked (null is not unique)', () async {
      expect((await db.select(db.vanDrivers).get()).where((d) => d.customerId == null),
          hasLength(2));
    });
  });

  group('summary and history feeds', () {
    test('summary counts sales, payments and the balance owed', () async {
      final cid = await seedCustomer(name: 'Johnson Kim', topUp: 10000);
      final s = await db.vanDriversDao.summariseOldAccount(cid);
      expect(s.salesCount, 1);
      expect(s.paymentsCount, 1);
      expect(s.balanceKobo, -50000);
      expect(s.owedKobo, 50000);
    });

    test('old sales, payments and adjustments are listed; the move shows as '
        'an adjustment, not a payment',
        () async {
      final cid = await seedCustomer(name: 'Johnson Kim', topUp: 10000);
      await db.vanDriversDao
          .linkOldCustomerAccount(vanDriverId: driver, customerId: cid);
      final sales = await db.vanDriversDao.watchOldAccountSales(cid).first;
      expect(sales, hasLength(1));
      final pays = await db.vanDriversDao.watchOldAccountPayments(cid).first;
      // The payment, plus the move itself as an account adjustment (so the
      // history adds up). The summary still counts payments only.
      expect(pays, hasLength(2));
      final topUp = pays.singleWhere((p) => p.referenceType == 'topup_cash');
      expect(topUp.amountKobo, 10000);
      expect(
        pays.where((p) => p.referenceType == 'adjustment'),
        hasLength(1),
      );
    });

    test('a linked customer shows in the linked set (hidden from the picker)',
        () async {
      final cid = await seedCustomer(name: 'Johnson Kim');
      final free = await seedCustomer(name: 'Walk Up');
      await db.vanDriversDao
          .linkOldCustomerAccount(vanDriverId: driver, customerId: cid);
      final linked = await db.vanDriversDao.watchLinkedCustomerIds().first;
      expect(linked, {cid});
      expect(linked.contains(free), isFalse);
      expect((await db.vanDriversDao.driverLinkedToCustomer(cid))!.id, driver);
    });
  });

  group('reports are identical before and after', () {
    Future<List<num>> figures(DateTime start, DateTime end) async {
      final rows = await loadReconPeriodRows(db, start, end);
      final balances =
          await db.walletTransactionsDao.watchAllBalancesKobo().first;
      final r = reconDataFrom(
        ReconInputs(
          start: start,
          endExclusive: end,
          orders: rows.orders,
          payments: rows.payments,
          expenses: rows.expenses,
          creditBalancesKobo: balances,
        ),
      );
      return [
        r.totalRevenueKobo,
        r.cashSalesKobo,
        r.cashDebtsCollectedKobo,
        r.cashInKobo,
        r.cashOutKobo,
        r.netCashMovementKobo,
        r.expensesKobo,
        r.salesPaidNowKobo,
        r.salesOnCreditKobo,
        r.netProfitKobo,
        r.totalOwedKobo,
      ];
    }

    test('every day (past days and the day of the link): only "customers owe" '
        'drops, by exactly the moved amount', () async {
      final cid = await seedCustomer(name: 'Johnson Kim', topUp: 10000);
      final today = DateTime.now();
      final days = [
        for (final back in [0, 1, 2, 3])
          DateTime(today.year, today.month, today.day)
              .subtract(Duration(days: back)),
      ];
      final before = <List<num>>[
        for (final d in days)
          await figures(d, d.add(const Duration(days: 1))),
      ];
      // The seeded sale and top-up are two days back: the figures are not all 0.
      expect(before[2][0], 100000);
      expect(before[2][1], 40000);

      await db.vanDriversDao
          .linkOldCustomerAccount(vanDriverId: driver, customerId: cid);

      for (var i = 0; i < days.length; i++) {
        final after = await figures(days[i], days[i].add(const Duration(days: 1)));
        // Index 10 is totalOwedKobo; every other figure is identical.
        expect(after.sublist(0, 10), before[i].sublist(0, 10),
            reason: 'flow figures changed on day -$i');
        expect(after[10], 0, reason: 'the customer no longer owes');
        expect(before[i][10], 50000);
      }
    });

    test('the move writes no order and no payment row', () async {
      final cid = await seedCustomer(name: 'Johnson Kim');
      final orders = await count('orders');
      final payments = await count('payment_transactions');
      await db.vanDriversDao
          .linkOldCustomerAccount(vanDriverId: driver, customerId: cid);
      expect(await count('orders'), orders);
      expect(await count('payment_transactions'), payments);
    });
  });
}
