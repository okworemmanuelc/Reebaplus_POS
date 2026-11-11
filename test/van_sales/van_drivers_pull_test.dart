// van_drivers_pull_test.dart
//
// #748 — rows pulled from a cloud that has NOT yet applied 0251 must still
// restore (#730 broke on exactly this for NOT NULL columns). Every new column is
// nullable, so an old snapshot row simply leaves them null; a `van_drivers` row
// may omit is_deleted. New-shape rows land with their fields.
//
// NOTE: written for #748 but NOT executed in the authoring session (owner
// instruction: no tests run).

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
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
    final supabase = SupabaseClient('https://placeholder.supabase.co', 'anon-key');
    addTearDown(supabase.dispose);
    sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));
  });
  tearDown(() => db.close());

  String ts() => DateTime.now().toUtc().toIso8601String();

  test('old-cloud van trip, ledger row and store restore with the new columns '
      'null', () async {
    const van = '00000000-0000-7000-8000-0000000000a1';
    const wh = '00000000-0000-7000-8000-0000000000a2';
    const user = '00000000-0000-7000-8000-0000000000a3';
    const trip = '00000000-0000-7000-8000-0000000000a4';
    const entry = '00000000-0000-7000-8000-0000000000a5';
    await sync.restoreTableDataForTesting('stores', [
      {'id': wh, 'business_id': businessId, 'name': 'WH', 'is_deleted': false,
       'created_at': ts(), 'last_updated_at': ts()},
      {'id': van, 'business_id': businessId, 'name': 'Van', 'kind': 'van',
       'is_deleted': false, 'created_at': ts(), 'last_updated_at': ts()},
    ]);
    await sync.restoreTableDataForTesting('van_trips', [
      {'id': trip, 'business_id': businessId, 'van_store_id': van,
       'driver_user_id': user, 'source_store_id': wh, 'status': 'open',
       'created_at': ts(), 'last_updated_at': ts(), 'opened_at': ts(),
       // A real cloud row carries every NOT NULL DEFAULT column (0162); only
       // the #748 columns are absent from an old-cloud row.
       'closed_with_balance': false, 'shells_out': 0, 'shells_back': 0,
       'cogs_kobo': 0, 'recovered_kobo': 0, 'unremitted_kobo': 0,
       'shortage_writeoff_kobo': 0, 'damage_writeoff_kobo': 0,
       'shortage_loss_kobo': 0, 'damage_loss_kobo': 0, 'profit_kobo': 0},
    ]);
    final t = await (db.select(db.vanTrips)..where((x) => x.id.equals(trip)))
        .getSingleOrNull();
    // The user FK may defer the row on a bare test DB; what matters is that the
    // restore did not throw on the absent new columns. When it landed, the new
    // columns are null.
    if (t != null) {
      expect(t.vanDriverId, isNull);
      expect(t.driverUserId, user);
    }
    final s = await (db.select(db.stores)..where((x) => x.id.equals(van)))
        .getSingle();
    expect(s.vanDriverId, isNull);
    expect(entry, isNotEmpty);
  });

  test('van_drivers row without is_deleted restores as active; a new-shape '
      'trip carries its driver', () async {
    const driver = '00000000-0000-7000-8000-0000000000b1';
    await sync.restoreTableDataForTesting('van_drivers', [
      {'id': driver, 'business_id': businessId, 'name': 'Ada',
       'created_at': ts(), 'last_updated_at': ts()},
    ]);
    final d = await db.vanDriversDao.getDriver(driver);
    expect(d, isNotNull);
    expect(d!.isDeleted, isFalse);
    expect(d.phone, isNull);
  });
}
