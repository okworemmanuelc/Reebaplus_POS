import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

/// Sync safeguard — realtime DELETE propagation for hard-delete tables.
///
/// Supabase Realtime authorizes a DELETE against the row's RLS SELECT policy
/// using only the columns in the table's REPLICA IDENTITY. Every hard-delete
/// table here carries a `business_id`-scoped RLS policy, so unless the table is
/// `REPLICA IDENTITY FULL`, `business_id` is absent from a delete's old record,
/// the RLS check fails, and Realtime DROPS the DELETE — so a row the client
/// hard-deletes never disappears live on other devices (it only clears on the
/// next full snapshot reconcile). This was the per-staff-override "toggle ON
/// propagates but toggle OFF doesn't revert" bug (migration 0090), and the
/// `role_permissions` / `saved_carts` / `notifications` bug before it (0064).
///
/// Rule: every table the client hard-deletes — the registry entries carrying a
/// `hardDelete` rule, exposed as `kHardDeleteReconcileTables` (the
/// `enqueueDelete` + realtime-DELETE + snapshot-reconcile set) — must have an
/// `ALTER TABLE … REPLICA IDENTITY FULL` in some migration. Add a new
/// hard-delete table and forget the migration and this goes red.
void main() {
  test('every hard-delete table is REPLICA IDENTITY FULL in a migration', () {
    final tables = kHardDeleteReconcileTables;
    expect(tables, isNotEmpty,
        reason: 'kHardDeleteReconcileTables is empty — the SyncedTable registry '
            'has no hard-delete entries?');

    final migrations = StringBuffer();
    final dir = Directory('supabase/migrations');
    if (dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>()) {
        if (f.path.endsWith('.sql')) migrations.write(f.readAsStringSync());
      }
    }
    final sql = migrations.toString();

    final missing = <String>[
      for (final t in tables)
        if (!RegExp(
                'ALTER\\s+TABLE\\s+(public\\.)?$t\\s+REPLICA\\s+IDENTITY\\s+FULL',
                caseSensitive: false)
            .hasMatch(sql))
          t,
    ]..sort();

    expect(
      missing,
      isEmpty,
      reason: 'Hard-delete table(s) with no `REPLICA IDENTITY FULL` migration — '
          'their realtime DELETEs are dropped by RLS and never propagate live '
          '(see migrations 0064 / 0090):\n  ${missing.join('\n  ')}\n\nAdd '
          '`ALTER TABLE public.<table> REPLICA IDENTITY FULL;` in a new '
          'migration and deploy it.',
    );
  });
}
