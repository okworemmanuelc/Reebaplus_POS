// pull_path_decision_test.dart
//
// Unit tests for [SupabaseSyncService.shouldUseSnapshotRpc], the pure
// @visibleForTesting static helper that encodes the Phase 2 pull-path
// routing rule:
//
//   Full/first pulls (since == null) NEVER call pos_pull_snapshot, regardless
//   of connectivity. The unbounded aggregate RPC can time out on large datasets.
//
//   Incremental pulls (since != null) on a fast link still use the RPC — the
//   payload is bounded by what changed since the cursor, so one round-trip is
//   cheaper than paginating every table.
//
// Truth table (all four cells must pass):
//   isSlow=false, since=null     → false  (the core fix: fast+full → paginated)
//   isSlow=false, since=DateTime → true   (fast+incremental → RPC)
//   isSlow=true,  since=null     → false  (slow+full → paginated)
//   isSlow=true,  since=DateTime → false  (slow+incremental → paginated)
//
// These tests exercise only the pure decision function — no network, no DB,
// no Supabase client required.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

void main() {
  final aSince = DateTime.utc(2026, 6, 1, 12);

  group('SupabaseSyncService.shouldUseSnapshotRpc', () {
    test(
      'fast link + full pull (since=null) → false '
      '(core fix: full pull bypasses RPC)',
      () {
        expect(
          SupabaseSyncService.shouldUseSnapshotRpc(
            isSlow: false,
            since: null,
          ),
          isFalse,
          reason: 'A full pull on a fast link must use the paginated path, '
              'never the monolithic pos_pull_snapshot RPC.',
        );
      },
    );

    test(
      'fast link + incremental pull (since=DateTime) → true '
      '(incremental on fast link uses RPC)',
      () {
        expect(
          SupabaseSyncService.shouldUseSnapshotRpc(
            isSlow: false,
            since: aSince,
          ),
          isTrue,
          reason: 'An incremental pull on a fast link may use the RPC — '
              'the payload is bounded by the since-cursor window.',
        );
      },
    );

    test(
      'slow link + full pull (since=null) → false '
      '(slow+full → paginated PostgREST)',
      () {
        expect(
          SupabaseSyncService.shouldUseSnapshotRpc(
            isSlow: true,
            since: null,
          ),
          isFalse,
          reason: 'A slow link never calls the RPC regardless of since.',
        );
      },
    );

    test(
      'slow link + incremental pull (since=DateTime) → false '
      '(slow link never uses RPC)',
      () {
        expect(
          SupabaseSyncService.shouldUseSnapshotRpc(
            isSlow: true,
            since: aSince,
          ),
          isFalse,
          reason: 'A slow link always uses the paginated path, even for '
              'incremental pulls.',
        );
      },
    );
  });
}
