// background_connection_test.dart
//
// #687 (PRD #680 S6): the app's database behaviour through the real background
// connection on a temporary file, plus the cloud off switch. The in-memory test
// databases elsewhere run on the test's own thread and cannot see any of this.

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/local_database_connection.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/db_worker_switch_watcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('reeba_bg_db_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Opens the way the app does: a lazy connection, in the remembered home.
  Future<AppDatabase> openDb() async {
    final db = AppDatabase.forTesting(
      LazyDatabase(() => openRememberedLocalDatabase(dir)),
    );
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();
    return db;
  }

  group('through the background connection', () {
    late AppDatabase db;
    late String biz;
    late String mfr;
    late String customer;
    late String staff;

    setUp(() async {
      db = await openDb();
      biz = UuidV7.generate();
      mfr = UuidV7.generate();
      customer = UuidV7.generate();
      staff = UuidV7.generate();
      db.businessIdResolver = () => biz;
      await db
          .into(db.businesses)
          .insert(BusinessesCompanion.insert(id: Value(biz), name: 'Shop'));
      await db
          .into(db.manufacturers)
          .insert(
            ManufacturersCompanion.insert(
              id: Value(mfr),
              businessId: biz,
              name: 'Brand',
            ),
          );
      await db
          .into(db.customers)
          .insert(
            CustomersCompanion.insert(
              id: Value(customer),
              businessId: biz,
              name: 'Ada',
            ),
          );
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: Value(staff),
              businessId: biz,
              name: 'Staff',
              pin: '__INIT__',
            ),
          );
    });

    test('the open steps ran on the connection', () async {
      Future<Object?> pragma(String name) async => (await db
          .customSelect('PRAGMA $name')
          .getSingle()).data.values.first;

      expect(await pragma('journal_mode'), 'wal');
      expect(await pragma('synchronous'), 1);
      expect(await pragma('cache_size'), -8000);
      expect(await pragma('temp_store'), 2);
      expect(await pragma('foreign_keys'), 1);
    });

    test('a unique clash is still recognised, by its text', () async {
      await db.ensurePermissionsSeeded();
      final key = (await db.select(db.permissions).get()).first.key;
      final role = UuidV7.generate();
      await db
          .into(db.roles)
          .insert(
            RolesCompanion.insert(
              id: Value(role),
              businessId: biz,
              name: 'CEO',
              slug: 'ceo',
            ),
          );
      Future<void> grant() => db
          .into(db.rolePermissions)
          .insert(
            RolePermissionsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: biz,
              roleId: role,
              permissionKey: key,
            ),
          );
      await grant();

      final error = await grant().then<Object?>((_) => null, onError: (e) => e);

      expect(error, isNot(isA<SqliteException>()), reason: 'wrapped');
      expect(SyncRestoreExecutor.isUniqueConstraintViolation(error!), isTrue);
      expect(SyncRestoreExecutor.isForeignKeyViolation(error), isFalse);
      expect(error.toString(), contains('2067'));
    });

    test('a foreign-key failure is still recognised, by its text', () async {
      final error = await db
          .into(db.manufacturers)
          .insert(
            ManufacturersCompanion.insert(
              businessId: UuidV7.generate(),
              name: 'Nobody',
            ),
          )
          .then<Object?>((_) => null, onError: (e) => e);

      expect(error, isNot(isA<SqliteException>()), reason: 'wrapped');
      expect(SyncRestoreExecutor.isForeignKeyViolation(error!), isTrue);
      expect(SyncRestoreExecutor.isUniqueConstraintViolation(error), isFalse);
      expect(error.toString(), contains('787'));
    });

    test('the logout wipe empties every table, restores the delete guards '
        'and reseeds permissions', () async {
      Future<List<String>> triggers() async {
        final rows = await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'trigger' "
              'ORDER BY name',
            )
            .get();
        return rows.map((r) => r.read<String>('name')).toList();
      }

      Future<void> crateRow() => db.cratePoolDao.addEmptiesToPool(mfr, 1);

      await crateRow();
      expect(await db.select(db.crateLedger).get(), isNotEmpty);
      final before = await triggers();
      expect(before, contains('crate_ledger_no_delete'));

      await db.clearAllData();

      for (final table in db.allTables) {
        final count = await db
            .customSelect('SELECT COUNT(*) AS n FROM ${table.actualTableName}')
            .getSingle();
        if (table.actualTableName == 'permissions') {
          expect(count.read<int>('n'), greaterThan(0), reason: 'reseeded');
        } else {
          expect(count.read<int>('n'), 0, reason: table.actualTableName);
        }
      }
      expect(await triggers(), before);
      final fk = await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(fk.data.values.first, 1);

      // The guard really is back: the same connection refuses a ledger delete.
      await db
          .into(db.businesses)
          .insert(BusinessesCompanion.insert(id: Value(biz), name: 'Shop'));
      await db
          .into(db.manufacturers)
          .insert(
            ManufacturersCompanion.insert(
              id: Value(mfr),
              businessId: biz,
              name: 'Brand',
            ),
          );
      await crateRow();
      await expectLater(
        db.customStatement('DELETE FROM crate_ledger'),
        throwsA(anything),
      );
    });

    test('a live list emits again after a save', () async {
      final seen = <int>[];
      final twoRows = Completer<void>();
      final sub = db.select(db.manufacturers).watch().listen((rows) {
        seen.add(rows.length);
        if (rows.length == 2 && !twoRows.isCompleted) twoRows.complete();
      });
      addTearDown(sub.cancel);

      await db
          .into(db.manufacturers)
          .insert(ManufacturersCompanion.insert(businessId: biz, name: 'Next'));

      await twoRows.future.timeout(const Duration(seconds: 5));
      expect(seen.last, 2);
    });

    test('a failed Record Return leaves nothing, and a retry counts it '
        'once (#659)', () async {
      Future<double> stock() async {
        final row = await (db.select(
          db.manufacturers,
        )..where((m) => m.id.equals(mfr))).getSingle();
        return row.emptyCrateStock;
      }

      // The same steps as the customer screen's Record Return.
      Future<void> save() => db.transaction(() async {
        await db.inventoryDao.addEmptyCrates(mfr, 2);
        await db.cratePoolDao.recordCrateReturnByCustomer(
          customerId: customer,
          manufacturerId: mfr,
          quantity: 2,
          performedBy: staff,
        );
        await db.activityLogDao.logActivity(
          action: 'crate_return',
          description: '2 crates returned',
          staffId: staff,
          entityType: 'customer',
          entityId: customer,
        );
      });

      final stockBefore = await stock();
      final ledgerBefore = (await db.select(db.crateLedger).get()).length;
      final queueBefore = (await db.select(db.syncQueue).get()).length;

      // The empties write succeeds, then the customer's return write fails.
      await db.customStatement(
        'CREATE TRIGGER fail_return BEFORE INSERT ON crate_ledger '
        'WHEN NEW.customer_id IS NOT NULL '
        "BEGIN SELECT RAISE(ABORT, 'boom'); END",
      );
      await expectLater(save(), throwsA(anything));

      expect(await stock(), stockBefore);
      expect(await db.select(db.crateLedger).get(), hasLength(ledgerBefore));
      expect(await db.select(db.syncQueue).get(), hasLength(queueBefore));
      expect(await db.select(db.activityLogs).get(), isEmpty);

      await db.customStatement('DROP TRIGGER fail_return');
      await save();
      expect(await stock(), stockBefore + 2);
    });
  });

  group('off switch', () {
    Future<QueryExecutor> nextOpen() => openRememberedLocalDatabase(dir);
    File switchFile() => File('${dir.path}/$kDbWorkerSwitchFileName');

    test('with nothing remembered, the background worker opens', () async {
      expect(await nextOpen(), isNot(isA<NativeDatabase>()));
    });

    test('a remembered off opens the old on-screen-thread connection, and '
        'a remembered on the worker', () async {
      await DbWorkerSwitch(dir).remember(false);
      expect(await nextOpen(), isA<NativeDatabase>());

      await DbWorkerSwitch(dir).remember(true);
      expect(await nextOpen(), isNot(isA<NativeDatabase>()));
    });

    test('junk or an unreadable memory means the background worker', () async {
      switchFile().writeAsStringSync('maybe');
      expect(await nextOpen(), isNot(isA<NativeDatabase>()));

      switchFile().deleteSync();
      Directory(switchFile().path).createSync();
      expect(await nextOpen(), isNot(isA<NativeDatabase>()));
    });

    test('the off path really opens and saves', () async {
      await DbWorkerSwitch(dir).remember(false);
      final db = await openDb();
      expect(await db.select(db.permissions).get(), isNotEmpty);
    });

    test('a new cloud value only takes effect at the next open', () async {
      final db = await openDb();
      final watcher = DbWorkerSwitchWatcher(
        fetch: () async => false,
        directory: () async => dir,
      );
      await watcher.check();

      // Still the same working connection, on the worker.
      expect(
        (await db
                .customSelect('SELECT 1 AS one')
                .getSingle())
            .read<int>('one'),
        1,
      );
      expect(await nextOpen(), isA<NativeDatabase>());
    });

    test('no answer from the cloud keeps the last one', () async {
      await DbWorkerSwitch(dir).remember(false);
      await DbWorkerSwitchWatcher(
        fetch: () async => null,
        directory: () async => dir,
      ).check();
      expect(await nextOpen(), isA<NativeDatabase>());
    });

    test('a failed read cannot escape', () async {
      await DbWorkerSwitchWatcher(
        fetch: () => Future<bool?>.error(StateError('offline')),
        directory: () async => dir,
      ).check();
      expect(await nextOpen(), isNot(isA<NativeDatabase>()));
    });

    test('opening the app never waits on the network', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cloud = Completer<bool?>(); // never answers
      final watcher = DbWorkerSwitchWatcher(
        fetch: () => cloud.future,
        directory: () async => dir,
      );
      addTearDown(() {
        cloud.complete(null);
      });

      watcher.start();
      final db = await openDb().timeout(const Duration(seconds: 30));

      expect(await db.select(db.permissions).get(), isNotEmpty);
    });

    test('launch and resume reads are debounced', () async {
      var reads = 0;
      final watcher = DbWorkerSwitchWatcher(
        fetch: () async {
          reads++;
          return true;
        },
        directory: () async => dir,
      );
      await watcher.check();
      await watcher.check();
      expect(reads, 1);
    });
  });
}
