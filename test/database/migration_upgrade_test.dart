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

import 'package:drift/drift.dart' hide isNull, isNotNull;
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


  // Reverts the v20 (Funds Register) delta: drop the three funds tables (their
  // indexes + triggers drop with them). Shared by the scenarios below.
  Future<void> dropFundsTables(AppDatabase db) async {
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await db.customStatement('DROP TABLE IF EXISTS fund_transactions');
    await db.customStatement('DROP TABLE IF EXISTS fund_days');
    await db.customStatement('DROP TABLE IF EXISTS funds_accounts');
    await db.customStatement('PRAGMA foreign_keys = ON');
  }

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

  group('onUpgrade v21 → v22 (customers.set_debt_limit permission)', () {
    test('re-seeds the permission row on a DB that lacks it', () async {
      Future<int> permCount(AppDatabase db) async {
        final r = await db
            .customSelect(
              "SELECT COUNT(*) c FROM permissions "
              "WHERE key = 'customers.set_debt_limit'",
            )
            .getSingle();
        return r.read<int>('c');
      }

      // Fresh DB already seeds the key in onCreate (it's in _defaultPermissionRows).
      // Delete it + revert to v21 so the re-open's v22 block has work to do.
      final db1 = await openAndInit();
      await db1.customStatement(
        "DELETE FROM permissions WHERE key = 'customers.set_debt_limit'",
      );
      expect(await permCount(db1), 0);
      await db1.customStatement('PRAGMA user_version = 21');
      await db1.close();

      // Re-open → onUpgrade(21 → 22) must re-insert the catalog row.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await permCount(db2), 1,
          reason: 'v22 block must seed customers.set_debt_limit');
    });
  });

  group('onUpgrade v37 → v38 (stores.manage permission)', () {
    test('re-seeds the permission row on a DB that lacks it', () async {
      Future<int> permCount(AppDatabase db) async {
        final r = await db
            .customSelect(
              "SELECT COUNT(*) c FROM permissions "
              "WHERE key = 'stores.manage'",
            )
            .getSingle();
        return r.read<int>('c');
      }

      // Fresh DB already seeds the key in onCreate (it's in _defaultPermissionRows).
      // Delete it + revert to v37 so the re-open's v38 block has work to do.
      final db1 = await openAndInit();
      await db1.customStatement(
        "DELETE FROM permissions WHERE key = 'stores.manage'",
      );
      expect(await permCount(db1), 0);
      await db1.customStatement('PRAGMA user_version = 37');
      await db1.close();

      // Re-open → onUpgrade(37 → 38) must re-insert the catalog row.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await permCount(db2), 1,
          reason: 'v38 block must seed stores.manage');
    });
  });

  group('onUpgrade v38 → v39 (staff.assign_stores permission)', () {
    test('re-seeds the permission row on a DB that lacks it', () async {
      Future<int> permCount(AppDatabase db) async {
        final r = await db
            .customSelect(
              "SELECT COUNT(*) c FROM permissions "
              "WHERE key = 'staff.assign_stores'",
            )
            .getSingle();
        return r.read<int>('c');
      }

      // Fresh DB already seeds the key in onCreate (it's in _defaultPermissionRows).
      // Delete it + revert to v38 so the re-open's v39 block has work to do.
      final db1 = await openAndInit();
      await db1.customStatement(
        "DELETE FROM permissions WHERE key = 'staff.assign_stores'",
      );
      expect(await permCount(db1), 0);
      await db1.customStatement('PRAGMA user_version = 38');
      await db1.close();

      // Re-open → onUpgrade(38 → 39) must re-insert the catalog row.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await permCount(db2), 1,
          reason: 'v39 block must seed staff.assign_stores');
    });
  });

  group('onUpgrade v39 → v40 (customers.wallet.withdraw permission)', () {
    test('re-seeds the permission row on a DB that lacks it', () async {
      Future<int> permCount(AppDatabase db) async {
        final r = await db
            .customSelect(
              "SELECT COUNT(*) c FROM permissions "
              "WHERE key = 'customers.wallet.withdraw'",
            )
            .getSingle();
        return r.read<int>('c');
      }

      // Fresh DB already seeds the key in onCreate (it's in _defaultPermissionRows).
      // Delete it + revert to v39 so the re-open's v40 block has work to do.
      final db1 = await openAndInit();
      await db1.customStatement(
        "DELETE FROM permissions WHERE key = 'customers.wallet.withdraw'",
      );
      expect(await permCount(db1), 0);
      await db1.customStatement('PRAGMA user_version = 39');
      await db1.close();

      // Re-open → onUpgrade(39 → 40) must re-insert the catalog row.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await permCount(db2), 1,
          reason: 'v40 block must seed customers.wallet.withdraw');
    });
  });

  group('onUpgrade v40 → v41 (store_role_permissions table, §10.2.1 Store)', () {
    Future<bool> tableExists(AppDatabase db, String name) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$name'",
          )
          .get();
      return r.isNotEmpty;
    }

    test('creates the table (with its index + bump trigger) on a DB that lacks it',
        () async {
      // Fresh DB already has the table (onCreate). Drop it + revert to v40 so
      // the re-open's v41 block has work to do.
      final db1 = await openAndInit();
      expect(await tableExists(db1, 'store_role_permissions'), isTrue);
      await db1.customStatement('PRAGMA foreign_keys = OFF');
      await db1
          .customStatement('DROP TABLE IF EXISTS store_role_permissions');
      await db1.customStatement('PRAGMA foreign_keys = ON');
      expect(await tableExists(db1, 'store_role_permissions'), isFalse);
      await db1.customStatement('PRAGMA user_version = 40');
      await db1.close();

      // Re-open → onUpgrade(40 → 41) must recreate the table.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await tableExists(db2, 'store_role_permissions'), isTrue,
          reason: 'v41 block must create store_role_permissions');
      expect(
        await columnsOf(db2, 'store_role_permissions'),
        containsAll(
            {'id', 'business_id', 'store_id', 'role_id', 'permission_key',
             'is_granted', 'created_at', 'last_updated_at'}),
      );
      // The sync index + bump trigger must exist too (so a fresh install and an
      // upgrade end up identical, per the new-synced-table contract).
      final idx = await db2
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='index' "
            "AND name='idx_store_role_permissions_business_lua'",
          )
          .get();
      expect(idx, isNotEmpty, reason: 'v41 must create the (business_id, '
          'last_updated_at) sync index');
      final trig = await db2
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='trigger' "
            "AND name='bump_store_role_permissions_last_updated_at'",
          )
          .get();
      expect(trig, isNotEmpty, reason: 'v41 must create the bump trigger');
    });
  });

  group('onUpgrade v24 → v25 (activity_logs generic shape + notif severity)', () {
    test(
        'backfills entity_type/entity_id, drops the FK columns, adds severity, '
        'and re-creates the append-only trigger', () async {
      final businessId = UuidV7.generate();
      final orderId = UuidV7.generate();
      final logWithEntity = UuidV7.generate();
      final logNoEntity = UuidV7.generate();
      final notifId = UuidV7.generate();

      final db1 = await openAndInit();
      await db1.into(db1.businesses).insert(
            BusinessesCompanion.insert(id: Value(businessId), name: 'Biz'),
          );

      // --- Revert activity_logs to the v24 shape ---
      // Drop the v25 append-only triggers first (they reference the new cols).
      await db1
          .customStatement('DROP TRIGGER IF EXISTS activity_logs_immutable');
      await db1
          .customStatement('DROP TRIGGER IF EXISTS activity_logs_no_delete');
      for (final c in const [
        'entity_type',
        'entity_id',
        'before_json',
        'after_json',
      ]) {
        await db1.customStatement('ALTER TABLE activity_logs DROP COLUMN $c');
      }
      for (final c in const [
        'order_id',
        'product_id',
        'customer_id',
        'expense_id',
        'delivery_id',
        'wallet_txn_id',
      ]) {
        await db1.customStatement('ALTER TABLE activity_logs ADD COLUMN $c TEXT');
      }
      // Two v24-shape rows: one carrying order_id, one with no entity.
      await db1.customStatement(
        'INSERT INTO activity_logs (id, business_id, action, description, '
        'order_id, created_at, last_updated_at) '
        "VALUES (?, ?, 'order_action', 'has order', ?, 0, 0)",
        [logWithEntity, businessId, orderId],
      );
      await db1.customStatement(
        'INSERT INTO activity_logs (id, business_id, action, description, '
        'created_at, last_updated_at) '
        "VALUES (?, ?, 'plain', 'no entity', 0, 0)",
        [logNoEntity, businessId],
      );

      // --- Revert notifications to the v24 shape (no severity / no CHECK) ---
      await db1.customStatement('PRAGMA foreign_keys = OFF');
      await db1.customStatement(
        'CREATE TABLE notifications_v24 AS SELECT id, business_id, type, '
        'message, is_read, linked_record_id, recipient_user_id, created_at, '
        'last_updated_at FROM notifications',
      );
      await db1.customStatement('DROP TABLE notifications');
      await db1.customStatement(
          'ALTER TABLE notifications_v24 RENAME TO notifications');
      await db1.customStatement('PRAGMA foreign_keys = ON');
      await db1.customStatement(
        'INSERT INTO notifications (id, business_id, type, message, is_read, '
        'created_at, last_updated_at) '
        "VALUES (?, ?, 'low_stock', 'msg', 0, 0, 0)",
        [notifId, businessId],
      );

      await db1.customStatement('PRAGMA user_version = 24');
      await db1.close();

      // Re-open → onUpgrade(24 → 25).
      final db2 = await openAndInit();
      addTearDown(db2.close);

      // activity_logs: column shape migrated.
      final cols = await columnsOf(db2, 'activity_logs');
      expect(cols.contains('entity_type'), isTrue);
      expect(cols.contains('entity_id'), isTrue);
      expect(cols.contains('before_json'), isTrue);
      expect(cols.contains('after_json'), isTrue);
      expect(cols.contains('store_id'), isTrue,
          reason: 'store_id kept for the §24.2 store filter');
      expect(cols.contains('order_id'), isFalse);
      expect(cols.contains('wallet_txn_id'), isFalse);

      // Backfill: the order row → ('order', orderId); the plain row → null.
      final rows = await db2
          .customSelect(
            'SELECT id, entity_type, entity_id FROM activity_logs ORDER BY id',
          )
          .get();
      final byId = {for (final r in rows) r.read<String>('id'): r};
      expect(byId[logWithEntity]!.read<String?>('entity_type'), 'order');
      expect(byId[logWithEntity]!.read<String?>('entity_id'), orderId);
      expect(byId[logNoEntity]!.read<String?>('entity_type'), isNull);

      // notifications.severity present + the pre-existing row defaulted to info.
      final ncols = await columnsOf(db2, 'notifications');
      expect(ncols.contains('severity'), isTrue);
      final n = await db2
          .customSelect(
            'SELECT severity FROM notifications WHERE id = ?',
            variables: [Variable<String>(notifId)],
          )
          .getSingle();
      expect(n.read<String>('severity'), 'info');

      // The append-only trigger was re-created on the new shape: mutating a
      // non-void column aborts.
      await expectLater(
        db2.customStatement(
          "UPDATE activity_logs SET action = 'tampered' WHERE id = ?",
          [logNoEntity],
        ),
        throwsA(anything),
      );
    });
  });

  group('onUpgrade v27 → v28 (customers.wallet.totals.view permission)', () {
    Future<bool> permissionExists(AppDatabase db, String key) async {
      final rows = await db
          .customSelect(
            'SELECT 1 FROM permissions WHERE key = ?',
            variables: [Variable<String>(key)],
          )
          .get();
      return rows.isNotEmpty;
    }

    test('re-seeds the new permission key into the local catalog', () async {
      // Build a fresh v28 DB, then revert the v28 delta: drop the new permission
      // key (the catalog seed put it there at onCreate) and step user_version
      // back. Every other table is untouched.
      final db1 = await openAndInit();
      expect(
        await permissionExists(db1, 'customers.wallet.totals.view'),
        isTrue,
        reason: 'onCreate should seed the key',
      );
      await db1.customStatement(
        "DELETE FROM permissions WHERE key = 'customers.wallet.totals.view'",
      );
      await db1.customStatement('PRAGMA user_version = 27');
      await db1.close();

      // Re-open → onUpgrade(27 → 28) re-inserts the key via INSERT OR IGNORE.
      final db2 = await openAndInit();
      addTearDown(db2.close);

      expect(
        await permissionExists(db2, 'customers.wallet.totals.view'),
        isTrue,
      );
    });
  });

  group('onUpgrade v28 → v29 (crate tracking by manufacturer, §13.4)', () {
    test('re-keys the crate balance/pending tables + relaxes the ledger CHECK',
        () async {
      // Build a fresh v29 DB, then revert the v29 delta on the two balance
      // CACHES + pending_crate_returns to their old crate-size-group shape so
      // the migration guards (hasCol crate_size_group_id) re-fire. The exact old
      // constraints don't matter — the block DROPs + recreates these tables from
      // the current schema — only that crate_size_group_id is present.
      final db1 = await openAndInit();
      await db1.customStatement('PRAGMA foreign_keys = OFF');
      await db1.customStatement('DROP TABLE IF EXISTS customer_crate_balances');
      await db1.customStatement(
        'CREATE TABLE customer_crate_balances (id TEXT NOT NULL PRIMARY KEY, '
        'business_id TEXT NOT NULL, customer_id TEXT NOT NULL, '
        'crate_size_group_id TEXT NOT NULL, balance INTEGER NOT NULL DEFAULT 0, '
        'created_at INTEGER NOT NULL DEFAULT 0, last_updated_at INTEGER NOT NULL DEFAULT 0)',
      );
      await db1.customStatement(
          'DROP TABLE IF EXISTS manufacturer_crate_balances');
      await db1.customStatement(
        'CREATE TABLE manufacturer_crate_balances (id TEXT NOT NULL PRIMARY KEY, '
        'business_id TEXT NOT NULL, manufacturer_id TEXT NOT NULL, '
        'crate_size_group_id TEXT NOT NULL, balance INTEGER NOT NULL DEFAULT 0, '
        'created_at INTEGER NOT NULL DEFAULT 0, last_updated_at INTEGER NOT NULL DEFAULT 0)',
      );
      await db1.customStatement('DROP TABLE IF EXISTS pending_crate_returns');
      await db1.customStatement(
        'CREATE TABLE pending_crate_returns (id TEXT NOT NULL PRIMARY KEY, '
        'business_id TEXT NOT NULL, order_id TEXT, customer_id TEXT NOT NULL, '
        'crate_size_group_id TEXT NOT NULL, quantity INTEGER NOT NULL, '
        'submitted_by TEXT NOT NULL, submitted_at INTEGER NOT NULL DEFAULT 0, '
        'approved_by TEXT, approved_at INTEGER, '
        "status TEXT NOT NULL DEFAULT 'pending', rejection_reason TEXT, "
        'created_at INTEGER NOT NULL DEFAULT 0, last_updated_at INTEGER NOT NULL DEFAULT 0)',
      );
      // Revert crate_ledger to its OLD shape (crate_size_group_id NOT NULL) so
      // the rebuild branch (cgIsNotNull) actually runs — AND recreate its
      // indexes, because drift's alterTable re-applies them, which is what made
      // the first attempt crash on a duplicate idx_crate_ledger_business_lua.
      await db1.customStatement('DROP TABLE IF EXISTS crate_ledger');
      await db1.customStatement(
        'CREATE TABLE crate_ledger (id TEXT NOT NULL PRIMARY KEY, '
        'business_id TEXT NOT NULL, customer_id TEXT, manufacturer_id TEXT, '
        'crate_size_group_id TEXT NOT NULL, quantity_delta INTEGER NOT NULL, '
        'movement_type TEXT NOT NULL, reference_order_id TEXT, '
        'reference_return_id TEXT, performed_by TEXT, voided_at INTEGER, '
        'voided_by TEXT, void_reason TEXT, '
        'created_at INTEGER NOT NULL DEFAULT 0, last_updated_at INTEGER NOT NULL DEFAULT 0)',
      );
      await db1.customStatement(
        'CREATE INDEX idx_crate_ledger_business_lua '
        'ON crate_ledger (business_id, last_updated_at)',
      );
      await db1.customStatement(
        'CREATE INDEX idx_crate_ledger_owner_group '
        'ON crate_ledger (business_id, customer_id, manufacturer_id, crate_size_group_id, created_at)',
      );
      await db1.customStatement('PRAGMA foreign_keys = ON');
      await db1.customStatement('PRAGMA user_version = 28');
      await db1.close();

      // Re-open → onUpgrade(28 → 29). Must succeed and produce the new shape.
      final db2 = await openAndInit();
      addTearDown(db2.close);

      final ccb = await columnsOf(db2, 'customer_crate_balances');
      expect(ccb.contains('manufacturer_id'), isTrue);
      expect(ccb.contains('crate_size_group_id'), isFalse);

      final mcb = await columnsOf(db2, 'manufacturer_crate_balances');
      expect(mcb.contains('crate_size_group_id'), isFalse);

      final pcr = await columnsOf(db2, 'pending_crate_returns');
      expect(pcr.contains('manufacturer_id'), isTrue);

      // The relaxed owner CHECK lets a customer crate row also name a
      // manufacturer (both set) — the core of the re-key.
      final biz = UuidV7.generate();
      final cust = UuidV7.generate();
      final mfr = UuidV7.generate();
      await db2.customStatement(
          "INSERT INTO businesses (id, name) VALUES ('$biz', 'B')");
      await db2.customStatement(
          "INSERT INTO customers (id, business_id, name) VALUES ('$cust', '$biz', 'C')");
      await db2.customStatement(
          "INSERT INTO manufacturers (id, business_id, name) VALUES ('$mfr', '$biz', 'M')");
      await db2.customStatement(
        "INSERT INTO crate_ledger (id, business_id, customer_id, manufacturer_id, "
        "quantity_delta, movement_type) "
        "VALUES ('${UuidV7.generate()}', '$biz', '$cust', '$mfr', -2, 'returned')",
      );
      final rows = await db2.customSelect(
        "SELECT customer_id, manufacturer_id FROM crate_ledger WHERE business_id = '$biz'",
      ).get();
      expect(rows, hasLength(1));
      expect(rows.first.read<String?>('customer_id'), cust);
      expect(rows.first.read<String?>('manufacturer_id'), mfr);
    });
  });

  group('onUpgrade → v36 (Funds Register removal, FK-safe teardown)', () {
    test(
        'drops funds_accounts even when a stray table still references it '
        '(parallel Supplier Accounts coupling) — no 787', () async {
      // Reproduces the on-device crash: a till that also ran the parallel
      // Supplier Accounts work carries a supplier_payments.funds_account_id ->
      // funds_accounts FK that THIS branch's schema never defines. With FK
      // enforcement ON, the v36 `DROP TABLE funds_accounts` runs an implicit
      // DELETE that orphans that payment row -> SqliteException(787). The current
      // schema (onCreate) no longer has the funds tables, so recreate the parent
      // + a stray child referrer, then drive onUpgrade across the v36 boundary.
      final db1 = await openAndInit();

      // funds_accounts (parent) — minimal shape; only the FK target id matters.
      await db1.customStatement(
        'CREATE TABLE funds_accounts (id TEXT NOT NULL PRIMARY KEY, '
        'business_id TEXT NOT NULL)',
      );
      // Stray referrer from the parallel work — FK INTO funds_accounts.
      await db1.customStatement(
        'CREATE TABLE supplier_payments (id TEXT NOT NULL PRIMARY KEY, '
        'funds_account_id TEXT REFERENCES funds_accounts (id))',
      );
      final acct = UuidV7.generate();
      await db1.customStatement(
        "INSERT INTO funds_accounts (id, business_id) VALUES ('$acct', 'b')",
      );
      await db1.customStatement(
        "INSERT INTO supplier_payments (id, funds_account_id) "
        "VALUES ('${UuidV7.generate()}', '$acct')",
      );

      await db1.customStatement('PRAGMA user_version = 35');
      await db1.close();

      // Re-open with FK enforcement enabled at raw-open (mirrors production's
      // _openConnection setup) so onUpgrade runs with FK ON — the condition that
      // makes the drop throw 787. The shared openAndInit() omits that setup, so
      // its onUpgrade runs FK-OFF and would pass this test even WITHOUT the fix;
      // this local open is what gives the regression teeth. The v36 block must
      // NOT throw 787 — reaching past the forced open at all proves the fix.
      final db2 = AppDatabase.forTesting(
        NativeDatabase(
          dbFile,
          setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      addTearDown(db2.close);
      await db2.customSelect('SELECT 1').get();

      final funds = await db2.customSelect(
        "SELECT name FROM sqlite_master "
        "WHERE type='table' AND name='funds_accounts'",
      ).get();
      expect(funds, isEmpty, reason: 'v36 must drop funds_accounts');
    });
  });

  group('onUpgrade v55 → v56 (store-transfer permissions)', () {
    test('re-seeds both catalog rows on a DB that lacks them', () async {
      Future<int> permCount(AppDatabase db) async {
        final r = await db
            .customSelect(
              "SELECT COUNT(*) c FROM permissions "
              "WHERE key IN ('stores.request_transfer', "
              "'stores.dispatch_transfer')",
            )
            .getSingle();
        return r.read<int>('c');
      }

      // Fresh DB already seeds both keys in onCreate (they're in
      // _defaultPermissionRows). Delete them + revert to v55 so the re-open's
      // v56 block has work to do.
      final db1 = await openAndInit();
      await db1.customStatement(
        "DELETE FROM permissions WHERE key IN "
        "('stores.request_transfer', 'stores.dispatch_transfer')",
      );
      expect(await permCount(db1), 0);
      await db1.customStatement('PRAGMA user_version = 55');
      await db1.close();

      // Re-open → onUpgrade(55 → 56) must re-insert both catalog rows.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await permCount(db2), 2,
          reason: 'v56 block must seed the two store-transfer permissions');
    });
  });
}
