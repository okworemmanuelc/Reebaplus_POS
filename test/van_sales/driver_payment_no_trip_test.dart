// driver_payment_no_trip_test.dart
//
// #787 — a payment taken from a DRIVER, with no trip and no van. Debt sits with
// the driver, so a driver with no trip at all (an old customer account brought
// in, #783) can still pay, and the cash still reaches the shop's books.
//
//   · both legs are written: a driver-only ledger credit and a
//     `van_remittance` payment row whose one parent is the driver, stamped to
//     the shop that took the money;
//   · the driver's balance falls by exactly the amount;
//   · it can be voided like any other ledger row;
//   · bad input writes nothing.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String shopId;
  late String driverId;
  late String managerId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    shopId = UuidV7.generate();
    driverId = UuidV7.generate();
    managerId = UuidV7.generate();

    await db.into(db.stores).insert(
      StoresCompanion.insert(
        id: Value(shopId),
        businessId: businessId,
        name: 'Main Shop',
      ),
    );
    await db.into(db.users).insert(
      UsersCompanion.insert(
        id: Value(managerId),
        businessId: businessId,
        name: 'Manager Mo',
        pin: '1111',
      ),
    );
    await db.into(db.vanDrivers).insert(
      VanDriversCompanion.insert(
        id: Value(driverId),
        businessId: businessId,
        name: 'Johnson Kim',
      ),
    );
    // He owes 610,150 with no van and no trip (a brought-in old account).
    await db.driverLedgerDao.postEntry(
      vanDriverId: driverId,
      type: kDriverLedgerTypeRestatement,
      amountKobo: 61015000,
      isCredit: false,
      referenceType: kDriverLedgerRefEntry,
      activityDate: DateTime.now(),
      performedBy: managerId,
    );
  });

  tearDown(() async => db.close());

  test('writes both legs and lowers the balance by exactly the amount',
      () async {
    expect(await db.driverLedgerDao.getBalanceKobo(driverId), -61015000);

    final r = await db.vanTripsDao.recordDriverPaymentNoTrip(
      vanDriverId: driverId,
      storeId: shopId,
      amountKobo: 10000000,
      method: 'cash',
      performedBy: managerId,
      referenceNote: 'handed in at the shop',
    );
    expect(r.driverBalanceKoboAfter, -51015000);
    expect(await db.driverLedgerDao.getBalanceKobo(driverId), -51015000);

    final pay = await (db.select(db.paymentTransactions)
          ..where((p) => p.id.equals(r.paymentTransactionId)))
        .getSingle();
    expect(pay.type, kPaymentTypeVanRemittance);
    expect(pay.amountKobo, 10000000);
    expect(pay.method, 'cash');
    expect(pay.storeId, shopId);
    expect(pay.vanDriverId, driverId);
    expect(pay.vanTripId, isNull);

    final entry = await (db.select(db.driverLedgerEntries)
          ..where((e) => e.id.equals(r.ledgerEntryId)))
        .getSingle();
    expect(entry.type, kDriverLedgerTypePaymentCash);
    expect(entry.signedAmountKobo, 10000000);
    expect(entry.vanDriverId, driverId);
    expect(entry.vanStoreId, isNull);
    expect(entry.tripId, isNull);
    expect(entry.referenceId, r.paymentTransactionId);

    // Both rows are queued for upload.
    final queued = await db.select(db.syncQueue).get();
    expect(
      queued.map((q) => q.actionType).toSet(),
      containsAll(['payment_transactions:upsert', 'driver_ledger_entries:upsert']),
    );
  });

  test('a transfer is booked as a transfer', () async {
    final r = await db.vanTripsDao.recordDriverPaymentNoTrip(
      vanDriverId: driverId,
      storeId: shopId,
      amountKobo: 500000,
      method: 'transfer',
      performedBy: managerId,
    );
    final entry = await (db.select(db.driverLedgerEntries)
          ..where((e) => e.id.equals(r.ledgerEntryId)))
        .getSingle();
    expect(entry.type, kDriverLedgerTypePaymentTransfer);
  });

  test('voiding the payment puts the debt back', () async {
    final r = await db.vanTripsDao.recordDriverPaymentNoTrip(
      vanDriverId: driverId,
      storeId: shopId,
      amountKobo: 10000000,
      method: 'cash',
      performedBy: managerId,
    );
    final voided = await db.driverLedgerDao.voidEntry(
      entryId: r.ledgerEntryId,
      voidedBy: managerId,
      reason: 'wrong driver',
    );
    expect(voided, isTrue);
    expect(await db.driverLedgerDao.getBalanceKobo(driverId), -61015000);
  });

  test('bad input writes nothing', () async {
    Future<int> payments() async =>
        (await db.select(db.paymentTransactions).get()).length;
    await expectLater(
      db.vanTripsDao.recordDriverPaymentNoTrip(
        vanDriverId: driverId,
        storeId: shopId,
        amountKobo: 0,
        method: 'cash',
        performedBy: managerId,
      ),
      throwsArgumentError,
    );
    await expectLater(
      db.vanTripsDao.recordDriverPaymentNoTrip(
        vanDriverId: UuidV7.generate(),
        storeId: shopId,
        amountKobo: 1000,
        method: 'cash',
        performedBy: managerId,
      ),
      throwsStateError,
    );
    expect(await payments(), 0);
    expect(await db.driverLedgerDao.getBalanceKobo(driverId), -61015000);
  });
}
