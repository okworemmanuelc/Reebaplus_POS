// Shared seed for the Store Details / Transfer hub tests and goldens (#441):
// a second store and one transfer in every hub section. Fixed dates only.

import 'package:drift/drift.dart' hide isNull, isNotNull;

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/screen_harness.dart';

class StoreDetailsSeed {
  const StoreDetailsSeed({required this.otherStoreId, required this.ids});

  final String otherStoreId;

  /// Transfer ids by role: `fulfil`, `receive`, `requested`, `dispatched`,
  /// `done`, `cancelled`.
  final Map<String, String> ids;
}

/// Names the env store "Abuja HQ", adds "Lagos Island Annex" and seeds one
/// transfer per hub section for the env store, plus two history rows.
Future<StoreDetailsSeed> seedStoreDetails(ScreenTestEnvironment env) async {
  final db = env.db;
  db.userIdResolver = () => 'test-user-id';
  await db.customStatement(
    "UPDATE stores SET name = 'Abuja HQ', location = '14 Wuse Road, Nigeria' "
    "WHERE id = '${env.storeId}'",
  );
  await db
      .into(db.users)
      .insert(
        UsersCompanion.insert(
          id: const Value('test-user-id'),
          businessId: env.businessId,
          name: 'Chidi Okeke',
          pin: '0000',
        ),
      );
  final lagos = UuidV7.generate();
  await db
      .into(db.stores)
      .insert(
        StoresCompanion.insert(
          id: Value(lagos),
          businessId: env.businessId,
          name: 'Lagos Island Annex',
          location: const Value('3 Marina Street, Lagos, Nigeria'),
        ),
      );
  for (final p in env.products) {
    await db
        .into(db.inventory)
        .insert(
          InventoryCompanion.insert(
            id: Value(UuidV7.generate()),
            businessId: env.businessId,
            storeId: lagos,
            productId: p.id,
            quantity: const Value(40),
          ),
        );
  }

  final ids = <String, String>{};
  Future<void> transfer(
    String key, {
    required String from,
    required String to,
    required String status,
    required int quantity,
    int product = 0,
  }) async {
    final id = UuidV7.generate();
    ids[key] = id;
    final at = DateTime(2026, 3, 10, 14, 30);
    await db
        .into(db.stockTransfers)
        .insert(
          StockTransfersCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            fromLocationId: from,
            toLocationId: to,
            productId: env.products[product].id,
            quantity: quantity,
            status: Value(status),
            initiatedBy: 'test-user-id',
            initiatedAt: Value(at),
            createdAt: Value(at),
            lastUpdatedAt: Value(at),
          ),
        );
  }

  // Lagos asks Abuja for stock: Abuja holds it, so Abuja fulfils.
  await transfer(
    'fulfil',
    from: env.storeId,
    to: lagos,
    status: 'pending',
    quantity: 12,
  );
  // Lagos dispatched stock to Abuja: Abuja confirms receipt.
  await transfer(
    'receive',
    from: lagos,
    to: env.storeId,
    status: 'in_transit',
    quantity: 8,
    product: 1,
  );
  // Abuja asked Lagos for stock: awaiting dispatch.
  await transfer(
    'requested',
    from: lagos,
    to: env.storeId,
    status: 'pending',
    quantity: 5,
    product: 2,
  );
  // Abuja dispatched stock to Lagos: in transit.
  await transfer(
    'dispatched',
    from: env.storeId,
    to: lagos,
    status: 'in_transit',
    quantity: 6,
    product: 1,
  );
  await transfer(
    'done',
    from: lagos,
    to: env.storeId,
    status: 'received',
    quantity: 20,
  );
  await transfer(
    'cancelled',
    from: env.storeId,
    to: lagos,
    status: 'cancelled',
    quantity: 3,
    product: 2,
  );
  return StoreDetailsSeed(otherStoreId: lagos, ids: ids);
}
