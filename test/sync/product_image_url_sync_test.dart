// Product photo — the URL write rides the sync path (#78, PRD #76).
//
// The photo bytes live in Storage + a local cache; only products.image_url
// crosses devices. This is the locked DAO/sync seam for that field: writing the
// URL via CatalogDao.setProductImageUrl must (a) persist it on the local row and
// (b) enqueue a products upsert whose snake_case payload carries `image_url`, so
// peers converge through the normal outbox → upsert → pull path (products is a
// pass-through push table). The pull side rides the generic ProductData restore
// already covered for every product column, so it needs no separate test.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  test('setProductImageUrl persists the URL and enqueues it for sync', () async {
    final boot = await bootstrapTestDb();
    try {
      final id = UuidV7.generate();
      await boot.db.into(boot.db.products).insert(
            ProductsCompanion.insert(
              id: Value(id),
              businessId: boot.businessId,
              name: 'Widget',
            ),
          );

      // A product with no photo starts null (optional — save is never blocked).
      final before = await boot.db.catalogDao.findById(id);
      expect(before!.imageUrl, isNull);

      const url =
          'https://x.supabase.co/storage/v1/object/public/product-images/b/p.png';
      await boot.db.catalogDao.setProductImageUrl(id, url);

      // (a) Local row carries the URL (renders on this device immediately).
      final after = await boot.db.catalogDao.findById(id);
      expect(after!.imageUrl, url);

      // (b) An outbox products upsert carries image_url so peers converge.
      final pending = await getPendingQueue(boot.db);
      final carrying = pending.where((q) {
        if (!q.actionType.startsWith('products')) return false;
        final p = jsonDecode(q.payload) as Map<String, dynamic>;
        return p['id'] == id && p['image_url'] == url;
      });
      expect(carrying, isNotEmpty,
          reason: 'a products upsert must push image_url cross-device');
    } finally {
      await boot.db.close();
    }
  });
}
