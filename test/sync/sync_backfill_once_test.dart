// sync_backfill_once_test.dart
//
// SupabaseSyncService.ensureBackfillOnce() is the one-time, device-wide
// backfill for tables added to the pull path after a device already advanced
// its per-business `last_sync_timestamp::<businessId>` cursor (invite_codes,
// added in 0053). Incremental pulls only return rows newer than the cursor, so
// pre-existing rows never reach an already-synced device. Clearing every
// `last_sync_timestamp::*` key forces the next pull to run full (since = null).
//
// This test exercises the guard's SharedPreferences logic directly — it never
// touches the DB or network, so an in-memory DB + bare client suffice.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late SupabaseClient supabase;
  late SupabaseSyncService sync;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    supabase = SupabaseClient(
      'https://placeholder.supabase.co',
      'placeholder-anon-key',
    );
    sync = SupabaseSyncService(db, supabase);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  test('clears every last_sync_timestamp::* cursor and sets the flag once',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_sync_timestamp::biz1', '2026-05-29T00:00:00Z');
    await prefs.setString('last_sync_timestamp::biz2', '2026-05-28T00:00:00Z');
    // An unrelated key must survive — we only clear the pull cursors.
    await prefs.setString('consecutive_pull_failures::biz1', '0');
    await prefs.setString('some_other_key', 'keep-me');

    await sync.ensureBackfillOnce();

    expect(prefs.getString('last_sync_timestamp::biz1'), isNull);
    expect(prefs.getString('last_sync_timestamp::biz2'), isNull);
    expect(prefs.getString('consecutive_pull_failures::biz1'), '0');
    expect(prefs.getString('some_other_key'), 'keep-me');
    expect(prefs.getBool('sync_backfill_done::invite_codes_v2'), isTrue);
  });

  test('is a no-op on the second call (runs exactly once per device)',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_sync_timestamp::biz1', '2026-05-29T00:00:00Z');

    await sync.ensureBackfillOnce();
    expect(prefs.getString('last_sync_timestamp::biz1'), isNull,
        reason: 'first call clears the cursor');

    // A subsequent sync advances the cursor again; the second backfill call
    // must NOT wipe it — otherwise every pull would be a full pull forever.
    await prefs.setString('last_sync_timestamp::biz1', '2026-06-01T00:00:00Z');
    await sync.ensureBackfillOnce();
    expect(prefs.getString('last_sync_timestamp::biz1'), '2026-06-01T00:00:00Z',
        reason: 'flag already set — second call is a no-op');
  });

  test('no cursors present is still a safe no-op (fresh device)', () async {
    final prefs = await SharedPreferences.getInstance();

    await sync.ensureBackfillOnce();

    expect(prefs.getBool('sync_backfill_done::invite_codes_v2'), isTrue);
  });
}
