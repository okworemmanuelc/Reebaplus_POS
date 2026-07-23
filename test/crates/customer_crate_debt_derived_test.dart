import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

/// #158 — customer crate debt DERIVED from the append-only ledger.
///
/// A customer's crate debt per manufacturer is `SUM(quantity_delta)` over their
/// `crate_ledger` rows — never a stored `customer_crate_balances` total — exactly
/// the way the wallet balance derives from `wallet_transactions`. This suite pins
/// the three properties the derive-from-ledger model buys:
///   1. the Crates-tab read (`watchCustomerCrateDebt` / `watchCrateBalancesWithGroups`)
///      equals the ledger sum and re-emits live on a new movement;
///   2. `customer_crate_balances` is no longer pushed — only append-only ledger
///      rows sync for customer crates;
///   3. multi-device convergence — two independently-built ledgers (as two offline
///      tills) merge and the derived balance equals the combined sum, with no
///      movement lost (the exact scenario the old absolute-value push clobbered).
void main() {
  const businessId = 'biz-1';
  const userId = 'user-1';
  const customerId = 'cust-1';
  const manufacturerA = 'mfr-a';
  const manufacturerB = 'mfr-b';

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
    await db.into(db.customers).insert(
          CustomersCompanion.insert(
            id: const Value(customerId),
            businessId: businessId,
            name: 'Carla',
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

  group('derived read (in-memory)', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(db);
    });

    tearDown(() => db.close());

    Future<Map<String, int>> derived() async {
      final rows = await db.cratePoolDao.watchCustomerCrateDebt(customerId).first;
      return {for (final r in rows) r.manufacturerId: r.balance};
    }

    test('debt per manufacturer == SUM over the customer ledger', () async {
      // Issue 5 of A, return 2 of A → net owes 3. Return 4 of B (credit).
      await db.cratePoolDao.recordCrateIssueByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerA,
        quantity: 5,
        performedBy: userId,
      );
      await db.cratePoolDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerA,
        quantity: 2,
        performedBy: userId,
      );
      await db.cratePoolDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerB,
        quantity: 4,
        performedBy: userId,
      );

      expect(await derived(), {manufacturerA: 3, manufacturerB: -4});
    });

    test('a fully-returned brand nets to 0 (Clear), not a phantom debt',
        () async {
      await db.cratePoolDao.recordCrateIssueByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerA,
        quantity: 6,
        performedBy: userId,
      );
      await db.cratePoolDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerA,
        quantity: 6,
        performedBy: userId,
      );

      expect(await derived(), {manufacturerA: 0});
    });

    test('watchCrateBalancesWithGroups (the Crates-tab read) derives + re-emits '
        'live', () async {
      final emissions = <Map<String, int>>[];
      final sub = db.customersDao
          .watchCrateBalancesWithGroups(customerId)
          .map((rows) => {for (final e in rows) e.manufacturerId: e.balance})
          .listen(emissions.add);

      await pumpEventQueue();
      expect(emissions.last, isEmpty, reason: 'no crate activity yet');

      await db.cratePoolDao.recordCrateIssueByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerA,
        quantity: 7,
        performedBy: userId,
      );
      await pumpEventQueue();

      expect(emissions.last, {manufacturerA: 7},
          reason: 'the ledger-derived read re-emits live on a new movement');
      await sub.cancel();
    });
  });

  group('no absolute-value push (AC: only ledger rows sync)', () {
    late AppDatabase db;

    setUp(() async {
      // No `feature.domain_rpcs_v2.record_crate_return` row → flag defaults off,
      // exercising the per-table (non-envelope) enqueue path.
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(db);
    });

    tearDown(() => db.close());

    Future<List<String>> queuedActionTypes() async {
      final rows = await db.select(db.syncQueue).get();
      return rows.map((r) => r.actionType).toList()..sort();
    }

    test('issuing crates enqueues only the ledger row, never the cache',
        () async {
      await db.cratePoolDao.recordCrateIssueByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerA,
        quantity: 5,
        performedBy: userId,
      );

      final types = await queuedActionTypes();
      expect(types, contains('crate_ledger:upsert'));
      expect(types, isNot(contains('customer_crate_balances:upsert')),
          reason: 'the absolute cache value must never cross the wire');
    });

    test('a customer return (flag off) enqueues only the ledger row', () async {
      await db.cratePoolDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerA,
        quantity: 3,
        performedBy: userId,
      );

      final types = await queuedActionTypes();
      expect(types, ['crate_ledger:upsert']);
    });
  });

  group('multi-device convergence (the drift the model removes)', () {
    test('two offline tills merge; derived balance == combined ledger sum',
        () async {
      // Two devices build INDEPENDENT ledgers offline for the SAME customer +
      // manufacturer. Till 1 issues 5 at sale; Till 2 takes a return of 2. Under
      // the old absolute-cache push these two would clobber each other (last
      // writer wins → one movement lost). Under ledger-as-truth both rows survive
      // the merge and the derived balance is their sum (5 - 2 = 3).
      final till1 = AppDatabase.forTesting(NativeDatabase.memory());
      final till2 = AppDatabase.forTesting(NativeDatabase.memory());
      await seed(till1);
      await seed(till2);

      await till1.cratePoolDao.recordCrateIssueByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerA,
        quantity: 5,
        performedBy: userId,
      );
      await till2.cratePoolDao.recordCrateReturnByCustomer(
        customerId: customerId,
        manufacturerId: manufacturerA,
        quantity: 2,
        performedBy: userId,
      );

      // Simulate the cloud converging both append-only ledgers onto one device:
      // copy every crate_ledger row from each till into a merged database. Rows
      // are id-keyed (UUIDv7) so an insert-or-ignore merge keeps both.
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

      final rows =
          await merged.cratePoolDao.watchCustomerCrateDebt(customerId).first;
      expect(rows, hasLength(1));
      expect(rows.single.balance, 3,
          reason: 'both movements survive the merge — nothing clobbered');

      // Both ledger rows are physically present on the merged device.
      final ledger = await merged.select(merged.crateLedger).get();
      expect(ledger, hasLength(2));

      await till1.close();
      await till2.close();
      await merged.close();
    });
  });
}
