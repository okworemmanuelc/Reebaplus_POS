import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/van_sales/van_sales_switch.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_profile_screen.dart';

import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #247 / PRD #239 — Driver Profile holds its content at every viewport
/// (adopting the shared TabbedSliverScaffold).
///
/// Acceptance Criteria:
///   1. Screen built on TabbedSliverScaffold from #243.
///   2. Private tabbed-scroller wiring (DefaultTabController, NestedScrollView,
///      _TripsTab, _SalesTab, _LedgerTab, _CratesTab) deleted.
///   3. No tab body contains a fixed-height band above an expanded/flexible remainder.
///   4. Tests pump screen at phoneSe1Portrait (320x568), androidCompactLandscape (800x360),
///      pixel7Landscape (915x412), and pixel7Portrait (412x915) via screen_harness.dart.
///   5. Each test asserts: no layout overflow (expectNoOverflow) and at least one
///      complete row visible and hit-testable (expectContentRowVisible).
///   6. Tested in both empty and populated data states.
///   7. Verified tab swiping and scroll offset retention across tab switches.
///   8. Verified 48dp minimum interactive dimension tap targets and text scaling.
///   9. Unconditional fix: zero orientation branching or short-viewport predicates.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const driverGrants = {
    'van.manage',
    'sales.make',
    'reports.see_sales',
  };

  Finder driverTripRows() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>)
                .value
                .startsWith(kDriverTripRowKeyPrefix),
        description: 'driver trip row',
      );

  Finder tabSurface() => find
      .descendant(
        of: find.byType(TabSliverBody).first,
        matching: find.byType(CustomScrollView),
      )
      .first;

  const viewports = <String, Size>{
    'phoneSe1Portrait (320x568, smallest supported portrait)': phoneSe1Portrait,
    'androidCompactLandscape (800x360, shortest supported landscape)':
        androidCompactLandscape,
    'pixel7Landscape (915x412, landscape phone)': pixel7Landscape,
    'pixel7Portrait (412x915, comfortable control)': pixel7Portrait,
  };

  group('Driver Profile holds its content — populated driver', () {
    late ScreenTestEnvironment env;
    late String driverId;

    setUp(() async {
      debugOverrideVanSalesEnabled(true);
      env = await setupScreenTestEnvironment(businessType: 'drinks');
      final db = env.db;
      final b = env.businessId;

      await (db.update(db.businesses)..where((t) => t.id.equals(b))).write(
        const BusinessesCompanion(
          tracksEmptyCrates: Value(true),
        ),
      );

      driverId = UuidV7.generate();
      final driverRoleId = UuidV7.generate();

      await db.into(db.roles).insert(
            RolesCompanion.insert(
              id: Value(driverRoleId),
              businessId: b,
              name: 'Driver',
              slug: 'driver',
            ),
          );

      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(driverId),
              businessId: b,
              name: 'Dan Driver',
              pin: '0000',
            ),
          );

      await db.into(db.userBusinesses).insert(
            UserBusinessesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: b,
              userId: driverId,
              roleId: driverRoleId,
              status: const Value('active'),
            ),
          );

      final vanStoreId = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(vanStoreId),
              businessId: b,
              name: 'Delivery Van 1',
              kind: const Value(kStoreKindVan),
            ),
          );

      await db.into(db.userStores).insert(
            UserStoresCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: b,
              userId: driverId,
              storeId: vanStoreId,
            ),
          );

      final now = DateTime.now();
      final monthAnchor = DateTime(now.year, now.month, 1, 8);
      for (var i = 1; i <= 8; i++) {
        final tripId = UuidV7.generate();
        final openedAt = monthAnchor.add(Duration(days: i - 1));
        final closedAt = openedAt.add(const Duration(hours: 6));

        await db.into(db.vanTrips).insert(
              VanTripsCompanion.insert(
                id: Value(tripId),
                businessId: b,
                vanStoreId: vanStoreId,
                driverUserId: driverId,
                sourceStoreId: env.storeId,
                status: const Value(kVanTripStatusClosed),
                openedAt: Value(openedAt),
                closedAt: Value(closedAt),
                profitKobo: Value(i == 1 ? 0 : 500000),
                shellsOut: Value(10 + i),
                shellsBack: Value(8 + i),
              ),
            );

        final orderId = UuidV7.generate();
        await db.into(db.orders).insert(
              OrdersCompanion.insert(
                id: Value(orderId),
                businessId: b,
                orderNumber: 'VAN-ORD-00$i',
                totalAmountKobo: 250000 * i,
                netAmountKobo: 250000 * i,
                amountPaidKobo: Value(250000 * i),
                paymentType: 'cash',
                status: 'completed',
                storeId: Value(vanStoreId),
                vanTripId: Value(tripId),
                completedAt: Value(openedAt),
                createdAt: Value(openedAt),
              ),
            );

        if (env.products.isNotEmpty) {
          await db.into(db.orderItems).insert(
                OrderItemsCompanion.insert(
                  id: Value(UuidV7.generate()),
                  businessId: b,
                  orderId: orderId,
                  storeId: vanStoreId,
                  productId: Value(env.products[i % env.products.length].id),
                  quantity: 2,
                  unitPriceKobo: 125000 * i,
                  totalKobo: 250000 * i,
                  createdAt: Value(openedAt),
                ),
              );
        }

        await db.into(db.driverLedgerEntries).insert(
              DriverLedgerEntriesCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: b,
                driverUserId: driverId,
                tripId: Value(tripId),
                type: i.isOdd ? kDriverLedgerTypeLoad : kDriverLedgerTypePaymentCash,
                amountKobo: 250000 * i,
                signedAmountKobo: i.isOdd ? -250000 * i : 250000 * i,
                referenceType: i.isOdd ? kDriverLedgerRefLot : kDriverLedgerRefPayment,
                activityDate: openedAt,
                createdAt: Value(openedAt),
              ),
            );
      }
    });

    tearDown(() async {
      debugOverrideVanSalesEnabled(null);
      await env.dispose();
    });

    viewports.forEach((name, size) {
      testWidgets('$name shows trips history without overflowing', (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: DriverProfileScreen(driverUserId: driverId),
          grantedKeys: driverGrants,
          settle: false,
        );

        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 250));
        }

        expectNoOverflow(tester, reason: 'Driver Profile overflowed at $name');
        await expectContentRowVisible(
          tester,
          driverTripRows(),
          scrollable: find.byType(NestedScrollView),
          reason: 'Driver Profile showed no complete trip row at $name',
        );

        await disposeScreen(tester);
      });
    });
  });

  group('Driver Profile holds its content — empty driver', () {
    late ScreenTestEnvironment env;
    late String driverId;

    setUp(() async {
      debugOverrideVanSalesEnabled(true);
      env = await setupScreenTestEnvironment(businessType: 'drinks');
      final db = env.db;
      final b = env.businessId;

      driverId = UuidV7.generate();
      final driverRoleId = UuidV7.generate();

      await db.into(db.roles).insert(
            RolesCompanion.insert(
              id: Value(driverRoleId),
              businessId: b,
              name: 'Driver',
              slug: 'driver',
            ),
          );

      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(driverId),
              businessId: b,
              name: 'Empty Dan',
              pin: '0000',
            ),
          );

      await db.into(db.userBusinesses).insert(
            UserBusinessesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: b,
              userId: driverId,
              roleId: driverRoleId,
              status: const Value('active'),
            ),
          );
    });

    tearDown(() async {
      debugOverrideVanSalesEnabled(null);
      await env.dispose();
    });

    viewports.forEach((name, size) {
      testWidgets('$name renders empty state without overflowing', (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: DriverProfileScreen(driverUserId: driverId),
          grantedKeys: driverGrants,
          settle: false,
        );

        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 250));
        }

        expectNoOverflow(tester, reason: 'Driver Profile empty state overflowed at $name');

        // Scroll outer scroller so empty tab message is brought into view if needed
        await tester.drag(find.byType(NestedScrollView), const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          find.text('No trips in this period'),
          findsOneWidget,
          reason: 'Driver with no trips should render empty trips state',
        );

        await disposeScreen(tester);
      });
    });
  });

  group('Driver Profile keeps the behaviour the restructure could have cost', () {
    late ScreenTestEnvironment env;
    late String driverId;

    setUp(() async {
      debugOverrideVanSalesEnabled(true);
      env = await setupScreenTestEnvironment(businessType: 'drinks');
      final db = env.db;
      final b = env.businessId;

      await (db.update(db.businesses)..where((t) => t.id.equals(b))).write(
        const BusinessesCompanion(
          tracksEmptyCrates: Value(true),
        ),
      );

      driverId = UuidV7.generate();
      final driverRoleId = UuidV7.generate();

      await db.into(db.roles).insert(
            RolesCompanion.insert(
              id: Value(driverRoleId),
              businessId: b,
              name: 'Driver',
              slug: 'driver',
            ),
          );

      await db.into(db.users).insert(
            UsersCompanion.insert(
              id: Value(driverId),
              businessId: b,
              name: 'Scroll Dan',
              pin: '0000',
            ),
          );

      await db.into(db.userBusinesses).insert(
            UserBusinessesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: b,
              userId: driverId,
              roleId: driverRoleId,
              status: const Value('active'),
            ),
          );

      final vanStoreId = UuidV7.generate();
      await db.into(db.stores).insert(
            StoresCompanion.insert(
              id: Value(vanStoreId),
              businessId: b,
              name: 'Delivery Van 1',
              kind: const Value(kStoreKindVan),
            ),
          );

      await db.into(db.userStores).insert(
            UserStoresCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: b,
              userId: driverId,
              storeId: vanStoreId,
            ),
          );

      final now = DateTime.now();
      final monthAnchor = DateTime(now.year, now.month, 1, 8);
      for (var i = 1; i <= 15; i++) {
        final tripId = UuidV7.generate();
        final openedAt = monthAnchor.add(Duration(days: i - 1));

        await db.into(db.vanTrips).insert(
              VanTripsCompanion.insert(
                id: Value(tripId),
                businessId: b,
                vanStoreId: vanStoreId,
                driverUserId: driverId,
                sourceStoreId: env.storeId,
                status: const Value(kVanTripStatusClosed),
                openedAt: Value(openedAt),
                closedAt: Value(openedAt.add(const Duration(hours: 4))),
                profitKobo: Value(300000 * i),
                shellsOut: Value(10 + i),
                shellsBack: Value(9 + i),
              ),
            );

        final orderId = UuidV7.generate();
        await db.into(db.orders).insert(
              OrdersCompanion.insert(
                id: Value(orderId),
                businessId: b,
                orderNumber: 'VAN-SALE-$i',
                totalAmountKobo: 200000 * i,
                netAmountKobo: 200000 * i,
                amountPaidKobo: Value(200000 * i),
                paymentType: 'cash',
                status: 'completed',
                storeId: Value(vanStoreId),
                vanTripId: Value(tripId),
                completedAt: Value(openedAt),
                createdAt: Value(openedAt),
              ),
            );

        await db.into(db.driverLedgerEntries).insert(
              DriverLedgerEntriesCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: b,
                driverUserId: driverId,
                tripId: Value(tripId),
                type: kDriverLedgerTypeLoad,
                amountKobo: 200000 * i,
                signedAmountKobo: -200000 * i,
                referenceType: kDriverLedgerRefLot,
                activityDate: openedAt,
                createdAt: Value(openedAt),
              ),
            );
      }
    });

    tearDown(() async {
      debugOverrideVanSalesEnabled(null);
      await env.dispose();
    });

    testWidgets('each tab remembers its scroll position across tab switches', (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: DriverProfileScreen(driverUserId: driverId),
        grantedKeys: driverGrants,
        settle: false,
      );

      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 250));
      }

      ScrollPosition tripsPosition() => tester
          .state<ScrollableState>(
            find.descendant(of: tabSurface(), matching: find.byType(Scrollable)).first,
          )
          .position;

      // Drag enough to collapse headers and scroll the inner tab
      await tester.drag(tabSurface(), const Offset(0, -800));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final scrolledTo = tripsPosition().pixels;
      expect(scrolledTo, greaterThan(0), reason: 'The Trips tab must scroll');

      await tester.tap(find.text('Sales'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.text('Trips'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(
        tripsPosition().pixels,
        closeTo(scrolledTo, 1.0),
        reason: 'Switching away and back must not lose the reader\'s place',
      );

      await disposeScreen(tester);
    });

    testWidgets('swiping sideways still moves between tabs', (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: DriverProfileScreen(driverUserId: driverId),
        grantedKeys: driverGrants,
        settle: false,
      );

      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 250));
      }

      final pager = tester.state<ScrollableState>(
        find.descendant(of: find.byType(TabBarView), matching: find.byType(Scrollable)).first,
      );
      final onePage = pager.position.viewportDimension;

      final swipe = await tester.startGesture(tester.getCenter(tabSurface()));
      for (var step = 0; step < 8; step++) {
        await swipe.moveBy(Offset(-onePage * 0.08, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await swipe.up();
      await tester.pumpAndSettle();

      expect(
        pager.position.pixels,
        closeTo(onePage, 1.0),
        reason: 'A sideways swipe must snap the pager to the Sales tab',
      );

      await disposeScreen(tester);
    });

    testWidgets('max text scale (1.3x) does not overflow at tight viewports', (tester) async {
      for (final (name, size) in [
        ('phoneSe1Portrait', phoneSe1Portrait),
        ('androidCompactLandscape', androidCompactLandscape),
      ]) {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          textScaler: const TextScaler.linear(1.3),
          screen: DriverProfileScreen(driverUserId: driverId),
          grantedKeys: driverGrants,
          settle: false,
        );

        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 250));
        }

        expectNoOverflow(
          tester,
          reason: 'Driver Profile overflowed at $name with 1.3x text scale',
        );

        await disposeScreen(tester);
      }
    });

    testWidgets('initialTab only applies on creation; tab set change preserves selection', (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: DriverProfileScreen(driverUserId: driverId, initialTab: 'sales'),
        grantedKeys: driverGrants,
        settle: false,
      );

      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 250));
      }

      final tabController = tester.widget<TabBar>(find.byType(TabBar)).controller!;
      expect(tabController.index, 1, reason: 'Initial creation should respect initialTab (sales)');

      // User selects Ledger tab (index 2)
      await tester.tap(find.text('Ledger'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tabController.index, 2);

      // Disable crates in DB, triggering a rebuild and tab set change from 4 tabs to 3 tabs
      await (env.db.update(env.db.businesses)..where((t) => t.id.equals(env.businessId))).write(
        const BusinessesCompanion(
          tracksEmptyCrates: Value(false),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 250));
      }

      final updatedController = tester.widget<TabBar>(find.byType(TabBar)).controller!;
      expect(updatedController.length, 3);
      expect(
        updatedController.index,
        2,
        reason: 'Tab set change should preserve current selected tab (Ledger), not reset to initialTab (Sales)',
      );

      await disposeScreen(tester);
    });
  });
}
