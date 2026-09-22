// clear_business_data_test.dart
//
// #285 part B. A phone can hold an older business's rows alongside the one it
// is signing in to, and `clearAllData` is the wrong hammer — it would take the
// current business's unsent sales with it and force a full re-download.
// `clearBusinessData(X)` must remove X and ONLY X.
//
// The coverage assertion is deliberately schema-driven: it sweeps every table
// in `sqlite_master` that carries a `business_id` column, so a synced table
// added later and forgotten by the routine fails this test instead of quietly
// leaking a dead tenant's rows onto the next sign-in.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String bizA;
  late String bizB;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    bizA = UuidV7.generate();
    bizB = UuidV7.generate();
    await _seedBusiness(db, bizA, 'Old Biz');
    await _seedBusiness(db, bizB, 'Current Biz');
  });

  tearDown(() => db.close());

  test(
    'removes every business_id-scoped row for the cleared business, in every '
    'table the schema says carries one',
    () async {
      await db.clearBusinessData(bizA);

      final scopedTables = await _tablesWithBusinessId(db);
      expect(
        scopedTables,
        isNotEmpty,
        reason: 'the sweep is worthless if it found no scoped tables',
      );

      final leftovers = <String, int>{};
      for (final table in scopedTables) {
        final row = await db
            .customSelect(
              'SELECT COUNT(*) AS c FROM $table WHERE business_id = ?1',
              variables: [Variable.withString(bizA)],
            )
            .getSingle();
        final count = row.read<int>('c');
        if (count > 0) leftovers[table] = count;
      }

      expect(
        leftovers,
        isEmpty,
        reason:
            'clearBusinessData left rows behind. If a table was added since, '
            'it is covered automatically only while it carries business_id — '
            'check businessScopedTableNames.',
      );

      final businessRows = await db
          .customSelect(
            'SELECT COUNT(*) AS c FROM businesses WHERE id = ?1',
            variables: [Variable.withString(bizA)],
          )
          .getSingle();
      expect(businessRows.read<int>('c'), 0);
    },
  );

  test('leaves the other business — rows, business row and outbox — intact',
      () async {
    await db.clearBusinessData(bizA);

    final stores = await (db.select(
      db.stores,
    )..where((s) => s.businessId.equals(bizB))).get();
    expect(stores, hasLength(1));

    final users = await (db.select(
      db.users,
    )..where((u) => u.businessId.equals(bizB))).get();
    expect(users, hasLength(1));

    expect(await db.syncDao.countPending(businessId: bizB), 1);
    expect(await db.syncDao.countOrphans(businessId: bizB), 1);

    final businesses = await db.select(db.businesses).get();
    expect(businesses.map((b) => b.id), [bizB]);
  });

  test('clears both outbox tables for the cleared business only', () async {
    await db.clearBusinessData(bizA);

    expect(await db.syncDao.countPending(businessId: bizA), 0);
    expect(await db.syncDao.countOrphans(businessId: bizA), 0);
  });

  test('clears only the cleared business\'s per-business prefs keys', () async {
    SharedPreferences.setMockInitialValues({
      'last_sync_timestamp::$bizA': '2026-09-01T00:00:00Z',
      'last_sync_timestamp::$bizB': '2026-09-02T00:00:00Z',
      'users_backfill_v1::$bizA': true,
      'users_backfill_v1::$bizB': true,
      'first_pull_done_v1_$bizA': true,
      'first_pull_done_v1_$bizB': true,
    });

    await db.clearBusinessData(bizA);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('last_sync_timestamp::$bizA'), isNull);
    expect(prefs.getBool('users_backfill_v1::$bizA'), isNull);
    expect(prefs.getBool('first_pull_done_v1_$bizA'), isNull);

    expect(
      prefs.getString('last_sync_timestamp::$bizB'),
      '2026-09-02T00:00:00Z',
      reason: 'the business being signed in to must keep its pull cursor — '
          'clearing it would force a needless full re-download',
    );
    expect(prefs.getBool('users_backfill_v1::$bizB'), isTrue);
    expect(prefs.getBool('first_pull_done_v1_$bizB'), isTrue);
  });

  test('survives the append-only ledger delete guards', () async {
    // `crate_ledger` carries a BEFORE DELETE trigger that RAISE(ABORT)s. If
    // clearBusinessData did not suspend the guards, this clear would throw and
    // nothing would be removed.
    final ledgerBefore = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM crate_ledger WHERE business_id = ?1',
          variables: [Variable.withString(bizA)],
        )
        .getSingle();
    expect(ledgerBefore.read<int>('c'), 1, reason: 'seed sanity check');

    await db.clearBusinessData(bizA);

    final ledgerAfter = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM crate_ledger WHERE business_id = ?1',
          variables: [Variable.withString(bizA)],
        )
        .getSingle();
    expect(ledgerAfter.read<int>('c'), 0);

    // And the guard is back: a later delete must still be refused.
    final guard = await db
        .customSelect(
          "SELECT COUNT(*) AS c FROM sqlite_master "
          "WHERE type = 'trigger' AND name = 'crate_ledger_no_delete'",
        )
        .getSingle();
    expect(
      guard.read<int>('c'),
      1,
      reason: 'the append-only guard must be recreated after the clear',
    );
  });
}

/// Every table `sqlite_master` says carries a `business_id` column — the same
/// discovery `clearBusinessData` does, read independently from SQLite so the
/// test cannot inherit a bug from the routine it is checking.
Future<List<String>> _tablesWithBusinessId(AppDatabase db) async {
  final tables = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  final scoped = <String>[];
  for (final t in tables) {
    final name = t.read<String>('name');
    final columns = await db.customSelect('PRAGMA table_info($name)').get();
    if (columns.any((c) => c.read<String>('name') == 'business_id')) {
      scoped.add(name);
    }
  }
  return scoped;
}

/// Seeds one business with a representative row in a parent table, a child
/// table, an append-only ledger, and both outbox tables.
Future<void> _seedBusiness(AppDatabase db, String businessId, String name) async {
  await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(businessId), name: name),
      );

  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: '$name Store',
        ),
      );

  final userId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(userId),
          businessId: businessId,
          name: 'Owner of $name',
          email: Value('owner-$businessId@example.com'),
          pin: '__HASHED__',
        ),
      );

  final customerId = UuidV7.generate();
  await db.into(db.customers).insert(
        CustomersCompanion.insert(
          id: Value(customerId),
          businessId: businessId,
          name: 'Customer of $name',
        ),
      );

  await db.into(db.crateLedger).insert(
        CrateLedgerCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: businessId,
          customerId: Value(customerId),
          quantityDelta: 3,
          movementType: 'issued',
        ),
      );

  await db.into(db.syncQueue).insert(
        SyncQueueCompanion.insert(
          id: Value(UuidV7.generate()),
          businessId: businessId,
          actionType: 'customers:upsert',
          payload: '{"id":"$customerId","business_id":"$businessId"}',
        ),
      );

  await db.into(db.syncQueueOrphans).insert(
        SyncQueueOrphansCompanion.insert(
          id: Value(UuidV7.generate()),
          originalId: UuidV7.generate(),
          actionType: 'customers:upsert',
          payload: '{"id":"$customerId","business_id":"$businessId"}',
          reason: 'test',
        ),
      );
}
