import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    db.businessIdResolver = () => businessId;

    await db.into(db.businesses).insert(BusinessesCompanion.insert(
          id: Value(businessId),
          name: 'Test Biz',
        ));
  });

  tearDown(() => db.close());

  // v25 (Ring 0 #2, §24.4): activity_logs uses a generic (entityType, entityId)
  // reference + before/after JSON snapshots instead of the six per-entity FK
  // columns and the old "<=1 FK set" CHECK. entity_id is polymorphic (not a
  // foreign key), so these no longer need a parent row to exist.
  group('ActivityLog generic shape', () {
    test('a log with no entity stores null entity_type/entity_id', () async {
      await db.activityLogDao.logActivity(
        action: 'test_action',
        description: 'No entity',
      );
      final log = await db.select(db.activityLogs).getSingle();
      expect(log.entityType, isNull);
      expect(log.entityId, isNull);
    });

    test('logActivity stores entity_type/entity_id + before/after JSON',
        () async {
      final id = UuidV7.generate();
      await db.activityLogDao.logActivity(
        action: 'product_action',
        description: 'edited price',
        entityType: 'product',
        entityId: id,
        before: {'price': 100},
        after: {'price': 120},
      );
      final log = await db.select(db.activityLogs).getSingle();
      expect(log.entityType, equals('product'));
      expect(log.entityId, equals(id));
      expect(log.beforeJson, contains('100'));
      expect(log.afterJson, contains('120'));
    });

    test('legacy log(orderId:) folds onto the generic (type, id) pair',
        () async {
      final orderId = UuidV7.generate();
      await db.activityLogDao.log(
        action: 'order_action',
        description: 'One entity',
        orderId: orderId,
      );
      final log = await db.select(db.activityLogs).getSingle();
      expect(log.entityType, equals('order'));
      expect(log.entityId, equals(orderId));
    });
  });
}
