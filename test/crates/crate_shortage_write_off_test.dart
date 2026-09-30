// crate_shortage_write_off_test.dart
//
// #296 / PRD #284 decision 7 — writing off a counted Crate Shortage, reversing
// a write-off, and Daily Reconciliation reading the same shortage as the
// manufacturer screen. Through the Crate Pool seam against a real database.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_ledger_movement_types.dart';
import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/crates/crate_shortfall.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';

void main() {
  const businessId = 'biz-1';
  const managerId = 'user-manager';
  const storeA = 'store-a';
  const storeB = 'store-b';
  const brand = 'mfr-star';
  // ₦3,500 a crate.
  const rate = 350000;

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => businessId;
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(managerId),
            businessId: businessId,
            name: 'Manager',
            pin: '1234',
          ),
        );
    for (final s in [storeA, storeB]) {
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(s),
              businessId: businessId,
              name: 'Store $s',
            ),
          );
    }
    // A swap-only brand: the count-based shortage is tracked and written off
    // whatever the arrangement.
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: const Value(brand),
            businessId: businessId,
            name: 'Star Lager',
            depositAmountKobo: const Value(rate),
            crateMoneyArrangement: const Value(kCrateMoneyArrangementNone),
          ),
        );
  });

  tearDown(() => db.close());

  Future<void> count(int counted, {String storeId = storeA}) =>
      db.cratePoolDao.recordManualCountCorrection(
        manufacturerId: brand,
        storeId: storeId,
        performedBy: managerId,
        countedEmpties: counted,
      );

  Future<int> openAt(String? storeId) =>
      db.cratePoolDao.watchCrateShortageByManufacturer(brand, storeId: storeId).first;

  Future<List<CrateShortfallWriteoffData>> writeOffRows() =>
      db.select(db.crateShortfallWriteoffs).get();

  Future<void> setCrateValue(int kobo) =>
      (db.update(db.manufacturers)..where((t) => t.id.equals(brand))).write(
        ManufacturersCompanion(depositAmountKobo: Value(kobo)),
      );

  Future<ManufacturerData> manufacturer() =>
      (db.select(db.manufacturers)..where((t) => t.id.equals(brand))).getSingle();

  /// The P&L crate-loss line for `[start, end)`, the way Daily Reconciliation
  /// computes it.
  Future<int> bookedLoss(DateTime start, DateTime end) async {
    final d = reconDataFrom(
      ReconInputs(
        showCrates: true,
        manufacturers: [await manufacturer()],
        crateShortfallWriteOffs: await writeOffRows(),
        start: start,
        endExclusive: end,
      ),
    );
    return d.crateShortfallWrittenOffKobo;
  }

  DateTime startOfToday() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  group('write off', () {
    test('reduces the open shortage and books a loss today at the snapshotted '
        'crate value; a later crate value change does not move it', () async {
      await count(30); // opening count
      await count(20); // 10 missing
      expect(await openAt(storeA), 10);

      final id = await db.cratePoolDao.writeOffCrateShortage(
        manufacturerId: brand,
        storeId: storeA,
        crateCount: 6,
        performedBy: managerId,
      );
      expect(id, isNotNull);
      expect(await openAt(storeA), 4);

      final row = (await writeOffRows()).single;
      expect(row.source, kCrateWriteOffSourceCountShortage);
      expect(row.storeId, storeA);
      expect(row.crateCount, 6);
      expect(row.ratePerCrateKobo, rate);
      expect(row.performedBy, managerId);

      final today = startOfToday();
      final tomorrow = today.add(const Duration(days: 1));
      expect(await bookedLoss(today, tomorrow), 6 * rate);

      await setCrateValue(900000);
      expect(
        await bookedLoss(today, tomorrow),
        6 * rate,
        reason: 'the loss was valued at the rate on the day it was taken',
      );
      expect(
        await bookedLoss(today.subtract(const Duration(days: 1)), today),
        0,
        reason: 'no earlier day moves',
      );
    });

    test('is capped at the open shortage — the same crates cannot be written '
        'off twice, from either screen', () async {
      await count(30);
      await count(25); // 5 missing
      expect(
        await db.cratePoolDao.writeOffCrateShortage(
          manufacturerId: brand,
          storeId: storeA,
          crateCount: 6,
          performedBy: managerId,
        ),
        isNull,
      );
      expect(
        await db.cratePoolDao.writeOffCrateShortage(
          manufacturerId: brand,
          storeId: storeA,
          crateCount: 5,
          performedBy: managerId,
        ),
        isNotNull,
      );
      // The second screen opens with the same 5 and tries again.
      expect(
        await db.cratePoolDao.writeOffCrateShortage(
          manufacturerId: brand,
          storeId: storeA,
          crateCount: 5,
          performedBy: managerId,
        ),
        isNull,
      );
      expect(await writeOffRows(), hasLength(1));
    });

    test('only touches the store whose count found the crates missing',
        () async {
      await count(30);
      await count(25);
      await count(10, storeId: storeB);
      await count(7, storeId: storeB);
      await db.cratePoolDao.writeOffCrateShortage(
        manufacturerId: brand,
        storeId: storeA,
        crateCount: 5,
        performedBy: managerId,
      );
      expect(await openAt(storeA), 0);
      expect(await openAt(storeB), 3);
      expect(await openAt(null), 3);
    });

    test('is enqueued for sync with its source', () async {
      await count(30);
      await count(28);
      await db.cratePoolDao.writeOffCrateShortage(
        manufacturerId: brand,
        storeId: storeA,
        crateCount: 2,
        performedBy: managerId,
      );
      final queued = await db
          .customSelect(
            "SELECT payload FROM sync_queue "
            "WHERE action_type LIKE 'crate_shortfall_writeoffs:%'",
          )
          .get();
      expect(queued, hasLength(1));
      expect(queued.single.read<String>('payload'), contains('count_shortage'));
    });

    test('moves no crates and no cash', () async {
      await count(30);
      await count(20);
      final before = await db.cratePoolDao
          .watchEmptiesPoolByManufacturer(storeId: storeA)
          .first;
      await db.cratePoolDao.writeOffCrateShortage(
        manufacturerId: brand,
        storeId: storeA,
        crateCount: 10,
        performedBy: managerId,
      );
      final after = await db.cratePoolDao
          .watchEmptiesPoolByManufacturer(storeId: storeA)
          .first;
      expect(after, before);
      expect(await db.select(db.paymentTransactions).get(), isEmpty);
    });
  });

  group('reverse write-off', () {
    /// Yesterday: opening 30, counted 20, wrote off 10 — inserted with their
    /// own timestamps so "yesterday" is a closed day.
    Future<DateTime> writtenOffYesterday() async {
      final yesterday = startOfToday().subtract(const Duration(hours: 12));
      Future<void> ledger(String type, int delta, int minutes) =>
          db.into(db.crateLedger).insert(
                CrateLedgerCompanion.insert(
                  businessId: businessId,
                  manufacturerId: const Value(brand),
                  storeId: const Value(storeA),
                  quantityDelta: delta,
                  movementType: type,
                  performedBy: const Value(managerId),
                  createdAt: Value(yesterday.add(Duration(minutes: minutes))),
                ),
              );
      await ledger(kCrateMovementOpeningCount, 30, 0);
      await ledger(kCrateMovementCount, -10, 1);
      await db.into(db.crateShortfallWriteoffs).insert(
            CrateShortfallWriteoffsCompanion.insert(
              businessId: businessId,
              manufacturerId: brand,
              storeId: const Value(storeA),
              crateCount: 10,
              ratePerCrateKobo: const Value(rate),
              source: const Value(kCrateWriteOffSourceCountShortage),
              performedBy: const Value(managerId),
              createdAt: Value(yesterday.add(const Duration(minutes: 2))),
              lastUpdatedAt: Value(yesterday.add(const Duration(minutes: 2))),
            ),
          );
      return yesterday;
    }

    test('books a gain on its own day at the written-off value, capped at crates '
        'found, and changes no earlier day', () async {
      await writtenOffYesterday();
      final today = startOfToday();
      final tomorrow = today.add(const Duration(days: 1));
      final yesterday = today.subtract(const Duration(days: 1));
      expect(await bookedLoss(yesterday, today), 10 * rate);

      // Nothing has turned up yet: nothing to reverse.
      expect(
        await db.cratePoolDao.reverseCrateWriteOff(
          manufacturerId: brand,
          storeId: storeA,
          crateCount: 1,
          performedBy: managerId,
        ),
        isEmpty,
      );

      // Today a count finds 4 of them. The crate value has since gone up.
      await count(24);
      await setCrateValue(500000);
      expect(
        await db.cratePoolDao.reverseCrateWriteOff(
          manufacturerId: brand,
          storeId: storeA,
          crateCount: 5,
          performedBy: managerId,
        ),
        isEmpty,
        reason: 'only 4 were found',
      );
      final ids = await db.cratePoolDao.reverseCrateWriteOff(
        manufacturerId: brand,
        storeId: storeA,
        crateCount: 4,
        performedBy: managerId,
      );
      expect(ids, hasLength(1));

      final reversal = (await writeOffRows()).firstWhere((r) => r.crateCount < 0);
      expect(reversal.crateCount, -4);
      expect(reversal.ratePerCrateKobo, rate, reason: 'the written-off value');
      expect(reversal.source, kCrateWriteOffSourceCountShortage);

      expect(await bookedLoss(yesterday, today), 10 * rate,
          reason: 'yesterday is closed and reads exactly as it did');
      expect(await bookedLoss(today, tomorrow), -4 * rate,
          reason: 'the gain is booked today');
      expect(await openAt(storeA), 0, reason: 'a reversal never reopens it');

      // Nothing more can be reversed until another count finds crates.
      expect(
        await db.cratePoolDao.reverseCrateWriteOff(
          manufacturerId: brand,
          storeId: storeA,
          crateCount: 1,
          performedBy: managerId,
        ),
        isEmpty,
      );
    });
  });

  group('one shortage, not two', () {
    test('Daily Reconciliation shows the same shortage as the manufacturer '
        'screen, per store and in All Stores', () async {
      await count(30);
      await count(22);
      await count(10, storeId: storeB);
      await count(7, storeId: storeB);
      await db.cratePoolDao.writeOffCrateShortage(
        manufacturerId: brand,
        storeId: storeA,
        crateCount: 2,
        performedBy: managerId,
      );

      for (final storeId in [storeA, storeB, null]) {
        final position = await db.cratePoolDao
            .watchManufacturerCratePosition(brand, storeId: storeId)
            .first;
        final rollup =
            await db.cratePoolDao.watchCrateShortageRollup(storeId: storeId).first;
        final recon = reconDataFrom(
          ReconInputs(
            showCrates: true,
            manufacturers: [await manufacturer()],
            crateShortages: rollup,
          ),
        );
        expect(
          recon.crateShortages.openCrates,
          position.short.count,
          reason: 'store $storeId',
        );
        expect(
          recon.crateShortages.openValueKobo,
          position.short.moneyKobo,
          reason: 'store $storeId',
        );
      }
      expect(
        (await db.cratePoolDao.watchManufacturerCratePosition(brand).first)
            .short
            .count,
        6 + 3,
      );
    });

    test('a non-crate business shows no shortage and books no write-off',
        () async {
      await count(30);
      await count(20);
      await db.cratePoolDao.writeOffCrateShortage(
        manufacturerId: brand,
        storeId: storeA,
        crateCount: 10,
        performedBy: managerId,
      );
      final d = reconDataFrom(
        ReconInputs(
          showCrates: false,
          manufacturers: [await manufacturer()],
          crateShortages: await db.cratePoolDao.watchCrateShortageRollup().first,
          crateShortfallWriteOffs: await writeOffRows(),
        ),
      );
      expect(d.crateShortfallWrittenOffKobo, 0);
      expect(d.crateShortages.hasShortage, isFalse);
    });

    test('old `manual` and `customer_forfeit` write-offs never net against the '
        'new shortage', () async {
      await count(30);
      await count(20); // 10 missing
      final now = DateTime.now();
      for (final source in [
        kCrateWriteOffSourceManual,
        kCrateWriteOffSourceCustomerForfeit,
      ]) {
        await db.into(db.crateShortfallWriteoffs).insert(
              CrateShortfallWriteoffsCompanion.insert(
                businessId: businessId,
                manufacturerId: brand,
                storeId: const Value(storeA),
                crateCount: 4,
                ratePerCrateKobo: const Value(rate),
                source: Value(source),
                performedBy: const Value(managerId),
                createdAt: Value(now),
                lastUpdatedAt: Value(now),
              ),
            );
      }
      expect(await openAt(storeA), 10);
      expect(
        (await db.cratePoolDao.watchCrateShortageRollup().first)
            .brand(brand)!
            .lastWrittenOffAt,
        isNull,
        reason: 'the card names only count-shortage write-offs',
      );
      // Nor can a count-shortage write-off be stretched past the counted gap
      // by those older rows.
      expect(
        await db.cratePoolDao.writeOffCrateShortage(
          manufacturerId: brand,
          storeId: storeA,
          crateCount: 10,
          performedBy: managerId,
        ),
        isNotNull,
      );
      expect(await openAt(storeA), 0);
    });
  });
}
