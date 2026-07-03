// store_crate_balances_id_divergence_test.dart
//
// Regression net for SqliteException(2067) "UNIQUE constraint failed:
// store_crate_balances.business_id, store_crate_balances.store_id,
// store_crate_balances.manufacturer_id".
//
// store_crate_balances carries a surrogate `id` (PK), but its LOGICAL identity
// is (business_id, store_id, manufacturer_id) — a second UNIQUE constraint. The
// cache has two id-minting authorities for the SAME triple: the client
// (UuidV7, via addEmptyCrates / updateManufacturerStock plain-enqueues) and the
// cloud domain RPC pos_transfer_crates (gen_random_uuid). So the local row and
// the cloud row for one (store, manufacturer) routinely hold DIFFERENT ids.
//
// The old restore path upserted on `id`, so when it met a cloud row whose id
// differed from the local row for that triple, the id-keyed
// insertOnConflictUpdate tripped UNIQUE(business_id, store_id, manufacturer_id)
// and crashed the app (the user hit this right after a crate transfer — the
// cloud row carried a gen_random_uuid id while the local row had a UuidV7).
//
// Pinned here: _restoreTableData('store_crate_balances', ...) reconciles on the
// natural key, so a divergent cloud id converges instead of crashing. The same
// fix is mirrored for manufacturer_crate_balances and customer_crate_balances.

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/services/supabase_cloud_transport.dart';
import 'package:reebaplus_pos/core/services/supabase_sync_service.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late SupabaseClient supabase;
  late SupabaseSyncService sync;
  late String businessId;
  late String storeId;
  late String manufacturerId;

  final ts = DateTime.utc(2026, 6, 6, 12).toIso8601String();

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    supabase = SupabaseClient(
      'https://placeholder.supabase.co',
      'placeholder-anon-key',
    );
    sync = SupabaseSyncService(db, SupabaseCloudTransport(supabase));

    // FK parents for store_crate_balances.
    storeId = UuidV7.generate();
    manufacturerId = UuidV7.generate();
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
            name: 'ACME Drinks',
          ),
        );
  });

  tearDown(() async {
    await supabase.dispose();
    await db.close();
  });

  Future<void> restoreCloudRow(String id, int balance) {
    return sync.restoreTableDataForTesting('store_crate_balances', [
      {
        'id': id,
        'business_id': businessId,
        'store_id': storeId,
        'manufacturer_id': manufacturerId,
        'balance': balance,
        'created_at': ts,
        'last_updated_at': ts,
      },
    ]);
  }

  test('restore converges a divergent cloud id instead of crashing', () async {
    // Local row minted its own id (e.g. via addEmptyCrates' applyDelta).
    final localId = UuidV7.generate();
    await db.into(db.storeCrateBalances).insert(
          StoreCrateBalancesCompanion.insert(
            id: Value(localId),
            businessId: businessId,
            storeId: storeId,
            manufacturerId: manufacturerId,
            balance: const Value(10),
          ),
        );

    // The cloud holds the SAME triple under a DIFFERENT id (gen_random_uuid from
    // pos_transfer_crates) and a newer balance. Pre-fix this threw 2067.
    final cloudId = UuidV7.generate();
    expect(cloudId == localId, isFalse);

    await restoreCloudRow(cloudId, 375);

    final rows = await db.select(db.storeCrateBalances).get();
    expect(rows, hasLength(1), reason: 'no duplicate for the same triple');
    expect(rows.single.id, cloudId,
        reason: 'device converges on the cloud id');
    expect(rows.single.balance, 375,
        reason: 'cloud-authoritative balance applied');
  });

  test('restore creates the row when none exists locally', () async {
    final cloudId = UuidV7.generate();
    await restoreCloudRow(cloudId, 42);

    final rows = await db.select(db.storeCrateBalances).get();
    expect(rows, hasLength(1));
    expect(rows.single.id, cloudId);
    expect(rows.single.balance, 42);
  });

  test('restore with the same id stays idempotent', () async {
    final cloudId = UuidV7.generate();
    await restoreCloudRow(cloudId, 7);
    await restoreCloudRow(cloudId, 7);

    final rows = await db.select(db.storeCrateBalances).get();
    expect(rows, hasLength(1));
    expect(rows.single.balance, 7);
  });
}
