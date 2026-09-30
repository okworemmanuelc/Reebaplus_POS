// crate_shortfall_writeoff_test.dart
//
// #216 / PRD #203, ADR 0023 rule 5 — the booked crate loss. A write-off is the
// deliberate, dated decision that crates are not coming back. It reaches
// profit on the day it was taken, at the rate snapshotted then, and nothing
// anywhere takes it automatically.
//
// PRD #284 (#296) retired the depot-gap Crate Shortfall these rows used to
// answer: the warning is now the count-based Crate Shortage
// (crate_shortage_write_off_test.dart). The `manual` rows already booked stay
// in their periods, which is what the groups below still pin.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/crates/crate_money_arrangement.dart';
import 'package:reebaplus_pos/core/crates/crate_shortfall.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/shared/services/supplier_crate_service.dart';

void main() {
  const businessId = 'biz-1';
  const managerId = 'user-manager';
  const storeId = 'store-1';
  const supplierA = 'sup-a';
  const supplierB = 'sup-b';
  // ₦3,500 a crate.
  const rate = 350000;
  const moneyBrand = 'mfr-money';
  const floatBrand = 'mfr-float';
  const swapBrand = 'mfr-swap';

  // ══════════════════════════════════════════════════════════════════════════
  // 3. THE LOSS — typed so it hits profit, on the day it was taken.
  // ══════════════════════════════════════════════════════════════════════════

  group('the write-off books the loss on the day it was taken', () {
    final july = DateTime.utc(2026, 7, 15);
    final august = DateTime.utc(2026, 8, 3);
    const arrangements = {moneyBrand: CrateMoneyArrangement.perDelivery};

    test('it lands in the period the DECISION was taken, not the discovery',
        () {
      // A shortfall that opened in March and was accepted in July reduces
      // JULY's profit. That is the whole reason the decision is persisted.
      final writeOffs = [
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: 10,
          ratePerCrateKobo: rate,
          writtenOffAt: july,
        ),
      ];

      // July's report sees it.
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 7, 1),
          endExclusive: DateTime.utc(2026, 8, 1),
        ),
        10 * rate,
      );
      // June's does not.
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 6, 1),
          endExclusive: DateTime.utc(2026, 7, 1),
        ),
        0,
      );
      // And neither does August's — the loss does not follow the shortfall
      // forward into every later period.
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 8, 1),
          endExclusive: DateTime.utc(2026, 9, 1),
        ),
        0,
      );
    });

    test('the window is half-open: the end instant belongs to the next period',
        () {
      final boundary = DateTime.utc(2026, 8, 1);
      final w = [
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: 1,
          ratePerCrateKobo: rate,
          writtenOffAt: boundary,
        ),
      ];
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: w,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 7, 1),
          endExclusive: boundary,
        ),
        0,
      );
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: w,
          arrangementByManufacturerId: arrangements,
          start: boundary,
          endExclusive: DateTime.utc(2026, 9, 1),
        ),
        rate,
      );
    });

    test('each decision keeps ITS OWN snapshotted rate — no restatement', () {
      // July's loss was 10 crates at ₦3,500. August's rate is ₦5,000. July's
      // figure must not move: a rate edited later cannot rewrite a closed day.
      const augustRate = 500000;
      final writeOffs = [
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: 10,
          ratePerCrateKobo: rate,
          writtenOffAt: july,
        ),
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: 4,
          ratePerCrateKobo: augustRate,
          writtenOffAt: august,
        ),
      ];
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 7, 1),
          endExclusive: DateTime.utc(2026, 8, 1),
        ),
        10 * rate,
      );
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 8, 1),
          endExclusive: DateTime.utc(2026, 9, 1),
        ),
        4 * augustRate,
      );
    });

    test('a compensating NEGATIVE row books a gain on ITS day, not a rewrite',
        () {
      // Crates written off in July turn up in August. The ledger is
      // append-only, so July stays as it was and August carries the reversal.
      final writeOffs = [
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: 10,
          ratePerCrateKobo: rate,
          writtenOffAt: july,
        ),
        CrateShortfallWriteOff(
          manufacturerId: moneyBrand,
          crateCount: -10,
          ratePerCrateKobo: rate,
          writtenOffAt: august,
        ),
      ];
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 7, 1),
          endExclusive: DateTime.utc(2026, 8, 1),
        ),
        10 * rate,
        reason: 'July is a closed day and must read exactly as it did',
      );
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: arrangements,
          start: DateTime.utc(2026, 8, 1),
          endExclusive: DateTime.utc(2026, 9, 1),
        ),
        -10 * rate,
        reason: 'the reversal is a gain in the month it was decided',
      );
    });

    test('a `none` brand books nothing, and an unknown brand fails closed', () {
      final writeOffs = [
        CrateShortfallWriteOff(
          manufacturerId: swapBrand,
          crateCount: 10,
          ratePerCrateKobo: rate,
          writtenOffAt: july,
        ),
        CrateShortfallWriteOff(
          manufacturerId: 'mfr-vanished',
          crateCount: 10,
          ratePerCrateKobo: rate,
          writtenOffAt: july,
        ),
      ];
      expect(
        crateShortfallWriteOffKobo(
          writeOffs: writeOffs,
          arrangementByManufacturerId: const {
            swapBrand: CrateMoneyArrangement.none,
          },
        ),
        0,
        reason:
            'a swap-only brand has no shortfall to accept, and a brand missing '
            'from the map reads `none` rather than booking a loss',
      );
    });

    test('it reaches netProfit and periodNetResult, and NOTHING else', () {
      // The typing question, asserted rather than promised. A Placed Deposit is
      // an asset and can never cut profit; this is the one thing in PRD #203
      // that can, so it must land in exactly those two lines and no other.
      ReconData dataWith(int writtenOffKobo) => reconDataFrom(
        ReconInputs(
          showCrates: true,
          manufacturers: [
            ManufacturerData(
              id: moneyBrand,
              businessId: businessId,
              name: 'Star Lager',
              emptyCrateStock: 0,
              depositAmountKobo: rate,
              crateMoneyArrangement: kCrateMoneyArrangementPerDelivery,
              isDeleted: false,
              createdAt: july,
              lastUpdatedAt: july,
            ),
          ],
          crateShortfallWriteOffs: writtenOffKobo == 0
              ? const []
              : [
                  CrateShortfallWriteoffData(
                    id: 'wo-1',
                    businessId: businessId,
                    manufacturerId: moneyBrand,
                    storeId: storeId,
                    crateCount: writtenOffKobo ~/ rate,
                    source: kCrateWriteOffSourceManual,
                    ratePerCrateKobo: rate,
                    note: null,
                    performedBy: managerId,
                    createdAt: july,
                    lastUpdatedAt: july,
                  ),
                ],
          start: DateTime.utc(2026, 7, 1),
          endExclusive: DateTime.utc(2026, 8, 1),
        ),
      );

      final none = dataWith(0);
      final booked = dataWith(10 * rate);

      expect(booked.crateShortfallWrittenOffKobo, 10 * rate);
      expect(
        booked.netProfitKobo,
        none.netProfitKobo - 10 * rate,
        reason: 'an accepted crate loss is a realized loss',
      );
      expect(
        booked.periodNetResultKobo,
        none.periodNetResultKobo - 10 * rate,
      );

      // It is NOT cash: nobody handed anything over when the owner accepted the
      // loss, so no cash line may move.
      expect(booked.cashInKobo, none.cashInKobo);
      expect(booked.cashOutKobo, none.cashOutKobo);
      expect(booked.netCashMovementKobo, none.netCashMovementKobo);
      expect(
        booked.cashCrateDepositsPlacedKobo,
        none.cashCrateDepositsPlacedKobo,
      );
      // It is NOT an expense and NOT a refund — the #190/#201 family defect.
      expect(booked.expensesKobo, none.expensesKobo);
      expect(booked.refundsKobo, none.refundsKobo);
      // And it does not touch point-in-time worth: the crate left the yard when
      // it went missing, and worth already fell then. This books the P&L half.
      expect(
        booked.businessNetPositionKobo,
        none.businessNetPositionKobo,
      );
    });

    test('a non-crate business books nothing even with rows present', () {
      final d = reconDataFrom(
        ReconInputs(
          showCrates: false,
          manufacturers: [
            ManufacturerData(
              id: moneyBrand,
              businessId: businessId,
              name: 'Star Lager',
              emptyCrateStock: 0,
              depositAmountKobo: rate,
              crateMoneyArrangement: kCrateMoneyArrangementPerDelivery,
              isDeleted: false,
              createdAt: july,
              lastUpdatedAt: july,
            ),
          ],
          crateShortfallWriteOffs: [
            CrateShortfallWriteoffData(
              id: 'wo-1',
              businessId: businessId,
              manufacturerId: moneyBrand,
              storeId: storeId,
              crateCount: 10,
              source: kCrateWriteOffSourceManual,
              ratePerCrateKobo: rate,
              note: null,
              performedBy: managerId,
              createdAt: july,
              lastUpdatedAt: july,
            ),
          ],
        ),
      );
      expect(d.crateShortfallWrittenOffKobo, 0);
      expect(d.netProfitKobo, 0);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 6. THE WRITE PATH — through CratePoolDao, against a real database.
  // ══════════════════════════════════════════════════════════════════════════

  group('the write path', () {
    late AppDatabase db;

    Future<void> seed() async {
      db.businessIdResolver = () => businessId;
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
          );
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: const Value(managerId),
              businessId: businessId,
              name: 'Manager',
              pin: '1234',
            ),
          );
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
        moneyBrand: ('Star Lager', kCrateMoneyArrangementPerDelivery),
        floatBrand: ('Gulder', kCrateMoneyArrangementStandingFloat),
        swapBrand: ('Trophy', kCrateMoneyArrangementNone),
      };
      for (final e in brands.entries) {
        await db
            .into(db.manufacturers)
            .insert(
              ManufacturersCompanion.insert(
                id: Value(e.key),
                businessId: businessId,
                name: e.value.$1,
                depositAmountKobo: const Value(rate),
                crateMoneyArrangement: Value(e.value.$2),
              ),
            );
      }
      for (final s in [supplierA, supplierB]) {
        await db
            .into(db.suppliers)
            .insert(
              SuppliersCompanion.insert(
                id: Value(s),
                businessId: businessId,
                name: 'Depot $s',
              ),
            );
      }
    }

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed();
    });

    tearDown(() => db.close());

    test('the ledger is append-only — a booked loss cannot be edited away',
        () async {
      final now = DateTime.now();
      await db
          .into(db.crateShortfallWriteoffs)
          .insert(
            CrateShortfallWriteoffsCompanion.insert(
              id: const Value('wo-1'),
              businessId: businessId,
              manufacturerId: moneyBrand,
              crateCount: 7,
              ratePerCrateKobo: const Value(rate),
              performedBy: const Value(managerId),
              createdAt: Value(now),
              lastUpdatedAt: Value(now),
            ),
          );
      await expectLater(
        (db.update(db.crateShortfallWriteoffs)
              ..where((t) => t.id.equals('wo-1')))
            .write(const CrateShortfallWriteoffsCompanion(
              crateCount: Value(1),
            )),
        throwsA(anything),
        reason: 'the immutable trigger freezes every column but last_updated_at',
      );
    });

    test('NOTHING writes off automatically — no timer, no sweep, no backfill',
        () async {
      // A brand found 20 crates short at a count, then left completely alone.
      await db.cratePoolDao.recordManualCountCorrection(
        manufacturerId: moneyBrand,
        storeId: storeId,
        performedBy: managerId,
        countedEmpties: 30,
      );
      await db.cratePoolDao.recordManualCountCorrection(
        manufacturerId: moneyBrand,
        storeId: storeId,
        performedBy: managerId,
        countedEmpties: 10,
      );
      // Time passes; the app opens, reads, re-reads.
      final first = await db.cratePoolDao.watchCrateShortageRollup().first;
      final second = await db.cratePoolDao.watchCrateShortageRollup().first;

      expect(first.openCrates, 20);
      expect(second.openCrates, 20, reason: 'reading it changes nothing');
      expect(
        await db.select(db.crateShortfallWriteoffs).get(),
        isEmpty,
        reason:
            'a shortage of any age is still only a warning until somebody '
            'deliberately accepts it',
      );
    });

    test('the structural half: nothing in lib/ writes off without being asked',
        () {
      // The write verbs' only callers are the shared sheets. If a later slice
      // adds a scheduler, a migration backfill or an "auto-accept after N days"
      // sweep, it lands here first.
      const allowedCallers = {
        'writeOffCrateShortage': {
          'lib/core/database/daos_crates.dart',
          'lib/shared/widgets/crate_shortage_write_off_sheet.dart',
        },
        'reverseCrateWriteOff': {
          'lib/core/database/daos_crates.dart',
          'lib/shared/widgets/reverse_crate_write_off_sheet.dart',
        },
      };
      for (final verb in allowedCallers.entries) {
        final found = <String>{};
        for (final entity in Directory('lib').listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          if (entity.path.endsWith('.g.dart')) continue;
          if (entity.readAsStringSync().contains(verb.key)) {
            found.add(entity.path.replaceAll(r'\', '/'));
          }
        }
        expect(
          found.difference(verb.value),
          isEmpty,
          reason:
              'a new caller of ${verb.key}. If it is a timer, a scheduled '
              'sweep or a migration backfill, it must not exist: ADR 0023 rule '
              '5 says profit is never reduced by a decision nobody made.',
        );
      }
    });

    test('the depot gap is no longer write-off-able anywhere (#296)', () {
      // Only the #217 forfeit netting still writes a non-count-shortage row.
      final dao = File('lib/core/database/daos_crates.dart').readAsStringSync();
      expect(dao, isNot(contains('CrateWriteOffSource.manual')));
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('.g.dart')) continue;
        expect(
          entity.readAsStringSync(),
          isNot(contains('writeOffCrateShortfall')),
          reason: '${entity.path} still calls the retired depot-gap verb',
        );
      }
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 8. THE EMPTIES-POOL GAP #213 LEFT — the regression that makes the figure
  //    honest.
  // ══════════════════════════════════════════════════════════════════════════

  group('a standalone settlement moves BOTH legs', () {
    late AppDatabase db;

    Future<void> seed() async {
      db.businessIdResolver = () => businessId;
      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
          );
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: const Value(managerId),
              businessId: businessId,
              name: 'Manager',
              pin: '1234',
            ),
          );
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
        moneyBrand: ('Star Lager', kCrateMoneyArrangementPerDelivery),
        swapBrand: ('Trophy', kCrateMoneyArrangementNone),
      };
      for (final e in brands.entries) {
        await db
            .into(db.manufacturers)
            .insert(
              ManufacturersCompanion.insert(
                id: Value(e.key),
                businessId: businessId,
                name: e.value.$1,
                depositAmountKobo: const Value(rate),
                crateMoneyArrangement: Value(e.value.$2),
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

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed();
    });

    tearDown(() => db.close());

    test('it drops the yard as well as the debt, so a real shortfall survives',
        () async {
      // THE BUG #213 FLAGGED AND DID NOT FIX. 100 crates received, 90 empties
      // back in the yard: the brand is genuinely 10 short.
      await db.cratePoolDao.recordReceiveFromSupplier(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        quantity: 100,
        performedBy: managerId,
        storeId: storeId,
      );
      await db.cratePoolDao.addEmptiesToPool(moneyBrand, 90, storeId: storeId);

      // Now a settlement run carries 40 empties to the depot. Before the fix
      // this dropped `cratesOwed` to 60 while the yard still claimed 90, so the
      // shortfall read max(0, 60 − 90) = 0 — a real loss silently erased and
      // profit overstated by ₦35,000.
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 40,
        performedBy: managerId,
      );

      final pool = await db.cratePoolDao
          .watchEmptiesPoolByManufacturer()
          .first;
      expect(pool[moneyBrand], 50, reason: 'the empties left the yard');

      final debt = await db.cratePoolDao.watchSupplierCrateDebt(supplierA).first;
      expect(
        debt.single.balance - pool[moneyBrand]!,
        10,
        reason:
            'settling is not finding: handing back 40 of the 90 you hold '
            'leaves the gap between debt and yard exactly where it was',
      );
    });

    test('a settlement with no crates on the truck moves no empties', () async {
      // A pure money settlement — a closing account, a refund owed from a
      // previous trip. There are no crates on it, so the yard must not move.
      await db.cratePoolDao.addEmptiesToPool(moneyBrand, 30, storeId: storeId);
      await db.cratePoolDao.recordCrateSettlement(
        supplierId: supplierA,
        manufacturerId: moneyBrand,
        storeId: storeId,
        crateCount: 0,
        performedBy: managerId,
        refundAmountKobo: 500000,
      );
      final pool = await db.cratePoolDao
          .watchEmptiesPoolByManufacturer()
          .first;
      expect(pool[moneyBrand], 30);
    });

    test('a `none` brand is untouched: it never reaches the settlement verb',
        () async {
      // #213 left the gap because it did not want to change what the button
      // does for `none` brands. It does not: the settlement sheet routes to
      // `recordSettlement` only on the `per_delivery` branch, and a swap-only
      // brand takes the untouched pre-#203 `recordReturn` path, which still
      // moves the supplier ledger alone.
      final service = SupplierCrateService(db);
      await db.cratePoolDao.addEmptiesToPool(swapBrand, 30, storeId: storeId);
      await service.recordReturn(
        supplierId: supplierA,
        supplierName: 'Ade Depot',
        manufacturerId: swapBrand,
        manufacturerName: 'Trophy',
        quantity: 10,
        staffId: managerId,
        storeId: storeId,
      );

      final pool = await db.cratePoolDao
          .watchEmptiesPoolByManufacturer()
          .first;
      expect(
        pool[swapBrand],
        30,
        reason:
            'the pre-#203 manual return has never moved the yard, and #216 did '
            'not change that',
      );
      // The supplier debt still fell, exactly as it always did.
      final debt = await db.cratePoolDao.watchSupplierCrateDebt(supplierA).first;
      expect(debt.single.balance, -10);
      // And no money was involved anywhere.
      expect(await db.select(db.supplierCrateDeposits).get(), isEmpty);
      expect(await db.select(db.paymentTransactions).get(), isEmpty);
    });
  });
}
