// manufacturer_partial_upsert_test.dart
//
// Regression for the Sync Issues "manufacturers:upsert … null value in column
// name (23502)" failure. The per-column manufacturer update methods used to
// enqueue a PARTIAL companion (only the changed column + keys), so the queued
// payload omitted the NOT NULL `name` and the cloud upsert's INSERT was rejected
// — the empty-crate value / deposit / stock never reached the cloud and the row
// retried forever. Each method now reads the row back and enqueues every column.

import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String manufacturerId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    manufacturerId = await db.inventoryDao.insertManufacturer(
      ManufacturersCompanion.insert(name: 'Coca-Cola', businessId: businessId),
    );
    // Drop the insert's own queued upsert so each test asserts only its update.
    await db.customStatement('DELETE FROM sync_queue');
  });

  tearDown(() => db.close());

  Future<Map<String, dynamic>> latestManufacturerUpsert() async {
    final pending = await getPendingQueue(db);
    final mfr =
        pending.where((r) => r.actionType == 'manufacturers:upsert').toList();
    expect(mfr, isNotEmpty,
        reason: 'a manufacturer update must enqueue a manufacturers:upsert');
    return decodePayload(mfr.last);
  }

  test('updateManufacturerEmptyCrateValue enqueues a full row incl. name', () async {
    await db.catalogDao
        .updateManufacturerEmptyCrateValue(manufacturerId, 150000);
    final p = await latestManufacturerUpsert();
    expect(p['name'], 'Coca-Cola',
        reason: 'NOT NULL name must be in the payload or the cloud 23502s');
    expect(p['deposit_amount_kobo'], 150000);
    expect(p['business_id'], businessId);
  });

  test('updateManufacturerStock enqueues a full row incl. name, but the pushed '
      'payload OMITS empty_crate_stock (#159 demote)', () async {
    await db.inventoryDao.updateManufacturerStock(manufacturerId, 42);
    final p = await latestManufacturerUpsert();
    // The enqueued row is still full (NOT NULL `name` present, avoids the
    // 23502), and the local projection carries the new count…
    expect(p['name'], 'Coca-Cola');
    expect(p['empty_crate_stock'], 42);
    // …but #159 DEMOTES the scalar: the push-column whitelist scrubs
    // `empty_crate_stock` out of what actually crosses the wire. The physical
    // pool is derived from the append-only crate_ledger, never pushed absolute.
    final pushed = SupabaseSyncService.scrubForTesting('manufacturers', p);
    expect(pushed.containsKey('empty_crate_stock'), isFalse,
        reason: 'the absolute empties scalar must never be pushed (#159)');
    expect(pushed['name'], 'Coca-Cola',
        reason: 'other columns still sync');
  });

  test('updateManufacturerDeposit enqueues a full row incl. name', () async {
    await db.inventoryDao.updateManufacturerDeposit(manufacturerId, 99000);
    final p = await latestManufacturerUpsert();
    expect(p['name'], 'Coca-Cola');
    expect(p['deposit_amount_kobo'], 99000);
  });
}
