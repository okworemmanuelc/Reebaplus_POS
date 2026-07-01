import 'package:shared_preferences/shared_preferences.dart';

/// Clears the SharedPreferences sync-engine pull state that lives OUTSIDE the
/// Drift DB and therefore SURVIVES `AppDatabase.clearAllData()` — the same
/// wipe-trap pattern as [FirstLoadMarkerService].
///
/// Called from `clearAllData()` (logout / business-delete / onboarding reset).
/// Without it, a wiped device keeps its per-business pull cursor
/// (`last_sync_timestamp::<biz>`); the next login then reads that surviving
/// cursor and runs an **incremental** pull that only returns rows changed after
/// it — so the catalogue, customers, and roles/permissions (all created before
/// the cursor, and hence the whole navigation, which is permission-gated) never
/// re-download. The re-onboarded device lands on an almost-empty store. Clearing
/// the cursor makes the next pull a full pull, exactly like a brand-new device.
///
/// The prefixes below MUST stay in sync with the constants in
/// `SupabaseSyncService` (`_lastSyncPrefix`, `pendingDeferredTablesKey`,
/// `backfillTablesKey`, `_consecutiveFailuresKey`). They are duplicated here as
/// literals on purpose: `SupabaseSyncService` imports `AppDatabase`, so importing
/// it back into `clearAllData` would create a cycle — the same reason
/// `FirstLoadMarkerService` owns its prefix independently.
class SyncCursorResetService {
  static const _prefixes = <String>[
    // Per-business incremental-pull cursor — the load-bearing one.
    'last_sync_timestamp::',
    // Per-business "still catching up" deferred-table record (SyncIssues UI).
    'pending_deferred_tables::',
    // Per-business §3.6 per-table backfill set.
    'backfill_tables::',
    // Per-business consecutive-pull-failure counter.
    'consecutive_pull_failures::',
  ];

  /// Removes every per-business pull-state key so the next pull runs full.
  /// Best-effort by the caller (`clearAllData` swallows any error).
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final toRemove = prefs
        .getKeys()
        .where((k) => _prefixes.any(k.startsWith))
        .toList();
    for (final k in toRemove) {
      await prefs.remove(k);
    }
  }
}
