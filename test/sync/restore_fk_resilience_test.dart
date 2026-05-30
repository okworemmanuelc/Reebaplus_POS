// restore_fk_resilience_test.dart
//
// Phase 0 of the inventory re-sequence plan: a Cashier logging in crashed with
// `SqliteException(787) FOREIGN KEY constraint failed` when the inbound
// snapshot carried a product whose parent (supplier / manufacturer / category)
// slice was absent locally — the whole pull aborted and the app couldn't load.
//
// The fix: `_restoreTableData` now isolates per-row FOREIGN KEY violations on
// the product-cascade tables, skips-and-logs the orphaned row, and records its
// table in `fkSkipped` so `pullChanges` holds the sync cursor and the next full
// pull retries it once the parent arrives. The restore must NOT throw and the
// non-orphaned rows must still land.
//
// These tests drive `_restoreTableData` through the @visibleForTesting seam
// against an in-memory DB (foreign_keys = ON), so no network is exercised.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

void main() {
  late AppDatabase db;
  late SupabaseClient supabase;
  late SupabaseSyncService sync;

  late String businessId;
  late String storeId;
  late String manufacturerId; // present parent
  late String absentSupplierId; // deliberately never inserted

  final ts = DateTime.utc(2026, 5, 28, 12).toIso8601String();

  Map<String, dynamic> productRow(
    String id, {
    String? supplierId,
    String? manufacturerId,
  }) =>
      {
        'id': id,
        'business_id': businessId,
        'category_id': null,
        'crate_size_group_id': null,
        'supplier_id': supplierId,
        'manufacturer_id': manufacturerId,
        'name': 'Product $id',
        'subtitle': null,
        'sku': null,
        'size': null,
        'unit': 'Bottle',
        'retailer_price_kobo': 50000,
        'wholesaler_price_kobo': 45000,
        'buying_price_kobo': 30000,
        'icon_code_point': null,
        'color_hex': '#3B82F6',
        'is_available': true,
        'is_deleted': false,
        'low_stock_threshold': 5,
        'avg_daily_sales': 0.0,
        'lead_time_days': 0,
        'safety_stock_qty': 0,
        'monthly_target_units': 0,
        'empty_crate_value_kobo': 0,
        'track_empties': false,
        'allow_fractional_sales': false,
        'barcode': null,
        'image_path': null,
        'version': 1,
        'created_at': ts,
        'last_updated_at': ts,
      };

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    supabase = SupabaseClient(
      'https://placeholder.supabase.co',
      'placeholder-anon-key',
    );
    sync = SupabaseSyncService(db, supabase);

    businessId = UuidV7.generate();
    storeId = UuidV7.generate();
    manufacturerId = UuidV7.generate();
    absentSupplierId = UuidV7.generate();

    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Test Biz'),
        );
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: Value(manufacturerId),
            businessId: businessId,
            name: 'Acme',
          ),
        );
    // NB: no supplier row for `absentSupplierId` — this is the missing parent.
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  test(
      'product referencing an absent supplier is skipped, not crashed; '
      'good products still land and the table is recorded in fkSkipped',
      () async {
    final goodId = UuidV7.generate();
    final orphanId = UuidV7.generate();
    final fkSkipped = <String>{};

    // Must not throw even though one row violates an FK.
    await sync.restoreTableDataForTesting(
      'products',
      [
        productRow(goodId, manufacturerId: manufacturerId),
        productRow(orphanId, supplierId: absentSupplierId),
      ],
      fkSkipped: fkSkipped,
    );

    final products = await db.select(db.products).get();
    expect(products.map((p) => p.id), [goodId],
        reason: 'good product lands; orphaned product is skipped');
    expect(fkSkipped, contains('products'));
  });

  test('cascade: inventory for a skipped product is itself skipped', () async {
    final goodId = UuidV7.generate();
    final orphanId = UuidV7.generate();
    final fkSkipped = <String>{};

    await sync.restoreTableDataForTesting(
      'products',
      [
        productRow(goodId, manufacturerId: manufacturerId),
        productRow(orphanId, supplierId: absentSupplierId),
      ],
      fkSkipped: fkSkipped,
    );

    // Inventory for both products. The row for the skipped (never-inserted)
    // product must FK-fail-then-skip; the row for the good product lands.
    await sync.restoreTableDataForTesting(
      'inventory',
      [
        {
          'id': UuidV7.generate(),
          'business_id': businessId,
          'product_id': goodId,
          'store_id': storeId,
          'quantity': 10,
          'created_at': ts,
          'last_updated_at': ts,
        },
        {
          'id': UuidV7.generate(),
          'business_id': businessId,
          'product_id': orphanId,
          'store_id': storeId,
          'quantity': 7,
          'created_at': ts,
          'last_updated_at': ts,
        },
      ],
      fkSkipped: fkSkipped,
    );

    final inventory = await db.select(db.inventory).get();
    expect(inventory.map((i) => i.productId), [goodId],
        reason: 'inventory for the skipped product is itself skipped');
    expect(fkSkipped, containsAll(<String>{'products', 'inventory'}));
  });

  test('a fully-satisfiable batch leaves fkSkipped empty (no false positives)',
      () async {
    final id = UuidV7.generate();
    final fkSkipped = <String>{};

    await sync.restoreTableDataForTesting(
      'products',
      [productRow(id, manufacturerId: manufacturerId)],
      fkSkipped: fkSkipped,
    );

    expect(await db.select(db.products).get(), hasLength(1));
    expect(fkSkipped, isEmpty);
  });
}
