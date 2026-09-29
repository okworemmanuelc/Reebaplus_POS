import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// #298 — crate value fill-in. Sales made while a brand had no crate value take
/// the value once it is first set (0 → positive): gap-only, once, no money leg,
/// full-row sync. Mirrors the cost backfill (F5).
void main() {
  late AppDatabase db;
  late String businessId;
  late String unsetBrand;
  late String otherBrand;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    unsetBrand = await db.inventoryDao.insertManufacturer(
      ManufacturersCompanion.insert(name: 'Unset', businessId: businessId),
    );
    otherBrand = await db.inventoryDao.insertManufacturer(
      ManufacturersCompanion.insert(name: 'Other', businessId: businessId),
    );
  });

  tearDown(() => db.close());

  Future<String> seedLine(
    String brandId, {
    int rate = 0,
    int paid = 0,
    String tag = 'A',
  }) async {
    final orderId = UuidV7.generate();
    await db.into(db.orders).insert(
          OrdersCompanion.insert(
            id: Value(orderId),
            businessId: businessId,
            orderNumber: 'ORD-$tag-${UuidV7.generate()}',
            totalAmountKobo: 100000,
            netAmountKobo: 100000,
            paymentType: 'cash',
            status: 'completed',
          ),
        );
    final lineId = UuidV7.generate();
    await db.into(db.orderCrateLines).insert(
          OrderCrateLinesCompanion.insert(
            id: Value(lineId),
            businessId: businessId,
            orderId: orderId,
            manufacturerId: brandId,
            cratesTaken: 2,
            depositRateKobo: Value(rate),
            depositPaidKobo: Value(paid),
          ),
        );
    return lineId;
  }

  Future<OrderCrateLineData> line(String id) => (db.select(db.orderCrateLines)
        ..where((l) => l.id.equals(id)))
      .getSingle();

  Future<int> rows(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle())
          .read<int>('c');

  test('0 → positive stamps only that brand\'s 0-rate lines', () async {
    final unrated = await seedLine(unsetBrand);
    final rated = await seedLine(unsetBrand, rate: 50000, tag: 'B');
    final other = await seedLine(otherBrand, tag: 'C');

    await db.inventoryDao.updateManufacturerDeposit(unsetBrand, 120000);

    expect((await line(unrated)).depositRateKobo, 120000);
    expect((await line(rated)).depositRateKobo, 50000);
    expect((await line(other)).depositRateKobo, 0);
  });

  test('positive → positive fills nothing, and 0 → positive fills once',
      () async {
    await db.inventoryDao.updateManufacturerDeposit(unsetBrand, 120000);
    // A line that arrives at rate 0 AFTER the first value is not retro-filled
    // by a later change.
    final late = await seedLine(unsetBrand, tag: 'L');

    await db.inventoryDao.updateManufacturerDeposit(unsetBrand, 200000);

    expect((await line(late)).depositRateKobo, 0);
  });

  test('writes no money leg and leaves deposit paid alone', () async {
    final id = await seedLine(unsetBrand);
    final before = {
      for (final t in ['wallet_transactions', 'expenses', 'payment_transactions'])
        t: await rows(t),
    };

    await db.inventoryDao.updateManufacturerDeposit(unsetBrand, 120000);

    final after = {
      for (final t in before.keys) t: await rows(t),
    };
    expect(after, before);
    final l = await line(id);
    expect(l.depositPaidKobo, 0, reason: 'stays Crate-Track');
    expect(l.settledAt, isNull);
  });

  test('stamped lines are enqueued as FULL rows', () async {
    final id = await seedLine(unsetBrand);
    await db.customStatement('DELETE FROM sync_queue');

    await db.inventoryDao.updateManufacturerDeposit(unsetBrand, 120000);

    final pending = await getPendingQueue(db);
    final lines = pending
        .where((r) => r.actionType == 'order_crate_lines:upsert')
        .map(decodePayload)
        .toList();
    expect(lines, hasLength(1));
    expect(lines.single['id'], id);
    expect(lines.single['deposit_rate_kobo'], 120000);
    // NOT NULL columns present, or the cloud rejects the row.
    expect(lines.single['order_id'], isNotNull);
    expect(lines.single['manufacturer_id'], unsetBrand);
    expect(lines.single['crates_taken'], 2);
  });

  test('countUnratedLines counts what a save would fill', () async {
    await seedLine(unsetBrand);
    await seedLine(unsetBrand, tag: 'B');
    await seedLine(unsetBrand, rate: 1000, tag: 'C');
    expect(await db.orderCrateLinesDao.countUnratedLines(unsetBrand), 2);
    expect(await db.orderCrateLinesDao.countUnratedLines(otherBrand), 0);
  });
}
