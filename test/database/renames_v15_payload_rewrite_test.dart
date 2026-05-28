// renames_v15_payload_rewrite_test.dart
//
// Verifies the JSON payload rewrites performed by the v15 (pivot step 4
// "small renames") migration in lib/core/database/app_database.dart.
//
// The v15 block performs five sync_queue rewrites after its column /
// table renames (see the `if (from < 15)` block):
//
//   1. Top-level   $.customer_group  → $.price_tier   (customers upserts)
//   2. Domain      $.p_customer_group → $.p_price_tier (pos_create_customer)
//   3. action_type purchases:upsert  → shipments:upsert
//   4. action_type purchases:delete  → shipments:delete
//   5. Top-level   $.purchase_id     → $.shipment_id, scoped to
//      action_type IN (stock_transactions:upsert, payment_transactions:upsert)
//      ONLY — purchase_items KEEPS purchase_id (that table is dropped in
//      step 25, so its payloads must not be rewritten).
//
// Without these, pending rows enqueued before v15 would hard-fail with
// PostgREST 42703 once cloud 0046 deploys (it renames the columns and the
// pos_create_customer parameter).
//
// Like stores_v14_payload_rewrite_test.dart, this runs the same SQL the
// migration block runs and asserts the rewrites land, leave unrelated
// rows alone, and are idempotent. IMPORTANT: the SQL in runV15PayloadRewrite
// below is a verbatim mirror of the migration block — if you change one,
// change the other.

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

  // Mirrors the rewrite SQL embedded in the v15 migration block in
  // app_database.dart. If you change the SQL there, change it here.
  Future<void> runV15PayloadRewrite() async {
    // (a) customers.customer_group → price_tier (table-upsert envelopes).
    await db.customStatement(
      "UPDATE sync_queue "
      "SET payload = json_remove("
      "  json_set(payload, '\$.price_tier', json_extract(payload, '\$.customer_group')), "
      "  '\$.customer_group'"
      ") "
      "WHERE status = 'pending' "
      "  AND json_extract(payload, '\$.customer_group') IS NOT NULL",
    );
    // (a) pos_create_customer domain envelope p_customer_group → p_price_tier.
    await db.customStatement(
      "UPDATE sync_queue "
      "SET payload = json_remove("
      "  json_set(payload, '\$.p_price_tier', json_extract(payload, '\$.p_customer_group')), "
      "  '\$.p_customer_group'"
      ") "
      "WHERE status = 'pending' "
      "  AND json_extract(payload, '\$.p_customer_group') IS NOT NULL",
    );
    // (b) purchases:* action types → shipments:*.
    await db.customStatement(
      "UPDATE sync_queue SET action_type = 'shipments:upsert' "
      "WHERE action_type = 'purchases:upsert' AND status = 'pending'",
    );
    await db.customStatement(
      "UPDATE sync_queue SET action_type = 'shipments:delete' "
      "WHERE action_type = 'purchases:delete' AND status = 'pending'",
    );
    // (b) ledger purchase_id → shipment_id, scoped to the two permanent
    // ledger tables only. purchase_items KEEPS purchase_id.
    await db.customStatement(
      "UPDATE sync_queue "
      "SET payload = json_remove("
      "  json_set(payload, '\$.shipment_id', json_extract(payload, '\$.purchase_id')), "
      "  '\$.purchase_id'"
      ") "
      "WHERE status = 'pending' "
      "  AND action_type IN ('stock_transactions:upsert', 'payment_transactions:upsert') "
      "  AND json_extract(payload, '\$.purchase_id') IS NOT NULL",
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

  group('Schema v15 — sync_queue payload rewrite', () {
    test('customers upsert: top-level customer_group → price_tier', () async {
      await enqueue(
        actionType: 'customers:upsert',
        payload: {
          'id': 'cust-1',
          'business_id': 'biz-1',
          'name': 'Ada',
          'customer_group': 'wholesaler',
        },
      );

      await runV15PayloadRewrite();

      final p = await readPayload('customers:upsert');
      expect(p['price_tier'], 'wholesaler');
      expect(p.containsKey('customer_group'), isFalse);
      // Other keys untouched.
      expect(p['id'], 'cust-1');
      expect(p['business_id'], 'biz-1');
      expect(p['name'], 'Ada');
    });

    test('domain pos_create_customer: p_customer_group → p_price_tier',
        () async {
      await enqueue(
        actionType: 'domain:pos_create_customer',
        payload: {
          'p_business_id': 'biz-1',
          'p_customer_id': 'cust-1',
          'p_customer_group': 'retailer',
          'p_name': 'Ada',
        },
      );

      await runV15PayloadRewrite();

      final p = await readPayload('domain:pos_create_customer');
      expect(p['p_price_tier'], 'retailer');
      expect(p.containsKey('p_customer_group'), isFalse);
      expect(p['p_business_id'], 'biz-1');
      expect(p['p_name'], 'Ada');
    });

    test('action_type purchases:upsert → shipments:upsert (payload kept)',
        () async {
      await enqueue(
        actionType: 'purchases:upsert',
        payload: {'id': 'ship-1', 'supplier_id': 'sup-1', 'status': 'pending'},
      );

      await runV15PayloadRewrite();

      expect(await countByActionType('purchases:upsert'), 0);
      final p = await readPayload('shipments:upsert');
      expect(p['id'], 'ship-1');
      expect(p['supplier_id'], 'sup-1');
      expect(p['status'], 'pending');
    });

    test('action_type purchases:delete → shipments:delete', () async {
      await enqueue(
        actionType: 'purchases:delete',
        payload: {'id': 'ship-9'},
      );

      await runV15PayloadRewrite();

      expect(await countByActionType('purchases:delete'), 0);
      final p = await readPayload('shipments:delete');
      expect(p['id'], 'ship-9');
    });

    test('ledger tables: purchase_id → shipment_id', () async {
      await enqueue(
        actionType: 'stock_transactions:upsert',
        payload: {'id': 'stx-1', 'purchase_id': 'pur-1', 'quantity_delta': 5},
      );
      await enqueue(
        actionType: 'payment_transactions:upsert',
        payload: {'id': 'pay-1', 'purchase_id': 'pur-2', 'amount_kobo': 100},
      );

      await runV15PayloadRewrite();

      final stx = await readPayload('stock_transactions:upsert');
      expect(stx['shipment_id'], 'pur-1');
      expect(stx.containsKey('purchase_id'), isFalse);
      expect(stx['quantity_delta'], 5);

      final pay = await readPayload('payment_transactions:upsert');
      expect(pay['shipment_id'], 'pur-2');
      expect(pay.containsKey('purchase_id'), isFalse);
      expect(pay['amount_kobo'], 100);
    });

    test('purchase_items KEEPS purchase_id (scoped out of the rewrite)',
        () async {
      // purchase_items is deferred to step 25 and retains purchase_id; its
      // payloads must NOT be rewritten to shipment_id.
      await enqueue(
        actionType: 'purchase_items:upsert',
        payload: {'id': 'pi-1', 'purchase_id': 'pur-1', 'quantity': 3},
      );

      await runV15PayloadRewrite();

      final p = await readPayload('purchase_items:upsert');
      expect(p['purchase_id'], 'pur-1');
      expect(p.containsKey('shipment_id'), isFalse);
      expect(p['quantity'], 3);
    });

    test('payloads without any renamed key are not modified', () async {
      await enqueue(
        actionType: 'products:upsert',
        payload: {'id': 'prod-1', 'name': 'Widget'},
      );

      await runV15PayloadRewrite();

      final p = await readPayload('products:upsert');
      expect(p, {'id': 'prod-1', 'name': 'Widget'});
    });

    test('non-pending rows are skipped', () async {
      await enqueue(
        actionType: 'customers:upsert',
        payload: {'id': 'c-done', 'customer_group': 'wholesaler'},
        status: 'completed',
      );

      await runV15PayloadRewrite();

      final p = await readPayload('customers:upsert');
      // Completed rows are historical — leave them (and their action_type)
      // alone.
      expect(p['customer_group'], 'wholesaler');
      expect(p.containsKey('price_tier'), isFalse);
    });

    test('idempotent on a redundant second run', () async {
      await enqueue(
        actionType: 'customers:upsert',
        payload: {'id': 'c-1', 'customer_group': 'retailer'},
      );

      await runV15PayloadRewrite();
      await runV15PayloadRewrite();

      final p = await readPayload('customers:upsert');
      expect(p['price_tier'], 'retailer');
      expect(p.containsKey('customer_group'), isFalse);
    });
  });
}
