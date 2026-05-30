// partial_upsert_full_row_test.dart
//
// Regression for the partial-row upsert class (same root cause as the
// manufacturer 23502 fix): per-column update / soft-delete methods used to
// enqueue a PARTIAL companion, so the cloud upsert's INSERT was missing a
// NOT NULL column (e.g. products.name) and was rejected with 23502 — the change
// never synced. Every such method now re-reads and enqueues the FULL row.
//
// Covers the shared CatalogDao `_enqueueFullProduct` helper (products table).
// The manufacturer cases live in manufacturer_partial_upsert_test.dart; the
// remaining offenders (orders/sessions/notifications/funds/customers/…) use the
// identical re-read + toCompanion(true) pattern verified here.

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String productId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    productId = UuidV7.generate();
    await db.into(db.products).insert(
          ProductsCompanion.insert(
            id: Value(productId),
            businessId: businessId,
            name: 'Star Lager',
          ),
        );
    // Drop the seed insert's own queued upsert so each test asserts only its update.
    await db.customStatement('DELETE FROM sync_queue');
  });

  tearDown(() => db.close());

  Future<Map<String, dynamic>> latestProductUpsert() async {
    final pending = await getPendingQueue(db);
    final p = pending.where((r) => r.actionType == 'products:upsert').toList();
    expect(p, isNotEmpty,
        reason: 'a product update must enqueue a products:upsert');
    return decodePayload(p.last);
  }

  test('softDeleteProduct enqueues a full row incl. name', () async {
    await db.catalogDao.softDeleteProduct(productId);
    final p = await latestProductUpsert();
    expect(p['name'], 'Star Lager',
        reason: 'NOT NULL name must be in the payload or the cloud 23502s');
    expect(p['is_deleted'], anyOf(true, 1));
    expect(p['business_id'], businessId);
  });

  test('updateMonthlyTarget enqueues a full row incl. name', () async {
    await db.catalogDao.updateMonthlyTarget(productId, 250);
    final p = await latestProductUpsert();
    expect(p['name'], 'Star Lager');
    expect(p['monthly_target_units'], 250);
  });

  test('updateTrackEmpties enqueues a full row incl. name', () async {
    await db.catalogDao.updateTrackEmpties(productId, true);
    final p = await latestProductUpsert();
    expect(p['name'], 'Star Lager');
    expect(p['track_empties'], anyOf(true, 1));
  });
}
