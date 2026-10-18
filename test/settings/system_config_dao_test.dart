import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  group('SystemConfigDao', () {
    test('SystemConfig is global (no business scoping)', () async {
      final biz1 = UuidV7.generate();
      final biz2 = UuidV7.generate();

      // Set with biz1 context
      db.businessIdResolver = () => biz1;
      await db.systemConfigDao.set('schema_version', '7');

      // Get with biz2 context - should still return '7'
      db.businessIdResolver = () => biz2;
      expect(await db.systemConfigDao.get('schema_version'), equals('7'));

      // Total rows in DB should be 1
      final allRows = await db.select(db.systemConfig).get();
      expect(allRows.length, equals(1));
    });

    test('set() performs an upsert', () async {
      await db.systemConfigDao.set('sync_enabled', 'true');
      await db.systemConfigDao.set('sync_enabled', 'false');

      expect(await db.systemConfigDao.get('sync_enabled'), equals('false'));
      
      final rows = await db.select(db.systemConfig).get();
      expect(rows.length, equals(1));
    });

    test('Returns null for non-existent key', () async {
      expect(await db.systemConfigDao.get('invalid_key'), isNull);
    });
  });
}
