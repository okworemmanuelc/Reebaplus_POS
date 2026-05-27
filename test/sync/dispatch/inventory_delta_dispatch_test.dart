import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/dispatch_test_utils.dart';

/// Seeds: store, staff, product, an inventory row at qty=10 so a
/// negative-delta path has stock to debit.
Future<({String storeId, String staffId, String productId})>
    _seedInventoryFixtures(AppDatabase db, String businessId) async {
  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main',
        ),
      );
  final staffId = UuidV7.generate();
  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Stockkeeper',
          pin: '0000',
        ),
      );
  final productId = UuidV7.generate();
  await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: Value(productId),
          businessId: businessId,
          name: 'Test Beer',
          sellingPriceKobo: const Value(100000),
        ),
      );
  await db.into(db.inventory).insert(
        InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeId,
          quantity: const Value(10),
        ),
      );
  return (storeId: storeId, staffId: staffId, productId: productId);
}

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  group('InventoryDao.adjustStock dispatch', () {
    test(
        'flag OFF: enqueues stock_adjustments + stock_transactions + inventory '
        '(no domain envelope)', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);
      final fx = await _seedInventoryFixtures(db, businessId);

      await db.inventoryDao.adjustStock(
        fx.productId,
        fx.storeId,
        5,
        'restock',
        fx.staffId,
      );

      // Local mirror: full ledger trail.
      expect(await db.select(db.stockAdjustments).get(), hasLength(1));
      expect(await db.select(db.stockTransactions).get(), hasLength(1));
      final inv = await db.select(db.inventory).getSingle();
      expect(inv.quantity, 15);

      final pending = await getPendingQueue(db);
      final actionTypes = pending.map((r) => r.actionType).toList()..sort();
      expect(actionTypes, [
        'inventory:upsert',
        'stock_adjustments:upsert',
        'stock_transactions:upsert',
      ]);
    });

    test(
        'flag ON: one envelope, inventory cache flips locally, no '
        'stock_adjustments / stock_transactions written locally', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: true);
      final fx = await _seedInventoryFixtures(db, businessId);

      await db.inventoryDao.adjustStock(
        fx.productId,
        fx.storeId,
        -3,
        'damage',
        fx.staffId,
      );

      // Local: inventory flipped (immediate UI feedback), but the audit
      // trail (stock_adjustments + stock_transactions) lives only in the
      // envelope until the RPC response writes them back.
      final inv = await db.select(db.inventory).getSingle();
      expect(inv.quantity, 7);
      expect(await db.select(db.stockAdjustments).get(), isEmpty,
          reason: 'no local adjustment row until RPC response is applied');
      expect(await db.select(db.stockTransactions).get(), isEmpty,
          reason: 'no local stock_tx row until RPC response is applied');

      final pending = await getPendingQueue(db);
      expect(pending, hasLength(1));
      expect(pending.first.actionType, 'domain:pos_inventory_delta_v2');

      final payload = decodePayload(pending.first);
      expect(payload['p_business_id'], businessId);
      expect(payload['p_actor_id'], fx.staffId);

      final movements = payload['p_movements'] as List;
      expect(movements, hasLength(1));
      final mv = movements.first as Map;
      // The v2 RPC reads `movement_id` (not `id`) — finding 2 from the
      // earlier audit lands here.
      expect(mv['movement_id'], isA<String>());
      expect(mv['product_id'], fx.productId);
      expect(mv['store_id'], fx.storeId);
      expect(mv['quantity_delta'], -3);
      expect(mv['movement_type'], 'adjustment');
      expect(mv['reason'], 'damage');
      // ref_type / ref_id / performed_by must NOT be present — server
      // mints the stock_adjustments row and uses p_actor_id at the
      // top level.
      expect(mv.containsKey('ref_type'), isFalse);
      expect(mv.containsKey('ref_id'), isFalse);
      expect(mv.containsKey('performed_by'), isFalse);
    });

    test('flag ON: insufficient stock raises before any local writes',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: true);
      final fx = await _seedInventoryFixtures(db, businessId);

      Object? caught;
      try {
        // Inventory only has 10 units; -100 must fail the stock guard.
        await db.inventoryDao.adjustStock(
          fx.productId,
          fx.storeId,
          -100,
          'overdraw',
          fx.staffId,
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<InsufficientStockException>());

      // No envelope, no inventory change locally, no audit rows.
      final pending = await getPendingQueue(db);
      expect(pending, isEmpty);
      final inv = await db.select(db.inventory).getSingle();
      expect(inv.quantity, 10, reason: 'inventory must NOT change on overdraw');
    });
  });
}
