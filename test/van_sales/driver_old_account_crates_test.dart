// driver_old_account_crates_test.dart
//
// #821 — a driver linked to an old customer account sees that account's empty
// crates on the "Crates owed" tab: what is still owed per manufacturer (plus a
// total) and the crate history, newest first. Shown only, never rewritten.
//   · linked driver: owed counts per manufacturer, total, history rows;
//   · unlinked driver: no "Crates owed" tab;
//   · a shop that does not track crates: no "Crates owed" tab;
//   · the page pumps cleanly at 360x800 and 1920x1080.

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_profile_screen.dart';

import '../helpers/screen_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const grants = {'van.manage', 'sales.make', 'reports.see_sales'};

  late ScreenTestEnvironment env;
  late String driverId;
  late String customerId;
  late String alphaId;
  final ledgerIds = <String>[];

  Future<void> settleFrames(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> link(WidgetTester tester) async {
    await tester.runAsync(
      () => env.db.vanDriversDao.linkOldCustomerAccount(
        vanDriverId: driverId,
        customerId: customerId,
      ),
    );
  }

  Future<void> pumpDriver(WidgetTester tester, Size size) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: DriverProfileScreen(
        vanDriverId: driverId,
        initialTab: 'oldCrates',
      ),
      grantedKeys: grants,
      settle: false,
    );
    await settleFrames(tester);
    // The tab list grows once the business loads, so select the last tab
    // ("Crates owed" when shown) on the controller rather than relying on
    // initialTab; on a phone the tab may sit past the strip's visible edge.
    if (find.text('Crates owed').evaluate().isNotEmpty) {
      final controller = tester.widget<TabBar>(find.byType(TabBar)).controller!;
      controller.index = controller.length - 1;
      await settleFrames(tester);
    }
  }

  setUp(() async {
    debugOverrideVanSalesEnabled(true);
    debugOverrideDriverScreensEnabled(true);
    env = await setupScreenTestEnvironment(businessType: 'Bar');
    final db = env.db;
    final b = env.businessId;
    ledgerIds.clear();

    driverId = UuidV7.generate();
    customerId = UuidV7.generate();
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
        .into(db.customers)
        .insert(
          CustomersCompanion.insert(
            id: Value(customerId),
            businessId: b,
            name: 'Johnson Kim (Van Driver)',
          ),
        );
    await db
        .into(db.customerWallets)
        .insert(
          CustomerWalletsCompanion.insert(
            businessId: b,
            customerId: customerId,
          ),
        );

    alphaId = UuidV7.generate();
    final betaId = UuidV7.generate();
    for (final (id, name) in [
      (alphaId, 'Alpha Brewery'),
      (betaId, 'Beta Brewery'),
    ]) {
      await db
          .into(db.manufacturers)
          .insert(
            ManufacturersCompanion.insert(
              id: Value(id),
              businessId: b,
              name: name,
            ),
          );
    }

    // Alpha: +5 given out, -2 returned, +1 correction = 4 owed.
    // Beta: +3 given out, -3 returned = clear (not listed as owed).
    final base = DateTime(2026, 3, 1);
    final rows = [
      (alphaId, 5.0, 'issued', 0),
      (betaId, 3.0, 'issued', 1),
      (alphaId, -2.0, 'returned', 2),
      (betaId, -3.0, 'returned', 3),
      (alphaId, 1.0, 'adjusted', 4),
    ];
    for (final (mId, qty, type, day) in rows) {
      final id = UuidV7.generate();
      ledgerIds.add(id);
      final at = base.add(Duration(days: day));
      await db
          .into(db.crateLedger)
          .insert(
            CrateLedgerCompanion.insert(
              id: Value(id),
              businessId: b,
              customerId: Value(customerId),
              manufacturerId: Value(mId),
              quantityDelta: qty,
              movementType: type,
              createdAt: Value(at),
              lastUpdatedAt: Value(at),
            ),
          );
    }
  });

  tearDown(() async {
    debugOverrideVanSalesEnabled(null);
    debugOverrideDriverScreensEnabled(null);
    await env.dispose();
  });

  testWidgets('linked driver: owed per manufacturer, total, and history', (
    tester,
  ) async {
    await link(tester);
    // Tall, so every history row is built.
    await pumpDriver(tester, const Size(412, 2400));

    expect(find.text('Crates owed'), findsOneWidget);
    final card = find.byKey(kDriverCratesOwedCardKey);
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('Empty crates owed')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('Alpha Brewery')),
      findsOneWidget,
    );
    // Beta nets to zero: not listed as owed.
    expect(
      find.descendant(of: card, matching: find.text('Beta Brewery')),
      findsNothing,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('driver-crates-owed-total')))
          .data,
      '4',
    );

    // Every history row, newest first, in plain words with a signed count.
    for (final id in ledgerIds) {
      expect(find.byKey(driverOldCrateRowKey(id)), findsOneWidget);
    }
    expect(find.text('Given out'), findsNWidgets(2));
    expect(find.text('Returned'), findsNWidgets(2));
    expect(find.text('Correction'), findsOneWidget);
    expect(find.text('+5'), findsOneWidget);
    expect(find.text('−3'), findsOneWidget);
    final newest = tester.getTopLeft(
      find.byKey(driverOldCrateRowKey(ledgerIds.last)),
    );
    final oldest = tester.getTopLeft(
      find.byKey(driverOldCrateRowKey(ledgerIds.first)),
    );
    expect(newest.dy, lessThan(oldest.dy));
    expect(tester.takeException(), isNull);
    await disposeScreen(tester);
  });

  testWidgets('linked driver with nothing owed says so in one line', (
    tester,
  ) async {
    // Alpha owes 4: a -4 correction clears it (Beta is already clear).
    await tester.runAsync(
      () => env.db
          .into(env.db.crateLedger)
          .insert(
            CrateLedgerCompanion.insert(
              businessId: env.businessId,
              customerId: Value(customerId),
              manufacturerId: Value(alphaId),
              quantityDelta: -4,
              movementType: 'adjusted',
            ),
          ),
    );
    await link(tester);
    await pumpDriver(tester, const Size(412, 1200));
    expect(find.text('No empty crates owed.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('driver-crates-owed-total')),
      findsNothing,
    );
    await disposeScreen(tester);
  });

  testWidgets('unlinked driver: no crates-owed tab', (tester) async {
    await pumpDriver(tester, const Size(412, 1200));
    expect(find.text('Crates'), findsOneWidget);
    expect(find.text('Crates owed'), findsNothing);
    expect(find.byKey(kDriverCratesOwedCardKey), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('a shop that does not track crates: no crates-owed tab', (
    tester,
  ) async {
    await tester.runAsync(
      () =>
          (env.db.update(
            env.db.businesses,
          )..where((b) => b.id.equals(env.businessId))).write(
            const BusinessesCompanion(tracksEmptyCrates: Value(false)),
          ),
    );
    await link(tester);
    await pumpDriver(tester, const Size(412, 1200));
    expect(find.text('Crates owed'), findsNothing);
    expect(find.byKey(kDriverCratesOwedCardKey), findsNothing);
    await disposeScreen(tester);
  });

  for (final size in const [Size(360, 800), Size(1920, 1080)]) {
    testWidgets(
      'pumps cleanly at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await link(tester);
        await pumpDriver(tester, size);
        expect(find.byKey(kDriverCratesOwedCardKey), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (size.width > 1000) {
          // The card stays in the 720 column.
          expect(
            tester.getSize(find.byKey(kDriverCratesOwedCardKey)).width,
            lessThanOrEqualTo(720),
          );
        }
        await disposeScreen(tester);
      },
    );
  }
}
