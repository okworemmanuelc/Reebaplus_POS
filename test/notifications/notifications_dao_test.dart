import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

// v25 (Ring 0 #2, §26.2/§26.4): NotificationsDao.fireNotification sets the
// severity used for the card colour (blue info / yellow warning / red alert)
// and routes through enqueueUpsert (synced).
void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    db.businessIdResolver = () => businessId;
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Biz'),
        );
  });

  tearDown(() => db.close());

  group('NotificationsDao.fireNotification', () {
    test('stores the given severity + enqueues a sync upsert', () async {
      await db.notificationsDao.fireNotification(
        type: 'low_stock',
        message: 'Beer is low',
        severity: 'warning',
      );
      final n = await db.select(db.notifications).getSingle();
      expect(n.severity, 'warning');
      expect(n.type, 'low_stock');

      final queued = await db
          .customSelect(
            "SELECT COUNT(*) c FROM sync_queue "
            "WHERE action_type = 'notifications:upsert'",
          )
          .getSingle();
      expect(queued.read<int>('c'), greaterThan(0));
    });

    test('defaults severity to info', () async {
      await db.notificationsDao
          .fireNotification(type: 'sync_issue', message: 'hi');
      final n = await db.select(db.notifications).getSingle();
      expect(n.severity, 'info');
    });

    test('rejects an invalid severity (CHECK)', () async {
      await expectLater(
        db.notificationsDao.fireNotification(
          type: 'x',
          message: 'y',
          severity: 'bogus',
        ),
        throwsA(anything),
      );
    });
  });
}
