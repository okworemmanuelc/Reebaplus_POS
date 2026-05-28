// crate_size_groups_v16_payload_rewrite_test.dart
//
// Verifies the JSON payload + action_type rewrites performed by the v16
// (Crate Size Groups) migration in lib/core/database/app_database.dart.
//
// The v16 block performs four sync_queue rewrites after its table / column
// renames (see the `if (from < 16)` block):
//
//   1. action_type crate_groups:upsert → crate_size_groups:upsert
//   2. action_type crate_groups:delete → crate_size_groups:delete
//   3. Top-level   $.crate_group_id    → $.crate_size_group_id  (table upserts:
//      products, suppliers, the two crate-balance caches, pending_crate_returns)
//   4. Domain      $.p_crate_group_id  → $.p_crate_size_group_id
//      (pos_create_product, pos_record_crate_return)
//
// Without these, pending rows enqueued before v16 would hard-fail with
// PostgREST 42703 once cloud 0047 deploys (it renames the table, the FK
// columns, and the RPC parameter).
//
// Like renames_v15_payload_rewrite_test.dart, this runs the same SQL the
// migration block runs and asserts the rewrites land, leave unrelated rows
// alone, and are idempotent. IMPORTANT: the SQL in runV16PayloadRewrite below
// is a verbatim mirror of the migration block — if you change one, change the
// other.

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
    await db.customSelect('SELECT 1').get();
    businessId = UuidV7.generate();
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(
            id: Value(businessId),
            name: 'Test Business',
          ),
        );
  });

  tearDown(() => db.close());

  // Mirrors the rewrite SQL embedded in the v16 migration block in
  // app_database.dart. If you change the SQL there, change it here.
  Future<void> runV16PayloadRewrite() async {
    await db.customStatement(
      "UPDATE sync_queue SET action_type = 'crate_size_groups:upsert' "
      "WHERE action_type = 'crate_groups:upsert' AND status = 'pending'",
    );
    await db.customStatement(
      "UPDATE sync_queue SET action_type = 'crate_size_groups:delete' "
      "WHERE action_type = 'crate_groups:delete' AND status = 'pending'",
    );
    await db.customStatement(
      "UPDATE sync_queue "
      "SET payload = json_remove("
      "  json_set(payload, '\$.crate_size_group_id', json_extract(payload, '\$.crate_group_id')), "
      "  '\$.crate_group_id'"
      ") "
      "WHERE status = 'pending' "
      "  AND json_extract(payload, '\$.crate_group_id') IS NOT NULL",
    );
    await db.customStatement(
      "UPDATE sync_queue "
      "SET payload = json_remove("
      "  json_set(payload, '\$.p_crate_size_group_id', json_extract(payload, '\$.p_crate_group_id')), "
      "  '\$.p_crate_group_id'"
      ") "
      "WHERE status = 'pending' "
      "  AND json_extract(payload, '\$.p_crate_group_id') IS NOT NULL",
    );
  }

  var seq = 0;
  Future<void> enqueue({
    required String actionType,
    required Map<String, dynamic> payload,
    String status = 'pending',
  }) async {
    await db.customStatement(
      "INSERT INTO sync_queue (id, business_id, action_type, payload, status, attempts, created_at, is_synced) "
      "VALUES (?, ?, ?, ?, ?, 0, ?, 0)",
      [
        'qid-${DateTime.now().microsecondsSinceEpoch}-${seq++}',
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

  Future<int> countByActionType(String actionType) async {
    final row = await db
        .customSelect(
          "SELECT COUNT(*) AS c FROM sync_queue WHERE action_type = ?",
          variables: [Variable<String>(actionType)],
        )
        .getSingle();
    return row.read<int>('c');
  }

  group('Schema v16 — crate_size_groups sync_queue rewrite', () {
    test('action_type crate_groups:upsert → crate_size_groups:upsert (payload kept)',
        () async {
      await enqueue(
        actionType: 'crate_groups:upsert',
        payload: {'id': 'cg-1', 'name': 'Crate A', 'crate_size_label': 'big'},
      );

      await runV16PayloadRewrite();

      expect(await countByActionType('crate_groups:upsert'), 0);
      final p = await readPayload('crate_size_groups:upsert');
      expect(p['id'], 'cg-1');
      expect(p['name'], 'Crate A');
      expect(p['crate_size_label'], 'big');
    });

    test('action_type crate_groups:delete → crate_size_groups:delete', () async {
      await enqueue(actionType: 'crate_groups:delete', payload: {'id': 'cg-9'});

      await runV16PayloadRewrite();

      expect(await countByActionType('crate_groups:delete'), 0);
      final p = await readPayload('crate_size_groups:delete');
      expect(p['id'], 'cg-9');
    });

    test('table upsert: top-level crate_group_id → crate_size_group_id',
        () async {
      await enqueue(
        actionType: 'products:upsert',
        payload: {
          'id': 'prod-1',
          'name': 'Star Lager',
          'crate_group_id': 'cg-1',
        },
      );

      await runV16PayloadRewrite();

      final p = await readPayload('products:upsert');
      expect(p['crate_size_group_id'], 'cg-1');
      expect(p.containsKey('crate_group_id'), isFalse);
      expect(p['id'], 'prod-1');
      expect(p['name'], 'Star Lager');
    });

    test('domain pos_create_product: p_crate_group_id → p_crate_size_group_id',
        () async {
      await enqueue(
        actionType: 'domain:pos_create_product_v2',
        payload: {
          'p_business_id': 'biz-1',
          'p_product_id': 'prod-1',
          'p_crate_group_id': 'cg-1',
          'p_name': 'Star Lager',
        },
      );

      await runV16PayloadRewrite();

      final p = await readPayload('domain:pos_create_product_v2');
      expect(p['p_crate_size_group_id'], 'cg-1');
      expect(p.containsKey('p_crate_group_id'), isFalse);
      expect(p['p_business_id'], 'biz-1');
      expect(p['p_name'], 'Star Lager');
    });

    test('domain pos_record_crate_return: p_crate_group_id → p_crate_size_group_id',
        () async {
      await enqueue(
        actionType: 'domain:pos_record_crate_return',
        payload: {
          'p_business_id': 'biz-1',
          'p_ledger_id': 'led-1',
          'p_crate_group_id': 'cg-1',
          'p_quantity_delta': -3,
        },
      );

      await runV16PayloadRewrite();

      final p = await readPayload('domain:pos_record_crate_return');
      expect(p['p_crate_size_group_id'], 'cg-1');
      expect(p.containsKey('p_crate_group_id'), isFalse);
      expect(p['p_quantity_delta'], -3);
    });

    test('payloads without any renamed key are not modified', () async {
      await enqueue(
        actionType: 'customers:upsert',
        payload: {'id': 'cust-1', 'name': 'Ada'},
      );

      await runV16PayloadRewrite();

      final p = await readPayload('customers:upsert');
      expect(p, {'id': 'cust-1', 'name': 'Ada'});
    });

    test('non-pending rows are skipped', () async {
      await enqueue(
        actionType: 'crate_groups:upsert',
        payload: {'id': 'cg-done', 'crate_group_id': 'cg-x'},
        status: 'completed',
      );

      await runV16PayloadRewrite();

      // Completed rows are historical — action_type and payload left alone.
      expect(await countByActionType('crate_groups:upsert'), 1);
      final p = await readPayload('crate_groups:upsert');
      expect(p['crate_group_id'], 'cg-x');
      expect(p.containsKey('crate_size_group_id'), isFalse);
    });

    test('idempotent on a redundant second run', () async {
      await enqueue(
        actionType: 'products:upsert',
        payload: {'id': 'prod-1', 'crate_group_id': 'cg-1'},
      );

      await runV16PayloadRewrite();
      await runV16PayloadRewrite();

      final p = await readPayload('products:upsert');
      expect(p['crate_size_group_id'], 'cg-1');
      expect(p.containsKey('crate_group_id'), isFalse);
    });
  });
}
