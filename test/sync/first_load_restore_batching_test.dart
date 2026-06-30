// first_load_restore_batching_test.dart
//
// Seam B for the First-Load Overlay Redesign (§4.5 / §4.6). Two concerns:
//
//  1. Restore batching: pullInitialData now wraps each table's restore in a
//     single Drift transaction (one commit per table instead of one per row).
//     This test proves the wrap preserves correctness — a caught FK/orphan skip
//     inside the transaction does NOT roll back the good rows, and the table is
//     still recorded in `fkSkipped` so the cursor is held. (The per-row
//     resilience itself is covered by restore_fk_resilience_test; here we assert
//     it still holds when the same restore runs inside a transaction.)
//
//  2. Row-weighted progress: the `PullStatus.rowPercent` getter that the overlay
//     and the thin top line read from.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

void main() {
  group('PullStatus.rowPercent (row-weighted progress, §4.5)', () {
    test('null until the row total is known', () {
      const s = PullStatus(stage: PullStage.background);
      expect(s.rowPercent, isNull);
    });

    test('advances in proportion to rows restored', () {
      const s = PullStatus(
        stage: PullStage.background,
        rowsTotal: 200,
        rowsDone: 50,
      );
      expect(s.rowPercent, 25);
    });

    test('clamps to 100 at completion', () {
      const s = PullStatus(
        stage: PullStage.background,
        rowsTotal: 10,
        rowsDone: 10,
      );
      expect(s.rowPercent, 100);
    });
  });

  group('restore inside a transaction (§4.6 batching)', () {
    late AppDatabase db;
    late SupabaseClient supabase;
    late SupabaseSyncService sync;
    late String businessId;
    late String storeId;
    late String manufacturerId;
    late String absentSupplierId;

    final ts = DateTime.utc(2026, 6, 30, 12).toIso8601String();

    Map<String, dynamic> productRow(
      String id, {
      String? supplierId,
      String? manufacturerId,
    }) => {
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

      await db
          .into(db.businesses)
          .insert(
            BusinessesCompanion.insert(id: Value(businessId), name: 'Test Biz'),
          );
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(
              id: Value(storeId),
              businessId: businessId,
              name: 'Main Store',
            ),
          );
      await db
          .into(db.manufacturers)
          .insert(
            ManufacturersCompanion.insert(
              id: Value(manufacturerId),
              businessId: businessId,
              name: 'Acme',
            ),
          );
      // No supplier row for absentSupplierId — the deliberately missing parent.
    });

    tearDown(() async {
      await supabase.dispose();
      await db.close();
    });

    test('all-valid batch lands every row in one transaction (parity)', () async {
      final ids = [for (var i = 0; i < 5; i++) UuidV7.generate()];
      await db.transaction(
        () => sync.restoreTableDataForTesting(
          'products',
          [for (final id in ids) productRow(id, manufacturerId: manufacturerId)],
        ),
      );
      final products = await db.select(db.products).get();
      expect(products.map((p) => p.id).toSet(), ids.toSet(),
          reason: 'every valid row commits when restored inside a transaction');
    });

    test(
        'an orphaned row is skipped WITHOUT rolling back the good rows in the '
        'same transaction, and the table is still recorded in fkSkipped',
        () async {
      final goodId = UuidV7.generate();
      final orphanId = UuidV7.generate();
      final fkSkipped = <String>{};

      await db.transaction(
        () => sync.restoreTableDataForTesting(
          'products',
          [
            productRow(goodId, manufacturerId: manufacturerId),
            productRow(orphanId, supplierId: absentSupplierId),
          ],
          fkSkipped: fkSkipped,
        ),
      );

      final products = await db.select(db.products).get();
      expect(products.map((p) => p.id), [goodId],
          reason: 'caught FK skip must not roll back the committed good row');
      expect(fkSkipped, contains('products'),
          reason: 'cursor-hold semantics preserved under transaction batching');
    });
  });
}
