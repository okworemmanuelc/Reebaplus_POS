// van_money_handed_in_test.dart
//
// #805 — Home's van sales are the money drivers HANDED IN in the period: the
// non-voided `van_remittance` payment rows (trip or no-trip), dated by the
// row's own created_at, scoped by its store_id. Pure function first, then the
// period-bounded DAO read over a real in-memory database (same style as
// van_remittance_test.dart).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/van_sales/van_money_handed_in.dart';

import '../helpers/dispatch_test_utils.dart';

PaymentTransactionData _pay({
  required int kobo,
  required DateTime at,
  String type = kPaymentTypeVanRemittance,
  String? storeId = 'shop-a',
  String? tripId = 'trip-1',
  String? driverId,
  String? performedBy = 'mgr',
  DateTime? voidedAt,
}) {
  return PaymentTransactionData(
    id: UuidV7.generate(),
    businessId: 'biz',
    storeId: storeId,
    amountKobo: kobo,
    method: 'cash',
    type: type,
    vanTripId: tripId,
    vanDriverId: driverId,
    performedBy: performedBy,
    voidedAt: voidedAt,
    createdAt: at,
    lastUpdatedAt: at,
  );
}

void main() {
  final mon = DateTime(2026, 11, 9, 10);
  final tue = DateTime(2026, 11, 10, 10);
  bool onlyTue(DateTime d) =>
      d.year == tue.year && d.month == tue.month && d.day == tue.day;
  bool anyStore(String? _) => true;
  bool always(DateTime _) => true;

  group('vanMoneyHandedInKobo (pure)', () {
    test('a trip payment and a no-trip driver payment both count', () {
      final total = vanMoneyHandedInKobo(
        [
          _pay(kobo: 90000000, at: tue),
          _pay(kobo: 5000000, at: tue, tripId: null, driverId: 'drv-1'),
        ],
        inSpan: always,
        inScope: anyStore,
      );
      expect(total, 95000000);
    });

    test('dated by the day the money was recorded, not the trip', () {
      final rows = [_pay(kobo: 100000, at: mon), _pay(kobo: 250000, at: tue)];
      expect(
        vanMoneyHandedInKobo(rows, inSpan: onlyTue, inScope: anyStore),
        250000,
      );
    });

    test('a voided payment never counts', () {
      final rows = [
        _pay(kobo: 100000, at: tue),
        _pay(kobo: 700000, at: tue, voidedAt: tue),
      ];
      expect(
        vanMoneyHandedInKobo(rows, inSpan: always, inScope: anyStore),
        100000,
      );
    });

    test(
      'only van_remittance rows: shop takings and other payments are out',
      () {
        final rows = [
          _pay(kobo: 100000, at: tue),
          _pay(kobo: 900000, at: tue, type: 'sale', tripId: null),
          _pay(kobo: 300000, at: tue, type: 'wallet_topup', tripId: null),
        ];
        expect(
          vanMoneyHandedInKobo(rows, inSpan: always, inScope: anyStore),
          100000,
        );
      },
    );

    test('a store lock counts only the payments booked to that store; '
        'All Stores counts all', () {
      final rows = [
        _pay(kobo: 100000, at: tue, storeId: 'shop-a'),
        _pay(kobo: 40000, at: tue, storeId: 'shop-b'),
      ];
      expect(
        vanMoneyHandedInKobo(
          rows,
          inSpan: always,
          inScope: (s) => s == 'shop-b',
        ),
        40000,
      );
      expect(
        vanMoneyHandedInKobo(rows, inSpan: always, inScope: anyStore),
        140000,
      );
    });

    test('recordedBy keeps only the rows that user recorded', () {
      final rows = [
        _pay(kobo: 100000, at: tue, performedBy: 'mgr'),
        _pay(kobo: 20000, at: tue, performedBy: 'cashier-1'),
      ];
      expect(
        vanMoneyHandedInKobo(
          rows,
          inSpan: always,
          inScope: anyStore,
          recordedBy: 'cashier-1',
        ),
        20000,
      );
    });

    test('nothing handed in reads 0', () {
      expect(
        vanMoneyHandedInKobo(const [], inSpan: always, inScope: anyStore),
        0,
      );
    });
  });

  group('VanTripsDao.watchDriverPaymentsBetween (real database)', () {
    late AppDatabase db;
    late String businessId;
    late String warehouseId;
    late String vanId;
    late String driverId;
    late String managerId;
    late String productId;

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
              id: Value(managerId),
              businessId: businessId,
              name: 'Manager Mo',
              pin: '1111',
            ),
          );
      await db
          .into(db.vanDrivers)
          .insert(
            VanDriversCompanion.insert(
              id: Value(driverId),
              businessId: businessId,
              name: 'Driver Dan',
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
      await db.inventoryDao.adjustStock(
        productId,
        warehouseId,
        100,
        'opening',
        managerId,
        trackCost: false,
      );
      await db.costBatchesDao.recordInflowBatch(
        productId: productId,
        storeId: warehouseId,
        quantity: 100,
        costKobo: 1000000,
      );
    });

    tearDown(() async => db.close());

    Future<String> loadVan() async {
      final r = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanId,
        vanDriverId: driverId,
        sourceStoreId: warehouseId,
        performedBy: managerId,
        dispatchEventId: UuidV7.generate(),
        dispatchedAt: mon,
        lines: [
          VanLoadLine(
            productId: productId,
            quantity: 40,
            loadPriceKobo: 1150000,
          ),
        ],
      );
      return r.tripId;
    }

    test('the period read returns only that window\'s non-voided driver '
        'payments, and the sum counts each payment ONCE (its ledger credit '
        'is the same money)', () async {
      final tripId = await loadVan();
      // Goods left on Monday: no money handed in yet, so nothing counts.
      expect(
        await db.vanTripsDao
            .watchDriverPaymentsBetween(from: mon, to: tue)
            .first,
        isEmpty,
      );

      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 30000000,
        method: 'cash',
        performedBy: managerId,
        paidOn: mon,
      );
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 12000000,
        method: 'transfer',
        performedBy: managerId,
        paidOn: tue,
      );
      await db.vanTripsDao.recordDriverPaymentNoTrip(
        vanDriverId: driverId,
        storeId: warehouseId,
        amountKobo: 5000000,
        method: 'cash',
        performedBy: managerId,
        paidOn: tue,
      );
      // A voided driver payment and a shop sale payment on Tuesday: both out.
      await db
          .into(db.paymentTransactions)
          .insert(
            PaymentTransactionsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: businessId,
              storeId: Value(warehouseId),
              amountKobo: 99900000,
              method: 'cash',
              type: kPaymentTypeVanRemittance,
              vanTripId: Value(tripId),
              voidedAt: Value(tue),
              createdAt: Value(tue),
              lastUpdatedAt: Value(tue),
            ),
          );

      final tueStart = DateTime(2026, 11, 10);
      final tueEnd = DateTime(2026, 11, 10, 23, 59, 59, 999);
      final tueRows = await db.vanTripsDao
          .watchDriverPaymentsBetween(from: tueStart, to: tueEnd)
          .first;
      expect(tueRows.map((r) => r.amountKobo).toSet(), {12000000, 5000000});
      expect(
        vanMoneyHandedInKobo(
          tueRows,
          inSpan: (_) => true,
          inScope: (s) => s == warehouseId,
        ),
        17000000,
      );

      // Open lower bound ("To Date"): every non-voided payment so far.
      final all = await db.vanTripsDao.watchDriverPaymentsBetween().first;
      final total = vanMoneyHandedInKobo(
        all,
        inSpan: (_) => true,
        inScope: (_) => true,
      );
      expect(total, 47000000);

      // One source only: the ledger carries the same three payments as
      // credits; adding them as well would double the figure.
      final ledgerPayments = (await db.select(db.driverLedgerEntries).get())
          .where(
            (e) =>
                e.type == kDriverLedgerTypePaymentCash ||
                e.type == kDriverLedgerTypePaymentTransfer,
          )
          .fold<int>(0, (s, e) => s + e.signedAmountKobo);
      expect(ledgerPayments, total);
    });

    test('another business\'s driver payments never appear', () async {
      final tripId = await loadVan();
      await db.vanTripsDao.recordDriverPayment(
        tripId: tripId,
        amountKobo: 1000000,
        method: 'cash',
        performedBy: managerId,
        paidOn: tue,
      );
      final otherBiz = UuidV7.generate();
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(id: Value(otherBiz), name: 'Other'),
          );
      db.businessIdResolver = () => otherBiz;
      expect(await db.vanTripsDao.watchDriverPaymentsBetween().first, isEmpty);
    });
  });
}
