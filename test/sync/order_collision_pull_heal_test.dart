// order_collision_pull_heal_test.dart
//
// §30.8.1 pull-side legacy order-number collision self-heal. When the cloud's
// authoritative order can't restore because a LOCAL order holds the same
// (business_id, order_number) under a different id (a pre-device-tag offline
// dup), _healLocalOrderNumberBlocker renumbers the local blocker (append this
// device's tag + re-enqueue) so the cloud order — and its FK-children — land in
// the SAME pull instead of orphaning forever. Renumber, never delete: the local
// order is a real, different sale.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';
import 'package:reebaplus_pos/shared/services/secure_storage_service.dart';

import '../helpers/dispatch_test_utils.dart';

class _FakeSecureStorage extends SecureStorageService {
  @override
  Future<String> getOrCreateDeviceId() async => 'pull-heal-device';
}

void main() {
  final ts = DateTime.utc(2026, 6, 7, 12).toIso8601String();

  Map<String, dynamic> cloudOrderRow(
          String id, String number, String businessId) =>
      {
        'id': id,
        'business_id': businessId,
        'order_number': number,
        'customer_id': null,
        'total_amount_kobo': 100000,
        'discount_kobo': 0,
        'net_amount_kobo': 100000,
        'amount_paid_kobo': 100000,
        'payment_type': 'cash',
        'status': 'completed',
        'rider_name': 'Pick-up Order',
        'cancellation_reason': null,
        'barcode': null,
        'staff_id': null,
        'store_id': null,
        'crate_deposit_paid_kobo': 0,
        'completed_at': null,
        'cancelled_at': null,
        'created_at': ts,
        'last_updated_at': ts,
      };

  test('restoring a cloud order whose number a local order holds renumbers the '
      'local blocker and lands the cloud order in the same pull', () async {
    final boot = await bootstrapTestDb();
    final supabase = SupabaseClient(
      'https://placeholder.supabase.co',
      'placeholder-anon-key',
    );
    final sync = SupabaseSyncService(boot.db, supabase, _FakeSecureStorage());
    try {
      // Local pre-tag order occupying ORD-000050 under a LOCAL id.
      final localId = UuidV7.generate();
      await boot.db.into(boot.db.orders).insert(OrdersCompanion.insert(
            id: Value(localId),
            businessId: boot.businessId,
            orderNumber: 'ORD-000050',
            totalAmountKobo: 50000,
            netAmountKobo: 50000,
            paymentType: 'cash',
            status: 'completed',
          ));

      // The cloud's authoritative order carries the SAME number under a
      // DIFFERENT id — this is what was orphaning its children every pull.
      final cloudId = UuidV7.generate();
      await sync.restoreTableDataForTesting(
        'orders',
        [cloudOrderRow(cloudId, 'ORD-000050', boot.businessId)],
      );

      // The local blocker was renumbered with this device's tag…
      final local = await (boot.db.select(boot.db.orders)
            ..where((t) => t.id.equals(localId)))
          .getSingle();
      expect(local.orderNumber, startsWith('ORD-000050-'));
      expect(local.orderNumber, isNot('ORD-000050'));

      // …and re-enqueued so it uploads under the new number.
      final pending = await getPendingQueue(boot.db);
      final reEnqueued = pending.where((r) =>
          r.actionType == 'orders:upsert' &&
          (jsonDecode(r.payload) as Map<String, dynamic>)['id'] == localId);
      expect(reEnqueued, isNotEmpty);

      // …and the cloud's order now lives locally under ORD-000050.
      final cloud = await (boot.db.select(boot.db.orders)
            ..where((t) => t.id.equals(cloudId)))
          .getSingleOrNull();
      expect(cloud, isNotNull,
          reason: 'cloud order must land once the number is freed');
      expect(cloud!.orderNumber, 'ORD-000050');
    } finally {
      await supabase.dispose();
      await boot.db.close();
    }
  });

  test('no local blocker → cloud order restores normally, nothing renumbered',
      () async {
    final boot = await bootstrapTestDb();
    final supabase = SupabaseClient(
      'https://placeholder.supabase.co',
      'placeholder-anon-key',
    );
    final sync = SupabaseSyncService(boot.db, supabase, _FakeSecureStorage());
    try {
      final cloudId = UuidV7.generate();
      await sync.restoreTableDataForTesting(
        'orders',
        [cloudOrderRow(cloudId, 'ORD-000077', boot.businessId)],
      );

      final cloud = await (boot.db.select(boot.db.orders)
            ..where((t) => t.id.equals(cloudId)))
          .getSingle();
      expect(cloud.orderNumber, 'ORD-000077');

      // No spurious re-enqueue.
      final pending = await getPendingQueue(boot.db);
      expect(pending.where((r) => r.actionType == 'orders:upsert'), isEmpty);
    } finally {
      await supabase.dispose();
      await boot.db.close();
    }
  });
}
