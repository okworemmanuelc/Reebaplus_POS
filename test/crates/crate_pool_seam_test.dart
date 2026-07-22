import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

/// #157 — the Crate Pool seam (`CratePoolDao`). Covers the two NEW ledger-
/// completeness behaviors this slice adds (a manual "set to N" becomes a
/// reconciling delta row; a store-less pool credit/debit now writes a row too)
/// and the v62→v63 opening-balance seed that guarantees `SUM(quantity_delta)`
/// equals the existing cache value at cutover.
void main() {
  const businessId = 'biz-1';
  const userId = 'user-1';
  const customerId = 'cust-1';
  const manufacturerId = 'mfr-1';
  const storeId = 'store-1';
  const supplierId = 'sup-1';

  group('ledger completeness (in-memory)', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      db.businessIdResolver = () => businessId;
      await db.into(db.businesses).insert(
            BusinessesCompanion.insert(
              id: const Value(businessId),
              name: 'Biz',
            ),
          );
      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: const Value(userId),
              businessId: businessId,
              name: 'U',
              pin: '1234',
            ),
          );
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: const Value(storeId),
              businessId: businessId,
              name: 'Store',
            ),
          );
      await db.into(db.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: const Value(manufacturerId),
              businessId: businessId,
              name: 'Mfr',
            ),
          );
    });

    tearDown(() => db.close());

    Future<int> scalar() async {
      final m = await (db.select(db.manufacturers)
            ..where((t) => t.id.equals(manufacturerId)))
          .getSingle();
      return m.emptyCrateStock;
    }

    Future<List<CrateLedgerData>> ledger() =>
        db.select(db.crateLedger).get();

    test('addEmptiesToPool (store-less) bumps the scalar AND appends a ledger row',
        () async {
      await db.cratePoolDao.addEmptiesToPool(manufacturerId, 8);

      expect(await scalar(), 8);
      final rows = await ledger();
      expect(rows.length, 1);
      expect(rows.single.quantityDelta, 8);
      expect(rows.single.movementType, 'adjusted');
      expect(rows.single.manufacturerId, manufacturerId);
      expect(rows.single.storeId, isNull);
      expect(rows.single.customerId, isNull);
    });

    test('recordDamage (store-less) debits the scalar AND appends a damaged row',
        () async {
      await db.cratePoolDao.addEmptiesToPool(manufacturerId, 8);
      await db.cratePoolDao.recordDamage(manufacturerId, 3);

      expect(await scalar(), 5);
      final damaged =
          (await ledger()).where((r) => r.movementType == 'damaged').toList();
      expect(damaged.length, 1);
      expect(damaged.single.quantityDelta, -3);
      expect(damaged.single.storeId, isNull);
    });

    test('recordManualCountCorrection (store-less) records a DELTA row (N-current)',
        () async {
      await db.cratePoolDao.recordManualCountCorrection(manufacturerId, 15);
      expect(await scalar(), 15);

      // A second correction downward records the negative delta, not an overwrite.
      await db.cratePoolDao.recordManualCountCorrection(manufacturerId, 10);
      expect(await scalar(), 10);

      final rows = await ledger();
      expect(rows.map((r) => r.quantityDelta).toList(), [15, -5]);
      // The ledger sums to the current displayed count.
      expect(rows.fold<int>(0, (s, r) => s + r.quantityDelta), 10);
    });

    test('recordManualCountCorrection (store) sets store balance + a store row',
        () async {
      await db.cratePoolDao.recordManualCountCorrection(
        manufacturerId,
        12,
        storeId: storeId,
      );

      final bal = await db.storeCrateBalancesDao.getBalance(
        storeId: storeId,
        manufacturerId: manufacturerId,
      );
      expect(bal, 12);
      expect(await scalar(), 12); // business total bumped by the same delta

      final storeRows =
          (await ledger()).where((r) => r.storeId == storeId).toList();
      expect(storeRows.length, 1);
      expect(storeRows.single.quantityDelta, 12);
      expect(storeRows.single.movementType, 'adjusted');
    });
  });

  group('v62->v63 opening-balance seed (file-backed migration)', () {
    late Directory tmpDir;
    late File dbFile;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('reeba_crate_seed');
      dbFile = File('${tmpDir.path}/app.db');
    });

    tearDown(() async {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    test('after upgrade, SUM(ledger) == each cache value at cutover', () async {
      // 1. Fresh current-schema DB; seed the FK parents + drifted caches.
      final db1 = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db1.customSelect('SELECT 1').get();
      await db1.into(db1.businesses).insert(
            BusinessesCompanion.insert(id: const Value(businessId), name: 'B'),
          );
      await db1.into(db1.customers).insert(
            CustomersCompanion.insert(
              id: const Value(customerId),
              businessId: businessId,
              name: 'C',
            ),
          );
      await db1.into(db1.stores).insert(
            StoresCompanion.insert(
              id: const Value(storeId),
              businessId: businessId,
              name: 'S',
            ),
          );
      await db1.into(db1.manufacturers).insert(
            ManufacturersCompanion.insert(
              id: const Value(manufacturerId),
              businessId: businessId,
              name: 'M',
            ),
          );
      await db1.into(db1.suppliers).insert(
            SuppliersCompanion.insert(
              id: const Value(supplierId),
              businessId: businessId,
              name: 'Sup',
            ),
          );

      // Drifted caches (a mature business): a balance with no / partial ledger.
      await db1.into(db1.customerCrateBalances).insert(
            CustomerCrateBalancesCompanion.insert(
              businessId: businessId,
              customerId: customerId,
              manufacturerId: manufacturerId,
              balance: const Value(10),
            ),
          );
      // A partial ledger of +3 already exists → the seed must reconcile +7.
      await db1.into(db1.crateLedger).insert(
            CrateLedgerCompanion.insert(
              businessId: businessId,
              customerId: const Value(customerId),
              manufacturerId: const Value(manufacturerId),
              quantityDelta: 3,
              movementType: 'issued',
            ),
          );
      await db1.into(db1.storeCrateBalances).insert(
            StoreCrateBalancesCompanion.insert(
              businessId: businessId,
              storeId: storeId,
              manufacturerId: manufacturerId,
              balance: const Value(5),
            ),
          );
      await db1.into(db1.manufacturerCrateBalances).insert(
            ManufacturerCrateBalancesCompanion.insert(
              businessId: businessId,
              manufacturerId: manufacturerId,
              balance: const Value(20),
            ),
          );
      await db1.into(db1.supplierCrateBalances).insert(
            SupplierCrateBalancesCompanion.insert(
              businessId: businessId,
              supplierId: supplierId,
              manufacturerId: manufacturerId,
              balance: const Value(4),
            ),
          );

      // 2. Stamp user_version back to 62 (v62->v63 is data-only, no schema
      //    delta to revert), close, and re-open to drive the real onUpgrade.
      await db1.customStatement('PRAGMA user_version = 62');
      await db1.close();

      final db2 = AppDatabase.forTesting(NativeDatabase(dbFile));
      await db2.customSelect('SELECT 1').get(); // forces onUpgrade

      Future<int> sum(String where) async {
        final r = await db2
            .customSelect(
              'SELECT COALESCE(SUM(quantity_delta),0) AS s FROM crate_ledger '
              'WHERE business_id = ? AND $where',
              variables: const [Variable(businessId)],
            )
            .getSingle();
        return r.read<int>('s');
      }

      // customer: SUM by (customer, manufacturer) == 10.
      expect(
        await sum("customer_id = '$customerId' AND manufacturer_id = "
            "'$manufacturerId'"),
        10,
      );
      // store: SUM by (store, manufacturer), customer-less == 5.
      expect(
        await sum("store_id = '$storeId' AND manufacturer_id = "
            "'$manufacturerId' AND customer_id IS NULL"),
        5,
      );
      // manufacturer: SUM by manufacturer, store-less + customer-less == 20.
      expect(
        await sum("manufacturer_id = '$manufacturerId' AND customer_id IS NULL "
            "AND store_id IS NULL"),
        20,
      );

      // supplier: SUM over supplier_crate_ledger by (supplier, manufacturer) == 4.
      final sup = await db2
          .customSelect(
            'SELECT COALESCE(SUM(quantity_delta),0) AS s FROM supplier_crate_ledger '
            "WHERE business_id = ? AND supplier_id = '$supplierId' "
            "AND manufacturer_id = '$manufacturerId'",
            variables: const [Variable(businessId)],
          )
          .getSingle();
      expect(sup.read<int>('s'), 4);

      await db2.close();
    });
  });
}
