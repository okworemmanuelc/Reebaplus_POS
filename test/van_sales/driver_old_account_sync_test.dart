// driver_old_account_sync_test.dart
//
// #783 — `van_drivers.customer_id` syncs both ways. Down: a pulled row carries
// it; an OLD-shape row (cloud not yet on 0256, or a device that never sends it)
// restores with it null. Up: the queued upsert payload carries `customer_id`
// (also asserted in driver_old_account_link_test.dart for the link itself) and
// an ordinary driver edit still pushes a complete row.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late SupabaseSyncService sync;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    final supabase =
        SupabaseClient('https://placeholder.supabase.co', 'anon-key');
    addTearDown(supabase.dispose);
    sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));
  });
  tearDown(() => db.close());

  String ts() => DateTime.now().toUtc().toIso8601String();

  test('a pulled van_drivers row restores its customer_id', () async {
    const cust = '00000000-0000-7000-8000-0000000000c1';
    const driver = '00000000-0000-7000-8000-0000000000d1';
    await sync.restoreTableDataForTesting('customers', [
      {'id': cust, 'business_id': businessId, 'name': 'Old Acct',
       'price_tier': 'retailer', 'wallet_limit_kobo': 0,
       'is_deleted': false, 'created_at': ts(), 'last_updated_at': ts()},
    ]);
    await sync.restoreTableDataForTesting('van_drivers', [
      {'id': driver, 'business_id': businessId, 'name': 'Johnson Kim',
       'customer_id': cust, 'is_deleted': false,
       'created_at': ts(), 'last_updated_at': ts()},
    ]);
    final d = await db.vanDriversDao.getDriver(driver);
    expect(d, isNotNull);
    expect(d!.customerId, cust);
    expect((await db.vanDriversDao.driverLinkedToCustomer(cust))!.id, driver);
  });

  test('an old-shape pulled row (no customer_id key) restores with it null',
      () async {
    const driver = '00000000-0000-7000-8000-0000000000d2';
    await sync.restoreTableDataForTesting('van_drivers', [
      {'id': driver, 'business_id': businessId, 'name': 'Ada',
       'is_deleted': false, 'created_at': ts(), 'last_updated_at': ts()},
    ]);
    final d = await db.vanDriversDao.getDriver(driver);
    expect(d, isNotNull);
    expect(d!.customerId, isNull);
    expect(d.name, 'Ada');
  });

  test('a pulled row with an explicit null customer_id restores unlinked',
      () async {
    const driver = '00000000-0000-7000-8000-0000000000d3';
    await sync.restoreTableDataForTesting('van_drivers', [
      {'id': driver, 'business_id': businessId, 'name': 'Bo',
       'customer_id': null, 'is_deleted': false,
       'created_at': ts(), 'last_updated_at': ts()},
    ]);
    expect((await db.vanDriversDao.getDriver(driver))!.customerId, isNull);
  });

  test('the push payload carries customer_id once linked, and leaves it out '
      'while null (so an older row on the cloud is never overwritten)',
      () async {
    final id = await db.vanDriversDao.addDriver(name: 'Ada');
    await db.vanDriversDao.updateDriver(id, name: 'Ada B');
    var q = await getPendingQueue(db);
    var payload = decodePayload(
      q.lastWhere((r) => r.actionType == 'van_drivers:upsert'),
    );
    expect(payload['id'], id);
    expect(payload['name'], 'Ada B');
    expect(payload.containsKey('customer_id'), isFalse);

    final cust = UuidV7.generate();
    await db.into(db.customers).insert(
      CustomersCompanion.insert(
        id: Value(cust),
        businessId: businessId,
        name: 'Old Acct',
      ),
    );
    await db.vanDriversDao
        .linkOldCustomerAccount(vanDriverId: id, customerId: cust);
    q = await getPendingQueue(db);
    payload = decodePayload(
      q.lastWhere((r) => r.actionType == 'van_drivers:upsert'),
    );
    expect(payload['customer_id'], cust);
    // The row is complete: name and business still ride with it.
    expect(payload['name'], 'Ada B');
    expect(payload['business_id'], businessId);
  });
}
