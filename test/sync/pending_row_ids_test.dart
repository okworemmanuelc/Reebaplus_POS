// pending_row_ids_test.dart
//
// Invariant #12 (the outbox is sacred) — the enforcement primitive.
//
// `SyncDao.pendingRowIds(table, businessId)` is the single source every
// protection (reconcile exclusion B, clobber prevention C) consults to decide
// whether a local row is still un-uploaded and therefore inviolable. These
// tests pin its contract:
//   (1) a pending `sync_queue` upsert is reported;
//   (2) a `sync_queue_orphans` row is reported (an orphan is still un-uploaded);
//   (3) a `completed` queue row is NOT reported (the server confirmed it);
//   (4) the table filter is exact (a different table's pending row is excluded);
//   (5) the businessId filter scopes correctly, and the unscoped form matches
//       across businesses (ids are globally unique, so still exact).
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

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() async => db.close());

  Future<void> enqueueRow({
    required String table,
    required String rowId,
    required String biz,
    String status = 'pending',
    String action = 'upsert',
  }) async {
    await db.into(db.syncQueue).insert(
          SyncQueueCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: biz,
            actionType: '$table:$action',
            payload: jsonEncode({'id': rowId, 'business_id': biz}),
            status: Value(status),
            isSynced: Value(status == 'completed'),
          ),
        );
  }

  Future<void> orphanRow({
    required String table,
    required String rowId,
    required String biz,
  }) async {
    await db.into(db.syncQueueOrphans).insert(
          SyncQueueOrphansCompanion.insert(
            originalId: UuidV7.generate(),
            actionType: '$table:upsert',
            payload: jsonEncode({'id': rowId, 'business_id': biz}),
            reason: 'insufficient_privilege (42501)',
          ),
        );
  }

  test('reports a pending sync_queue upsert', () async {
    final rowId = UuidV7.generate();
    await enqueueRow(table: 'products', rowId: rowId, biz: businessId);

    final ids = await db.syncDao.pendingRowIds('products',
        businessId: businessId);
    expect(ids, contains(rowId));
  });

  test('reports a sync_queue_orphans row (orphan is still un-uploaded)',
      () async {
    final rowId = UuidV7.generate();
    await orphanRow(table: 'products', rowId: rowId, biz: businessId);

    final ids = await db.syncDao.pendingRowIds('products',
        businessId: businessId);
    expect(ids, contains(rowId),
        reason: 'an orphan is un-pushable local data the invariant protects');
  });

  test('does NOT report a completed (server-confirmed) row', () async {
    final rowId = UuidV7.generate();
    await enqueueRow(
        table: 'products', rowId: rowId, biz: businessId, status: 'completed');

    final ids = await db.syncDao.pendingRowIds('products',
        businessId: businessId);
    expect(ids, isNot(contains(rowId)),
        reason: 'a confirmed upload is no longer pending');
  });

  test('table filter is exact — another table\'s pending row is excluded',
      () async {
    final productId = UuidV7.generate();
    final categoryId = UuidV7.generate();
    await enqueueRow(table: 'products', rowId: productId, biz: businessId);
    await enqueueRow(table: 'categories', rowId: categoryId, biz: businessId);

    final productIds = await db.syncDao.pendingRowIds('products',
        businessId: businessId);
    expect(productIds, contains(productId));
    expect(productIds, isNot(contains(categoryId)));
  });

  test('businessId filter scopes; unscoped matches across businesses',
      () async {
    final otherBiz = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(otherBiz), name: 'Other Biz'),
        );
    final mineId = UuidV7.generate();
    final otherId = UuidV7.generate();
    await enqueueRow(table: 'products', rowId: mineId, biz: businessId);
    await enqueueRow(table: 'products', rowId: otherId, biz: otherBiz);

    final scoped = await db.syncDao.pendingRowIds('products',
        businessId: businessId);
    expect(scoped, contains(mineId));
    expect(scoped, isNot(contains(otherId)),
        reason: 'scoped lookup excludes another business');

    final unscoped = await db.syncDao.pendingRowIds('products');
    expect(unscoped, containsAll(<String>[mineId, otherId]),
        reason: 'unscoped lookup matches every business (ids are unique)');
  });
}
