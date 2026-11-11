// van_return_fast_entry_test.dart
//
// #790 — recording goods back quickly, without loosening the count rule:
//   · every product on the van is listed straight away (no name typing), and
//     its count box is EMPTY: the app never suggests how many came back;
//   · only rows with a count are saved; the rest are just the list;
//   · nothing typed at all is refused;
//   · the van card on the hub has "Record payment", which opens the form.

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_return_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_sales_hub_screen.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {'van.manage', 'sales.make'};

  late ScreenTestEnvironment env;
  late String driverId;
  late String vanStoreId;
  late String starId;
  late String maltId;
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
    // A general shop: no crates, so a row is a name and a count.
    env = await setupScreenTestEnvironment(businessType: 'supermarket');
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
    for (final (id, name, price) in [
      (starId, 'Star Lager', 1150000),
      (maltId, 'Malta Guinness', 900000),
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
        50,
        'opening',
        'test-user-id',
        trackCost: false,
      );
    }
    final r = await db.vanTripsDao.dispatchLoad(
      vanStoreId: vanStoreId,
      vanDriverId: driverId,
      sourceStoreId: env.storeId,
      performedBy: 'test-user-id',
      dispatchEventId: UuidV7.generate(),
      lines: [
        VanLoadLine(productId: starId, quantity: 10, loadPriceKobo: 1150000),
        VanLoadLine(productId: maltId, quantity: 20, loadPriceKobo: 900000),
      ],
    );
    trip = (await db.vanTripsDao.getTrip(r.tripId))!;
  });

  tearDown(() async {
    debugOverrideVanSalesEnabled(null);
    await env.dispose();
  });

  Future<void> openReturns(WidgetTester tester) async {
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
  }

  testWidgets('everything on the van is listed, with empty count boxes', (
    tester,
  ) async {
    await openReturns(tester);
    for (final id in [starId, maltId]) {
      final box = tester.widget<TextField>(find.byKey(Key('return-qty-$id')));
      // No controller, no initial figure: the app does not guess.
      expect(box.controller, isNull);
    }
    expect(find.text('Star Lager'), findsOneWidget);
    expect(find.text('Malta Guinness'), findsOneWidget);
    // Good / Damaged only shows once a count is typed.
    expect(find.text('Damaged'), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('only the rows with a count are saved', (tester) async {
    await openReturns(tester);
    // 10 Star went out at 11,500: the driver owes 295,000 in all.
    await tester.enterText(find.byKey(Key('return-qty-$starId')), '4');
    await tester.pump();
    expect(find.text('Damaged'), findsOneWidget);
    await tester.tap(find.byKey(const Key('return-submit')));
    await settleFrames(tester);

    final db = env.db;
    final (events, owed) = (await tester.runAsync(() async {
      return (
        await db.select(db.vanReturnEvents).get(),
        await db.driverLedgerDao.getBalanceKobo(driverId),
      );
    }))!;
    expect(events, hasLength(1));
    expect(events.single.productId, starId);
    expect(events.single.quantity, 4);
    // 295,000 - 4 x 11,500 = 249,000.
    expect(owed, -24900000);
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });

  testWidgets('nothing typed is refused', (tester) async {
    await openReturns(tester);
    await tester.tap(find.byKey(const Key('return-submit')));
    await settleFrames(tester);
    expect(
      find.text('Type how many came back beside at least one item.'),
      findsOneWidget,
    );
    final events = await tester.runAsync(
      () => env.db.select(env.db.vanReturnEvents).get(),
    );
    expect(events, isEmpty);
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });

  testWidgets('the van card has Record payment, and it opens the form', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(412, 2000),
      screen: const VanSalesHubScreen(),
      grantedKeys: grants,
      settle: false,
    );
    await settleFrames(tester);
    await tester.tap(find.byKey(Key('van-record-payment-$vanStoreId')));
    await settleFrames(tester);
    expect(find.text('Amount handed in'), findsOneWidget);
    // Close the form before the screen goes.
    Navigator.of(tester.element(find.text('Amount handed in'))).pop();
    await settleFrames(tester);
    await disposeScreen(tester);
    // The form's balance stream reads the database as it shuts down; give
    // that real time to finish before the database is closed.
    await settleFrames(tester);
  });
}
