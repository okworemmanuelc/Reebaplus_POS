// migration_upgrade_test.dart
//
// REAL onUpgrade tests. Unlike the existing v14/v15/v16 migration tests — which
// assert a fresh `onCreate` target shape and *mirror* the migration's SQL into a
// throwaway table — these drive the actual `MigrationStrategy.onUpgrade` chain on
// a populated database and assert the result. A bug in the real migration block
// fails the test (a mirror can't catch that).
//
// Fixture pattern: "revert-then-re-upgrade". We open a fresh current-schema DB
// (onCreate at the live schemaVersion), surgically revert ONLY the deltas of the
// versions under test so the file looks like the older version — every OTHER
// table stays intact, so the second open's `beforeOpen` / schema audit don't choke
// on missing tables — stamp `PRAGMA user_version` back, close, then re-open. The
// re-open sees `user_version < schemaVersion` and runs `onUpgrade`, which we assert.
//
// A file-backed DB (not `NativeDatabase.memory()`) is required: the schema and
// user_version must survive across the two separate opens.

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late Directory tmpDir;
  late File dbFile;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('reeba_mig_test');
    dbFile = File('${tmpDir.path}/app.db');
  });

  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  // Opens AppDatabase on the temp file and forces the open (which runs
  // onCreate on a fresh file, or onUpgrade when user_version < schemaVersion).
  Future<AppDatabase> openAndInit() async {
    final db = AppDatabase.forTesting(NativeDatabase(dbFile));
    await db.customSelect('SELECT 1').get();
    return db;
  }

  Future<Set<String>> columnsOf(AppDatabase db, String table) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  Future<bool> tableExists(AppDatabase db, String table) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          variables: [Variable<String>(table)],
        )
        .get();
    return rows.isNotEmpty;
  }

  // Reverts the v20 (Funds Register) delta: drop the three funds tables (their
  // indexes + triggers drop with them). Shared by the scenarios below.
  Future<void> dropFundsTables(AppDatabase db) async {
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await db.customStatement('DROP TABLE IF EXISTS fund_transactions');
    await db.customStatement('DROP TABLE IF EXISTS fund_days');
    await db.customStatement('DROP TABLE IF EXISTS funds_accounts');
    await db.customStatement('PRAGMA foreign_keys = ON');
  }

  group('onUpgrade v19 → v21 (Funds Register tables + account_number)', () {
    test('upgrade succeeds and funds_accounts ends with account_number', () async {
      // Build a fresh v21 DB, then revert to the v19 shape: funds tables did not
      // exist at v19 (they arrive in v20). products is unchanged between v19 and
      // v21, so nothing else to revert.
      final db1 = await openAndInit();
      await dropFundsTables(db1);
      await db1.customStatement('PRAGMA user_version = 19');
      await db1.close();

      // Re-open → onUpgrade(19 → 21). Block 20 recreates the funds tables from
      // the CURRENT schema (which already has account_number); block 21 must NOT
      // blindly re-add account_number or this open throws "duplicate column".
      final db2 = await openAndInit();
      addTearDown(db2.close);

      expect(await tableExists(db2, 'funds_accounts'), isTrue);
      expect(await tableExists(db2, 'fund_days'), isTrue);
      expect(await tableExists(db2, 'fund_transactions'), isTrue);

      final cols = await columnsOf(db2, 'funds_accounts');
      expect(cols.contains('account_number'), isTrue,
          reason: 'v21 must leave funds_accounts.account_number present');
    });
  });

  group('onUpgrade v17 → v21 (product price salvage-map, decision Q4 revised)', () {
    test('carries retail→retailer and coalesce(distributor,retail)→wholesaler',
        () async {
      final businessId = UuidV7.generate();
      final productA = UuidV7.generate(); // has a distributor price
      final productB = UuidV7.generate(); // no distributor price → coalesce

      final db1 = await openAndInit();

      await db1.into(db1.businesses).insert(
            BusinessesCompanion.insert(
              id: Value(businessId),
              name: 'Test Business',
            ),
          );
      for (final (id, name) in [(productA, 'Beer'), (productB, 'Soda')]) {
        await db1.into(db1.products).insert(
              ProductsCompanion.insert(
                id: Value(id),
                businessId: businessId,
                name: name,
              ),
            );
      }

      // Revert products to the v17 shape: add the four legacy price columns,
      // populate them, then drop the v18 (retailer/wholesaler/barcode) and v19
      // (expiry_date) columns. Then revert the v20 funds tables.
      for (final col in const [
        'retail_price_kobo',
        'bulk_breaker_price_kobo',
        'distributor_price_kobo',
        'selling_price_kobo',
      ]) {
        await db1.customStatement('ALTER TABLE products ADD COLUMN $col INTEGER');
      }
      await db1.customStatement(
        'UPDATE products SET retail_price_kobo = 1000, distributor_price_kobo = 800 '
        "WHERE id = ?",
        [productA],
      );
      await db1.customStatement(
        'UPDATE products SET retail_price_kobo = 500, distributor_price_kobo = NULL '
        "WHERE id = ?",
        [productB],
      );
      for (final col in const [
        'retailer_price_kobo',
        'wholesaler_price_kobo',
        'barcode',
        'expiry_date',
      ]) {
        await db1.customStatement('ALTER TABLE products DROP COLUMN $col');
      }

      // A pending products:upsert in the sync queue carrying the legacy keys —
      // the v18 block must rewrite it to retailer/wholesaler.
      await db1.customStatement(
        "INSERT INTO sync_queue (id, business_id, action_type, payload, status, created_at) "
        "VALUES (?, ?, 'products:upsert', ?, 'pending', 0)",
        [
          UuidV7.generate(),
          businessId,
          '{"id":"$productA","retail_price_kobo":1000,"distributor_price_kobo":800}',
        ],
      );

      await dropFundsTables(db1);
      await db1.customStatement('PRAGMA user_version = 17');
      await db1.close();

      // Re-open → onUpgrade(17 → 21).
      final db2 = await openAndInit();
      addTearDown(db2.close);

      final rows = await db2
          .customSelect(
            'SELECT id, retailer_price_kobo, wholesaler_price_kobo '
            'FROM products ORDER BY id',
          )
          .get();
      final byId = {
        for (final r in rows)
          r.read<String>('id'): (
            retailer: r.read<int>('retailer_price_kobo'),
            wholesaler: r.read<int>('wholesaler_price_kobo'),
          ),
      };

      expect(byId[productA]!.retailer, 1000);
      expect(byId[productA]!.wholesaler, 800, reason: 'uses distributor price');
      expect(byId[productB]!.retailer, 500);
      expect(byId[productB]!.wholesaler, 500,
          reason: 'distributor is null → coalesce to retail');

      // Legacy columns gone, barcode added.
      final cols = await columnsOf(db2, 'products');
      expect(cols.contains('retail_price_kobo'), isFalse);
      expect(cols.contains('distributor_price_kobo'), isFalse);
      expect(cols.contains('bulk_breaker_price_kobo'), isFalse);
      expect(cols.contains('selling_price_kobo'), isFalse);
      expect(cols.contains('barcode'), isTrue);

      // The pending sync_queue payload was rewritten to the new keys.
      final q = await db2
          .customSelect(
            "SELECT payload FROM sync_queue WHERE action_type = 'products:upsert'",
          )
          .getSingle();
      final payload = q.read<String>('payload');
      expect(payload.contains('retailer_price_kobo'), isTrue);
      expect(payload.contains('wholesaler_price_kobo'), isTrue);
      expect(payload.contains('retail_price_kobo'), isFalse,
          reason: 'legacy key removed from the queued payload');
      expect(payload.contains('distributor_price_kobo'), isFalse);
    });
  });
}
