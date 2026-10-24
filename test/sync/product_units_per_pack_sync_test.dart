// products.units_per_pack (#487) — "how many in one", display only.
//
// products is a pass-through push table (no push-column whitelist) restored by
// ProductData.fromJson, so the new column needs no registry change. These tests
// pin that it actually round-trips: the DAO write paths carry it into the
// outbox payload, the push scrub keeps it, the pull restore writes it, and an
// edit that does not carry it never wipes it.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  Future<ProductData> row(String id) =>
      (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();

  Future<Map<String, dynamic>> pendingProductPayload(String id) async {
    final rows = (await getPendingQueue(db))
        .where((q) => q.actionType == 'products:upsert')
        .map(decodePayload)
        .where((p) => p['id'] == id)
        .toList();
    expect(rows, hasLength(1));
    return rows.single;
  }

  test('Add Product (v1 path) saves it and pushes units_per_pack', () async {
    await setFlag(db, 'feature.domain_rpcs_v2.create_product', on: false);
    final id = await db.catalogDao.insertProductWithInitialStock(
      ProductsCompanion.insert(
        businessId: businessId,
        name: 'Star Lager',
        unit: const Value('Bottle'),
        unitsPerPack: const Value(12),
      ),
    );

    expect((await row(id)).unitsPerPack, 12);
    final payload = await pendingProductPayload(id);
    expect(payload['units_per_pack'], 12);
    expect(
      SupabaseSyncService.scrubForTesting(
        'products',
        payload,
      )['units_per_pack'],
      12,
      reason: 'products has no push whitelist, so the column is not scrubbed',
    );
  });

  test('a product saved without it pushes no units_per_pack key', () async {
    final id = await db.catalogDao.insertProduct(
      ProductsCompanion.insert(businessId: businessId, name: 'Gulder'),
    );
    expect((await row(id)).unitsPerPack, isNull);
    expect(
      (await pendingProductPayload(id)).containsKey('units_per_pack'),
      isFalse,
      reason: 'safe against a cloud that has not run 0187 yet',
    );
  });

  test('Update Product writes it when given', () async {
    final id = await db.catalogDao.insertProduct(
      ProductsCompanion.insert(businessId: businessId, name: 'Gulder'),
    );
    await db.catalogDao.updateProductDetails(
      id,
      name: 'Gulder',
      buyingPriceKobo: 100,
      retailerPriceKobo: 200,
      wholesalerPriceKobo: 150,
      unitsPerPack: 24,
    );
    expect((await row(id)).unitsPerPack, 24);
    expect((await pendingProductPayload(id))['units_per_pack'], 24);
  });

  test('an edit that does not carry it never wipes it', () async {
    final id = await db.catalogDao.insertProduct(
      ProductsCompanion.insert(
        businessId: businessId,
        name: 'Star Lager',
        unitsPerPack: const Value(12),
      ),
    );

    await db.catalogDao.updateProductDetails(
      id,
      name: 'Star Lager Beer',
      buyingPriceKobo: 100,
      retailerPriceKobo: 200,
      wholesalerPriceKobo: 150,
    );
    await db.catalogDao.updateProductPrices(
      id,
      buyingPriceKobo: 110,
      retailerPriceKobo: 210,
      wholesalerPriceKobo: 160,
    );
    await db.catalogDao.updateTrackEmpties(id, true);
    await db.catalogDao.setProductArchived(id, true);

    expect((await row(id)).unitsPerPack, 12);
    expect((await pendingProductPayload(id))['units_per_pack'], 12);
  });

  group('pull restore', () {
    late SupabaseClient supabase;
    late SupabaseSyncService sync;

    setUp(() {
      supabase = SupabaseClient('https://placeholder.supabase.co', 'anon-key');
      sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));
    });

    tearDown(() => supabase.dispose());

    Map<String, dynamic> cloudRow(String id, {Object? unitsPerPack = 0}) => {
      'id': id,
      'business_id': businessId,
      'name': 'Coca-Cola',
      'unit': 'PET',
      'retailer_price_kobo': 30000,
      'wholesaler_price_kobo': 28000,
      'buying_price_kobo': 25000,
      'is_available': true,
      'is_deleted': false,
      'low_stock_threshold': 5,
      'avg_daily_sales': 0,
      'lead_time_days': 0,
      'safety_stock_qty': 0,
      'monthly_target_units': 0,
      'empty_crate_value_kobo': 0,
      'track_empties': false,
      'allow_fractional_sales': false,
      'version': 1,
      'created_at': DateTime.utc(2026, 10, 1).toIso8601String(),
      'last_updated_at': DateTime.utc(2026, 10, 1).toIso8601String(),
      if (unitsPerPack != 0) 'units_per_pack': unitsPerPack,
    };

    test('a cloud row carrying units_per_pack lands locally', () async {
      final id = UuidV7.generate();
      await sync.restoreTableDataForTesting('products', [
        cloudRow(id, unitsPerPack: 6),
      ]);
      expect((await row(id)).unitsPerPack, 6);
    });

    test(
      'a cloud row without the column (before 0187) restores as null',
      () async {
        final id = UuidV7.generate();
        await sync.restoreTableDataForTesting('products', [cloudRow(id)]);
        expect((await row(id)).unitsPerPack, isNull);
      },
    );

    test('an archived cloud row restores archived', () async {
      final id = UuidV7.generate();
      await sync.restoreTableDataForTesting('products', [
        {...cloudRow(id), 'is_available': false},
      ]);
      expect((await row(id)).isAvailable, isFalse);
    });

    test('#424 listing restore defaults only absent values and keeps opt-outs', () async {
      final legacyId = UuidV7.generate();
      final visibleId = UuidV7.generate();
      final hiddenId = UuidV7.generate();
      await sync.restoreTableDataForTesting('products', [
        cloudRow(legacyId),
        {...cloudRow(visibleId), 'show_online': true},
        {...cloudRow(hiddenId), 'show_online': false, 'is_available': false},
      ]);
      expect((await row(legacyId)).showOnline, isTrue);
      expect((await row(visibleId)).showOnline, isTrue);
      expect((await row(hiddenId)).showOnline, isFalse);
      expect((await row(hiddenId)).isAvailable, isFalse);
    });
  });
}
