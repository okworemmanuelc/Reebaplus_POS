// cloud_transport_seam_test.dart
//
// Characterization tests for the CloudTransport seam (ADR 0001). Two things:
//
//   1. The sync engine drives its cloud I/O through the seam — proven here for
//      the pull path via `refreshBusinessRow`, which is guard-free (no auth /
//      connectivity / Supabase.instance), so it exercises the real engine →
//      `_transport.fetchTable` wiring end-to-end against the in-memory fake.
//
//   2. `InMemoryCloudTransport` is a *real* second adapter, not a stub: its
//      `fetchTable` honours the same business_id / since / ordering filtering as
//      the Supabase adapter, and its push + fault-injection + realtime + identity
//      surfaces behave as the fidelity contract promises — the foundation the
//      sync data-safety brief's A–F vector tests build on.
//
// Restore mechanics themselves are covered by the existing restore/reconcile
// suites (via the *ForTesting seams); this file covers the seam wiring + fake.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgresChangeEvent, PostgresChangePayload, PostgrestException;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';
import '../helpers/in_memory_cloud_transport.dart';

void main() {
  group('engine ↔ CloudTransport wiring', () {
    late AppDatabase db;
    late String businessId;
    late InMemoryCloudTransport transport;
    late SupabaseSyncService sync;

    setUp(() async {
      final boot = await bootstrapTestDb();
      db = boot.db;
      businessId = boot.businessId;
      transport = InMemoryCloudTransport(authUserId: 'user-1');
      sync = SupabaseSyncService(db, transport);
    });

    tearDown(() async {
      await transport.dispose();
      await db.close();
    });

    test('refreshBusinessRow fetches the businesses slice through the seam',
        () async {
      await sync.refreshBusinessRow(businessId);

      expect(transport.fetchQueries, hasLength(1));
      final q = transport.fetchQueries.single;
      expect(q.table, 'businesses');
      expect(q.businessId, businessId);
      expect(q.since, isNull); // businesses is always a full fetch
    });
  });

  group('InMemoryCloudTransport fidelity', () {
    late InMemoryCloudTransport t;
    setUp(() => t = InMemoryCloudTransport());
    tearDown(() => t.dispose());

    test('fetchTable filters by business_id + since and orders by '
        '(last_updated_at, id)', () async {
      t.seed('categories', [
        {'id': 'c1', 'business_id': 'B', 'last_updated_at': '2026-01-01T00:00:00Z'},
        {'id': 'c2', 'business_id': 'B', 'last_updated_at': '2026-03-01T00:00:00Z'},
        {'id': 'c3', 'business_id': 'OTHER', 'last_updated_at': '2026-03-01T00:00:00Z'},
      ]);

      // since filter: only c2 is newer than the cursor; c3 is another tenant.
      final incremental = await t.fetchTable(
        TableQuery('categories', 'B', DateTime.utc(2026, 2, 1), pageSize: 500),
      );
      expect(incremental.map((r) => r['id']), ['c2']);

      // full pull for tenant B, ordered by last_updated_at ascending.
      final full = await t.fetchTable(
        const TableQuery('categories', 'B', null, pageSize: 500),
      );
      expect(full.map((r) => r['id']), ['c1', 'c2']);
    });

    test('fetchTable ignores since for businesses and skips the tenant filter '
        'for system_config', () async {
      t.seed('businesses', [
        {'id': 'B', 'last_updated_at': '2020-01-01T00:00:00Z'},
      ]);
      t.seed('system_config', [
        {'key': 'currency', 'value': 'NGN'},
      ]);

      // businesses is fetched unconditionally even with a future cursor.
      final biz = await t.fetchTable(
        TableQuery('businesses', 'B', DateTime.utc(2030), pageSize: 500),
      );
      expect(biz.map((r) => r['id']), ['B']);

      // system_config is global — returned regardless of the businessId arg.
      final cfg = await t.fetchTable(
        const TableQuery('system_config', 'ANY', null, pageSize: 500),
      );
      expect(cfg, hasLength(1));
    });

    test('upsertRows records the write and makes it visible to a later fetch',
        () async {
      await t.upsertRows('categories', [
        {'id': 'c9', 'business_id': 'B', 'last_updated_at': '2026-05-01T00:00:00Z'},
      ]);

      expect(t.upsertedRows('categories').map((r) => r['id']), ['c9']);
      final fetched = await t.fetchTable(
        const TableQuery('categories', 'B', null, pageSize: 500),
      );
      expect(fetched.map((r) => r['id']), ['c9']);
    });

    test('deleteRowsById removes the row and records the ids', () async {
      t.seed('notifications', [
        {'id': 'n1', 'business_id': 'B'},
        {'id': 'n2', 'business_id': 'B'},
      ]);

      await t.deleteRowsById('notifications', ['n1']);

      expect(t.deletedIds('notifications'), ['n1']);
      final remaining = await t.fetchTable(
        const TableQuery('notifications', 'B', null, pageSize: 500),
      );
      expect(remaining.map((r) => r['id']), ['n2']);
    });

    test('failNext makes the next push throw the injected PostgrestException '
        '(vector C/F fault injection)', () async {
      t.failNext(
        'categories',
        const PostgrestException(message: 'permission denied', code: '42501'),
      );

      await expectLater(
        t.upsertRows('categories', [
          {'id': 'x', 'business_id': 'B'},
        ]),
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      // Only the next call fails — a retry succeeds.
      await t.upsertRows('categories', [
        {'id': 'x', 'business_id': 'B'},
      ]);
      expect(t.upsertedRows('categories'), hasLength(1));
    });

    test('startRealtime + emitUpsert delivers a self-describing payload',
        () async {
      PostgresChangePayload? received;
      t.startRealtime(['categories'], 'B', onChange: (p) => received = p);

      t.emitUpsert('categories', {'id': 'c1', 'business_id': 'B'});

      expect(received, isNotNull);
      expect(received!.table, 'categories');
      expect(received!.eventType, PostgresChangeEvent.update);
      expect(received!.newRecord['id'], 'c1');
    });

    test('startBroadcast captures the tenant + callback; emitBroadcastSignal '
        'pumps a data-less nudge; stopBroadcast tears it down', () async {
      var signals = 0;
      t.startBroadcast('B', onSignal: () => signals++);
      expect(t.broadcastActive, isTrue);
      expect(t.broadcastBusinessId, 'B');
      expect(t.startBroadcastCount, 1);

      // A second start is idempotent while a subscription is live (mirrors the
      // real adapter's `_broadcastChannel != null` guard).
      t.startBroadcast('B', onSignal: () => signals += 100);
      expect(t.startBroadcastCount, 1);

      t.emitBroadcastSignal();
      t.emitBroadcastSignal();
      expect(signals, 2); // the first callback fired; the second never bound

      await t.stopBroadcast();
      expect(t.broadcastActive, isFalse);
      expect(t.broadcastBusinessId, isNull);
      expect(t.stopBroadcastCount, 1);
      // After teardown a stray signal is dropped, never delivered.
      t.emitBroadcastSignal();
      expect(signals, 2);
    });

    test('identity: currentAuthUserId is settable and authEvents pumps',
        () async {
      t.setAuthUserId('u-42');
      expect(t.currentAuthUserId, 'u-42');

      expectLater(t.authEvents, emits(TransportAuthEvent.signedOut));
      t.emitAuthEvent(TransportAuthEvent.signedOut);
    });
  });
}
