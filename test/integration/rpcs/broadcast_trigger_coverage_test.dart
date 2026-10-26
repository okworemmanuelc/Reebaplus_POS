@Tags(['integration'])
library;

// broadcast_trigger_coverage_test.dart — Tier-2, real dev Supabase (#470).
//
// Guard: every business-scoped cloud table must carry the live-sync signal
// trigger `zz_broadcast_sync_signal` (migration 0147). 0147 attached it with a
// one-time loop, so a table created later silently lacks it unless a migration
// attaches it (0198 backfilled the gap). This test turns that omission red.
//
// Uses the read-only service-role helper `broadcast_trigger_missing_tables`
// from 0198. Skips cleanly when TEST_SUPABASE_URL / SERVICE_ROLE_KEY are unset.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _env = Platform.environment;
final String? _skip =
    ['TEST_SUPABASE_URL', 'TEST_SUPABASE_SERVICE_ROLE_KEY']
            .any((key) => _env[key]?.isNotEmpty != true)
        ? 'Broadcast trigger coverage needs TEST_SUPABASE_URL and '
            'TEST_SUPABASE_SERVICE_ROLE_KEY.'
        : null;

void main() {
  late SupabaseClient admin;

  setUpAll(() {
    if (_skip != null) return;
    admin = SupabaseClient(
      _env['TEST_SUPABASE_URL']!,
      _env['TEST_SUPABASE_SERVICE_ROLE_KEY']!,
    );
  });

  tearDownAll(() async {
    if (_skip != null) return;
    await admin.dispose();
  });

  Future<List<String>> missing([List<String>? tables]) async {
    final rows = await admin.rpc(
      'broadcast_trigger_missing_tables',
      params: {'p_tables': tables},
    );
    return [for (final r in rows as List) r.toString()];
  }

  test('every tenant-scoped kSyncRegistry table (+ businesses) has the '
      'zz_broadcast_sync_signal trigger', () async {
    final tables = [...kSyncedTenantTables, 'businesses'];
    expect(tables, isNotEmpty);
    expect(
      await missing(tables),
      isEmpty,
      reason: 'Add a migration attaching zz_broadcast_sync_signal (see 0198).',
    );
  }, skip: _skip);

  test('every public table with business_id has the trigger (0147 rule)',
      () async {
    expect(
      await missing(),
      isEmpty,
      reason: 'Add a migration attaching zz_broadcast_sync_signal (see 0198).',
    );
  }, skip: _skip);
}
