import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String biz1;
  late String biz2;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    biz1 = UuidV7.generate();
    biz2 = UuidV7.generate();

    await db.into(db.businesses).insert(BusinessesCompanion.insert(
          id: Value(biz1),
          name: 'Biz 1',
        ));
    await db.into(db.businesses).insert(BusinessesCompanion.insert(
          id: Value(biz2),
          name: 'Biz 2',
        ));
  });

  tearDown(() => db.close());

  group('SettingsDao Scoping', () {
    test('Settings are tenant-scoped', () async {
      // Set for biz 1
      db.businessIdResolver = () => biz1;
      await db.settingsDao.set('auto_lock', 'true');
      
      // Set for biz 2
      db.businessIdResolver = () => biz2;
      await db.settingsDao.set('auto_lock', 'false');

      // Verify biz 1
      db.businessIdResolver = () => biz1;
      expect(await db.settingsDao.get('auto_lock'), equals('true'));

      // Verify biz 2
      db.businessIdResolver = () => biz2;
      expect(await db.settingsDao.get('auto_lock'), equals('false'));

      // Total rows in DB should be 2
      final allRows = await db.select(db.settings).get();
      expect(allRows.length, equals(2));
    });

    test('set() performs an upsert', () async {
      db.businessIdResolver = () => biz1;
      await db.settingsDao.set('theme', 'light');
      await db.settingsDao.set('theme', 'dark');

      expect(await db.settingsDao.get('theme'), equals('dark'));
      
      final rows = await db.select(db.settings).get();
      expect(rows.length, equals(1));
    });

    test('watch() re-emits after set() writes the key', () async {
      db.businessIdResolver = () => biz1;
      await db.settingsDao.set('business_design_system', 'amber');

      // A live watcher must see subsequent writes — this is what drives the
      // appearance colour applying instantly on the device that changed it
      // (and on a second device once the synced row lands locally). Use a
      // stream matcher rather than timed delays so the sequence is asserted
      // deterministically.
      final expectation = expectLater(
        db.settingsDao.watch('business_design_system'),
        emitsInOrder(['amber', 'purple']),
      );

      await db.settingsDao.set('business_design_system', 'purple');
      await expectation;
    });

    test('getTimezone returns Africa/Lagos by default (if configured) or UTC', () async {
      db.businessIdResolver = () => biz1;
      // If nothing set, should return default
      final tz = await db.settingsDao.getTimezone();
      // Per spec: "getTimezone returns 'UTC' when unset"
      // But some implementations might have a different default.
      // Let's see what the code says.
      expect(tz, equals('UTC'));
    });
  });
}
