import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/customers/screens/customer_detail_screen.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #245 / PRD #239 — the Customer Detail screen must hold its content at
/// every supported viewport.
///
/// Acceptance Criteria:
///   1. Screen built on TabbedSliverScaffold from #243.
///   2. Private tabbed-scroller wiring (NestedScrollView, DefaultTabController) deleted.
///   3. No tab body contains a fixed-height band above an expanded/flexible remainder.
///   4. Tests pump screen at phoneSe1Portrait (320x568), androidCompactLandscape (800x360),
///      and pixel7Portrait (412x915) using the shared harness.
///   5. Each test asserts: no layout overflow (expectNoOverflow), and at least one
///      complete content row visible and hit-testable (expectContentRowVisible).
///   6. Tested in both empty and populated data states.
///   7. Verified tab swiping and scroll offset retention across tab switches.
///   8. Unconditional fix: no orientation or short-viewport branches.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const customerGrants = {
    'customers.update',
    'customers.delete',
    'customers.wallet.update',
    'customers.set_debt_limit',
    'customers.wallet.withdraw',
    'customers.wallet.totals.view',
    'sales.make',
    'reports.see_sales',
  };

  Finder creditRows() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>)
                .value
                .startsWith(kCustomerCreditRowKeyPrefix),
        description: 'customer credit history row',
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

  group('Customer Detail holds its content — populated customer', () {
    late ScreenTestEnvironment env;
    late CustomerData customerData;

    setUp(() async {
      env = await setupScreenTestEnvironment();
      final db = env.db;
      final b = env.businessId;
      final cId = UuidV7.generate();

      await db.into(db.customers).insert(
            CustomersCompanion.insert(
              id: Value(cId),
              businessId: b,
              name: 'John Doe',
              phone: const Value('08012345678'),
              priceTier: const Value('retailer'),
            ),
          );

      customerData = await (db.select(db.customers)..where((t) => t.id.equals(cId))).getSingle();

      final walletId = UuidV7.generate();
      await db.into(db.customerWallets).insert(
            CustomerWalletsCompanion.insert(
              id: Value(walletId),
              businessId: b,
              customerId: cId,
            ),
          );

      final now = DateTime.now();
      for (var i = 1; i <= 10; i++) {
        await db.into(db.walletTransactions).insert(
              WalletTransactionsCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: b,
                walletId: walletId,
                customerId: cId,
                type: i.isEven ? 'credit' : 'debit',
                amountKobo: 50000 * i,
                signedAmountKobo: i.isEven ? 50000 * i : -50000 * i,
                referenceType: i.isEven ? 'topup_cash' : 'order_payment',
                createdAt: Value(now.subtract(Duration(hours: i))),
              ),
            );
      }
    });

    tearDown(() async {
      await env.dispose();
    });

    viewports.forEach((name, size) {
      testWidgets('$name shows credit history without overflowing', (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: CustomerDetailScreen(customer: Customer.fromDb(customerData)),
          grantedKeys: customerGrants,
          settle: false,
        );

        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 250));
        }

        expectNoOverflow(tester, reason: 'Customer Detail overflowed at $name');
        await expectContentRowVisible(
          tester,
          creditRows(),
          scrollable: find.byType(NestedScrollView),
          reason: 'Customer Detail showed no complete credit row at $name',
        );

        await disposeScreen(tester);
      });
    });
  });

  group('Customer Detail holds its content — empty customer', () {
    late ScreenTestEnvironment env;
    late CustomerData customerData;

    setUp(() async {
      env = await setupScreenTestEnvironment();
      final db = env.db;
      final b = env.businessId;
      final cId = UuidV7.generate();

      await db.into(db.customers).insert(
            CustomersCompanion.insert(
              id: Value(cId),
              businessId: b,
              name: 'Jane Empty',
              phone: const Value('08098765432'),
              priceTier: const Value('retailer'),
            ),
          );

      customerData = await (db.select(db.customers)..where((t) => t.id.equals(cId))).getSingle();
    });

    tearDown(() async {
      await env.dispose();
    });

    viewports.forEach((name, size) {
      testWidgets('$name renders empty state without overflowing', (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: CustomerDetailScreen(customer: Customer.fromDb(customerData)),
          grantedKeys: customerGrants,
          settle: false,
        );

        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 250));
        }

        expectNoOverflow(tester, reason: 'Customer Detail overflowed at $name');

        // Scroll outer scroller so empty state is brought into viewport if needed
        await tester.drag(find.byType(NestedScrollView), const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          find.text('No ledger entries yet'),
          findsOneWidget,
          reason: 'Customer with no history should render empty state',
        );

        await disposeScreen(tester);
      });
    });
  });

  group('Customer Detail keeps the behaviour the restructure could have cost', () {
    late ScreenTestEnvironment env;
    late CustomerData customerData;

    setUp(() async {
      env = await setupScreenTestEnvironment();
      final db = env.db;
      final b = env.businessId;
      final cId = UuidV7.generate();

      await db.into(db.customers).insert(
            CustomersCompanion.insert(
              id: Value(cId),
              businessId: b,
              name: 'Scroll Test User',
              phone: const Value('08011112222'),
              priceTier: const Value('retailer'),
            ),
          );

      customerData = await (db.select(db.customers)..where((t) => t.id.equals(cId))).getSingle();

      final walletId = UuidV7.generate();
      await db.into(db.customerWallets).insert(
            CustomerWalletsCompanion.insert(
              id: Value(walletId),
              businessId: b,
              customerId: cId,
            ),
          );

      final now = DateTime.now();
      for (var i = 1; i <= 25; i++) {
        await db.into(db.walletTransactions).insert(
              WalletTransactionsCompanion.insert(
                id: Value(UuidV7.generate()),
                businessId: b,
                walletId: walletId,
                customerId: cId,
                type: i.isEven ? 'credit' : 'debit',
                amountKobo: 10000 * i,
                signedAmountKobo: i.isEven ? 10000 * i : -10000 * i,
                referenceType: 'topup_cash',
                createdAt: Value(now.subtract(Duration(minutes: i * 10))),
              ),
            );
      }
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets('each tab remembers its scroll position across tab switches', (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: CustomerDetailScreen(customer: Customer.fromDb(customerData)),
        grantedKeys: customerGrants,
        settle: false,
      );

      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 250));
      }

      ScrollPosition creditsPosition() => tester
          .state<ScrollableState>(
            find.descendant(of: tabSurface(), matching: find.byType(Scrollable)).first,
          )
          .position;

      // Drag enough to collapse headers (~450dp) and scroll the inner tab
      await tester.drag(tabSurface(), const Offset(0, -800));
      await tester.pumpAndSettle();
      final scrolledTo = creditsPosition().pixels;
      expect(scrolledTo, greaterThan(0), reason: 'The Credits tab must scroll');

      await tester.tap(find.text('Orders'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Credits'));
      await tester.pumpAndSettle();

      expect(
        creditsPosition().pixels,
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
        screen: CustomerDetailScreen(customer: Customer.fromDb(customerData)),
        grantedKeys: customerGrants,
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
        reason: 'A sideways swipe must snap the pager to the Orders tab',
      );

      await disposeScreen(tester);
    });
  });
}
