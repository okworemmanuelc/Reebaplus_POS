import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

/// Tier-1 guard (#517): every synced tenant table in [kSyncRegistry] must be in
/// the `v_tenant_tables` list of the NEWEST migration that defines
/// `pos_pull_snapshot`. A table missing there is never delivered by snapshot or
/// incremental pulls (it only arrives via realtime), which is how
/// `crate_shortfall_writeoffs` was missed.
void main() {
  /// Tenant tables that intentionally are NOT pulled via pos_pull_snapshot.
  /// Justify every entry; the default for a new table is to add it to the RPC.
  const intentionallyNotSnapshotted = <String, String>{};

  List<String> latestSnapshotTables() {
    final files = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sql'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    File? latest;
    for (final f in files) {
      if (f.readAsStringSync().contains(
          'CREATE OR REPLACE FUNCTION public.pos_pull_snapshot')) {
        latest = f;
      }
    }
    expect(latest, isNotNull, reason: 'no migration defines pos_pull_snapshot');
    final sql = latest!.readAsStringSync();
    final m = RegExp(r'v_tenant_tables\s+text\[\]\s*:=\s*ARRAY\[(.*?)\];',
            dotAll: true)
        .firstMatch(sql);
    expect(m, isNotNull, reason: 'v_tenant_tables not found in ${latest.path}');
    final body = m!.group(1)!.replaceAll(RegExp(r'--[^\n]*'), '');
    return [for (final t in RegExp(r"'([a-z_0-9]+)'").allMatches(body)) t.group(1)!];
  }

  test('every synced tenant table is in the latest pos_pull_snapshot', () {
    final inRpc = latestSnapshotTables().toSet();
    final missing = [
      for (final t in kSyncedTenantTables)
        if (!inRpc.contains(t) && !intentionallyNotSnapshotted.containsKey(t)) t,
    ];
    expect(missing, isEmpty,
        reason: 'Add these to v_tenant_tables in a new migration that '
            're-issues pos_pull_snapshot (or justify in the allowlist).');
  });

  test('crate_shortfall_writeoffs is snapshotted and restored by the client',
      () {
    expect(latestSnapshotTables(), contains('crate_shortfall_writeoffs'));
    expect(kSyncedTenantTables, contains('crate_shortfall_writeoffs'));
  });

  test('allowlist entries are real tenant tables', () {
    for (final t in intentionallyNotSnapshotted.keys) {
      expect(kSyncedTenantTables, contains(t));
    }
  });
}
