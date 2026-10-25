// #426: Online Orders reach shop phones through the normal pull. Status is
// monotonic: a stale `new` snapshot must never overwrite an answered order
// (Restore.monotonicStatus with openStatus 'new').

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

void main() {
  late AppDatabase db;
  late SupabaseClient supabase;
  late SupabaseSyncService sync;
  late String businessId;
  late String storeId;
  late String productId;
  final orderId = UuidV7.generate();

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    db.businessIdResolver = () => businessId;
    supabase = SupabaseClient('https://placeholder.supabase.co', 'anon-key');
    sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));
    storeId = UuidV7.generate();
    productId = UuidV7.generate();
    await db.into(db.businesses).insert(
        BusinessesCompanion.insert(id: Value(businessId), name: 'Biz'));
    await db.into(db.stores).insert(StoresCompanion.insert(
        id: Value(storeId), businessId: businessId, name: 'Main'));
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: Value(productId), businessId: businessId, name: 'Star Lager'));
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  Map<String, dynamic> order(String status, DateTime lua) => {
        'id': orderId,
        'business_id': businessId,
        'store_id': storeId,
        'shopper_account_id': UuidV7.generate(),
        'customer_id': null,
        'status': status,
        'reference': 'ON-1A2B3C4D',
        'currency': 'NGN',
        'estimated_total_kobo': 900000,
        'shopper_name': 'Ada',
        'delivery_phone': '08030000000',
        'delivery_country': 'Nigeria',
        'delivery_state': 'Nasarawa',
        'delivery_lga': 'Keffi',
        'delivery_street': '1 Road',
        'note': null,
        'decline_reason': null,
        'cancel_reason': null,
        'linked_order_id': null,
        'placed_at': lua.toIso8601String(),
        'responded_at': null,
        'created_at': lua.toIso8601String(),
        'last_updated_at': lua.toIso8601String(),
      };

  Future<String> statusOf() async =>
      (await (db.select(db.onlineOrders)..where((t) => t.id.equals(orderId)))
              .getSingle())
          .status;

  test('a placed order and its lines are pulled to the shop phone', () async {
    final at = DateTime.utc(2026, 10, 25, 9);
    await sync.restoreTableDataForTesting('online_orders', [order('new', at)]);
    await sync.restoreTableDataForTesting('online_order_lines', [
      {
        'id': UuidV7.generate(),
        'business_id': businessId,
        'online_order_id': orderId,
        'product_id': productId,
        'product_name': 'Star Lager',
        'unit': 'Crate',
        'unit_price_kobo': 450000,
        'price_tier': 'retailer',
        'requested_qty': 2,
        'accepted_qty': null,
        'created_at': at.toIso8601String(),
        'last_updated_at': at.toIso8601String(),
      },
    ]);
    expect(await statusOf(), 'new');
    final line = await db.select(db.onlineOrderLines).getSingle();
    expect(line.requestedQty, 2);
    expect(line.unitPriceKobo, 450000);
  });

  test('a stale `new` never overwrites an accepted order', () async {
    final at = DateTime.utc(2026, 10, 25, 9);
    await sync.restoreTableDataForTesting(
        'online_orders', [order('accepted', at)]);
    expect(await statusOf(), 'accepted');
    await sync.restoreTableDataForTesting('online_orders',
        [order('new', at.add(const Duration(minutes: 5)))]);
    expect(await statusOf(), 'accepted');
  });

  test('answers still converge (new → declined)', () async {
    final at = DateTime.utc(2026, 10, 25, 9);
    await sync.restoreTableDataForTesting('online_orders', [order('new', at)]);
    await sync.restoreTableDataForTesting('online_orders',
        [order('declined', at.add(const Duration(minutes: 1)))]);
    expect(await statusOf(), 'declined');
  });

  test('an expired row restores, and a stale `new` cannot revive it', () async {
    final at = DateTime.utc(2026, 10, 25, 9);
    await sync.restoreTableDataForTesting('online_orders', [order('new', at)]);
    await sync.restoreTableDataForTesting('online_orders',
        [order('expired', at.add(const Duration(hours: 48)))]);
    expect(await statusOf(), 'expired');
    await sync.restoreTableDataForTesting('online_orders',
        [order('new', at.add(const Duration(hours: 49)))]);
    expect(await statusOf(), 'expired');
  });
}
