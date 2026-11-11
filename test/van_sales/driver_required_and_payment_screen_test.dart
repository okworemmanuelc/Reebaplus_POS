// driver_required_and_payment_screen_test.dart
//
// #787 — what a manager meets on screen:
//   · the driver's page has "Record payment"; recording one with no trip
//     lowers that driver's balance by exactly the amount, booked to the shop;
//   · a van cannot be loaded until a driver is chosen, and the picker no
//     longer offers "No driver assigned".

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_profile_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/load_van_screen.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {'van.manage', 'sales.make', 'reports.see_sales'};

  late ScreenTestEnvironment env;
  late String driverId;
  late String vanStoreId;

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
    driverId = UuidV7.generate();
    vanStoreId = UuidV7.generate();
    await db.into(db.vanDrivers).insert(
      VanDriversCompanion.insert(
        id: Value(driverId),
        businessId: env.businessId,
        name: 'Johnson Kim',
      ),
    );
    // The van has NO usual driver, so nothing is pre-filled at load.
    await db.into(db.stores).insert(
      StoresCompanion.insert(
        id: Value(vanStoreId),
        businessId: env.businessId,
        name: 'Beer Vsm',
        kind: const Value('van'),
      ),
    );
    // He owes 5,000 with no van and no trip.
    await db.driverLedgerDao.postEntry(
      vanDriverId: driverId,
      type: kDriverLedgerTypeRestatement,
      amountKobo: 500000,
      isCredit: false,
      referenceType: kDriverLedgerRefEntry,
      activityDate: DateTime.now(),
    );
  });

  tearDown(() async {
    debugOverrideVanSalesEnabled(null);
    await env.dispose();
  });

  testWidgets('Record payment on the driver page lowers the balance, with no '
      'trip', (tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(412, 2000),
      screen: DriverProfileScreen(vanDriverId: driverId, initialTab: 'ledger'),
      grantedKeys: grants,
      settle: false,
    );
    await settleFrames(tester);
    await tester.runAsync(
      () => env.db.into(env.db.users).insert(
        UsersCompanion.insert(
          id: const Value('test-user-id'),
          businessId: env.businessId,
          name: 'Test Admin',
          pin: '1234',
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('driver-record-payment')));
    await settleFrames(tester);
    expect(find.text('Amount handed in'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '2000');
    await tester.pump();
    await tester.tap(find.text('Record Payment').last);
    await settleFrames(tester);

    final db = env.db;
    final (bal, pays) = (await tester.runAsync(() async {
      return (
        await db.driverLedgerDao.getBalanceKobo(driverId),
        await db.select(db.paymentTransactions).get(),
      );
    }))!;
    expect(bal, -300000);
    expect(pays, hasLength(1));
    expect(pays.single.vanDriverId, driverId);
    expect(pays.single.vanTripId, isNull);
    expect(pays.single.storeId, env.storeId);
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });

  testWidgets('a van cannot be loaded without a driver', (tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(412, 2000),
      screen: LoadVanScreen(vanStoreId: vanStoreId),
      grantedKeys: grants,
      settle: false,
    );
    await settleFrames(tester);
    expect(find.text('Driver'), findsWidgets);
    expect(find.text('Driver (optional)'), findsNothing);
    expect(find.text('No driver assigned'), findsNothing);

    await tester.tap(find.byKey(const Key('load-van-send')));
    await settleFrames(tester);
    expect(find.text('Choose who is taking the van out.'), findsOneWidget);
    final trips = await tester.runAsync(
      () => env.db.select(env.db.vanTrips).get(),
    );
    expect(trips, isEmpty);
    await tester.pump(const Duration(seconds: 10));
    await disposeScreen(tester);
  });
}
