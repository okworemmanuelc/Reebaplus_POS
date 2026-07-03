// unsynced_export_discard_test.dart
//
// Invariant #12 wipe-gate (E) data layer — "Resolve unsynced data" flow.
//
// A sole-user logout with un-pushable orphans must never be trapped: the rows
// are EXPORTED, then a typed-confirm DISCARDS them. These tests pin the DAO
// methods that back that flow, plus the orphan count the gate uses to choose
// between "refuse (transient)" and "export + discard (un-pushable)":
//   (1) countOrphans scopes by the payload's business_id;
//   (2) unsyncedExportRows flattens BOTH pending queue rows and orphans;
//   (3) discardUnsyncedForBusiness removes this business's pending + orphan
//       rows and leaves another business's outbox untouched.
//
// Network-free: only the local Drift DB is touched.

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String otherBiz;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    otherBiz = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(otherBiz), name: 'Other Biz'),
        );
  });

  tearDown(() async => db.close());

  Future<void> enqueue(String table, String biz, {String? rowId}) async {
    await db.into(db.syncQueue).insert(
          SyncQueueCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: biz,
            actionType: '$table:upsert',
            payload: jsonEncode({
              'id': rowId ?? UuidV7.generate(),
              'business_id': biz,
            }),
          ),
        );
  }

  Future<void> orphan(String table, String biz, String reason) async {
    await db.into(db.syncQueueOrphans).insert(
          SyncQueueOrphansCompanion.insert(
            originalId: UuidV7.generate(),
            actionType: '$table:upsert',
            payload: jsonEncode({
              'id': UuidV7.generate(),
              'business_id': biz,
            }),
            reason: reason,
          ),
        );
  }

  test('countOrphans scopes by the payload business_id', () async {
    await orphan('orders', businessId, 'insufficient_privilege (42501)');
    await orphan('orders', businessId, 'created_at is immutable (P0001)');
    await orphan('orders', otherBiz, 'insufficient_privilege (42501)');

    expect(await db.syncDao.countOrphans(businessId: businessId), 2);
    expect(await db.syncDao.countOrphans(businessId: otherBiz), 1);
    expect(await db.syncDao.countOrphans(), 3,
        reason: 'unscoped counts every business');
  });

  test('unsyncedExportRows flattens both pending queue rows and orphans',
      () async {
    await enqueue('orders', businessId);
    await orphan('order_items', businessId, 'insufficient_privilege (42501)');

    final rows = await db.syncDao.unsyncedExportRows(businessId);
    expect(rows, hasLength(2));
    final sources = rows.map((r) => r[0]).toSet();
    expect(sources, containsAll(<String>['queue', 'orphan']));
    // Each record carries source, table, action, id, reason, created_at, payload.
    expect(rows.every((r) => r.length == 7), isTrue);
    final tables = rows.map((r) => r[1]).toSet();
    expect(tables, containsAll(<String>['orders', 'order_items']));
  });

  test('discardUnsyncedForBusiness removes this business only', () async {
    await enqueue('orders', businessId);
    await orphan('orders', businessId, 'insufficient_privilege (42501)');
    await enqueue('orders', otherBiz);
    await orphan('orders', otherBiz, 'insufficient_privilege (42501)');

    final discarded = await db.syncDao.discardUnsyncedForBusiness(businessId);
    expect(discarded, 2, reason: 'one pending + one orphan for this business');

    // This business is clean.
    expect(await db.syncDao.countPending(businessId: businessId), 0);
    expect(await db.syncDao.countOrphans(businessId: businessId), 0);
    // The other business is untouched.
    expect(await db.syncDao.countPending(businessId: otherBiz), 1);
    expect(await db.syncDao.countOrphans(businessId: otherBiz), 1);
  });

  test('a completed queue row is not exported or discarded', () async {
    // A confirmed upload is not un-synced — it must not appear in the export
    // nor be counted in the discard.
    await db.into(db.syncQueue).insert(
          SyncQueueCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: businessId,
            actionType: 'orders:upsert',
            payload: jsonEncode({'id': UuidV7.generate(), 'business_id': businessId}),
            status: const Value('completed'),
            isSynced: const Value(true),
          ),
        );

    expect(await db.syncDao.unsyncedExportRows(businessId), isEmpty);
    expect(await db.syncDao.discardUnsyncedForBusiness(businessId), 0);
  });
}
