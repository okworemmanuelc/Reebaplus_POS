// van_return_empties_per_manufacturer_test.dart
//
// #801 (owner): on the Returns screen empty crates are counted ONCE PER
// MANUFACTURER, not against each product. Full goods stay per product.

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
  late String starStoutId;
  late String legendId;
  late String starBrand;
  late String legendBrand;
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
    starStoutId = UuidV7.generate();
    legendId = UuidV7.generate();
    starBrand = UuidV7.generate();
    legendBrand = UuidV7.generate();
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
    for (final (id, name) in [
      (starBrand, 'Star Brewery'),
      (legendBrand, 'Legend Brewery'),
    ]) {
      await db.into(db.manufacturers).insert(
        ManufacturersCompanion.insert(
          id: Value(id),
          businessId: b,
          name: name,
        ),
      );
    }
    final loadLines = <VanLoadLine>[];
    for (final (id, name, brand) in [
      (starId, 'Star Lager Crate', starBrand),
      (starStoutId, 'Star Stout Crate', starBrand),
      (legendId, 'Legend Crate', legendBrand),
    ]) {
      await db.into(db.products).insert(
        ProductsCompanion.insert(
          id: Value(id),
          businessId: b,
          name: name,
          unit: const Value('Bottle'),
          trackEmpties: const Value(true),
          manufacturerId: Value(brand),
          retailerPriceKobo: const Value(1150000),
        ),
      );
      await db.inventoryDao.adjustStock(
        id,
        env.storeId,
        50,
        'opening',
        'test-user-id',
        trackCost: false,
      );
      loadLines.add(
        VanLoadLine(
          productId: id,
          quantity: 10,
          loadPriceKobo: 1150000,
          shellsOut: 10,
        ),
      );
    }
    final r = await db.vanTripsDao.dispatchLoad(
      vanStoreId: vanStoreId,
      vanDriverId: driverId,
      sourceStoreId: env.storeId,
      performedBy: 'test-user-id',
      dispatchEventId: UuidV7.generate(),
      lines: loadLines,
    );
    trip = (await db.vanTripsDao.getTrip(r.tripId))!;
  });

  tearDown(() async {
    debugOverrideVanSalesEnabled(null);
    await env.dispose();
  });

  Future<void> open(WidgetTester tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(412, 2400),
      screen: VanReturnScreen(
        trip: trip,
        driverName: 'Johnson Kim',
        vanName: 'Beer Vsm',
      ),
      grantedKeys: grants,
      settle: false,
    );
    await settleFrames(tester);
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('return-submit')));
    await settleFrames(tester);
  }

  Future<(List<VanReturnEventData>, Map<String, double>, VanTripData)> read(
    WidgetTester tester,
  ) async {
    final db = env.db;
    return (await tester.runAsync(() async {
      return (
        await db.select(db.vanReturnEvents).get(),
        await db.cratePoolDao
            .watchEmptiesPoolByManufacturer(storeId: env.storeId)
            .first,
        (await db.vanTripsDao.getTrip(trip.id))!,
      );
    }))!;
  }

  testWidgets('one empties box per manufacturer, none per product', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Empty crates'), findsOneWidget);
    expect(find.text('Star Brewery'), findsOneWidget);
    expect(find.text('Legend Brewery'), findsOneWidget);
    expect(find.byKey(Key('return-empties-$starBrand')), findsOneWidget);
    expect(find.byKey(Key('return-empties-$legendBrand')), findsOneWidget);
    expect(find.byKey(Key('return-shells-$starId')), findsNothing);
    // Goods boxes stay per product.
    expect(find.byKey(Key('return-qty-$starId')), findsOneWidget);
    expect(find.byKey(Key('return-qty-$starStoutId')), findsOneWidget);
    expect(find.byKey(Key('return-qty-$legendId')), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('empties alone, per manufacturer, credit the warehouse', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byKey(Key('return-empties-$starBrand')), '7');
    await tester.enterText(
      find.byKey(Key('return-empties-$legendBrand')),
      '3',
    );
    await tester.pump();
    await save(tester);

    final (events, pool, tripNow) = await read(tester);
    expect(events.every((e) => e.quantity == 0 && e.creditKobo == 0), isTrue);
    expect(events.fold<int>(0, (s, e) => s + e.shellsBack), 10);
    expect(pool[starBrand], 7);
    expect(pool[legendBrand], 3);
    expect(tripNow.shellsBack, 10);
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });

  testWidgets('two products of one manufacturer share one count', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byKey(Key('return-qty-$starId')), '2');
    await tester.enterText(find.byKey(Key('return-qty-$starStoutId')), '1');
    await tester.enterText(find.byKey(Key('return-empties-$starBrand')), '5');
    await tester.pump();
    await save(tester);

    final (events, pool, tripNow) = await read(tester);
    expect(events, hasLength(2));
    expect(events.fold<int>(0, (s, e) => s + e.quantity), 3);
    expect(events.fold<int>(0, (s, e) => s + e.shellsBack), 5);
    expect(pool[starBrand], 5);
    expect(pool[legendBrand], isNull);
    expect(tripNow.shellsBack, 5);
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });

  testWidgets('goods back without the manufacturer count is refused', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byKey(Key('return-qty-$legendId')), '2');
    await tester.pump();
    await save(tester);

    expect(find.textContaining('Legend Brewery'), findsWidgets);
    final (events, _, _) = await read(tester);
    expect(events, isEmpty);

    // 0 is a valid answer.
    await tester.enterText(
      find.byKey(Key('return-empties-$legendBrand')),
      '0',
    );
    await tester.pump();
    await save(tester);
    final (after, pool, _) = await read(tester);
    expect(after, hasLength(1));
    expect(after.single.quantity, 2);
    expect(after.single.shellsBack, 0);
    expect(pool[legendBrand], isNull);
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });
}
