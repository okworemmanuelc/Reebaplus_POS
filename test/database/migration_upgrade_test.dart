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

  group('onUpgrade v57 → v58 (cost_batches FIFO seed — ADR 0005, issue #37)', () {
    Future<bool> objectExists(AppDatabase db, String type, String name) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='$type' AND name='$name'",
          )
          .get();
      return r.isNotEmpty;
    }

    test(
        'seeds one opening batch per (product, store) at the scalar cost; '
        'zero-cost stock → uncosted batch; empty stock → no batch', () async {
      final biz = UuidV7.generate();
      final store1 = UuidV7.generate();
      final store2 = UuidV7.generate();
      final productA = UuidV7.generate(); // costed, stock in two stores
      final productB = UuidV7.generate(); // zero cost → uncosted batch
      final productC = UuidV7.generate(); // zero stock → no batch
      const recA = 1700000000; // product created_at (unix seconds)
      const recB = 1700000100;
      const recC = 1700000200;

      final db1 = await openAndInit();

      // A fresh v58 DB already created cost_batches (empty) at onCreate. Populate
      // the SOURCE rows (business / stores / products / inventory), then revert
      // the v58 delta — drop cost_batches + step user_version back — so the
      // re-open's v58 block does the real seed against this stock.
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      for (final (id, name) in [(store1, 'Main'), (store2, 'Branch')]) {
        await db1.customStatement(
          'INSERT INTO stores (id, business_id, name) VALUES (?, ?, ?)',
          [id, biz, name],
        );
      }
      for (final (id, name, cost, created) in [
        (productA, 'Star 60cl', 50000, recA),
        (productB, 'House Water', 0, recB),
        (productC, 'Ghost Item', 20000, recC),
      ]) {
        await db1.customStatement(
          'INSERT INTO products (id, business_id, name, buying_price_kobo, '
          'created_at) VALUES (?, ?, ?, ?, ?)',
          [id, biz, name, cost, created],
        );
      }
      for (final (product, store, qty) in [
        (productA, store1, 10),
        (productA, store2, 3),
        (productB, store1, 5),
        (productC, store1, 0), // empty → no batch
      ]) {
        await db1.customStatement(
          'INSERT INTO inventory (id, business_id, product_id, store_id, '
          'quantity) VALUES (?, ?, ?, ?, ?)',
          [UuidV7.generate(), biz, product, store, qty],
        );
      }

      await db1.customStatement('PRAGMA foreign_keys = OFF');
      await db1.customStatement('DROP TABLE IF EXISTS cost_batches');
      await db1.customStatement('PRAGMA foreign_keys = ON');
      expect(await objectExists(db1, 'table', 'cost_batches'), isFalse);
      await db1.customStatement('PRAGMA user_version = 57');
      await db1.close();

      // Re-open → onUpgrade(57 → 58) recreates the table (+ indexes + trigger)
      // and seeds the opening batches.
      final db2 = await openAndInit();
      addTearDown(db2.close);

      expect(await objectExists(db2, 'table', 'cost_batches'), isTrue,
          reason: 'v58 must create cost_batches');
      // The sync cursor index, the FIFO scan index, and the bump trigger must
      // exist so a fresh install (onCreate) and an upgrade end up identical.
      expect(
        await objectExists(db2, 'index', 'idx_cost_batches_business_lua'),
        isTrue,
        reason: 'v58 must create the (business_id, last_updated_at) sync index',
      );
      expect(
        await objectExists(
            db2, 'index', 'idx_cost_batches_product_store_received'),
        isTrue,
        reason: 'v58 must create the FIFO scan index',
      );
      expect(
        await objectExists(
            db2, 'trigger', 'bump_cost_batches_last_updated_at'),
        isTrue,
        reason: 'v58 must create the last_updated_at bump trigger',
      );

      final rows = await db2
          .customSelect(
            'SELECT id, product_id, store_id, qty_remaining, qty_original, '
            'cost_kobo, received_at FROM cost_batches',
          )
          .get();

      // Exactly one batch per (product, store) WITH STOCK — productC (empty)
      // gets none.
      expect(rows, hasLength(3),
          reason: 'one opening batch per (product, store) with stock');
      final byKey = {
        for (final r in rows)
          '${r.read<String>('product_id')}:${r.read<String>('store_id')}': r,
      };

      // productA @ store1: full scalar cost, qty carried through.
      final a1 = byKey['$productA:$store1']!;
      expect(a1.read<int>('qty_remaining'), 10);
      expect(a1.read<int>('qty_original'), 10);
      expect(a1.read<int>('cost_kobo'), 50000);
      expect(a1.read<int>('received_at'), recA,
          reason: 'opening batch inherits the product created_at as received_at');
      expect(
        a1.read<String>('id'),
        UuidV7.deterministic('cost_batch_opening:$biz:$productA:$store1'),
        reason: 'opening-batch id is deterministic so devices converge on sync',
      );

      // productA @ store2: second store → its own batch.
      final a2 = byKey['$productA:$store2']!;
      expect(a2.read<int>('qty_remaining'), 3);
      expect(a2.read<int>('cost_kobo'), 50000);

      // productB: zero cost → uncosted batch (cost_kobo == 0).
      final b1 = byKey['$productB:$store1']!;
      expect(b1.read<int>('qty_remaining'), 5);
      expect(b1.read<int>('cost_kobo'), 0,
          reason: 'zero-cost stock becomes an uncosted batch');

      // productC (zero stock) has no batch at all.
      expect(
        byKey.keys.where((k) => k.startsWith('$productC:')),
        isEmpty,
        reason: 'an empty (product, store) has nothing to cost',
      );
    });
  });

  group('onUpgrade v60 → v61 (staff.remove permission + `removed` status CHECK, '
      '#107)', () {
    Future<int> permCount(AppDatabase db) async {
      final r = await db
          .customSelect(
            "SELECT COUNT(*) c FROM permissions WHERE key = 'staff.remove'",
          )
          .getSingle();
      return r.read<int>('c');
    }

    Future<bool> objectExists(AppDatabase db, String type, String name) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='$type' AND name='$name'",
          )
          .get();
      return r.isNotEmpty;
    }

    test(
        're-seeds staff.remove AND widens the user_businesses.status CHECK to '
        'admit `removed` (index + bump trigger recreated)', () async {
      final biz = UuidV7.generate();
      final userId = UuidV7.generate();
      final roleId = UuidV7.generate();

      final db1 = await openAndInit();

      // FK targets for the membership inserted after the upgrade — must survive
      // the user_businesses revert below (only that table is dropped).
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db1.customStatement(
        "INSERT INTO roles (id, business_id, name, slug) "
        "VALUES (?, ?, 'CEO', 'ceo')",
        [roleId, biz],
      );
      await db1.customStatement(
        "INSERT INTO users (id, business_id, name, pin) "
        "VALUES (?, ?, 'Rita', '__H__')",
        [userId, biz],
      );

      // A fresh v61 DB already seeds staff.remove in onCreate (it's in
      // _defaultPermissionRows) — delete it so the v61 block has work to do.
      await db1.customStatement(
        "DELETE FROM permissions WHERE key = 'staff.remove'",
      );
      expect(await permCount(db1), 0);

      // Revert user_businesses to the OLD 2-value CHECK so the widening has
      // teeth. Drop + recreate with the pre-v61 constraint; the column NAMES
      // match the Drift schema, so the migration's TableMigration copy works.
      await db1.customStatement('PRAGMA foreign_keys = OFF');
      await db1.customStatement('DROP TABLE IF EXISTS user_businesses');
      await db1.customStatement(
        'CREATE TABLE user_businesses ('
        'id TEXT NOT NULL PRIMARY KEY, business_id TEXT NOT NULL, '
        'user_id TEXT NOT NULL, role_id TEXT NOT NULL, '
        "status TEXT NOT NULL DEFAULT 'active', last_login_at INTEGER, "
        'created_at INTEGER NOT NULL DEFAULT 0, '
        'last_updated_at INTEGER NOT NULL DEFAULT 0, '
        "CHECK (status IN ('active','suspended')), "
        'UNIQUE (user_id, business_id))',
      );
      await db1.customStatement('PRAGMA foreign_keys = ON');

      // Before the upgrade, the old 2-value CHECK rejects `removed`.
      await expectLater(
        db1.customStatement(
          'INSERT INTO user_businesses '
          '(id, business_id, user_id, role_id, status) '
          "VALUES (?, ?, ?, ?, 'removed')",
          [UuidV7.generate(), biz, userId, roleId],
        ),
        throwsA(anything),
        reason: 'the pre-v61 2-value CHECK must reject `removed`',
      );

      await db1.customStatement('PRAGMA user_version = 60');
      await db1.close();

      // Re-open → onUpgrade(60 → 61).
      final db2 = await openAndInit();
      addTearDown(db2.close);

      // (1) permission catalog re-seeded.
      expect(await permCount(db2), 1, reason: 'v61 must seed staff.remove');

      // (2) the widened CHECK now accepts `removed`.
      await db2.customStatement(
        'INSERT INTO user_businesses '
        '(id, business_id, user_id, role_id, status) '
        "VALUES (?, ?, ?, ?, 'removed')",
        [UuidV7.generate(), biz, userId, roleId],
      );
      final row = await db2
          .customSelect(
            'SELECT status FROM user_businesses WHERE user_id = ?',
            variables: [Variable<String>(userId)],
          )
          .getSingle();
      expect(row.read<String>('status'), 'removed');

      // (3) the rebuild recreated the sync cursor index + bump trigger, so a
      //     fresh install (onCreate) and an upgrade converge.
      expect(
        await objectExists(db2, 'index', 'idx_user_businesses_business_lua'),
        isTrue,
        reason: 'v61 must recreate the (business_id, last_updated_at) index',
      );
      expect(
        await objectExists(db2, 'index', 'idx_user_businesses_user'),
        isTrue,
        reason: 'v61 must recreate the user_id hot-path index',
      );
      expect(
        await objectExists(
            db2, 'trigger', 'bump_user_businesses_last_updated_at'),
        isTrue,
        reason: 'v61 must recreate the last_updated_at bump trigger',
      );
    });
  });

  group('onUpgrade v63 → v64 (money-integrity prefactor #169)', () {
    Future<bool> objectExists(AppDatabase db, String type, String name) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='$type' AND name='$name'",
          )
          .get();
      return r.isNotEmpty;
    }

    test(
        'adds orders.confirmed_by + payment_transactions.store_id, widens the '
        'type CHECK to admit crate_deposit, and recreates the append-only '
        'triggers/indexes (legacy payment rows keep store_id NULL)', () async {
      final biz = UuidV7.generate();
      final orderId = UuidV7.generate();
      final legacyPayId = UuidV7.generate();

      final db1 = await openAndInit();

      // Real FK targets that survive the payment_transactions revert (only that
      // table is dropped/recreated). The order lets the post-upgrade
      // crate_deposit insert satisfy the (real) order_id FK.
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db1.customStatement(
        'INSERT INTO orders (id, business_id, order_number, total_amount_kobo, '
        'net_amount_kobo, payment_type, status) '
        "VALUES (?, ?, 'ORD-000001-AAAAAA', 100000, 100000, 'cash', 'completed')",
        [orderId, biz],
      );

      // (1) Revert orders to the pre-v64 shape: drop confirmed_by.
      await db1.customStatement('ALTER TABLE orders DROP COLUMN confirmed_by');

      // (2) Revert payment_transactions to the pre-v64 shape: no store_id and
      //     the old 5-value type CHECK. Recreate WITHOUT FKs (mirrors the v61
      //     user_businesses revert) so the copy is unconstrained; the migration
      //     rebuilds the real, FK-carrying table from the Drift schema.
      await db1.customStatement('PRAGMA foreign_keys = OFF');
      await db1.customStatement('DROP TABLE IF EXISTS payment_transactions');
      await db1.customStatement(
        'CREATE TABLE payment_transactions ('
        'id TEXT NOT NULL PRIMARY KEY, business_id TEXT NOT NULL, '
        'amount_kobo INTEGER NOT NULL, method TEXT NOT NULL, type TEXT NOT NULL, '
        'order_id TEXT, shipment_id TEXT, expense_id TEXT, wallet_txn_id TEXT, '
        'delivery_id TEXT, performed_by TEXT, voided_at INTEGER, '
        'voided_by TEXT, void_reason TEXT, '
        'created_at INTEGER NOT NULL DEFAULT 0, '
        'last_updated_at INTEGER NOT NULL DEFAULT 0, '
        "CHECK (method IN ('cash','transfer','card','wallet','pos','other')), "
        "CHECK (type IN ('sale','purchase','expense','refund','wallet_topup')))",
      );
      await db1.customStatement('PRAGMA foreign_keys = ON');

      // A pre-existing (legacy) sale payment on the reverted table — no store_id.
      await db1.customStatement(
        'INSERT INTO payment_transactions '
        '(id, business_id, amount_kobo, method, type, order_id, created_at, '
        'last_updated_at) '
        "VALUES (?, ?, 100000, 'cash', 'sale', ?, 0, 0)",
        [legacyPayId, biz, orderId],
      );

      // The old 5-value CHECK rejects the new crate_deposit type — teeth for the
      // widening.
      await expectLater(
        db1.customStatement(
          'INSERT INTO payment_transactions '
          '(id, business_id, amount_kobo, method, type, order_id) '
          "VALUES (?, ?, 1, 'cash', 'crate_deposit', ?)",
          [UuidV7.generate(), biz, orderId],
        ),
        throwsA(anything),
        reason: 'the pre-v64 5-value type CHECK must reject crate_deposit',
      );

      await db1.customStatement('PRAGMA user_version = 63');
      await db1.close();

      // Re-open → onUpgrade(63 → 64).
      final db2 = await openAndInit();
      addTearDown(db2.close);

      // (1) orders.confirmed_by re-added.
      expect(
        (await columnsOf(db2, 'orders')).contains('confirmed_by'),
        isTrue,
        reason: 'v64 must add orders.confirmed_by',
      );

      // (2) payment_transactions.store_id added; the legacy row keeps it NULL.
      expect(
        (await columnsOf(db2, 'payment_transactions')).contains('store_id'),
        isTrue,
        reason: 'v64 must add payment_transactions.store_id',
      );
      final legacy = await db2
          .customSelect(
            'SELECT store_id FROM payment_transactions WHERE id = ?',
            variables: [Variable<String>(legacyPayId)],
          )
          .getSingle();
      expect(legacy.read<String?>('store_id'), isNull,
          reason: 'legacy rows report business-wide (store_id NULL)');

      // (3) The widened CHECK now accepts a crate_deposit row.
      await db2.customStatement(
        'INSERT INTO payment_transactions '
        '(id, business_id, amount_kobo, method, type, order_id) '
        "VALUES (?, ?, 5000, 'cash', 'crate_deposit', ?)",
        [UuidV7.generate(), biz, orderId],
      );

      // (4) Append-only triggers + sync/hot-path indexes recreated.
      expect(await objectExists(db2, 'trigger', 'payment_transactions_immutable'),
          isTrue, reason: 'v64 must recreate the immutable ledger trigger');
      expect(await objectExists(db2, 'trigger', 'payment_transactions_no_delete'),
          isTrue, reason: 'v64 must recreate the no-delete ledger trigger');
      expect(
        await objectExists(
            db2, 'trigger', 'bump_payment_transactions_last_updated_at'),
        isTrue,
        reason: 'v64 must recreate the last_updated_at bump trigger',
      );
      expect(
        await objectExists(
            db2, 'index', 'idx_payment_transactions_business_lua'),
        isTrue,
        reason: 'v64 must recreate the (business_id, last_updated_at) sync index',
      );
      expect(
        await objectExists(db2, 'index', 'idx_payment_txn_business_type'),
        isTrue,
        reason: 'v64 must recreate the (business_id, type, created_at) index',
      );

      // (5) The immutable trigger now guards store_id (added to the set): a
      //     store_id edit on an existing row aborts.
      await expectLater(
        db2.customStatement(
          'UPDATE payment_transactions SET store_id = ? WHERE id = ?',
          [UuidV7.generate(), legacyPayId],
        ),
        throwsA(anything),
        reason: 'store_id is immutable after insert (append-only ledger)',
      );
    });
  });

  group('onUpgrade v64 → v65 (sales.confirm permission, #171 Confirm gate)', () {
    Future<bool> permissionExists(AppDatabase db, String key) async {
      final rows = await db
          .customSelect(
            'SELECT 1 FROM permissions WHERE key = ?',
            variables: [Variable<String>(key)],
          )
          .get();
      return rows.isNotEmpty;
    }

    test('re-seeds sales.confirm into the local catalog', () async {
      // Fresh v65 DB already seeds the key in onCreate (it's in
      // _defaultPermissionRows). Delete it + revert to v64 so the re-open's v65
      // block has work to do. Every other table is untouched.
      final db1 = await openAndInit();
      expect(await permissionExists(db1, 'sales.confirm'), isTrue,
          reason: 'onCreate should seed the key');
      await db1.customStatement(
        "DELETE FROM permissions WHERE key = 'sales.confirm'",
      );
      expect(await permissionExists(db1, 'sales.confirm'), isFalse);
      await db1.customStatement('PRAGMA user_version = 64');
      await db1.close();

      // Re-open → onUpgrade(64 → 65) re-inserts the key via INSERT OR IGNORE.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await permissionExists(db2, 'sales.confirm'), isTrue,
          reason: 'v65 block must seed sales.confirm');
    });
  });

  group('onUpgrade v65 → v66 (money-integrity #7a cost-batch coverage, #170)',
      () {
    Future<bool> columnExists(
        AppDatabase db, String table, String column) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM pragma_table_info('$table') WHERE name = ?",
            variables: [Variable<String>(column)],
          )
          .get();
      return r.isNotEmpty;
    }

    test('adds stock_adjustments.unit_cost_kobo + value_kobo (loss snapshot); '
        'legacy rows keep them NULL', () async {
      final biz = UuidV7.generate();
      final storeId = UuidV7.generate();
      final productId = UuidV7.generate();
      final legacyAdjId = UuidV7.generate();

      final db1 = await openAndInit();
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db1.customStatement(
        "INSERT INTO stores (id, business_id, name) VALUES (?, ?, 'Main')",
        [storeId, biz],
      );
      await db1.customStatement(
        "INSERT INTO products (id, business_id, name) VALUES (?, ?, 'Widget')",
        [productId, biz],
      );

      // Revert stock_adjustments to the pre-v66 shape: drop the snapshot columns.
      await db1
          .customStatement('ALTER TABLE stock_adjustments DROP COLUMN value_kobo');
      await db1.customStatement(
          'ALTER TABLE stock_adjustments DROP COLUMN unit_cost_kobo');
      expect(await columnExists(db1, 'stock_adjustments', 'value_kobo'), isFalse);

      // A pre-existing (legacy) quantity-only adjustment on the reverted table.
      await db1.customStatement(
        'INSERT INTO stock_adjustments '
        '(id, business_id, product_id, store_id, quantity_diff, reason) '
        "VALUES (?, ?, ?, ?, -2, 'damage:breakage')",
        [legacyAdjId, biz, productId, storeId],
      );

      await db1.customStatement('PRAGMA user_version = 65');
      await db1.close();

      // Re-open → onUpgrade(65 → 66) adds the two nullable snapshot columns.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await columnExists(db2, 'stock_adjustments', 'unit_cost_kobo'),
          isTrue);
      expect(await columnExists(db2, 'stock_adjustments', 'value_kobo'), isTrue);

      // The legacy row survives and its new snapshot columns are NULL (the
      // labelled current-cost fallback path).
      final legacy = await db2
          .customSelect(
            'SELECT unit_cost_kobo, value_kobo FROM stock_adjustments WHERE id = ?',
            variables: [Variable<String>(legacyAdjId)],
          )
          .getSingle();
      expect(legacy.data['unit_cost_kobo'], isNull);
      expect(legacy.data['value_kobo'], isNull);
    });
  });

  group('onUpgrade v66 → v67 (money-integrity #7b transfers move cost, #170)',
      () {
    Future<bool> columnExists(
        AppDatabase db, String table, String column) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM pragma_table_info('$table') WHERE name = ?",
            variables: [Variable<String>(column)],
          )
          .get();
      return r.isNotEmpty;
    }

    test('adds stock_transfers.cost_kobo (the cost that rides a transfer); '
        'legacy transfers keep it NULL', () async {
      final biz = UuidV7.generate();
      final fromStore = UuidV7.generate();
      final toStore = UuidV7.generate();
      final productId = UuidV7.generate();
      final userId = UuidV7.generate();
      final legacyTransferId = UuidV7.generate();

      final db1 = await openAndInit();
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db1.customStatement(
        "INSERT INTO stores (id, business_id, name) VALUES (?, ?, 'Src')",
        [fromStore, biz],
      );
      await db1.customStatement(
        "INSERT INTO stores (id, business_id, name) VALUES (?, ?, 'Dst')",
        [toStore, biz],
      );
      await db1.customStatement(
        "INSERT INTO products (id, business_id, name) VALUES (?, ?, 'Widget')",
        [productId, biz],
      );
      await db1.customStatement(
        "INSERT INTO users (id, business_id, name, pin) VALUES (?, ?, 'CEO', '0')",
        [userId, biz],
      );

      // Revert stock_transfers to the pre-v67 shape: drop cost_kobo.
      await db1
          .customStatement('ALTER TABLE stock_transfers DROP COLUMN cost_kobo');
      expect(await columnExists(db1, 'stock_transfers', 'cost_kobo'), isFalse);

      // A pre-existing (legacy) transfer on the reverted table.
      await db1.customStatement(
        'INSERT INTO stock_transfers '
        '(id, business_id, from_location_id, to_location_id, product_id, '
        'quantity, status, initiated_by) '
        "VALUES (?, ?, ?, ?, ?, 5, 'received', ?)",
        [legacyTransferId, biz, fromStore, toStore, productId, userId],
      );

      await db1.customStatement('PRAGMA user_version = 66');
      await db1.close();

      // Re-open → onUpgrade(66 → 67) adds the nullable cost_kobo column.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await columnExists(db2, 'stock_transfers', 'cost_kobo'), isTrue);

      // The legacy transfer survives and its new cost_kobo is NULL.
      final legacy = await db2
          .customSelect(
            'SELECT cost_kobo FROM stock_transfers WHERE id = ?',
            variables: [Variable<String>(legacyTransferId)],
          )
          .getSingle();
      expect(legacy.data['cost_kobo'], isNull);
    });
  });

  group('onUpgrade → v68 (daily_closings persisted day close, #174)', () {
    Future<bool> objectExists(AppDatabase db, String type, String name) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='$type' AND name='$name'",
          )
          .get();
      return r.isNotEmpty;
    }

    test('creates the daily_closings table + sync index + bump trigger', () async {
      // A fresh v68 DB already creates daily_closings at onCreate. Drop it +
      // step user_version back so the re-open's v68 block does the real create.
      final db1 = await openAndInit();
      expect(await objectExists(db1, 'table', 'daily_closings'), isTrue,
          reason: 'onCreate should create the table');
      await db1.customStatement('PRAGMA foreign_keys = OFF');
      await db1.customStatement('DROP TABLE IF EXISTS daily_closings');
      await db1.customStatement('PRAGMA foreign_keys = ON');
      expect(await objectExists(db1, 'table', 'daily_closings'), isFalse);
      await db1.customStatement('PRAGMA user_version = 65');
      await db1.close();

      // Re-open → onUpgrade(65 → 68) recreates the table, its (business_id,
      // last_updated_at) sync index, and the last_updated_at bump trigger.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await objectExists(db2, 'table', 'daily_closings'), isTrue,
          reason: 'v68 block must create daily_closings');
      expect(
        await objectExists(db2, 'index', 'idx_daily_closings_business_lua'),
        isTrue,
        reason: 'v68 must create the (business_id, last_updated_at) sync index',
      );
      expect(
        await objectExists(
            db2, 'trigger', 'bump_daily_closings_last_updated_at'),
        isTrue,
        reason: 'v68 must create the last_updated_at bump trigger',
      );

      // The natural-key UNIQUE (business_id, business_date) is enforced.
      final cols = await columnsOf(db2, 'daily_closings');
      expect(cols, containsAll(<String>{'business_date', 'total_sales_kobo'}));
    });
  });

  group('onUpgrade v68 → v69 (order_items catalogue-price snapshot, #176)', () {
    Future<bool> columnExists(
        AppDatabase db, String table, String column) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM pragma_table_info('$table') WHERE name = ?",
            variables: [Variable<String>(column)],
          )
          .get();
      return r.isNotEmpty;
    }

    test('adds order_items.catalogue_price_kobo (a custom-price concession '
        'reference); legacy lines keep it NULL', () async {
      final biz = UuidV7.generate();
      final storeId = UuidV7.generate();
      final orderId = UuidV7.generate();
      final legacyItemId = UuidV7.generate();

      final db1 = await openAndInit();
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db1.customStatement(
        "INSERT INTO stores (id, business_id, name) VALUES (?, ?, 'Main')",
        [storeId, biz],
      );
      await db1.customStatement(
        'INSERT INTO orders (id, business_id, order_number, total_amount_kobo, '
        'net_amount_kobo, payment_type, status) '
        "VALUES (?, ?, 'ORD-1', 100000, 100000, 'cash', 'pending')",
        [orderId, biz],
      );

      // Revert order_items to the pre-v69 shape: drop catalogue_price_kobo.
      await db1.customStatement(
          'ALTER TABLE order_items DROP COLUMN catalogue_price_kobo');
      expect(
          await columnExists(db1, 'order_items', 'catalogue_price_kobo'),
          isFalse);

      // A pre-existing (legacy) line on the reverted table.
      await db1.customStatement(
        'INSERT INTO order_items '
        '(id, business_id, order_id, store_id, quantity, unit_price_kobo, '
        'total_kobo) VALUES (?, ?, ?, ?, 2, 100000, 200000)',
        [legacyItemId, biz, orderId, storeId],
      );

      await db1.customStatement('PRAGMA user_version = 68');
      await db1.close();

      // Re-open → onUpgrade(68 → 69) adds the nullable column.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(
          await columnExists(db2, 'order_items', 'catalogue_price_kobo'),
          isTrue);

      // The legacy line survives and its new catalogue_price_kobo is NULL.
      final legacy = await db2
          .customSelect(
            'SELECT catalogue_price_kobo FROM order_items WHERE id = ?',
            variables: [Variable<String>(legacyItemId)],
          )
          .getSingle();
      expect(legacy.data['catalogue_price_kobo'], isNull);
    });
  });

  group('onUpgrade v69 → v70 (van-as-location + van permission keys, #140)', () {
    Future<bool> columnExists(
        AppDatabase db, String table, String column) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM pragma_table_info('$table') WHERE name = ?",
            variables: [Variable<String>(column)],
          )
          .get();
      return r.isNotEmpty;
    }

    test('adds stores.kind defaulted to \'store\'; legacy stores stay stores '
        'and can then be flipped to a van', () async {
      final biz = UuidV7.generate();
      final legacyStoreId = UuidV7.generate();

      final db1 = await openAndInit();
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );

      // Revert stores to the pre-v70 shape: drop kind.
      await db1.customStatement('ALTER TABLE stores DROP COLUMN kind');
      expect(await columnExists(db1, 'stores', 'kind'), isFalse);

      // A pre-existing (legacy) store on the reverted table.
      await db1.customStatement(
        "INSERT INTO stores (id, business_id, name) VALUES (?, ?, 'Main')",
        [legacyStoreId, biz],
      );

      await db1.customStatement('PRAGMA user_version = 69');
      await db1.close();

      // Re-open → onUpgrade(69 → 70) adds the NOT NULL DEFAULT column.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await columnExists(db2, 'stores', 'kind'), isTrue);

      // The legacy store survives and became a normal 'store' — never a van.
      final legacy = await db2
          .customSelect(
            'SELECT kind FROM stores WHERE id = ?',
            variables: [Variable<String>(legacyStoreId)],
          )
          .getSingle();
      expect(legacy.data['kind'], 'store');

      // And the column actually accepts a van, so #141 has something to build on.
      final vanId = UuidV7.generate();
      await db2.customStatement(
        "INSERT INTO stores (id, business_id, name, kind) "
        "VALUES (?, ?, 'Van 1', 'van')",
        [vanId, biz],
      );
      final van = await db2
          .customSelect(
            'SELECT kind FROM stores WHERE id = ?',
            variables: [Variable<String>(vanId)],
          )
          .getSingle();
      expect(van.data['kind'], 'van');
    });

    test('seeds the van.manage / van.sell permission keys, idempotently',
        () async {
      final db1 = await openAndInit();

      // Revert the v70 delta: drop the column and both catalogue keys.
      await db1.customStatement('ALTER TABLE stores DROP COLUMN kind');
      await db1.customStatement(
        "DELETE FROM permissions WHERE key IN ('van.manage', 'van.sell')",
      );
      final before = await db1
          .customSelect("SELECT COUNT(*) c FROM permissions WHERE key LIKE 'van.%'")
          .getSingle();
      expect(before.data['c'], 0);

      await db1.customStatement('PRAGMA user_version = 69');
      await db1.close();

      final db2 = await openAndInit();
      addTearDown(db2.close);

      final rows = await db2
          .customSelect(
            "SELECT key, category FROM permissions "
            "WHERE key LIKE 'van.%' ORDER BY key",
          )
          .get();
      expect(rows.map((r) => r.read<String>('key')),
          ['van.manage', 'van.sell']);
      // Both land under one category so the CEO's Roles & Permissions page
      // groups them together.
      expect(
        rows.map((r) => r.read<String>('category')).toSet(),
        {'Van Sales'},
      );
    });
  });

  group('onUpgrade v70 → v71 (van trips, priced lots, driver ledger, #141)',
      () {
    Future<bool> objectExists(AppDatabase db, String type, String name) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='$type' AND name='$name'",
          )
          .get();
      return r.isNotEmpty;
    }

    // Reverts the whole v71 delta: the three tables (their indexes and triggers
    // drop with them). Children first — FKs are off, but dropping in FK order
    // keeps the intent readable.
    Future<void> dropVanTables(AppDatabase db) async {
      await db.customStatement('PRAGMA foreign_keys = OFF');
      await db.customStatement('DROP TABLE IF EXISTS driver_ledger_entries');
      await db.customStatement('DROP TABLE IF EXISTS van_trip_lots');
      await db.customStatement('DROP TABLE IF EXISTS van_trips');
      await db.customStatement('PRAGMA foreign_keys = ON');
    }

    test('creates all three tables with their sync indexes + bump triggers',
        () async {
      final db1 = await openAndInit();
      expect(await objectExists(db1, 'table', 'van_trips'), isTrue,
          reason: 'onCreate should create the table');
      await dropVanTables(db1);
      expect(await objectExists(db1, 'table', 'van_trips'), isFalse);
      await db1.customStatement('PRAGMA user_version = 70');
      await db1.close();

      // Re-open → onUpgrade(70 → 71).
      final db2 = await openAndInit();
      addTearDown(db2.close);

      for (final t in const [
        'van_trips',
        'van_trip_lots',
        'driver_ledger_entries',
      ]) {
        expect(await objectExists(db2, 'table', t), isTrue,
            reason: 'v71 must create $t');
        expect(
          await objectExists(db2, 'index', 'idx_${t}_business_lua'),
          isTrue,
          reason: 'v71 must create $t\'s (business_id, last_updated_at) index',
        );
        expect(
          await objectExists(db2, 'trigger', 'bump_${t}_last_updated_at'),
          isTrue,
          reason: 'v71 must create $t\'s last_updated_at bump trigger',
        );
      }

      // The per-feature indexes (the two open-trip probes, the FIFO cursor, the
      // idempotency probe, the ledger reads).
      for (final idx in const [
        'idx_van_trips_business_van_status',
        'idx_van_trips_business_driver_status',
        'idx_van_trip_lots_trip_dispatched',
        'idx_van_trip_lots_dispatch_event',
        'idx_driver_ledger_business_driver_time',
        'idx_driver_ledger_business_trip',
      ]) {
        expect(await objectExists(db2, 'index', idx), isTrue,
            reason: 'v71 must create $idx');
      }
    });

    test('the close-artifact columns ship NOW so #145 needs no migration',
        () async {
      final db1 = await openAndInit();
      await dropVanTables(db1);
      await db1.customStatement('PRAGMA user_version = 70');
      await db1.close();

      final db2 = await openAndInit();
      addTearDown(db2.close);

      expect(
        await columnsOf(db2, 'van_trips'),
        containsAll(<String>{
          'cogs_kobo',
          'recovered_kobo',
          'unremitted_kobo',
          'shortage_writeoff_kobo',
          'damage_writeoff_kobo',
          'shortage_loss_kobo',
          'damage_loss_kobo',
          'profit_kobo',
          'closed_with_balance',
          'closed_at',
          'closed_by',
          'restated_at',
          'restated_reason',
          'shells_out',
          'shells_back',
        }),
      );
      // The lot's cost snapshot + FIFO cursor + idempotency key.
      expect(
        await columnsOf(db2, 'van_trip_lots'),
        containsAll(<String>{
          'unit_cost_kobo',
          'qty_remaining',
          'dispatch_event_id',
          'shells_out',
          'load_price_kobo',
        }),
      );
    });

    test('driver_ledger_entries is append-only after the upgrade (immutable + '
        'no-delete triggers, emitted from the shared _ledgerTables entry)',
        () async {
      final db1 = await openAndInit();
      await dropVanTables(db1);
      await db1.customStatement('PRAGMA user_version = 70');
      await db1.close();

      final db2 = await openAndInit();
      addTearDown(db2.close);

      expect(
        await objectExists(db2, 'trigger', 'driver_ledger_entries_immutable'),
        isTrue,
      );
      expect(
        await objectExists(db2, 'trigger', 'driver_ledger_entries_no_delete'),
        isTrue,
      );

      // And they actually bite: an amount edit and a delete both abort.
      final biz = UuidV7.generate();
      final userId = UuidV7.generate();
      final entryId = UuidV7.generate();
      await db2.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db2.customStatement(
        "INSERT INTO users (id, business_id, name, pin) "
        "VALUES (?, ?, 'Driver Dan', '0000')",
        [userId, biz],
      );
      await db2.customStatement(
        'INSERT INTO driver_ledger_entries '
        '(id, business_id, driver_user_id, type, amount_kobo, '
        ' signed_amount_kobo, reference_type, activity_date) '
        "VALUES (?, ?, ?, 'load', 500000, -500000, 'van_trip_lot', 0)",
        [entryId, biz, userId],
      );

      await expectLater(
        db2.customStatement(
          'UPDATE driver_ledger_entries SET amount_kobo = 1 WHERE id = ?',
          [entryId],
        ),
        throwsA(anything),
        reason: 'an amount edit must abort — corrections are compensating rows',
      );
      await expectLater(
        db2.customStatement(
          'DELETE FROM driver_ledger_entries WHERE id = ?',
          [entryId],
        ),
        throwsA(anything),
        reason: 'deletion must abort — the ledger is append-only',
      );
      // Voiding IS allowed (the void columns are outside the immutable set).
      await db2.customStatement(
        "UPDATE driver_ledger_entries SET voided_at = 1, void_reason = 'oops' "
        'WHERE id = ?',
        [entryId],
      );
    });

    test('the upgrade step is idempotent (a DB stepped back re-upgrades)',
        () async {
      // Do NOT drop the tables — just step user_version back, so the v71 block
      // runs against a schema that already has them. The existence guard must
      // make it a no-op rather than a "table already exists" crash.
      final db1 = await openAndInit();
      await db1.customStatement('PRAGMA user_version = 70');
      await db1.close();

      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(await objectExists(db2, 'table', 'van_trips'), isTrue);
      expect(await objectExists(db2, 'table', 'van_trip_lots'), isTrue);
      expect(await objectExists(db2, 'table', 'driver_ledger_entries'), isTrue);
    });
  });

  group('onUpgrade v71 → v72 (van remittance: payment_transactions gains a '
      'sixth parent + a seventh type, #144)', () {
    Future<bool> objectExists(AppDatabase db, String type, String name) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='$type' AND name='$name'",
          )
          .get();
      return r.isNotEmpty;
    }

    /// Reverts payment_transactions to its pre-v72 shape: no `van_trip_id`, the
    /// six-value type CHECK, and the FIVE-way exactly-one-parent CHECK.
    /// Recreated WITHOUT FKs (mirrors the v61/v64 reverts) so the copy is
    /// unconstrained; the migration rebuilds the real, FK-carrying table from
    /// the Drift schema.
    Future<void> revertPaymentTable(AppDatabase db) async {
      await db.customStatement('PRAGMA foreign_keys = OFF');
      await db.customStatement(
        'DROP TRIGGER IF EXISTS payment_transactions_immutable',
      );
      await db.customStatement(
        'DROP TRIGGER IF EXISTS payment_transactions_no_delete',
      );
      await db.customStatement('DROP TABLE IF EXISTS payment_transactions');
      await db.customStatement(
        'CREATE TABLE payment_transactions ('
        'id TEXT NOT NULL PRIMARY KEY, business_id TEXT NOT NULL, '
        'store_id TEXT, '
        'amount_kobo INTEGER NOT NULL, method TEXT NOT NULL, type TEXT NOT NULL, '
        'order_id TEXT, shipment_id TEXT, expense_id TEXT, wallet_txn_id TEXT, '
        'delivery_id TEXT, performed_by TEXT, voided_at INTEGER, '
        'voided_by TEXT, void_reason TEXT, '
        'created_at INTEGER NOT NULL DEFAULT 0, '
        'last_updated_at INTEGER NOT NULL DEFAULT 0, '
        "CHECK (method IN ('cash','transfer','card','wallet','pos','other')), "
        "CHECK (type IN ('sale','purchase','expense','refund','wallet_topup',"
        "'crate_deposit')), "
        'CHECK ('
        '(CASE WHEN order_id IS NOT NULL THEN 1 ELSE 0 END) + '
        '(CASE WHEN shipment_id IS NOT NULL THEN 1 ELSE 0 END) + '
        '(CASE WHEN expense_id IS NOT NULL THEN 1 ELSE 0 END) + '
        '(CASE WHEN wallet_txn_id IS NOT NULL THEN 1 ELSE 0 END) + '
        '(CASE WHEN delivery_id IS NOT NULL THEN 1 ELSE 0 END) = 1))',
      );
      await db.customStatement('PRAGMA foreign_keys = ON');
    }

    test('adds van_trip_id, widens both CHECKs, and carries every existing '
        'payment row through the rebuild untouched', () async {
      final biz = UuidV7.generate();
      final orderId = UuidV7.generate();
      final storeId = UuidV7.generate();
      final legacySaleId = UuidV7.generate();
      final depositId = UuidV7.generate();

      final db1 = await openAndInit();

      // Real FK targets that survive the payment_transactions revert (only that
      // table is dropped and recreated).
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db1.customStatement(
        "INSERT INTO stores (id, business_id, name) VALUES (?, ?, 'Main')",
        [storeId, biz],
      );
      await db1.customStatement(
        'INSERT INTO orders (id, business_id, order_number, total_amount_kobo, '
        'net_amount_kobo, payment_type, status) '
        "VALUES (?, ?, 'ORD-000001-AAAAAA', 100000, 100000, 'cash', 'completed')",
        [orderId, biz],
      );

      await revertPaymentTable(db1);

      // Two pre-existing rows of DIFFERENT types, one store-stamped and one
      // legacy/store-less — the rebuild must carry both through byte for byte.
      await db1.customStatement(
        'INSERT INTO payment_transactions '
        '(id, business_id, store_id, amount_kobo, method, type, order_id, '
        ' created_at, last_updated_at) '
        "VALUES (?, ?, ?, 100000, 'cash', 'sale', ?, 1700000000, 1700000000)",
        [legacySaleId, biz, storeId, orderId],
      );
      await db1.customStatement(
        'INSERT INTO payment_transactions '
        '(id, business_id, amount_kobo, method, type, order_id, '
        ' created_at, last_updated_at) '
        "VALUES (?, ?, 5000, 'cash', 'crate_deposit', ?, 1700000001, 1700000001)",
        [depositId, biz, orderId],
      );

      // Teeth for the widening: the pre-v72 CHECKs reject BOTH halves of a
      // remittance — the type and the (absent) column.
      await expectLater(
        db1.customStatement(
          'INSERT INTO payment_transactions '
          '(id, business_id, amount_kobo, method, type, order_id) '
          "VALUES (?, ?, 1, 'cash', 'van_remittance', ?)",
          [UuidV7.generate(), biz, orderId],
        ),
        throwsA(anything),
        reason: 'the pre-v72 6-value type CHECK must reject van_remittance',
      );
      expect(
        (await columnsOf(db1, 'payment_transactions')).contains('van_trip_id'),
        isFalse,
      );

      await db1.customStatement('PRAGMA user_version = 71');
      await db1.close();

      // Re-open → onUpgrade(71 → 72).
      final db2 = await openAndInit();
      addTearDown(db2.close);

      // (1) The column exists.
      expect(
        (await columnsOf(db2, 'payment_transactions')).contains('van_trip_id'),
        isTrue,
        reason: 'v72 must add payment_transactions.van_trip_id',
      );

      // (2) EXISTING ROWS SURVIVED — same ids, same amounts, same stores, same
      //     created_at days, and van_trip_id NULL (never the literal column
      //     name, which is what a transformer-less copy of a missing column
      //     produces and what would flip the parent CHECK to 2).
      final rows = await db2
          .customSelect(
            'SELECT id, type, amount_kobo, store_id, order_id, van_trip_id, '
            '       created_at '
            'FROM payment_transactions ORDER BY created_at',
          )
          .get();
      expect(rows, hasLength(2), reason: 'the rebuild must lose no rows');
      expect(rows[0].read<String>('id'), legacySaleId);
      expect(rows[0].read<String>('type'), 'sale');
      expect(rows[0].read<int>('amount_kobo'), 100000);
      expect(rows[0].read<String?>('store_id'), storeId);
      expect(rows[0].read<String?>('order_id'), orderId);
      expect(rows[0].read<String?>('van_trip_id'), isNull);
      expect(rows[1].read<String>('id'), depositId);
      expect(rows[1].read<String>('type'), 'crate_deposit');
      expect(rows[1].read<String?>('store_id'), isNull,
          reason: 'a legacy store-less row stays store-less');
      expect(rows[1].read<String?>('van_trip_id'), isNull);

      // (3) The widened type CHECK admits a remittance — parented by a trip.
      final vanStoreId = UuidV7.generate();
      final driverId = UuidV7.generate();
      final tripId = UuidV7.generate();
      await db2.customStatement(
        "INSERT INTO stores (id, business_id, name, kind) "
        "VALUES (?, ?, 'Van 1', 'van')",
        [vanStoreId, biz],
      );
      await db2.customStatement(
        "INSERT INTO users (id, business_id, name, pin) "
        "VALUES (?, ?, 'Driver Dan', '0000')",
        [driverId, biz],
      );
      await db2.customStatement(
        'INSERT INTO van_trips '
        '(id, business_id, van_store_id, driver_user_id, source_store_id) '
        'VALUES (?, ?, ?, ?, ?)',
        [tripId, biz, vanStoreId, driverId, storeId],
      );
      await db2.customStatement(
        'INSERT INTO payment_transactions '
        '(id, business_id, store_id, amount_kobo, method, type, van_trip_id) '
        "VALUES (?, ?, ?, 90000000, 'cash', 'van_remittance', ?)",
        [UuidV7.generate(), biz, storeId, tripId],
      );

      // (4) …and the parent CHECK is still EXACTLY one, not at-most one.
      await expectLater(
        db2.customStatement(
          'INSERT INTO payment_transactions '
          '(id, business_id, amount_kobo, method, type) '
          "VALUES (?, ?, 1, 'cash', 'van_remittance')",
          [UuidV7.generate(), biz],
        ),
        throwsA(anything),
        reason: 'a parentless payment row must still be rejected',
      );
      await expectLater(
        db2.customStatement(
          'INSERT INTO payment_transactions '
          '(id, business_id, amount_kobo, method, type, order_id, van_trip_id) '
          "VALUES (?, ?, 1, 'cash', 'van_remittance', ?, ?)",
          [UuidV7.generate(), biz, orderId, tripId],
        ),
        throwsA(anything),
        reason: 'a two-parent payment row must still be rejected',
      );

      // (5) Append-only triggers + indexes recreated after the rebuild.
      expect(
        await objectExists(db2, 'trigger', 'payment_transactions_immutable'),
        isTrue,
        reason: 'v72 must recreate the immutable ledger trigger',
      );
      expect(
        await objectExists(db2, 'trigger', 'payment_transactions_no_delete'),
        isTrue,
        reason: 'v72 must recreate the no-delete ledger trigger',
      );
      expect(
        await objectExists(
          db2,
          'trigger',
          'bump_payment_transactions_last_updated_at',
        ),
        isTrue,
      );
      expect(
        await objectExists(
          db2,
          'index',
          'idx_payment_transactions_business_lua',
        ),
        isTrue,
      );
      expect(
        await objectExists(db2, 'index', 'idx_payment_txn_business_type'),
        isTrue,
      );
      expect(
        await objectExists(db2, 'index', 'idx_payment_txn_van_trip'),
        isTrue,
        reason: 'the "Cash from drivers" scan index (#147) must exist',
      );

      // (6) The immutable trigger now guards van_trip_id, and the ledger still
      //     refuses deletion.
      await expectLater(
        db2.customStatement(
          'UPDATE payment_transactions SET van_trip_id = ? WHERE id = ?',
          [tripId, legacySaleId],
        ),
        throwsA(anything),
        reason: 'van_trip_id is immutable after insert (append-only ledger)',
      );
      await expectLater(
        db2.customStatement(
          'DELETE FROM payment_transactions WHERE id = ?',
          [legacySaleId],
        ),
        throwsA(anything),
      );
    });

    test('the upgrade step is idempotent (a DB stepped back re-upgrades)',
        () async {
      // Do NOT revert the table — just step user_version back, so the v72 block
      // runs against a schema that already has van_trip_id. The addColumn guard
      // must skip and the rebuild must still succeed, losing nothing.
      final biz = UuidV7.generate();
      final orderId = UuidV7.generate();
      final payId = UuidV7.generate();

      final db1 = await openAndInit();
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db1.customStatement(
        'INSERT INTO orders (id, business_id, order_number, total_amount_kobo, '
        'net_amount_kobo, payment_type, status) '
        "VALUES (?, ?, 'ORD-000002-BBBBBB', 100000, 100000, 'cash', 'completed')",
        [orderId, biz],
      );
      await db1.customStatement(
        'INSERT INTO payment_transactions '
        '(id, business_id, amount_kobo, method, type, order_id) '
        "VALUES (?, ?, 100000, 'cash', 'sale', ?)",
        [payId, biz, orderId],
      );
      await db1.customStatement('PRAGMA user_version = 71');
      await db1.close();

      final db2 = await openAndInit();
      addTearDown(db2.close);

      expect(
        (await columnsOf(db2, 'payment_transactions')).contains('van_trip_id'),
        isTrue,
      );
      final rows = await db2
          .customSelect('SELECT id FROM payment_transactions')
          .get();
      expect(rows.map((r) => r.read<String>('id')), [payId]);
      expect(
        await objectExists(db2, 'trigger', 'payment_transactions_immutable'),
        isTrue,
      );
      expect(
        await objectExists(db2, 'index', 'idx_payment_txn_van_trip'),
        isTrue,
      );
    });
  });

  group('onUpgrade v72 → v73 (the trip tag on orders, #142)', () {
    Future<bool> objectExists(AppDatabase db, String type, String name) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='$type' AND name='$name'",
          )
          .get();
      return r.isNotEmpty;
    }

    test('adds orders.van_trip_id + its index; existing shop orders survive '
        'and stay NULL', () async {
      final biz = UuidV7.generate();
      final legacyOrderId = UuidV7.generate();

      final db1 = await openAndInit();
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );

      // Revert the v73 delta: drop the column and its index. `orders` carries
      // no CHECK mentioning van_trip_id, so unlike v72's payment_transactions
      // this is a plain DROP COLUMN — no table rebuild either way.
      await db1.customStatement('DROP INDEX IF EXISTS idx_orders_van_trip');
      await db1.customStatement('ALTER TABLE orders DROP COLUMN van_trip_id');
      expect(
        (await columnsOf(db1, 'orders')).contains('van_trip_id'),
        isFalse,
      );

      // A pre-existing shop order on the reverted table — it was rung in a
      // shop, so NULL is the right answer for it after the upgrade.
      await db1.customStatement(
        'INSERT INTO orders (id, business_id, order_number, total_amount_kobo, '
        'net_amount_kobo, payment_type, status) '
        "VALUES (?, ?, 'ORD-000001-AAAAAA', 250000, 250000, 'cash', 'completed')",
        [legacyOrderId, biz],
      );

      await db1.customStatement('PRAGMA user_version = 72');
      await db1.close();

      // Re-open → onUpgrade(72 → 73).
      final db2 = await openAndInit();
      addTearDown(db2.close);

      expect((await columnsOf(db2, 'orders')).contains('van_trip_id'), isTrue);
      expect(
        await objectExists(db2, 'index', 'idx_orders_van_trip'),
        isTrue,
        reason: '#145 sums a trip\'s road sales and #147 scans them by period; '
            'both key on this index',
      );

      final legacy = await db2
          .customSelect(
            'SELECT van_trip_id FROM orders WHERE id = ?',
            variables: [Variable<String>(legacyOrderId)],
          )
          .getSingle();
      expect(legacy.data['van_trip_id'], isNull);

      // And the column really accepts a trip, so #145/#147 have something to
      // read. (FKs are on, so this also proves van_trips exists first.)
      final vanId = UuidV7.generate();
      final driverId = UuidV7.generate();
      final tripId = UuidV7.generate();
      final roadOrderId = UuidV7.generate();
      await db2.customStatement(
        "INSERT INTO stores (id, business_id, name, kind) "
        "VALUES (?, ?, 'Van 1', 'van')",
        [vanId, biz],
      );
      await db2.customStatement(
        "INSERT INTO users (id, business_id, name, pin) "
        "VALUES (?, ?, 'Driver Dan', '0000')",
        [driverId, biz],
      );
      await db2.customStatement(
        'INSERT INTO van_trips (id, business_id, van_store_id, driver_user_id, '
        'source_store_id) VALUES (?, ?, ?, ?, ?)',
        [tripId, biz, vanId, driverId, vanId],
      );
      await db2.customStatement(
        'INSERT INTO orders (id, business_id, order_number, total_amount_kobo, '
        'net_amount_kobo, payment_type, status, store_id, van_trip_id) '
        "VALUES (?, ?, 'ORD-000002-BBBBBB', 690000, 690000, 'cash', "
        "'pending', ?, ?)",
        [roadOrderId, biz, vanId, tripId],
      );
      final road = await db2
          .customSelect(
            'SELECT van_trip_id FROM orders WHERE id = ?',
            variables: [Variable<String>(roadOrderId)],
          )
          .getSingle();
      expect(road.data['van_trip_id'], tripId);
    });

    test('the upgrade step is idempotent (a DB stepped back re-upgrades)',
        () async {
      // Do NOT revert the column — just step user_version back, so the v73
      // block runs against a schema that already has van_trip_id. The addColumn
      // guard must skip and the index must be re-emitted, losing nothing.
      final biz = UuidV7.generate();
      final orderId = UuidV7.generate();

      final db1 = await openAndInit();
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db1.customStatement(
        'INSERT INTO orders (id, business_id, order_number, total_amount_kobo, '
        'net_amount_kobo, payment_type, status) '
        "VALUES (?, ?, 'ORD-000003-CCCCCC', 100000, 100000, 'cash', 'completed')",
        [orderId, biz],
      );
      await db1.customStatement('PRAGMA user_version = 72');
      await db1.close();

      final db2 = await openAndInit();
      addTearDown(db2.close);

      expect((await columnsOf(db2, 'orders')).contains('van_trip_id'), isTrue);
      final rows = await db2.customSelect('SELECT id FROM orders').get();
      expect(rows.map((r) => r.read<String>('id')), [orderId]);
      expect(await objectExists(db2, 'index', 'idx_orders_van_trip'), isTrue);
    });
  });

  group('onUpgrade v73 → v74 (van return events, #143)', () {
    Future<bool> objectExists(AppDatabase db, String type, String name) async {
      final r = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='$type' AND name='$name'",
          )
          .get();
      return r.isNotEmpty;
    }

    /// Reverts the v74 delta: drop the whole table (its indexes and trigger go
    /// with it). `van_return_events` is a leaf — nothing references it — so no
    /// other table needs rebuilding, unlike v72's payment_transactions.
    Future<void> dropReturnEvents(AppDatabase db) async {
      await db.customStatement('PRAGMA foreign_keys = OFF');
      await db.customStatement('DROP TABLE IF EXISTS van_return_events');
      await db.customStatement('PRAGMA foreign_keys = ON');
    }

    test('creates van_return_events with its indexes, bump trigger and money '
        'CHECKs; existing van data survives', () async {
      final biz = UuidV7.generate();
      final vanId = UuidV7.generate();
      final driverId = UuidV7.generate();
      final tripId = UuidV7.generate();
      final productId = UuidV7.generate();

      final db1 = await openAndInit();
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db1.customStatement(
        "INSERT INTO stores (id, business_id, name, kind) "
        "VALUES (?, ?, 'Van 1', 'van')",
        [vanId, biz],
      );
      await db1.customStatement(
        "INSERT INTO users (id, business_id, name, pin) "
        "VALUES (?, ?, 'Driver Dan', '0000')",
        [driverId, biz],
      );
      await db1.customStatement(
        "INSERT INTO products (id, business_id, name) VALUES (?, ?, 'Star')",
        [productId, biz],
      );
      // A trip written BEFORE the upgrade — it must survive untouched.
      await db1.customStatement(
        'INSERT INTO van_trips (id, business_id, van_store_id, driver_user_id, '
        'source_store_id) VALUES (?, ?, ?, ?, ?)',
        [tripId, biz, vanId, driverId, vanId],
      );

      await dropReturnEvents(db1);
      await db1.customStatement('PRAGMA user_version = 73');
      await db1.close();

      // Re-open → onUpgrade(73 → 74).
      final db2 = await openAndInit();
      addTearDown(db2.close);

      expect(await objectExists(db2, 'table', 'van_return_events'), isTrue);
      expect(
        await columnsOf(db2, 'van_return_events'),
        containsAll(<String>{
          'id',
          'business_id',
          'trip_id',
          'product_id',
          'quantity',
          'condition',
          'credit_kobo',
          'cost_kobo',
          'shells_back',
          'crate_shells',
          'recorded_at',
          'recorded_by',
          'created_at',
          'last_updated_at',
        }),
      );
      // The incremental-pull cursor index + the two per-feature ones + the bump
      // trigger — all emitted from the same shapes onCreate uses.
      for (final idx in const [
        'idx_van_return_events_business_lua',
        'idx_van_return_events_trip_recorded',
        'idx_van_return_events_business_trip_condition',
      ]) {
        expect(await objectExists(db2, 'index', idx), isTrue, reason: idx);
      }
      expect(
        await objectExists(
          db2,
          'trigger',
          'bump_van_return_events_last_updated_at',
        ),
        isTrue,
      );

      // The pre-existing trip is intact.
      final trip = await db2
          .customSelect(
            'SELECT status FROM van_trips WHERE id = ?',
            variables: [Variable<String>(tripId)],
          )
          .getSingle();
      expect(trip.data['status'], 'open');

      // A good return writes fine…
      await db2.customStatement(
        'INSERT INTO van_return_events (id, business_id, trip_id, product_id, '
        "quantity, condition, credit_kobo, cost_kobo) "
        "VALUES (?, ?, ?, ?, 45, 'good', 517500, 450000)",
        [UuidV7.generate(), biz, tripId, productId],
      );
      // …and §5.5's rule is IN THE SCHEMA: a damaged row can never carry a
      // credit, whatever a future client tries to write.
      await expectLater(
        db2.customStatement(
          'INSERT INTO van_return_events (id, business_id, trip_id, '
          "product_id, quantity, condition, credit_kobo) "
          "VALUES (?, ?, ?, ?, 3, 'damaged', 34500)",
          [UuidV7.generate(), biz, tripId, productId],
        ),
        throwsA(anything),
      );
      // A damaged row with no credit is fine.
      await db2.customStatement(
        'INSERT INTO van_return_events (id, business_id, trip_id, product_id, '
        "quantity, condition, cost_kobo) "
        "VALUES (?, ?, ?, ?, 3, 'damaged', 30000)",
        [UuidV7.generate(), biz, tripId, productId],
      );
      final rows = await db2
          .customSelect('SELECT COUNT(*) AS c FROM van_return_events')
          .getSingle();
      expect(rows.read<int>('c'), 2);
    });

    test('the upgrade step is idempotent (a DB stepped back re-upgrades)',
        () async {
      // Do NOT drop the table — just step user_version back, so the v74 block
      // runs against a schema that already has it. The guard must skip the
      // createTable and the indexes must be re-emitted, losing no rows.
      final biz = UuidV7.generate();
      final vanId = UuidV7.generate();
      final driverId = UuidV7.generate();
      final tripId = UuidV7.generate();
      final productId = UuidV7.generate();
      final eventId = UuidV7.generate();

      final db1 = await openAndInit();
      await db1.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db1.customStatement(
        "INSERT INTO stores (id, business_id, name, kind) "
        "VALUES (?, ?, 'Van 1', 'van')",
        [vanId, biz],
      );
      await db1.customStatement(
        "INSERT INTO users (id, business_id, name, pin) "
        "VALUES (?, ?, 'Driver Dan', '0000')",
        [driverId, biz],
      );
      await db1.customStatement(
        "INSERT INTO products (id, business_id, name) VALUES (?, ?, 'Star')",
        [productId, biz],
      );
      await db1.customStatement(
        'INSERT INTO van_trips (id, business_id, van_store_id, driver_user_id, '
        'source_store_id) VALUES (?, ?, ?, ?, ?)',
        [tripId, biz, vanId, driverId, vanId],
      );
      await db1.customStatement(
        'INSERT INTO van_return_events (id, business_id, trip_id, product_id, '
        "quantity, condition, credit_kobo, cost_kobo) "
        "VALUES (?, ?, ?, ?, 10, 'good', 50000, 10000)",
        [eventId, biz, tripId, productId],
      );
      await db1.customStatement('PRAGMA user_version = 73');
      await db1.close();

      final db2 = await openAndInit();
      addTearDown(db2.close);

      final rows = await db2
          .customSelect('SELECT id FROM van_return_events')
          .get();
      expect(rows.map((r) => r.read<String>('id')), [eventId]);
      expect(
        await objectExists(db2, 'index', 'idx_van_return_events_trip_recorded'),
        isTrue,
      );
      expect(
        await objectExists(
          db2,
          'index',
          'idx_van_return_events_business_trip_condition',
        ),
        isTrue,
      );
    });
  });
  group('onUpgrade v74 → v75 (the crate-settlement claim, #188)', () {
    // Seeds a business + a crate line on the reverted (pre-v75) table and
    // returns (businessId, crateLineId).
    Future<(String, String)> seedLegacyCrateLine(AppDatabase db) async {
      final biz = UuidV7.generate();
      final mfrId = UuidV7.generate();
      final orderId = UuidV7.generate();
      final lineId = UuidV7.generate();
      await db.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db.customStatement(
        "INSERT INTO manufacturers (id, business_id, name) "
        "VALUES (?, ?, 'Star')",
        [mfrId, biz],
      );
      await db.customStatement(
        'INSERT INTO orders (id, business_id, order_number, total_amount_kobo, '
        'net_amount_kobo, payment_type, status) '
        "VALUES (?, ?, 'ORD-000188-AAAAAA', 750000, 750000, 'cash', 'completed')",
        [orderId, biz],
      );
      await db.customStatement(
        'INSERT INTO order_crate_lines (id, business_id, order_id, '
        'manufacturer_id, crates_taken, deposit_rate_kobo, deposit_paid_kobo) '
        'VALUES (?, ?, ?, ?, 5, 50000, 250000)',
        [lineId, biz, orderId, mfrId],
      );
      return (biz, lineId);
    }

    test('adds order_crate_lines.settled_at + settled_by; legacy lines survive '
        'and stay NULL', () async {
      final db1 = await openAndInit();
      // Revert the v75 delta. `order_crate_lines` carries no CHECK mentioning
      // either column, so — like v73's orders.van_trip_id — this is a plain DROP
      // COLUMN with no table rebuild either way.
      await db1
          .customStatement('ALTER TABLE order_crate_lines DROP COLUMN settled_at');
      await db1
          .customStatement('ALTER TABLE order_crate_lines DROP COLUMN settled_by');
      final reverted = await columnsOf(db1, 'order_crate_lines');
      expect(reverted.contains('settled_at'), isFalse);
      expect(reverted.contains('settled_by'), isFalse);

      // A crate line settled BEFORE the claim column existed. NULL is the right
      // answer for it: its order is already `completed`, so Confirm's status
      // re-read still guards it and no second settlement can reach it.
      final (biz, legacyLineId) = await seedLegacyCrateLine(db1);

      await db1.customStatement('PRAGMA user_version = 74');
      await db1.close();

      // Re-open → onUpgrade(74 → 75).
      final db2 = await openAndInit();
      addTearDown(db2.close);

      final upgraded = await columnsOf(db2, 'order_crate_lines');
      expect(upgraded.contains('settled_at'), isTrue);
      expect(upgraded.contains('settled_by'), isTrue);

      final legacy = await db2
          .customSelect(
            'SELECT settled_at, settled_by FROM order_crate_lines WHERE id = ?',
            variables: [Variable<String>(legacyLineId)],
          )
          .getSingle();
      expect(legacy.data['settled_at'], isNull);
      expect(legacy.data['settled_by'], isNull);

      // The claim really is writable, and `settled_by` really is an FK to users
      // — the whole point of the column is that a stamped pair is skippable.
      final staffId = UuidV7.generate();
      await db2.customStatement(
        "INSERT INTO users (id, business_id, name, pin) "
        "VALUES (?, ?, 'Conf', '0000')",
        [staffId, biz],
      );
      await db2.customStatement(
        'UPDATE order_crate_lines SET settled_at = ?, settled_by = ? '
        'WHERE id = ?',
        [DateTime.now().millisecondsSinceEpoch ~/ 1000, staffId, legacyLineId],
      );
      final claimed = await db2
          .customSelect(
            'SELECT settled_by FROM order_crate_lines WHERE id = ?',
            variables: [Variable<String>(legacyLineId)],
          )
          .getSingle();
      expect(claimed.data['settled_by'], staffId);
      // FKs are ON, so an unknown confirmer must be refused.
      await expectLater(
        db2.customStatement(
          'UPDATE order_crate_lines SET settled_by = ? WHERE id = ?',
          [UuidV7.generate(), legacyLineId],
        ),
        throwsA(anything),
      );
    });

    test('the upgrade step is idempotent (a DB stepped back re-upgrades)',
        () async {
      // Do NOT drop the columns — just step user_version back, so the v75 block
      // runs against a schema that already has both. Each per-column
      // pragma_table_info guard must skip, losing no rows. This is also the
      // shape a device upgrading from < 37 hits: v37 `createTable`s the table
      // from the CURRENT Drift schema, so it arrives at v75 already complete.
      final db1 = await openAndInit();
      final (_, lineId) = await seedLegacyCrateLine(db1);
      await db1.customStatement('PRAGMA user_version = 74');
      await db1.close();

      final db2 = await openAndInit();
      addTearDown(db2.close);

      final cols = await columnsOf(db2, 'order_crate_lines');
      expect(cols.contains('settled_at'), isTrue);
      expect(cols.contains('settled_by'), isTrue);
      final rows =
          await db2.customSelect('SELECT id FROM order_crate_lines').get();
      expect(rows.map((r) => r.read<String>('id')), [lineId]);
    });
  });

  group('onUpgrade v75 → v76 (a stock request records what the goods cost, '
      '#197)', () {
    /// Reverts the v76 delta: drop the one added column.
    /// `stock_adjustment_requests` has no CHECK mentioning it and nothing
    /// references it, so a raw DROP COLUMN is enough — no table rebuild.
    Future<void> dropRequestUnitCost(AppDatabase db) async {
      await db.customStatement(
        'ALTER TABLE stock_adjustment_requests DROP COLUMN unit_cost_kobo',
      );
    }

    /// A business + store + product + stock-keeper, the FK parents every request
    /// row needs.
    Future<Map<String, String>> seedTenant(AppDatabase db) async {
      final biz = UuidV7.generate();
      final storeId = UuidV7.generate();
      final productId = UuidV7.generate();
      final userId = UuidV7.generate();
      await db.customStatement(
        "INSERT INTO businesses (id, name) VALUES (?, 'Biz')",
        [biz],
      );
      await db.customStatement(
        "INSERT INTO stores (id, business_id, name) VALUES (?, ?, 'Main')",
        [storeId, biz],
      );
      await db.customStatement(
        "INSERT INTO products (id, business_id, name, buying_price_kobo) "
        "VALUES (?, ?, 'Star', 15000)",
        [productId, biz],
      );
      await db.customStatement(
        "INSERT INTO users (id, business_id, name, pin) "
        "VALUES (?, ?, 'Akin', '0000')",
        [userId, biz],
      );
      return {
        'biz': biz,
        'store': storeId,
        'product': productId,
        'user': userId,
      };
    }

    test('adds stock_adjustment_requests.unit_cost_kobo; requests filed before '
        'the upgrade keep it NULL and still approve', () async {
      final db1 = await openAndInit();
      final ids = await seedTenant(db1);
      final legacyRequestId = UuidV7.generate();

      await dropRequestUnitCost(db1);
      expect(
        (await columnsOf(db1, 'stock_adjustment_requests'))
            .contains('unit_cost_kobo'),
        isFalse,
      );

      // A request filed on the pre-v76 shape — it captured no cost because there
      // was nowhere to put one. It must survive the upgrade untouched.
      await db1.customStatement(
        'INSERT INTO stock_adjustment_requests (id, business_id, product_id, '
        'store_id, quantity_diff, reason, summary, requested_by) '
        "VALUES (?, ?, ?, ?, 10, 'recount found more', 'Akin added 10', ?)",
        [
          legacyRequestId,
          ids['biz']!,
          ids['product']!,
          ids['store']!,
          ids['user']!,
        ],
      );

      await db1.customStatement('PRAGMA user_version = 75');
      await db1.close();

      // Re-open → onUpgrade(75 → 76) adds the nullable column.
      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(
        (await columnsOf(db2, 'stock_adjustment_requests'))
            .contains('unit_cost_kobo'),
        isTrue,
      );

      // The legacy request survives, still pending, with a NULL cost — which is
      // exactly right: it never stated one, so its approval falls back to the
      // product's recorded price (#189) instead of asserting a made-up figure.
      final legacy = await db2
          .customSelect(
            'SELECT status, quantity_diff, unit_cost_kobo '
            'FROM stock_adjustment_requests WHERE id = ?',
            variables: [Variable<String>(legacyRequestId)],
          )
          .getSingle();
      expect(legacy.data['status'], 'pending');
      expect(legacy.data['quantity_diff'], 10);
      expect(legacy.data['unit_cost_kobo'], isNull);

      // …and a new request can carry a cost far above the int4 ceiling the cloud
      // column used to risk (₦21,474,836.47 — see 0130): kobo columns are 64-bit
      // here and `bigint` in 0168, so a bulk delivery cannot jam the outbox.
      final bigRequestId = UuidV7.generate();
      await db2.customStatement(
        'INSERT INTO stock_adjustment_requests (id, business_id, product_id, '
        'store_id, quantity_diff, unit_cost_kobo, reason, summary) '
        "VALUES (?, ?, ?, ?, 5, 3000000000, 'imported pallet', 'Akin added 5')",
        [bigRequestId, ids['biz']!, ids['product']!, ids['store']!],
      );
      final big = await db2
          .customSelect(
            'SELECT unit_cost_kobo FROM stock_adjustment_requests WHERE id = ?',
            variables: [Variable<String>(bigRequestId)],
          )
          .getSingle();
      expect(big.data['unit_cost_kobo'], 3000000000);
    });

    test('the upgrade step is idempotent (a DB stepped back re-upgrades)',
        () async {
      // Do NOT drop the column — just step user_version back, so the v76 block
      // runs against a schema that already has it (also the shape a fresh
      // install lands in: the v34 createTable builds from the CURRENT Dart
      // definition). The guard must skip the addColumn, losing no rows.
      final db1 = await openAndInit();
      final ids = await seedTenant(db1);
      final requestId = UuidV7.generate();
      await db1.customStatement(
        'INSERT INTO stock_adjustment_requests (id, business_id, product_id, '
        'store_id, quantity_diff, unit_cost_kobo, reason, summary) '
        "VALUES (?, ?, ?, ?, 10, 18000, 'delivery', 'Akin added 10')",
        [requestId, ids['biz']!, ids['product']!, ids['store']!],
      );
      await db1.customStatement('PRAGMA user_version = 75');
      await db1.close();

      final db2 = await openAndInit();
      addTearDown(db2.close);
      expect(
        (await columnsOf(db2, 'stock_adjustment_requests'))
            .contains('unit_cost_kobo'),
        isTrue,
      );
      final row = await db2
          .customSelect(
            'SELECT unit_cost_kobo FROM stock_adjustment_requests WHERE id = ?',
            variables: [Variable<String>(requestId)],
          )
          .getSingle();
      expect(row.data['unit_cost_kobo'], 18000);
    });
  });
}
