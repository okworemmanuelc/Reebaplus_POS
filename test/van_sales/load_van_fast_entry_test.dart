// load_van_fast_entry_test.dart
//
// #790 — loading a van quickly. A real load is 16 to 30 lines, so:
//   · a picked item lands as a compact row, the add box is cleared for the
//     next one, and an item already on the load is not offered again;
//   · quantity moves with plus / minus and by typing, never past stock or
//     below one;
//   · the load price is behind "Edit" and still changes what is charged;
//   · dispatch writes the same trip as before.

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/van_sales/screens/load_product_picker_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/load_van_screen.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {'van.manage', 'sales.make'};

  late ScreenTestEnvironment env;
  late String driverId;
  late String vanStoreId;
  late String starId;
  late String maltId;

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
    env = await setupScreenTestEnvironment(businessType: 'drinks');
    final db = env.db;
    final b = env.businessId;
    driverId = UuidV7.generate();
    vanStoreId = UuidV7.generate();
    starId = UuidV7.generate();
    maltId = UuidV7.generate();

    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: b,
            name: 'Test Admin',
            pin: '1234',
          ),
        );
    await db
        .into(db.vanDrivers)
        .insert(
          VanDriversCompanion.insert(
            id: Value(driverId),
            businessId: b,
            name: 'Johnson Kim',
          ),
        );
    // The van's usual driver, so the driver is pre-filled.
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(vanStoreId),
            businessId: b,
            name: 'Beer Vsm',
            kind: const Value('van'),
            vanDriverId: Value(driverId),
          ),
        );
    for (final (id, name, price, stock) in [
      (starId, 'Star Lager', 1150000, 5),
      (maltId, 'Malta Guinness', 900000, 40),
    ]) {
      await db
          .into(db.products)
          .insert(
            ProductsCompanion.insert(
              id: Value(id),
              businessId: b,
              name: name,
              retailerPriceKobo: Value(price),
            ),
          );
      await db.inventoryDao.adjustStock(
        id,
        env.storeId,
        stock.toDouble(),
        'opening',
        'test-user-id',
        trackCost: false,
      );
    }
  });

  tearDown(() async {
    debugOverrideVanSalesEnabled(null);
    await env.dispose();
  });

  Future<void> open(WidgetTester tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(412, 2000),
      screen: LoadVanScreen(vanStoreId: vanStoreId),
      grantedKeys: grants,
      settle: false,
    );
    await settleFrames(tester);
  }

  Future<void> add(WidgetTester tester, String typed, String name) async {
    await tester.enterText(find.byKey(const Key('load-van-add')), typed);
    await settleFrames(tester);
    await tester.tap(find.text(name).last);
    await settleFrames(tester);
  }

  String qtyOf(WidgetTester tester, String id) => tester
      .widget<TextField>(find.byKey(Key('load-qty-$id')))
      .controller!
      .text;

  testWidgets('a picked item becomes a compact row, the add box clears, and '
      'it is not offered twice', (tester) async {
    await open(tester);
    await add(tester, 'star', 'Star Lager');

    expect(find.byKey(Key('load-qty-$starId')), findsOneWidget);
    expect(qtyOf(tester, starId), '1');
    // The price box is tucked away until Edit is tapped.
    expect(find.byKey(Key('load-price-$starId')), findsNothing);
    // Cleared, ready for the next item.
    final addBox = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('load-van-add')),
        matching: find.byType(EditableText),
      ),
    );
    expect(addBox.controller.text, isEmpty);

    // Typing the same name again offers nothing to pick.
    await tester.enterText(find.byKey(const Key('load-van-add')), 'star');
    await settleFrames(tester);
    expect(find.text('Star Lager'), findsOneWidget); // the row only
    await disposeScreen(tester);
  });

  testWidgets('plus and minus move the quantity, never past stock or below '
      'one; typing sets it', (tester) async {
    await open(tester);
    await add(tester, 'star', 'Star Lager');

    await tester.tap(find.byKey(Key('load-minus-$starId')));
    await tester.pump();
    expect(qtyOf(tester, starId), '1');

    for (var i = 0; i < 7; i++) {
      await tester.tap(find.byKey(Key('load-plus-$starId')));
      await tester.pump();
    }
    expect(qtyOf(tester, starId), '5'); // only 5 in stock

    await tester.enterText(find.byKey(Key('load-qty-$starId')), '3');
    await tester.pump();
    final info = tester.widget<Text>(find.byKey(Key('load-line-info-$starId')));
    // 3 x 11,500 = 34,500.
    expect(info.data, contains('34,500'));
    await disposeScreen(tester);
  });

  testWidgets('two items, an edited price, and dispatch writes the trip', (
    tester,
  ) async {
    await open(tester);
    await add(tester, 'star', 'Star Lager');
    await tester.enterText(find.byKey(Key('load-qty-$starId')), '2');
    await tester.pump();
    await add(tester, 'malt', 'Malta Guinness');
    await tester.enterText(find.byKey(Key('load-qty-$maltId')), '10');
    await tester.pump();

    await tester.tap(find.byKey(Key('load-edit-$maltId')));
    await tester.pump();
    await tester.enterText(find.byKey(Key('load-price-$maltId')), '8500');
    await tester.pump();

    await tester.tap(find.byKey(const Key('load-van-send')));
    await settleFrames(tester);

    final db = env.db;
    final (trips, lots, owed) = (await tester.runAsync(() async {
      return (
        await db.select(db.vanTrips).get(),
        await db.select(db.vanTripLots).get(),
        await db.driverLedgerDao.getBalanceKobo(driverId),
      );
    }))!;
    expect(trips, hasLength(1));
    expect(trips.single.vanDriverId, driverId);
    expect(lots, hasLength(2));
    // 2 x 11,500 + 10 x 8,500 = 108,000.
    expect(owed, -10800000);
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });

  testWidgets('the product grid: a tap adds one, a long press sets the '
      'number, and Done brings them back as rows', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('load-van-browse')));
    await settleFrames(tester);

    await tester.tap(find.byKey(loadPickerTileKey(starId)));
    await tester.pump();
    await tester.tap(find.byKey(loadPickerTileKey(starId)));
    await tester.pump();
    await tester.longPress(find.byKey(loadPickerTileKey(maltId)));
    await settleFrames(tester);
    await tester.enterText(find.byKey(const Key('load-picker-qty')), '10');
    await tester.tap(find.byKey(const Key('load-picker-qty-ok')));
    await settleFrames(tester);
    expect(find.textContaining('2 items, 12 units'), findsOneWidget);

    await tester.tap(find.byKey(const Key('load-picker-done')));
    await settleFrames(tester);
    expect(qtyOf(tester, starId), '2');
    expect(qtyOf(tester, maltId), '10');

    // Back in the grid the counts are remembered; setting one to 0 takes it
    // off the load, and a number over stock is held at stock.
    await tester.tap(find.byKey(const Key('load-van-browse')));
    await settleFrames(tester);
    await tester.longPress(find.byKey(loadPickerTileKey(maltId)));
    await settleFrames(tester);
    await tester.enterText(find.byKey(const Key('load-picker-qty')), '0');
    await tester.tap(find.byKey(const Key('load-picker-qty-ok')));
    await settleFrames(tester);
    await tester.longPress(find.byKey(loadPickerTileKey(starId)));
    await settleFrames(tester);
    await tester.enterText(find.byKey(const Key('load-picker-qty')), '99');
    await tester.tap(find.byKey(const Key('load-picker-qty-ok')));
    await settleFrames(tester);
    await tester.pump(const Duration(seconds: 10));
    await tester.tap(find.byKey(const Key('load-picker-done')));
    await settleFrames(tester);
    expect(qtyOf(tester, starId), '5'); // only 5 in stock
    expect(find.byKey(Key('load-qty-$maltId')), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('the product grid searches by name', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('load-van-browse')));
    await settleFrames(tester);
    expect(find.byKey(loadPickerTileKey(starId)), findsOneWidget);
    expect(find.byKey(loadPickerTileKey(maltId)), findsOneWidget);
    await tester.enterText(find.byKey(const Key('load-picker-search')), 'malt');
    await settleFrames(tester);
    expect(find.byKey(loadPickerTileKey(starId)), findsNothing);
    expect(find.byKey(loadPickerTileKey(maltId)), findsOneWidget);
    await tester.tap(find.byKey(const Key('load-picker-done')));
    await settleFrames(tester);
    await disposeScreen(tester);
  });

  testWidgets('Same as last load copies the driver\'s last load at today\'s '
      'price, held at what is in stock, restocks left out', (tester) async {
    // Yesterday: 4 Star and 12 Malta at an old price, then a restock of 3.
    await tester.runAsync(() async {
      final db = env.db;
      final r = await db.vanTripsDao.dispatchLoad(
        vanStoreId: vanStoreId,
        vanDriverId: driverId,
        sourceStoreId: env.storeId,
        performedBy: 'test-user-id',
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: starId, quantity: 4, loadPriceKobo: 1000000),
          VanLoadLine(productId: maltId, quantity: 12, loadPriceKobo: 800000),
        ],
      );
      await db.vanTripsDao.restockTrip(
        tripId: r.tripId,
        performedBy: 'test-user-id',
        dispatchEventId: UuidV7.generate(),
        lines: [
          VanLoadLine(productId: maltId, quantity: 3, loadPriceKobo: 800000),
        ],
      );
      // The trip is over, so the van can load again.
      await (db.update(db.vanTrips)..where((t) => t.id.equals(r.tripId))).write(
        VanTripsCompanion(
          status: const Value('closed'),
          closedAt: Value(DateTime.now()),
        ),
      );
    });
    // Star: 5 - 4 = 1 left in the shop, so 4 is cut to 1.
    await open(tester);
    await tester.tap(find.byKey(const Key('load-van-same-as-last')));
    await settleFrames(tester);

    expect(qtyOf(tester, starId), '1');
    expect(qtyOf(tester, maltId), '12'); // the load, not the restock
    final info = tester.widget<Text>(find.byKey(Key('load-line-info-$maltId')));
    // Today's shop price (9,000), not last time's 8,000.
    expect(info.data, contains('9,000'));
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });

  testWidgets('Same as last load says so when there is nothing to copy', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('load-van-same-as-last')));
    await settleFrames(tester);
    expect(find.text('No earlier load to copy.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });
}
