// van_remittance_test.dart
//
// #144 (PRD #139 as amended by #161 / ADR 0019 decision 2, van-sales spec §4.7,
// §5.3, §9.5) — recording a driver's cash handed in.
//
// The whole slice is one claim: a remittance writes BOTH legs or neither.
//
//   · the driver-ledger CREDIT — what moves the balance toward zero, and
//   · a `payment_transactions` row typed `van_remittance`, store-stamped to the
//     SOURCE WAREHOUSE — what puts the cash into the business's books.
//
// Leg 2 is the one the original plan lacked, and its absence is the break ADR
// 0019 names: "the remittance days later landed only in the driver ledger,
// which the Daily Reconciliation never reads — so recorded cash was overstated
// forever by every unremitted naira". #142 lands next and stops road sales from
// writing payment rows at all, which is why this leg had to exist first: after
// #142 it is the ONLY moment van money enters the cash books.
//
// In-memory Drift via bootstrapTestDb(); same house style as
// test/van_sales/van_dispatch_test.dart.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String warehouseId;
  late String vanId;
  late String driverId;
  late String managerId;
  late String productId;

  /// A van out on the road with ₦1,150,000 signed for — the spec §6.3 Monday
  /// load, which is the position every remittance test starts from.
  late String tripId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;

    warehouseId = UuidV7.generate();
    vanId = UuidV7.generate();
    driverId = UuidV7.generate();
    managerId = UuidV7.generate();
    productId = UuidV7.generate();

    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(warehouseId),
            businessId: businessId,
            name: 'Main Warehouse',
          ),
        );
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(vanId),
            businessId: businessId,
            name: 'Van 1',
            kind: const Value(kStoreKindVan),
          ),
        );
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(driverId),
            businessId: businessId,
            name: 'Driver Dan',
            pin: '0000',
          ),
        );
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(managerId),
            businessId: businessId,
            name: 'Manager Mo',
            pin: '1111',
          ),
        );
    await db
        .into(db.products)
        .insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Star 60cl',
            retailerPriceKobo: const Value(1150000),
          ),
        );

    // 200 @ ₦10,000 cost in the warehouse, then load 100 @ ₦11,500.
    await db.inventoryDao.adjustStock(
      productId,
      warehouseId,
      200,
      'opening',
      managerId,
      trackCost: false,
    );
    await db.costBatchesDao.recordInflowBatch(
      productId: productId,
      storeId: warehouseId,
      quantity: 200,
      costKobo: 1000000,
    );
    final load = await db.vanTripsDao.dispatchLoad(
      vanStoreId: vanId,
      driverUserId: driverId,
      sourceStoreId: warehouseId,
      performedBy: managerId,
      dispatchEventId: UuidV7.generate(),
      lines: [
        VanLoadLine(productId: productId, quantity: 100, loadPriceKobo: 1150000),
      ],
    );
    tripId = load.tripId;
  });

  tearDown(() async => db.close());

  Future<List<PaymentTransactionData>> paymentRows() {
    return (db.select(db.paymentTransactions)
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
  }

  Future<List<DriverLedgerEntryData>> ledgerRows() {
    return (db.select(db.driverLedgerEntries)
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
  }

  // ═══ Both legs, one transaction ═════════════════════════════════════════

  group('recordDriverPayment — the two legs are one transaction', () {
    test('writes the ledger credit AND the van_remittance payment row, '
        'store-stamped to the SOURCE WAREHOUSE', () async {
      final result = await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 90000000, // ₦900,000 — the spec §6.3 Thursday remittance
        method: 'cash',
        performedBy: managerId,
      );

      // ── Leg 2: the cash row ──
      final payments = await paymentRows();
      expect(payments, hasLength(1), reason: 'exactly one remittance row');
      final pay = payments.single;
      expect(pay.id, result.paymentTransactionId);
      expect(pay.type, kPaymentTypeVanRemittance);
      expect(
        pay.type,
        isNot('sale'),
        reason: 'a remittance is not a sale — "Cash sales" must not see it',
      );
      expect(pay.method, 'cash');
      expect(pay.amountKobo, 90000000);
      expect(pay.vanTripId, tripId);
      expect(
        pay.storeId,
        warehouseId,
        reason:
            'cash comes back to the yard; stamping the VAN would book it to a '
            'location every per-store figure excludes, and it would vanish',
      );
      expect(pay.storeId, isNot(vanId));
      expect(pay.performedBy, managerId);

      // ── Leg 1: the ledger credit, pointing at leg 2 ──
      final credits = (await ledgerRows())
          .where((e) => e.referenceType == kDriverLedgerRefPayment)
          .toList();
      expect(credits, hasLength(1));
      final credit = credits.single;
      expect(credit.id, result.ledgerEntryId);
      expect(credit.type, kDriverLedgerTypePaymentCash);
      expect(credit.driverUserId, driverId);
      expect(credit.tripId, tripId);
      expect(credit.amountKobo, 90000000, reason: 'stored as a magnitude');
      expect(
        credit.signedAmountKobo,
        90000000,
        reason: 'a credit is POSITIVE — it reduces what the driver owes',
      );
      expect(
        credit.referenceId,
        pay.id,
        reason: 'the ledger line must trace to the cash row that justifies it',
      );
      expect(credit.paymentMethod, 'cash');
    });

    test('the balance moves toward zero by exactly the amount', () async {
      // After the load the driver signed for 100 × ₦11,500 = ₦1,150,000.
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -115000000);

      final result = await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 90000000,
        method: 'cash',
        performedBy: managerId,
      );

      expect(await db.driverLedgerDao.getBalanceKobo(driverId), -25000000);
      expect(result.driverBalanceKoboAfter, -25000000);
    });

    test('multiple payments per trip accumulate; the last one settles', () async {
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 50000000,
        method: 'cash',
        performedBy: managerId,
      );
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 40000000,
        method: 'transfer',
        performedBy: managerId,
        referenceNote: 'TRF-20938',
      );
      final last = await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 25000000,
        method: 'cash',
        performedBy: managerId,
      );

      expect(await paymentRows(), hasLength(3));
      expect(
        await db.vanTripsDao.remittedKoboForTrip(tripId),
        115000000,
        reason: '₦500,000 + ₦400,000 + ₦250,000',
      );
      expect(
        last.driverBalanceKoboAfter,
        0,
        reason: 'a perfectly settled trip closes at 0 (spec §5.1)',
      );
    });

    test('a non-cash tender books the ledger row as payment_transfer but the '
        'payment row keeps the real method', () async {
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 10000000,
        method: 'pos',
        performedBy: managerId,
      );

      final pay = (await paymentRows()).single;
      expect(
        pay.method,
        'pos',
        reason: 'the CASH card keys on the tender — POS is not cash',
      );
      final credit = (await ledgerRows())
          .firstWhere((e) => e.referenceType == kDriverLedgerRefPayment);
      expect(
        credit.type,
        kDriverLedgerTypePaymentTransfer,
        reason: 'the DRIVER ledger models exactly two payment kinds (spec §4.4)',
      );
    });

    test('proof and note ride on the ledger row (receipt_path stays local)',
        () async {
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 1000000,
        method: 'transfer',
        performedBy: managerId,
        receiptPath: '/data/user/0/app/cache/slip.jpg',
        referenceNote: 'handed over at the yard',
      );
      final credit = (await ledgerRows())
          .firstWhere((e) => e.referenceType == kDriverLedgerRefPayment);
      expect(credit.receiptPath, '/data/user/0/app/cache/slip.jpg');
      expect(credit.referenceNote, 'handed over at the yard');
    });

    test('both rows are enqueued for sync carrying their explicit ids',
        () async {
      final before = (await getPendingQueue(db)).length;
      final result = await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 5000000,
        method: 'cash',
        performedBy: managerId,
      );
      final queued = (await getPendingQueue(db)).skip(before).toList();

      final payQueued = queued
          .where((q) => q.actionType.contains('payment_transactions'))
          .toList();
      final ledgerQueued = queued
          .where((q) => q.actionType.contains('driver_ledger_entries'))
          .toList();
      expect(payQueued, hasLength(1));
      expect(ledgerQueued, hasLength(1));
      // [[project_synced_write_explicit_id]] — the pushed payload must carry
      // the id the device stored, or the cloud mints a different one (2067).
      expect(
        decodePayload(payQueued.single)['id'],
        result.paymentTransactionId,
      );
      expect(decodePayload(ledgerQueued.single)['id'], result.ledgerEntryId);
      expect(decodePayload(payQueued.single)['van_trip_id'], tripId);
      expect(decodePayload(payQueued.single)['store_id'], warehouseId);
    });
  });

  // ═══ Atomicity — half a remittance is worse than none ════════════════════

  group('a failure in either leg rolls BOTH back', () {
    test('the ledger leg failing un-writes the payment row it followed',
        () async {
      final balanceBefore = await db.driverLedgerDao.getBalanceKobo(driverId);
      final paymentsBefore = (await paymentRows()).length;

      // Make the LEDGER insert abort. The payment row is written first, so this
      // is precisely the "one leg landed, the other didn't" case — if the two
      // were not one transaction, the books would show cash the driver never
      // got credit for, and the trip would look settled when it is not.
      await db.customStatement(
        'CREATE TRIGGER t_ledger_boom BEFORE INSERT ON driver_ledger_entries '
        "BEGIN SELECT RAISE(ABORT, 'boom'); END",
      );
      addTearDown(
        () => db.customStatement('DROP TRIGGER IF EXISTS t_ledger_boom'),
      );

      await expectLater(
        db.vanTripsDao.recordDriverPayment(
          tripId: tripId,
          amountKobo: 90000000,
          method: 'cash',
          performedBy: managerId,
        ),
        throwsA(anything),
      );

      expect(
        (await paymentRows()).length,
        paymentsBefore,
        reason: 'the payment row must roll back with the ledger credit',
      );
      expect(
        await db.driverLedgerDao.getBalanceKobo(driverId),
        balanceBefore,
        reason: 'nothing moved',
      );
    });

    test('the payment leg failing writes no ledger credit', () async {
      final balanceBefore = await db.driverLedgerDao.getBalanceKobo(driverId);

      await db.customStatement(
        'CREATE TRIGGER t_pay_boom BEFORE INSERT ON payment_transactions '
        "BEGIN SELECT RAISE(ABORT, 'boom'); END",
      );
      addTearDown(
        () => db.customStatement('DROP TRIGGER IF EXISTS t_pay_boom'),
      );

      await expectLater(
        db.vanTripsDao.recordDriverPayment(
          tripId: tripId,
          amountKobo: 90000000,
          method: 'cash',
          performedBy: managerId,
        ),
        throwsA(anything),
      );

      expect(await paymentRows(), isEmpty);
      expect(await db.driverLedgerDao.getBalanceKobo(driverId), balanceBefore);
      expect(
        (await ledgerRows())
            .where((e) => e.referenceType == kDriverLedgerRefPayment),
        isEmpty,
      );
    });
  });

  // ═══ Guards ═════════════════════════════════════════════════════════════

  group('guards', () {
    test('a non-positive amount is refused before anything is written',
        () async {
      for (final amount in const [0, -1]) {
        await expectLater(
          db.vanTripsDao.recordDriverPayment(
            tripId: tripId,
            amountKobo: amount,
            method: 'cash',
            performedBy: managerId,
          ),
          throwsA(isA<ArgumentError>()),
        );
      }
      expect(await paymentRows(), isEmpty);
    });

    test('an unknown tender is refused (the payment_transactions method CHECK '
        'would otherwise abort mid-transaction)', () async {
      await expectLater(
        db.vanTripsDao.recordDriverPayment(
          tripId: tripId,
          amountKobo: 1000,
          method: 'crypto',
          performedBy: managerId,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(await paymentRows(), isEmpty);
    });

    test('a closed trip is never edited in place (spec §9.4 #16)', () async {
      await (db.update(db.vanTrips)..where((t) => t.id.equals(tripId))).write(
        VanTripsCompanion(
          status: const Value(kVanTripStatusClosed),
          closedAt: Value(DateTime.now()),
        ),
      );

      await expectLater(
        db.vanTripsDao.recordDriverPayment(
          tripId: tripId,
          amountKobo: 1000000,
          method: 'cash',
          performedBy: managerId,
        ),
        throwsA(isA<VanTripNotOpenException>()),
      );
      expect(await paymentRows(), isEmpty);
    });

    test('a missing trip throws before any write', () async {
      await expectLater(
        db.vanTripsDao.recordDriverPayment(
          tripId: UuidV7.generate(),
          amountKobo: 1000000,
          method: 'cash',
          performedBy: managerId,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await paymentRows(), isEmpty);
    });
  });

  // ═══ The exactly-one-parent CHECK still holds for everyone ═══════════════

  group('payment_transactions after the v72 rebuild', () {
    test('a remittance row has exactly ONE parent — the trip', () async {
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 1000000,
        method: 'cash',
        performedBy: managerId,
      );
      final pay = (await paymentRows()).single;
      expect(pay.vanTripId, isNotNull);
      expect(pay.orderId, isNull);
      expect(pay.shipmentId, isNull);
      expect(pay.expenseId, isNull);
      expect(pay.walletTxnId, isNull);
      expect(pay.deliveryId, isNull);
    });

    test('a parentless payment row is still rejected', () async {
      await expectLater(
        db.customStatement(
          'INSERT INTO payment_transactions '
          '(id, business_id, amount_kobo, method, type) '
          "VALUES (?, ?, 1000, 'cash', 'van_remittance')",
          [UuidV7.generate(), businessId],
        ),
        throwsA(anything),
        reason: 'the CHECK is exactly-one, not at-most-one',
      );
    });

    test('a two-parent payment row is still rejected', () async {
      await expectLater(
        db.customStatement(
          'INSERT INTO payment_transactions '
          '(id, business_id, amount_kobo, method, type, van_trip_id, order_id) '
          "VALUES (?, ?, 1000, 'cash', 'van_remittance', ?, ?)",
          [UuidV7.generate(), businessId, tripId, UuidV7.generate()],
        ),
        throwsA(anything),
      );
    });

    test('an unknown payment type is still rejected', () async {
      await expectLater(
        db.customStatement(
          'INSERT INTO payment_transactions '
          '(id, business_id, amount_kobo, method, type, van_trip_id) '
          "VALUES (?, ?, 1000, 'cash', 'van_tip', ?)",
          [UuidV7.generate(), businessId, tripId],
        ),
        throwsA(anything),
      );
    });

    test('the ledger stays append-only: van_trip_id cannot be edited after '
        'insert, and the row cannot be deleted', () async {
      final result = await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 1000000,
        method: 'cash',
        performedBy: managerId,
      );
      await expectLater(
        db.customStatement(
          'UPDATE payment_transactions SET van_trip_id = NULL WHERE id = ?',
          [result.paymentTransactionId],
        ),
        throwsA(anything),
      );
      await expectLater(
        db.customStatement(
          'DELETE FROM payment_transactions WHERE id = ?',
          [result.paymentTransactionId],
        ),
        throwsA(anything),
      );
    });
  });

  // ═══ Reads the later slices lean on ══════════════════════════════════════

  group('trip reads', () {
    test('watchRemittancesForTrip sees only this trip\'s remittances',
        () async {
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 1000000,
        method: 'cash',
        performedBy: managerId,
      );
      final rows = await db.vanTripsDao.watchRemittancesForTrip(tripId).first;
      expect(rows, hasLength(1));
      expect(
        await db.vanTripsDao.watchRemittancesForTrip(UuidV7.generate()).first,
        isEmpty,
      );
    });

    test('remittedKoboForTrip skips voided rows', () async {
      final a = await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 1000000,
        method: 'cash',
        performedBy: managerId,
      );
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 2000000,
        method: 'cash',
        performedBy: managerId,
      );
      expect(await db.vanTripsDao.remittedKoboForTrip(tripId), 3000000);

      // Voiding IS permitted on the ledger (the void columns sit outside the
      // immutable set); the recovered figure must drop it.
      await db.customStatement(
        'UPDATE payment_transactions SET voided_at = 1 WHERE id = ?',
        [a.paymentTransactionId],
      );
      expect(await db.vanTripsDao.remittedKoboForTrip(tripId), 2000000);
    });
  });
}
