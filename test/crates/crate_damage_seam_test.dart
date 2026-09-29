import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';

/// #297 — Record damaged empties through the Crate Pool seam
/// (`CratePoolDao.recordDamage`).
void main() {
  const businessId = 'biz-1';
  const userId = 'user-1';
  const manufacturerId = 'mfr-1';
  const storeA = 'store-1';
  const storeB = 'store-2';

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    db.businessIdResolver = () => businessId;
    await db.into(db.businesses).insert(
          BusinessesCompanion.insert(id: const Value(businessId), name: 'Biz'),
        );
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: const Value(userId),
            businessId: businessId,
            name: 'Staff',
            pin: '1234',
          ),
        );
    for (final id in const [storeA, storeB]) {
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(id),
              businessId: businessId,
              name: id,
            ),
          );
    }
    await db.into(db.manufacturers).insert(
          ManufacturersCompanion.insert(
            id: const Value(manufacturerId),
            businessId: businessId,
            name: 'Mfr',
            emptyCrateStock: const Value(15),
            depositAmountKobo: const Value(150000),
          ),
        );

    // Seed 10 empties in storeA and 5 in storeB via crate_ledger
    await db.into(db.crateLedger).insert(
          CrateLedgerCompanion.insert(
            businessId: businessId,
            manufacturerId: const Value(manufacturerId),
            storeId: const Value(storeA),
            quantityDelta: 10,
            movementType: 'count',
          ),
        );
    await db.into(db.crateLedger).insert(
          CrateLedgerCompanion.insert(
            businessId: businessId,
            manufacturerId: const Value(manufacturerId),
            storeId: const Value(storeB),
            quantityDelta: 5,
            movementType: 'count',
          ),
        );
  });

  tearDown(() => db.close());

  Future<int> pool({String? store}) async =>
      (await db.cratePoolDao
              .watchEmptiesPoolByManufacturer(storeId: store)
              .first)[manufacturerId] ??
      0;

  test(
      'debits the store warehouse count, leaves other stores untouched, '
      'and appends an attributed, store-stamped damage movement', () async {
    await db.cratePoolDao.recordDamage(
      manufacturerId,
      3,
      storeId: storeA,
      performedBy: userId,
      ratePerCrateKobo: 120000,
    );

    expect(await pool(store: storeA), 7);
    expect(await pool(store: storeB), 5);
    expect(await pool(), 12, reason: 'All Stores = sum of stores');

    final damageRows = await (db.select(db.crateLedger)
          ..where((t) => t.movementType.equals('damaged')))
        .get();
    expect(damageRows.length, 1);
    final row = damageRows.single;
    expect(row.movementType, 'damaged');
    expect(row.quantityDelta, -3);
    expect(row.storeId, storeA);
    expect(row.performedBy, userId);
    expect(row.ratePerCrateKobo, 120000);
    expect(row.manufacturerId, manufacturerId);
    expect(row.customerId, isNull);
  });

  test('defaults ratePerCrateKobo to manufacturer crate value if omitted',
      () async {
    await db.cratePoolDao.recordDamage(
      manufacturerId,
      2,
      storeId: storeA,
      performedBy: userId,
    );

    final damageRows = await (db.select(db.crateLedger)
          ..where((t) => t.movementType.equals('damaged')))
        .get();
    expect(damageRows.single.ratePerCrateKobo, 150000);
  });

  test('damage exceeding store warehouse count throws ArgumentError and writes nothing',
      () async {
    final beforeRows = await db.select(db.crateLedger).get();

    await expectLater(
      db.cratePoolDao.recordDamage(
        manufacturerId,
        11, // storeA only has 10
        storeId: storeA,
        performedBy: userId,
      ),
      throwsArgumentError,
    );

    final afterRows = await db.select(db.crateLedger).get();
    expect(afterRows.length, beforeRows.length);
    expect(await pool(store: storeA), 10);
  });

  test('booked loss remains unchanged when manufacturer crate value changes later',
      () async {
    await db.cratePoolDao.recordDamage(
      manufacturerId,
      2,
      storeId: storeA,
      performedBy: userId,
      ratePerCrateKobo: 150000,
    );

    final posBefore = await db.cratePoolDao
        .watchManufacturerCratePosition(manufacturerId, storeId: storeA)
        .first;
    expect(posBefore.damaged.count, 2);
    expect(posBefore.damaged.moneyKobo, 300000); // 2 * 150,000

    // Later, manufacturer crate value increases to ₦2,500 (250000 kobo)
    await (db.update(db.manufacturers)..where((t) => t.id.equals(manufacturerId)))
        .write(
      const ManufacturersCompanion(
        depositAmountKobo: Value(250000),
      ),
    );

    final posAfter = await db.cratePoolDao
        .watchManufacturerCratePosition(manufacturerId, storeId: storeA)
        .first;
    expect(posAfter.damaged.count, 2);
    // Crucial check: booked loss is still ₦3,000, NOT ₦5,000 (2 * 250,000)
    expect(posAfter.damaged.moneyKobo, 300000);
  });

  test('History labels it as Damaged', () async {
    await db.cratePoolDao.recordDamage(
      manufacturerId,
      1,
      storeId: storeA,
      performedBy: userId,
    );

    final history = await db.cratePoolDao
        .watchManufacturerCrateMovements(manufacturerId)
        .first;
    final damageEntry =
        history.firstWhere((h) => h.movementType == 'damaged');
    expect(damageEntry.movementLabel, 'Damaged');
  });

  test('Daily Reconciliation values damaged crates at snapshotted rate with fallback to current rate', () {
    final now = DateTime.now();
    final depositByMfr = {manufacturerId: 200000}; // current rate is ₦2,000

    // Row 1: snapshotted rate of ₦1,200 (120,000 kobo), lost 3
    final snapshottedRow = CrateLedgerData(
      id: 'damage-1',
      businessId: businessId,
      manufacturerId: manufacturerId,
      storeId: storeA,
      quantityDelta: -3,
      movementType: 'damaged',
      ratePerCrateKobo: 120000,
      createdAt: now,
      lastUpdatedAt: now,
    );

    // Row 2: legacy row with ratePerCrateKobo == null, lost 2
    final legacyRow = CrateLedgerData(
      id: 'damage-2',
      businessId: businessId,
      manufacturerId: manufacturerId,
      storeId: storeA,
      quantityDelta: -2,
      movementType: 'damaged',
      ratePerCrateKobo: null,
      createdAt: now,
      lastUpdatedAt: now,
    );

    int computeDamageDeposit(List<CrateLedgerData> crateDamages) {
      var crateDamageDepositKobo = 0;
      for (final c in crateDamages) {
        if (c.voidedAt != null) continue;
        final lostEmpties = -c.quantityDelta;
        if (lostEmpties <= 0) continue;
        final rate = c.ratePerCrateKobo ?? (depositByMfr[c.manufacturerId] ?? 0);
        crateDamageDepositKobo += lostEmpties * rate;
      }
      return crateDamageDepositKobo;
    }

    expect(computeDamageDeposit([snapshottedRow]), 360000,
        reason: '3 * 120,000 kobo snapshotted (not current 200,000)');
    expect(computeDamageDeposit([legacyRow]), 400000,
        reason: '2 * 200,000 kobo fallback to current rate for legacy row');
    expect(computeDamageDeposit([snapshottedRow, legacyRow]), 760000);
  });
}

