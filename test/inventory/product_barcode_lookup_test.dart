// product_barcode_lookup_test.dart
//
// #113 — product barcode field + lookup (foundation for scanning, #118).
//
// Covers the CatalogDao surface added for the barcode feature:
//   - findProductByBarcode returns the first business-scoped, non-deleted match
//   - it returns null when no product carries the code
//   - it ignores soft-deleted products
//   - a collision resolves to a DIFFERENT product (the id the form compares
//     against to decide whether to warn)
//   - findProductsByBarcode (#318) returns EVERY match for the POS "Which
//     one?" list: business-scoped (another business's product with the same
//     code never appears), soft-deleted rows excluded, ordered by name then id
//   - the barcode rides the push payload (products is a pass-through push
//     table), on both create and edit, so it converges cross-device once the
//     cloud column exists (migration 0150).

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

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

  Future<String> insertProduct(String name, {String? barcode}) {
    return db.catalogDao.insertProduct(
      ProductsCompanion.insert(
        businessId: businessId,
        name: name,
        barcode: Value(barcode),
      ),
    );
  }

  test('findProductByBarcode returns the matching product', () async {
    final id = await insertProduct('Star Lager', barcode: 'BC-001');

    final match = await db.catalogDao.findProductByBarcode('BC-001');
    expect(match, isNotNull);
    expect(match!.id, id);
    expect(match.name, 'Star Lager');
    expect(match.barcode, 'BC-001');
  });

  test('findProductByBarcode returns null when absent', () async {
    await insertProduct('Star Lager', barcode: 'BC-001');

    expect(await db.catalogDao.findProductByBarcode('NOPE-999'), isNull);
    // An empty query never matches (and never scans).
    expect(await db.catalogDao.findProductByBarcode('   '), isNull);
  });

  test('findProductByBarcode ignores soft-deleted products', () async {
    final id = await insertProduct('Star Lager', barcode: 'BC-001');
    await db.catalogDao.softDeleteProduct(id);

    expect(await db.catalogDao.findProductByBarcode('BC-001'), isNull);
  });

  test('collision: findProductByBarcode finds a DIFFERENT product', () async {
    final existingId = await insertProduct('Star Lager', barcode: 'BC-001');
    // A second product being edited to reuse BC-001 resolves the lookup to the
    // first product, whose id differs — the signal the form warns on.
    final editingId = await insertProduct('Gulder', barcode: null);

    final match = await db.catalogDao.findProductByBarcode('BC-001');
    expect(match, isNotNull);
    expect(match!.id, existingId);
    expect(match.id == editingId, isFalse);
  });

  group('findProductsByBarcode (#318)', () {
    test('returns every match, ordered by name', () async {
      final zId = await insertProduct('Zobo Drink', barcode: 'BC-DUP');
      final aId = await insertProduct('Apple Juice', barcode: 'BC-DUP');
      await insertProduct('Malta', barcode: 'BC-OTHER');

      final matches = await db.catalogDao.findProductsByBarcode(' BC-DUP ');
      expect(matches.map((p) => p.id), [aId, zId]);
    });

    test('same name orders by id, so the list is stable', () async {
      final first = await insertProduct('Panadol', barcode: 'BC-DUP');
      final second = await insertProduct('Panadol', barcode: 'BC-DUP');
      final ids = [first, second]..sort();

      final matches = await db.catalogDao.findProductsByBarcode('BC-DUP');
      expect(matches.map((p) => p.id), ids);
    });

    test('another business\'s product with the same code never appears', () async {
      final ownId = await insertProduct('Star Lager', barcode: 'BC-DUP');
      final otherBusinessId = UuidV7.generate();
      await db.into(db.businesses).insert(
            BusinessesCompanion.insert(
              id: Value(otherBusinessId),
              name: 'Other Biz',
            ),
          );
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: otherBusinessId,
              name: 'Their Lager',
              barcode: const Value('BC-DUP'),
            ),
          );

      final matches = await db.catalogDao.findProductsByBarcode('BC-DUP');
      expect(matches.map((p) => p.id), [ownId]);
    });

    test('soft-deleted products are excluded', () async {
      final keptId = await insertProduct('Star Lager', barcode: 'BC-DUP');
      final goneId = await insertProduct('Gulder', barcode: 'BC-DUP');
      await db.catalogDao.softDeleteProduct(goneId);

      final matches = await db.catalogDao.findProductsByBarcode('BC-DUP');
      expect(matches.map((p) => p.id), [keptId]);
    });

    test('a blank code or no match returns an empty list', () async {
      await insertProduct('Star Lager', barcode: 'BC-001');

      expect(await db.catalogDao.findProductsByBarcode('   '), isEmpty);
      expect(await db.catalogDao.findProductsByBarcode('NOPE-999'), isEmpty);
    });
  });

  test('insertProduct enqueues the barcode in the push payload', () async {
    await insertProduct('Star Lager', barcode: 'BC-001');

    final pending = await getPendingQueue(db);
    final upsert = pending
        .where((r) => r.actionType == 'products:upsert')
        .toList();
    expect(upsert, isNotEmpty);
    final payload = decodePayload(upsert.last);
    expect(payload['barcode'], 'BC-001',
        reason: 'products is pass-through; a set barcode must ride the push');
  });

  test('updateProductDetails enqueues the edited barcode', () async {
    final id = await insertProduct('Star Lager', barcode: null);
    await db.customStatement('DELETE FROM sync_queue');

    await db.catalogDao.updateProductDetails(
      id,
      name: 'Star Lager',
      buyingPriceKobo: 0,
      retailerPriceKobo: 50000,
      wholesalerPriceKobo: 50000,
      barcode: 'BC-777',
    );

    final pending = await getPendingQueue(db);
    final upsert = pending
        .where((r) => r.actionType == 'products:upsert')
        .toList();
    expect(upsert, isNotEmpty);
    final payload = decodePayload(upsert.last);
    expect(payload['barcode'], 'BC-777');
    expect(payload['name'], 'Star Lager',
        reason: 'NOT NULL name must stay in the partial upsert payload');
  });
}
