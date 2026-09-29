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
      await db.into(db.crateLedger).insert(
            CrateLedgerCompanion.insert(
              businessId: businessId,
              manufacturerId: const Value(manufacturerId),
              storeId: const Value(storeId),
              quantityDelta: 10,
              movementType: 'count',
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

    test('rejects damage exceeding warehouse count and ignores non-positive quantities',
        () async {
      await expectLater(
        db.inventoryDao
            .recordEmptyCrateDamage(manufacturerId, 25, storeId: storeId),
        throwsArgumentError,
      );

      final mfr = await (db.select(db.manufacturers)
            ..where((t) => t.id.equals(manufacturerId)))
          .getSingle();
      expect(mfr.emptyCrateStock, 10);

      await db.inventoryDao
          .recordEmptyCrateDamage(manufacturerId, 0, storeId: storeId);
      await db.inventoryDao
          .recordEmptyCrateDamage(manufacturerId, -5, storeId: storeId);
      final ledger = await (db.select(db.crateLedger)
            ..where((t) => t.movementType.equals('damaged')))
          .get();
      // No damaged ledger rows written.
      expect(ledger, isEmpty);
    });
  });

  group('Daily Reconciliation crate damage valuation (#299)', () {
    const businessId = 'biz-recon';
    const storeId = 'store-recon';
    const manufacturerId = 'mfr-recon';
    const productId = 'prod-recon';
    final now = DateTime(2026, 9, 29, 10, 0);

    late AppDatabase db;
    late ProductData product;
    late ManufacturerData mfr;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      db.businessIdResolver = () => businessId;
      await db.into(db.businesses).insert(
            BusinessesCompanion.insert(
              id: const Value(businessId),
              name: 'Recon Biz',
            ),
          );
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: const Value(storeId),
              businessId: businessId,
              name: 'Recon Store',
            ),
          );
      await db.into(db.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: const Value(manufacturerId),
              businessId: businessId,
              name: 'Test Mfr',
              emptyCrateStock: const Value(10),
              depositAmountKobo: const Value(200000), // ₦2,000
            ),
          );
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              id: const Value(productId),
              businessId: businessId,
              name: 'Beer Bottle',
              buyingPriceKobo: const Value(50000),
              retailerPriceKobo: const Value(70000),
              wholesalerPriceKobo: const Value(65000),
              manufacturerId: const Value(manufacturerId),
              unit: const Value('Bottle'),
              trackEmpties: const Value(true),
            ),
          );
      product = await (db.select(db.products)
            ..where((t) => t.id.equals(productId)))
          .getSingle();
      mfr = await (db.select(db.manufacturers)
            ..where((t) => t.id.equals(manufacturerId)))
          .getSingle();
    });

    tearDown(() async => db.close());

    test(
        '+cratelost today\'s-rate valuation path on stock adjustments no longer contributes',
        () {
      // Stock adjustment with legacy +cratelost suffix: lost 2 units.
      final adj = StockAdjustmentData(
        id: 'adj-1',
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantityDiff: -2,
        reason: 'damage:broken$kCrateLostSuffix',
        valueKobo: 100000, // 2 * 50,000
        createdAt: now,
        lastUpdatedAt: now,
      );

      final recon = reconDataFrom(
        ReconInputs(
          start: DateTime(2026, 9, 29),
          endExclusive: DateTime(2026, 9, 30),
          adjustments: [adj],
          productsWithStock: [
            ProductDataWithStock(product: product, totalStock: 8)
          ],
          manufacturers: [mfr],
          showCrates: true,
        ),
      );

      // The stock adjustment contributes to drink damage cost only
      expect(recon.damageCostKobo, 100000);
      // The +cratelost today's-rate valuation path on stock adjustments no longer contributes
      expect(recon.crateDamageDepositKobo, 0,
          reason: '+cratelost suffix must not add today\'s deposit rate');
    });

    test(
        'crate shell is valued exactly once from full_crate_damage leg\'s snapshot, and later crate value change does not change booked loss',
        () {
      // Stock adjustment carries drink loss only (lost 2 units of drink)
      final adj = StockAdjustmentData(
        id: 'adj-1',
        businessId: businessId,
        productId: productId,
        storeId: storeId,
        quantityDiff: -2,
        reason: 'damage:broken',
        valueKobo: 100000,
        createdAt: now,
        lastUpdatedAt: now,
      );

      // full_crate_damage leg snapshotted at ₦1,500 (150,000 kobo)
      final fullCrateDamageLeg = CrateLedgerData(
        id: 'cleg-1',
        businessId: businessId,
        manufacturerId: manufacturerId,
        storeId: storeId,
        quantityDelta: -2,
        movementType: 'full_crate_damage',
        ratePerCrateKobo: 150000,
        createdAt: now,
        lastUpdatedAt: now,
      );

      final recon = reconDataFrom(
        ReconInputs(
          start: DateTime(2026, 9, 29),
          endExclusive: DateTime(2026, 9, 30),
          adjustments: [adj],
          crateDamages: [fullCrateDamageLeg],
          productsWithStock: [
            ProductDataWithStock(product: product, totalStock: 8)
          ],
          manufacturers: [mfr],
          showCrates: true,
        ),
      );

      // Drink loss: ₦1,000 (100,000 kobo)
      expect(recon.damageCostKobo, 100000);
      // Crate shell loss: 2 * 150,000 = ₦3,000 (300,000 kobo)
      expect(recon.crateDamageDepositKobo, 300000);

      // Now simulate a later manufacturer crate value increase to ₦2,500 (250,000 kobo)
      final updatedMfr = mfr.copyWith(depositAmountKobo: 250000);

      final reconAfterMfrPriceChange = reconDataFrom(
        ReconInputs(
          start: DateTime(2026, 9, 29),
          endExclusive: DateTime(2026, 9, 30),
          adjustments: [adj],
          crateDamages: [fullCrateDamageLeg],
          productsWithStock: [
            ProductDataWithStock(product: product, totalStock: 8)
          ],
          manufacturers: [updatedMfr],
          showCrates: true,
        ),
      );

      // Crucial: booked shell loss is unchanged from snapshot (300,000 kobo, NOT 500,000)
      expect(reconAfterMfrPriceChange.crateDamageDepositKobo, 300000);
    });
  });
}
