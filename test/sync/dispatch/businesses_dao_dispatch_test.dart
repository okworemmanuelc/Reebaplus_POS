import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

import '../../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  group('BusinessesDao.updateInfo dispatch', () {
    test('updates the local row and enqueues a businesses:upsert', () async {
      await db.businessesDao.updateInfo(name: 'New Name', type: 'Bar');

      // Local row reflects the edit.
      final biz = await (db.select(db.businesses)
            ..where((t) => t.id.equals(businessId)))
          .getSingle();
      expect(biz.name, 'New Name');
      expect(biz.type, 'Bar');

      // Outbox: exactly one businesses upsert.
      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'businesses:upsert');

      // Payload shape — proves the push validation gate will pass: the
      // injected business_id equals the session business, and id/name/type
      // are carried through for the cloud upsert.
      final payload = decodePayload(pending.first);
      expect(payload['id'], businessId);
      expect(payload['business_id'], businessId);
      expect(payload['name'], 'New Name');
      expect(payload['type'], 'Bar');
    });

    test('coalesces repeated edits into a single pending upsert', () async {
      await db.businessesDao.updateInfo(name: 'First');
      await db.businessesDao.updateInfo(name: 'Second');

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1), reason: 'same row coalesces to latest');
      expect(decodePayload(pending.first)['name'], 'Second');
    });
  });
}
