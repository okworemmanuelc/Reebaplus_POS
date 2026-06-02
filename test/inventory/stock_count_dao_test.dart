import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// Daily Stock Count (master plan §17, Ring 2). Locks in the Save Count flow's
/// data layer: the stock-count adjustment reaches inventory, the saved session
/// snapshot (`stock_counts`) carries the itemized shortages payload the Daily
/// Reconciliation Report (Ring 3, §25.9) consumes, the write enqueues for sync
/// (§5), and a Record Damages reduces stock via the `damage:<reason>` ledger.
Future<({String storeId, String staffId, String productId})> _seed(
  AppDatabase db,
  String businessId, {
  int qty = 10,
  String name = 'Test Beer',
}) async {
  final storeId = UuidV7.generate();
  await db.into(db.stores).insert(
        StoresCompanion.insert(
          id: Value(storeId),
          businessId: businessId,
          name: 'Main Store',
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
          name: name,
          retailerPriceKobo: const Value(100000),
        ),
      );
  await db.into(db.inventory).insert(
        InventoryCompanion.insert(
          businessId: businessId,
          productId: productId,
          storeId: storeId,
          quantity: Value(qty),
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
    // Local (non-domain) adjust path so inventory + ledger land locally.
    await setFlag(db, 'feature.domain_rpcs_v2.inventory_delta', on: false);
  });

  tearDown(() => db.close());

  group('Save Count — adjustment + shortages snapshot', () {
    test(
        'a short count adjusts inventory AND records the shortages payload',
        () async {
      final fx = await _seed(db, businessId, qty: 10);

      // System 10, actual 7 → diff −3. The screen calls adjustStock for the
      // change, then recordCount with the changed line.
      await db.inventoryDao.adjustStock(
        fx.productId,
        fx.storeId,
        -3,
        'Daily stock count adjustment',
        fx.staffId,
      );

      final countId = await db.stockCountsDao.recordCount(
        storeId: fx.storeId,
        businessDate: '2026-06-02',
        productsCounted: 1,
        changedLines: [
          {'p': fx.productId, 'n': 'Test Beer', 's': 10, 'a': 7, 'd': -3},
        ],
        countedBy: fx.staffId,
      );

      // 1. The adjustment reached inventory.
      final inv = await db.select(db.inventory).getSingle();
      expect(inv.quantity, 7);

      // 2. One session snapshot row with the shortage roll-up.
      final rows = await db.stockCountsDao.watchAllForBusiness().first;
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.id, countId);
      expect(row.storeId, fx.storeId);
      expect(row.businessDate, '2026-06-02');
      expect(row.productsCounted, 1);
      expect(row.shortageCount, 1);
      expect(row.shortageUnits, 3);
      expect(row.surplusCount, 0);
      expect(row.surplusUnits, 0);
      expect(row.countedBy, fx.staffId);

      // 3. The itemized shortages payload the Ring 3 report consumes.
      final lines = jsonDecode(row.linesJson) as List;
      expect(lines, hasLength(1));
      final line = lines.single as Map<String, dynamic>;
      expect(line['p'], fx.productId);
      expect(line['d'], -3);
      expect(line['s'], 10);
      expect(line['a'], 7);
    });

    test('a matched count still records a (zero-shortage) session', () async {
      await _seed(db, businessId, qty: 10);

      final countId = await db.stockCountsDao.recordCount(
        storeId: null, // all-stores view
        businessDate: '2026-06-02',
        productsCounted: 1,
        changedLines: const [],
      );

      final row = (await db.stockCountsDao.watchAllForBusiness().first).single;
      expect(row.id, countId);
      expect(row.storeId, isNull);
      expect(row.productsCounted, 1);
      expect(row.shortageCount, 0);
      expect(row.shortageUnits, 0);
      expect(row.linesJson, '[]');
    });

    test('recordCount mixes shortage + surplus roll-ups correctly', () async {
      await _seed(db, businessId);

      await db.stockCountsDao.recordCount(
        storeId: null,
        businessDate: '2026-06-02',
        productsCounted: 3,
        changedLines: [
          {'p': 'a', 'n': 'A', 's': 10, 'a': 7, 'd': -3}, // short 3
          {'p': 'b', 'n': 'B', 's': 5, 'a': 6, 'd': 1}, // over 1
          {'p': 'c', 'n': 'C', 's': 2, 'a': 0, 'd': -2}, // short 2
        ],
      );

      final row = (await db.stockCountsDao.watchAllForBusiness().first).single;
      expect(row.shortageCount, 2);
      expect(row.shortageUnits, 5);
      expect(row.surplusCount, 1);
      expect(row.surplusUnits, 1);
    });

    test('recordCount enqueues a stock_counts upsert for sync (§5)', () async {
      await _seed(db, businessId);
      await db.delete(db.syncQueue).go();

      final countId = await db.stockCountsDao.recordCount(
        storeId: null,
        businessDate: '2026-06-02',
        productsCounted: 0,
        changedLines: const [],
      );

      final pending = await getPendingQueue(db);
      final upsert =
          pending.where((r) => r.actionType == 'stock_counts:upsert').toList();
      expect(upsert, hasLength(1));
      expect(decodePayload(upsert.single)['id'], countId);
    });
  });

  group('Record Damages', () {
    test('a damage reduces stock via the damage:<reason> ledger', () async {
      final fx = await _seed(db, businessId, qty: 10);

      await db.inventoryDao.adjustStock(
        fx.productId,
        fx.storeId,
        -2,
        'damage:broken',
        fx.staffId,
      );

      final inv = await db.select(db.inventory).getSingle();
      expect(inv.quantity, 8);

      final adj = await db.select(db.stockAdjustments).getSingle();
      expect(adj.reason, 'damage:broken');
      expect(adj.quantityDiff, -2);
    });
  });
}
