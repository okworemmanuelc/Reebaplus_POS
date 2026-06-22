import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:drift/drift.dart' hide isNull;

/// §17.2 crate-aware damages. Two layers are exercised here:
///   • the full-crate-lost reason suffix the Statement reads
///     (`damageForfeitsFullCrate` / `isDamageReason`), and
///   • `InventoryDao.recordEmptyCrateDamage`, the crate-only pool debit used for
///     the "stored empty crate was damaged" fate (no stock_adjustment — the
///     Statement reads its forfeited deposit from the `damaged` ledger row).
void main() {
  group('damage reason classification', () {
    test('the full-crate suffix still classifies as a damage', () {
      expect(isDamageReason('damage:broken'), isTrue);
      expect(isDamageReason('damage:broken$kCrateLostSuffix'), isTrue);
    });

    test('damageForfeitsFullCrate only fires for the full-crate fate', () {
      expect(damageForfeitsFullCrate('damage:broken'), isFalse);
      expect(damageForfeitsFullCrate('damage:broken$kCrateLostSuffix'), isTrue);
      // A plain manual removal must not forfeit a crate.
      expect(damageForfeitsFullCrate('Theft'), isFalse);
    });
  });

  group('InventoryDao.recordEmptyCrateDamage', () {
    late AppDatabase db;
    const businessId = 'biz-1';
    const storeId = 'store-1';
    const manufacturerId = 'mfr-1';

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      db.businessIdResolver = () => businessId;
      await db.into(db.businesses).insert(
            BusinessesCompanion.insert(
              id: const Value(businessId),
              name: 'Test Biz',
            ),
          );
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: const Value(storeId),
              businessId: businessId,
              name: 'Main',
            ),
          );
      await db.into(db.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: const Value(manufacturerId),
              businessId: businessId,
              name: 'Test Mfr',
              emptyCrateStock: const Value(10),
              depositAmountKobo: const Value(50000),
            ),
          );
    });

    tearDown(() async => db.close());

    test('debits the pool, store balance and writes a damaged ledger row',
        () async {
      await db.inventoryDao
          .recordEmptyCrateDamage(manufacturerId, 3, storeId: storeId);

      final mfr = await (db.select(db.manufacturers)
            ..where((t) => t.id.equals(manufacturerId)))
          .getSingle();
      expect(mfr.emptyCrateStock, 7);

      final ledger = await (db.select(db.crateLedger)
            ..where((t) => t.movementType.equals('damaged')))
          .get();
      expect(ledger.length, 1);
      expect(ledger.first.quantityDelta, -3);
      expect(ledger.first.manufacturerId, manufacturerId);
      expect(ledger.first.storeId, storeId);

      final bal = await (db.select(db.storeCrateBalances)
            ..where((t) => t.storeId.equals(storeId)))
          .getSingle();
      expect(bal.balance, -3);
    });

    test('clamps the pool at zero and ignores non-positive quantities',
        () async {
      await db.inventoryDao
          .recordEmptyCrateDamage(manufacturerId, 25, storeId: storeId);
      final mfr = await (db.select(db.manufacturers)
            ..where((t) => t.id.equals(manufacturerId)))
          .getSingle();
      expect(mfr.emptyCrateStock, 0);

      await db.inventoryDao
          .recordEmptyCrateDamage(manufacturerId, 0, storeId: storeId);
      await db.inventoryDao
          .recordEmptyCrateDamage(manufacturerId, -5, storeId: storeId);
      final ledger = await (db.select(db.crateLedger)
            ..where((t) => t.movementType.equals('damaged')))
          .get();
      // Only the one real debit wrote a ledger row.
      expect(ledger.length, 1);
    });
  });
}
