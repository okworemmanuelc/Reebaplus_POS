import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

// #806: two ways a cloud correction never reached a phone.

void main() {
  test(
    'the pull cursor is taken from the START of the pull, less a margin',
    () {
      final started = DateTime.utc(2026, 11, 12, 22, 56, 45);
      final cursor = SupabaseSyncService.pullCursorFor(started);
      // A row changed in the cloud 9 seconds into the pull is above the cursor.
      final changedDuringPull = DateTime.utc(2026, 11, 12, 22, 56, 54);
      expect(changedDuringPull.isAfter(cursor), isTrue);
      expect(
        started.difference(cursor),
        SupabaseSyncService.pullCursorSafetyMargin,
      );
    },
  );

  group('a field cleared in the cloud is cleared on the phone', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Map<String, dynamic> driverJson({String? customerId}) => {
      'id': 'd1',
      'businessId': 'b1',
      'name': 'Johnson',
      'phone': null,
      'customerId': customerId,
      'isDeleted': false,
      'createdAt': DateTime.utc(2026, 11, 12).toIso8601String(),
      'lastUpdatedAt': DateTime.utc(2026, 11, 12).toIso8601String(),
    };

    test('cloudRowUpdate keeps a null the cloud row carried', () {
      final json = driverJson();
      final cols = Restore.cloudRowUpdate(
        VanDriverData.fromJson(json),
        json,
      ).toColumns(false);
      expect(cols.containsKey('customer_id'), isTrue);
    });

    test('cloudRowUpdate leaves alone a column the cloud did not send', () {
      final json = driverJson()..remove('customerId');
      final cols = Restore.cloudRowUpdate(
        VanDriverData.fromJson(json),
        json,
      ).toColumns(false);
      expect(cols.containsKey('customer_id'), isFalse);
      expect(cols.containsKey('name'), isTrue);
    });

    test(
      'a pulled van driver with no customer overwrites the old link',
      () async {
        await db.customStatement('PRAGMA foreign_keys = OFF');
        final ex = SyncRestoreExecutor(db);
        final restore = syncedTableForName('van_drivers')!.restore;
        await restore(ex, 'van_drivers', [driverJson(customerId: 'c1')], null);
        expect((await db.select(db.vanDrivers).getSingle()).customerId, 'c1');
        await restore(ex, 'van_drivers', [driverJson()], null);
        expect((await db.select(db.vanDrivers).getSingle()).customerId, isNull);
      },
    );
  });
}
