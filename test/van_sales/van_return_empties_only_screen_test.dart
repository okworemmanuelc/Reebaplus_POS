// van_return_empties_only_screen_test.dart
//
// #790 (owner, 2026-11-11): empty crates can come back from a van alone. On
// the Returns screen a crate product shows an "Empty crates back" box that can
// be filled without a goods count; saving it raises the shop's empties and
// leaves what the driver owes untouched.

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_return_screen.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {'van.manage', 'sales.make'};

  late ScreenTestEnvironment env;
  late String driverId;
  late String starId;
  late String brandId;
  late VanTripData trip;

  Future<void> settleFrames(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  setUp(() async {
    debugOverrideVanSalesEnabled(true);
    env = await setupScreenTestEnvironment(businessType: 'Bar');
    final db = env.db;
    final b = env.businessId;
    driverId = UuidV7.generate();
    starId = UuidV7.generate();
    brandId = UuidV7.generate();
    final vanStoreId = UuidV7.generate();

    await db.into(db.users).insert(
      UsersCompanion.insert(
        id: const Value('test-user-id'),
        businessId: b,
        name: 'Test Admin',
        pin: '1234',
      ),
    );
    await db.into(db.vanDrivers).insert(
      VanDriversCompanion.insert(
        id: Value(driverId),
        businessId: b,
        name: 'Johnson Kim',
      ),
    );
    await db.into(db.stores).insert(
      StoresCompanion.insert(
        id: Value(vanStoreId),
        businessId: b,
        name: 'Beer Vsm',
        kind: const Value('van'),
        vanDriverId: Value(driverId),
      ),
    );
    await db.into(db.manufacturers).insert(
      ManufacturersCompanion.insert(
        id: Value(brandId),
        businessId: b,
        name: 'Star Brewery',
      ),
    );
    await db.into(db.products).insert(
      ProductsCompanion.insert(
        id: Value(starId),
        businessId: b,
        name: 'Star Lager Crate',
        unit: const Value('Bottle'),
        trackEmpties: const Value(true),
        manufacturerId: Value(brandId),
        retailerPriceKobo: const Value(1150000),
      ),
    );
    await db.inventoryDao.adjustStock(
      starId,
      env.storeId,
      50,
      'opening',
      'test-user-id',
      trackCost: false,
    );
    final r = await db.vanTripsDao.dispatchLoad(
      vanStoreId: vanStoreId,
      vanDriverId: driverId,
      sourceStoreId: env.storeId,
      performedBy: 'test-user-id',
      dispatchEventId: UuidV7.generate(),
      lines: [
        VanLoadLine(
          productId: starId,
          quantity: 10,
          loadPriceKobo: 1150000,
          shellsOut: 10,
        ),
      ],
    );
    trip = (await db.vanTripsDao.getTrip(r.tripId))!;
  });

  tearDown(() async {
    debugOverrideVanSalesEnabled(null);
    await env.dispose();
  });

  testWidgets('empties alone can be typed and saved', (tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(412, 2000),
      screen: VanReturnScreen(
        trip: trip,
        driverName: 'Johnson Kim',
        vanName: 'Beer Vsm',
      ),
      grantedKeys: grants,
      settle: false,
    );
    await settleFrames(tester);

    // The empties box is there without a goods count.
    expect(find.byKey(Key('return-shells-$starId')), findsOneWidget);
    await tester.enterText(find.byKey(Key('return-shells-$starId')), '6');
    await tester.pump();
    // No goods, so no Good / Damaged choice.
    expect(find.text('Damaged'), findsNothing);
    await tester.tap(find.byKey(const Key('return-submit')));
    await settleFrames(tester);

    final db = env.db;
    final (events, owed, pool) = (await tester.runAsync(() async {
      return (
        await db.select(db.vanReturnEvents).get(),
        await db.driverLedgerDao.getBalanceKobo(driverId),
        await db.cratePoolDao
            .watchEmptiesPoolByManufacturer(storeId: env.storeId)
            .first,
      );
    }))!;
    expect(events, hasLength(1));
    expect(events.single.quantity, 0);
    expect(events.single.shellsBack, 6);
    expect(events.single.creditKobo, 0);
    // Still owes for all 10: 115,000.
    expect(owed, -11500000);
    expect(pool[brandId], 6);
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });
}
