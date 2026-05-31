// customer_soft_delete_test.dart
//
// §18.4 / §18.5 + hard rule #9: deleting a customer must be a SOFT delete
// (is_deleted=true) pushed as a full-row UPSERT — never a hard tombstone, and
// never a partial payload (customers.name is NOT NULL → a partial upsert 23502s
// and never syncs). Mirrors partial_upsert_full_row_test.dart.

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String customerId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    customerId = UuidV7.generate();
    await db.into(db.customers).insert(
          CustomersCompanion.insert(
            id: Value(customerId),
            businessId: businessId,
            name: 'Ada Obi',
          ),
        );
    // Drop the seed insert's own queued upsert so we assert only the delete.
    await db.customStatement('DELETE FROM sync_queue');
  });

  tearDown(() => db.close());

  test('softDeleteCustomer enqueues a full customers upsert (not a delete)',
      () async {
    await db.customersDao.softDeleteCustomer(customerId);

    final pending = await getPendingQueue(db);
    // Must be an UPSERT, never a hard delete tombstone.
    expect(
      pending.any((r) => r.actionType == 'customers:delete'),
      isFalse,
      reason: 'soft-delete must not hard-tombstone the customer',
    );
    final upserts =
        pending.where((r) => r.actionType == 'customers:upsert').toList();
    expect(upserts, isNotEmpty);

    final p = decodePayload(upserts.last);
    expect(p['name'], 'Ada Obi',
        reason: 'NOT NULL name must be in the payload or the cloud 23502s');
    expect(p['is_deleted'], anyOf(true, 1));
    expect(p['business_id'], businessId);
  });

  test('soft-deleted customer is hidden from the live list', () async {
    await db.customersDao.softDeleteCustomer(customerId);
    final visible = await db.customersDao.watchAllCustomers().first;
    expect(visible.any((c) => c.id == customerId), isFalse);
  });
}
