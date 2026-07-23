import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

/// #159 — the PHYSICAL empties pool (business-wide + per-store) DERIVED from the
/// append-only ledger.
///
/// The pool per manufacturer is `SUM(quantity_delta)` over the business's
/// store-stamped, customer-less `crate_ledger` rows
/// (`store_id IS NOT NULL AND customer_id IS NULL`) — never the demoted
/// `manufacturers.empty_crate_stock` scalar or the `store_crate_balances` cache.
/// This suite pins the properties the derive-from-ledger model buys:
///   1. the derived business pool equals the SUM of its store-stamped ledger,
///      and business total == Σ store totals holds after every operation;
///   2. returning empties to a supplier REDUCES the business total (the
///      regression for the counter-only-grows asymmetry);
///   3. a damaged-empty write reduces the correct store and cannot push another
///      store negative (no cross-store clamp drift);
///   4. neither `store_crate_balances` nor the `empty_crate_stock` scalar is
///      ever pushed — only append-only ledger rows sync for the pool;
///   5. multi-device convergence — two independently-built ledgers merge and the
///      derived pool equals the combined sum, with no movement lost.
void main() {
  const businessId = 'biz-1';
  const userId = 'user-1';
  const manufacturerA = 'mfr-a';
  const manufacturerB = 'mfr-b';
  const storeA = 'store-a';
  const storeB = 'store-b';

  Future<void> seed(AppDatabase db) async {
    db.businessIdResolver = () => businessId;
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: businessId,
            name: 'U',
            pin: '1234',
          ),
        );
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: const Value(storeA),
            businessId: businessId,
            name: 'Store A',
          ),
        );
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: const Value(storeB),
            businessId: businessId,
            name: 'Store B',
          ),
        );
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: const Value(manufacturerA),
            businessId: businessId,
            name: 'Manco A',
          ),
        );
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: const Value(manufacturerB),
            businessId: businessId,
            name: 'Manco B',
          ),
        );
  }

  group('derived pool (in-memory)', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(db);
    });

    tearDown(() => db.close());

    Future<Map<String, int>> business() =>
        db.cratePoolDao.watchEmptiesPoolByManufacturer().first;
    Future<Map<String, int>> store(String storeId) =>
        db.cratePoolDao.watchEmptiesPoolByManufacturer(storeId: storeId).first;

    /// The store-stamped, customer-less ledger SUM, computed independently of
    /// the DAO query — the "truth" the derived read must reproduce.
    Future<int> ledgerSumFor(String mfr, {String? storeId}) async {
      final rows = await db.select(db.crateLedger).get();
      return rows
          .where((r) =>
              r.manufacturerId == mfr &&
              r.customerId == null &&
              r.storeId != null &&
              (storeId == null || r.storeId == storeId))
          .fold<int>(0, (s, r) => s + r.quantityDelta);
    }

    /// After any operation the business total for a manufacturer must equal the
    /// sum of that manufacturer's per-store totals (the store-stamp invariant).
    Future<void> expectBusinessEqualsSumOfStores() async {
      final biz = await business();
      final a = await store(storeA);
      final b = await store(storeB);
      for (final mfr in {...biz.keys, ...a.keys, ...b.keys}) {
        expect(biz[mfr] ?? 0, (a[mfr] ?? 0) + (b[mfr] ?? 0),
            reason: 'business total for $mfr must equal Σ store totals');
      }
    }

    test('business + per-store pool == SUM over the store-stamped ledger',
        () async {
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 10, storeId: storeA);
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 3, storeId: storeB);
      await db.cratePoolDao.addEmptiesToPool(manufacturerB, 4, storeId: storeA);

      expect(await business(), {manufacturerA: 13, manufacturerB: 4});
      expect(await store(storeA), {manufacturerA: 10, manufacturerB: 4});
      expect(await store(storeB), {manufacturerA: 3});

      // The derived read reproduces the independent ledger sum.
      expect((await business())[manufacturerA], await ledgerSumFor(manufacturerA));
      expect((await store(storeA))[manufacturerA],
          await ledgerSumFor(manufacturerA, storeId: storeA));
      await expectBusinessEqualsSumOfStores();
    });

    test('returning empties to a supplier REDUCES the business total '
        '(counter-only-grows asymmetry gone)', () async {
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 20, storeId: storeA);
      expect((await business())[manufacturerA], 20);

      // Hand 8 empties back to the supplier on a delivery (the Receive Stock
      // path). Under the old model this bumped a DIFFERENT tally and left the
      // "empties on hand" scalar at 20 — the asymmetry. Derived from the ledger,
      // the store-stamped `returned` −8 row now pulls the pool down.
      await db.cratePoolDao.recordCrateReturnByManufacturer(
        manufacturerId: manufacturerA,
        quantity: 8,
        performedBy: userId,
        storeId: storeA,
      );

      expect((await business())[manufacturerA], 12,
          reason: 'the business pool went DOWN when crates left');
      expect((await store(storeA))[manufacturerA], 12);
      await expectBusinessEqualsSumOfStores();
    });

    test('a damaged-empty reduces the correct store and cannot push another '
        'store negative', () async {
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 10, storeId: storeA);
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 3, storeId: storeB);

      // Damage 4 stored empties at store A.
      await db.cratePoolDao.recordDamage(manufacturerA, 4, storeId: storeA);

      expect((await store(storeA))[manufacturerA], 6,
          reason: 'only store A drops by the damaged quantity');
      expect((await store(storeB))[manufacturerA], 3,
          reason: 'store B is untouched — no cross-store clamp drift');
      expect((await business())[manufacturerA], 9);
      await expectBusinessEqualsSumOfStores();
    });

    test('business total == Σ store totals after a mixed sequence', () async {
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 10, storeId: storeA);
      await expectBusinessEqualsSumOfStores();
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 5, storeId: storeB);
      await expectBusinessEqualsSumOfStores();
      await db.cratePoolDao.recordDamage(manufacturerA, 2, storeId: storeA);
      await expectBusinessEqualsSumOfStores();
      await db.cratePoolDao.recordCrateReturnByManufacturer(
        manufacturerId: manufacturerA,
        quantity: 3,
        performedBy: userId,
        storeId: storeB,
      );
      await expectBusinessEqualsSumOfStores();
      await db.cratePoolDao.recordManualCountCorrection(
        manufacturerA,
        20,
        storeId: storeA,
      );
      await expectBusinessEqualsSumOfStores();

      // storeA: +10 −2 +(20−8 set-delta) = 20 ; storeB: +5 −3 = 2 ; business 22.
      expect((await store(storeA))[manufacturerA], 20);
      expect((await store(storeB))[manufacturerA], 2);
      expect((await business())[manufacturerA], 22);
    });
  });

  group('no absolute-value push (AC: only ledger rows sync)', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(db);
    });

    tearDown(() => db.close());

    Future<List<String>> queuedActionTypes() async {
      final rows = await db.select(db.syncQueue).get();
      return rows.map((r) => r.actionType).toList()..sort();
    }

    test('a pool credit enqueues the ledger row, never store_crate_balances',
        () async {
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 7, storeId: storeA);

      final types = await queuedActionTypes();
      expect(types, contains('crate_ledger:upsert'));
      expect(types, isNot(contains('store_crate_balances:upsert')),
          reason: 'the per-store cache is a local-only projection (#159)');
    });

    test('a damage debit enqueues the ledger row, never store_crate_balances',
        () async {
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 7, storeId: storeA);
      await db.customStatement('DELETE FROM sync_queue');

      await db.cratePoolDao.recordDamage(manufacturerA, 2, storeId: storeA);

      final types = await queuedActionTypes();
      expect(types, contains('crate_ledger:upsert'));
      expect(types, isNot(contains('store_crate_balances:upsert')));
    });

    test('a pool return enqueues the ledger row, never '
        'manufacturer_crate_balances (#166 — last absolute cache demoted)',
        () async {
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 10, storeId: storeA);
      await db.customStatement('DELETE FROM sync_queue');

      // recordCrateReturnByManufacturer was the SOLE remaining site that pushed
      // an absolute "balance is now N" row (the business-wide per-manufacturer
      // cache). It is demoted to a local-only projection.
      await db.cratePoolDao.recordCrateReturnByManufacturer(
        manufacturerId: manufacturerA,
        quantity: 4,
        performedBy: userId,
        storeId: storeA,
      );

      final types = await queuedActionTypes();
      expect(types, contains('crate_ledger:upsert'));
      expect(types, isNot(contains('manufacturer_crate_balances:upsert')),
          reason: 'the business-wide cache is a local-only projection (#166) — '
              'after this slice NO crate balance is ever pushed');
    });

    test('the manufacturers push scrubs empty_crate_stock (demoted scalar)',
        () async {
      await db.cratePoolDao.addEmptiesToPool(manufacturerA, 7, storeId: storeA);

      final rows = await db.select(db.syncQueue).get();
      final mfrRow =
          rows.where((r) => r.actionType == 'manufacturers:upsert').toList();
      // The pool verb keeps the manufacturers row full locally (NOT NULL name),
      // but the push-column whitelist strips the demoted scalar off the wire.
      expect(mfrRow, isNotEmpty);
      final payload =
          SupabaseSyncService.scrubForTesting('manufacturers', {
        'id': manufacturerA,
        'business_id': businessId,
        'name': 'Manco A',
        'empty_crate_stock': 7,
        'deposit_amount_kobo': 0,
      });
      expect(payload.containsKey('empty_crate_stock'), isFalse,
          reason: 'the absolute empties scalar must never cross the wire');
    });
  });

  group('multi-device convergence (the drift the model removes)', () {
    test('two offline tills merge; derived pool == combined ledger sum',
        () async {
      // Two devices build INDEPENDENT physical-pool ledgers offline for the SAME
      // (store, manufacturer). Till 1 receives 5 empties; Till 2 returns 2 to the
      // supplier. Under the old absolute-cache push these clobbered each other
      // (last writer wins → one movement lost). Under ledger-as-truth both rows
      // survive the merge and the derived pool is their sum (5 − 2 = 3).
      final till1 = AppDatabase.forTesting(NativeDatabase.memory());
      final till2 = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(till1);
      await seed(till2);

      await till1.cratePoolDao.addEmptiesToPool(manufacturerA, 5, storeId: storeA);
      await till2.cratePoolDao.recordCrateReturnByManufacturer(
        manufacturerId: manufacturerA,
        quantity: 2,
        performedBy: userId,
        storeId: storeA,
      );

      // Converge both append-only ledgers onto one device (id-keyed UuidV7 →
      // insert-or-ignore keeps both rows).
      final merged = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(merged);
      for (final source in [till1, till2]) {
        final rows = await source.select(source.crateLedger).get();
        for (final r in rows) {
          await merged
              .into(merged.crateLedger)
              .insert(r.toCompanion(true), mode: InsertMode.insertOrIgnore);
        }
      }

      final biz =
          await merged.cratePoolDao.watchEmptiesPoolByManufacturer().first;
      expect(biz[manufacturerA], 3,
          reason: 'both movements survive the merge — nothing clobbered');
      final perStore = await merged.cratePoolDao
          .watchEmptiesPoolByManufacturer(storeId: storeA)
          .first;
      expect(perStore[manufacturerA], 3);

      await till1.close();
      await till2.close();
      await merged.close();
    });
  });
}
