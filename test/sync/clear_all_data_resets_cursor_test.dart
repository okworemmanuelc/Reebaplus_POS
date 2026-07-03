// clear_all_data_resets_cursor_test.dart
//
// Wipe-trap regression: `AppDatabase.clearAllData()` wipes the Drift DB but the
// per-business pull cursor (`last_sync_timestamp::<biz>`) lives in
// SharedPreferences and SURVIVES the wipe. If left behind, the next login reads
// the stale cursor and runs an INCREMENTAL pull that skips every row created
// before it — the catalogue, customers, and roles/permissions (hence the whole
// permission-gated navigation) never re-download, leaving a re-onboarded device
// on an almost-empty store (the "existing CEO logs in, no nav/customers" bug).
//
// `SyncCursorResetService.clearAll()` (called from `clearAllData`) must clear
// every per-business pull-state key so the next pull runs full — like a
// brand-new device — while leaving unrelated prefs alone.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/services/sync_cursor_reset_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SyncCursorResetService clears every per-business pull-state key',
      () async {
    SharedPreferences.setMockInitialValues({
      'last_sync_timestamp::biz1': '2026-07-01T07:58:37Z',
      'last_sync_timestamp::biz2': '2026-06-30T00:00:00Z',
      'pending_deferred_tables::biz1': 'notifications',
      'backfill_tables::biz1': 'error_logs',
      'consecutive_pull_failures::biz1': '3',
      // Unrelated keys must survive.
      'first_pull_done_v1_biz1': 'true',
      'device_id': 'abc-123',
    });

    await SyncCursorResetService.clearAll();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('last_sync_timestamp::biz1'), isNull);
    expect(prefs.getString('last_sync_timestamp::biz2'), isNull);
    expect(prefs.getString('pending_deferred_tables::biz1'), isNull);
    expect(prefs.getString('backfill_tables::biz1'), isNull);
    expect(prefs.getString('consecutive_pull_failures::biz1'), isNull);
    // Untouched.
    expect(prefs.getString('first_pull_done_v1_biz1'), 'true');
    expect(prefs.getString('device_id'), 'abc-123');
  });

  test('clearAllData() removes the surviving pull cursor', () async {
    SharedPreferences.setMockInitialValues({
      // A cursor from a prior sync on this device — the value the login pull
      // would otherwise read to run an incremental (data-skipping) pull.
      'last_sync_timestamp::any': '2026-07-01T07:58:37Z',
    });

    final boot = await bootstrapTestDb();
    try {
      // Real cursor for THIS device's business, as pullChanges would have set.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'last_sync_timestamp::${boot.businessId}', '2026-07-01T07:58:37Z');

      await boot.db.clearAllData();

      final after = await SharedPreferences.getInstance();
      expect(after.getString('last_sync_timestamp::${boot.businessId}'), isNull,
          reason: 'a wipe must reset the cursor so the next pull runs full');
      expect(after.getString('last_sync_timestamp::any'), isNull);
    } finally {
      await boot.db.close();
    }
  });
}
