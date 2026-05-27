// stores_v14_payload_rewrite_test.dart
//
// Verifies the JSON payload rewrite performed by the v14 (warehouses →
// stores) migration in lib/core/database/app_database.dart (PIVOT_PLAN
// step 3).
//
// The migration block has two payload-rewrite UPDATEs at the bottom
// (after the column renames):
//
//   1. Top-level $.warehouse_id  → $.store_id   (table-upsert envelopes)
//   2. Top-level $.p_warehouse_id → $.p_store_id (domain RPC envelopes)
//
// Without these, pending sync_queue rows enqueued before v14 would
// either silently lose intent (writes to users.store_id stripped by
// the push-time column whitelist) or hard-fail with PostgREST 42703
// once cloud 0045 deploys.
//
// This test runs the same SQL statements that the v14 block runs and
// asserts both rewrites land correctly, leave unrelated keys alone,
// and skip already-renamed payloads.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // Force onCreate to materialise the schema (incl. sync_queue).
    await db.customSelect('SELECT 1').get();
    // sync_queue.business_id is NOT NULL + FK to businesses. Seed
    // one business row to satisfy the constraint.
    businessId = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
            id: Value(businessId),
            name: 'Test Business',
          ),
        );
  });

  tearDown(() => db.close());

  // Mirrors the rewrite SQL embedded in the v14 migration block in
  // app_database.dart. If you change the SQL there, change it here.
  Future<void> runV14PayloadRewrite() async {
    await db.customStatement(
      "UPDATE sync_queue "
      "SET payload = json_remove("
      "  json_set(payload, '\$.store_id', json_extract(payload, '\$.warehouse_id')), "
      "  '\$.warehouse_id'"
      ") "
      "WHERE status = 'pending' "
      "  AND json_extract(payload, '\$.warehouse_id') IS NOT NULL",
    );
    await db.customStatement(
      "UPDATE sync_queue "
      "SET payload = json_remove("
      "  json_set(payload, '\$.p_store_id', json_extract(payload, '\$.p_warehouse_id')), "
      "  '\$.p_warehouse_id'"
      ") "
      "WHERE status = 'pending' "
      "  AND json_extract(payload, '\$.p_warehouse_id') IS NOT NULL",
    );
  }

  Future<void> enqueue({
    required String actionType,
    required Map<String, dynamic> payload,
    String status = 'pending',
  }) async {
    await db.customStatement(
      "INSERT INTO sync_queue (id, business_id, action_type, payload, status, attempts, created_at, is_synced) "
      "VALUES (?, ?, ?, ?, ?, 0, ?, 0)",
      [
        'qid-${DateTime.now().microsecondsSinceEpoch}-${actionType.hashCode}',
        businessId,
        actionType,
        jsonEncode(payload),
        status,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ],
    );
  }

  Future<Map<String, dynamic>> readPayload(String actionType) async {
    final row = await db
        .customSelect(
          "SELECT payload FROM sync_queue WHERE action_type = ? LIMIT 1",
          variables: [Variable<String>(actionType)],
        )
        .getSingle();
    return jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
  }

  group('Schema v14 — sync_queue payload rewrite', () {
    test('table-upsert envelope: top-level warehouse_id → store_id', () async {
      await enqueue(
        actionType: 'users:upsert',
        payload: {
          'id': 'user-1',
          'business_id': 'biz-1',
          'name': 'Test',
          'warehouse_id': 'wh-1',
        },
      );

      await runV14PayloadRewrite();

      final p = await readPayload('users:upsert');
      expect(p['store_id'], 'wh-1');
      expect(p.containsKey('warehouse_id'), isFalse);
      // Other keys untouched.
      expect(p['id'], 'user-1');
      expect(p['business_id'], 'biz-1');
      expect(p['name'], 'Test');
    });

    test('cross-table tables get the same rewrite', () async {
      // These are the tables whose payloads could carry warehouse_id —
      // anything that had a warehouse_id FK column pre-v14.
      const tables = [
        'customers',
        'inventory',
        'orders',
        'order_items',
        'expenses',
        'stock_adjustments',
        'activity_logs',
        'invite_codes',
        'user_stores',
      ];

      for (final t in tables) {
        await enqueue(
          actionType: '$t:upsert',
          payload: {'id': 'row-$t', 'warehouse_id': 'wh-$t'},
        );
      }

      await runV14PayloadRewrite();

      for (final t in tables) {
        final p = await readPayload('$t:upsert');
        expect(p['store_id'], 'wh-$t', reason: 'table=$t');
        expect(p.containsKey('warehouse_id'), isFalse, reason: 'table=$t');
      }
    });

    test('domain envelope: top-level p_warehouse_id → p_store_id', () async {
      await enqueue(
        actionType: 'domain:complete_onboarding',
        payload: {
          'p_business_id': 'biz-1',
          'p_warehouse_id': 'wh-1',
          'p_owner_name': 'Owner',
        },
      );

      await runV14PayloadRewrite();

      final p = await readPayload('domain:complete_onboarding');
      expect(p['p_store_id'], 'wh-1');
      expect(p.containsKey('p_warehouse_id'), isFalse);
      expect(p['p_business_id'], 'biz-1');
      expect(p['p_owner_name'], 'Owner');
    });

    test('payloads without warehouse_id are not modified', () async {
      await enqueue(
        actionType: 'products:upsert',
        payload: {'id': 'prod-1', 'name': 'Widget'},
      );

      await runV14PayloadRewrite();

      final p = await readPayload('products:upsert');
      expect(p, {'id': 'prod-1', 'name': 'Widget'});
    });

    test('non-pending rows are skipped', () async {
      await enqueue(
        actionType: 'users:upsert',
        payload: {'id': 'u-done', 'warehouse_id': 'wh-1'},
        status: 'completed',
      );

      await runV14PayloadRewrite();

      final p = await readPayload('users:upsert');
      // Completed rows are historical — leave them alone.
      expect(p['warehouse_id'], 'wh-1');
      expect(p.containsKey('store_id'), isFalse);
    });

    test('already-renamed payloads (store_id already present) survive '
        'a redundant run idempotently', () async {
      await enqueue(
        actionType: 'users:upsert',
        payload: {'id': 'u-1', 'store_id': 'wh-1'},
      );

      // Run the rewrite twice — both should be no-ops since
      // warehouse_id is absent.
      await runV14PayloadRewrite();
      await runV14PayloadRewrite();

      final p = await readPayload('users:upsert');
      expect(p['store_id'], 'wh-1');
      expect(p.containsKey('warehouse_id'), isFalse);
    });

    test('both rewrites can apply to the same row (mixed payload)', () async {
      // Hypothetical pre-v14 payload that nested both — confirms the
      // two UPDATEs cooperate rather than fight.
      await enqueue(
        actionType: 'domain:pos_record_expense',
        payload: {
          'p_business_id': 'biz-1',
          'p_warehouse_id': 'wh-top',
          'warehouse_id': 'wh-extra',
        },
      );

      await runV14PayloadRewrite();

      final p = await readPayload('domain:pos_record_expense');
      expect(p['p_store_id'], 'wh-top');
      expect(p['store_id'], 'wh-extra');
      expect(p.containsKey('p_warehouse_id'), isFalse);
      expect(p.containsKey('warehouse_id'), isFalse);
    });
  });
}
