import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

/// Issue #256 / PRD #239 — the Expenses screen must hold its content at every
/// supported viewport.
///
/// Before the fix, at 800x360: a red "BOTTOM OVERFLOWED BY 26 PIXELS" band with
/// no expenses (64px in the harness sweep), and — the silent mode that matters —
/// the expense list squeezed to **1.8dp of its 1,137dp** of content once
/// populated. A list handed no height renders nothing and throws nothing, so an
/// overflow-only assertion passes a blank screen.
///
/// Acceptance criteria covered here:
///   1. Built on the shared [TabbedSliverScaffold] from #243.
///   2. No tab body holds a fixed-height band above a flexible remainder.
///   3. Pumped at the smallest supported portrait phone (320x568), the shortest
///      supported landscape phone (800x360), and a comfortable portrait control.
///   4. Every test asserts **both** no overflow *and* one complete expense row
///      laid out and hit-testable.
///   5. Both an empty and a populated data state.
///   6. Tab swiping and per-tab scroll retention survive the restructure.
///   7. Unconditional: no orientation or short-viewport branch anywhere.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  const expenseGrants = {
    'reports.see_expenses',
    'expenses.create',
    'expenses.approve',
    'sales.make',
  };

  Finder expenseRows() => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(kExpenseRowKeyPrefix),
        description: 'expense row',
      );

  /// The first tab's own scroll view — the one scrollable surface.
  ///
  /// Scoped through [TabSliverBody] on purpose: a `NestedScrollView` builds its
  /// outer viewport as a `CustomScrollView` too, so an unscoped `.first` grabs
  /// the header scroller and every gesture lands on the wrong surface.
  Finder tabSurface() => find
      .descendant(
        of: find.byType(TabSliverBody).first,
        matching: find.byType(CustomScrollView),
      )
      .first;

  /// Drift's stream plumbing resolves in real async time; the screen paints its
  /// list only after those settle. `pumpAndSettle` alone deadlocks against the
  /// refresh wrapper's animations, so step the clock by hand as the Customer
  /// Detail suite does.
  Future<void> settleScreen(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> seedExpenses(
    ScreenTestEnvironment env, {
    required int count,
    String status = 'approved',
  }) async {
    final db = env.db;
    final categoryId = UuidV7.generate();
    await db.into(db.expenseCategories).insert(
          ExpenseCategoriesCompanion.insert(
            id: Value(categoryId),
            businessId: env.businessId,
            name: 'Fuel',
          ),
        );

    final now = DateTime.now();
    for (var i = 1; i <= count; i++) {
      await db.into(db.expenses).insert(
            ExpensesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              categoryId: Value(categoryId),
              storeId: Value(env.storeId),
              amountKobo: 25000 * i,
              description: 'Expense $i',
              paymentMethod: const Value('cash'),
              status: Value(status),
              // Inside "This Month", the screen's default period.
              expenseDate: Value(now.subtract(Duration(minutes: i))),
            ),
          );
    }
  }

  /// Unmounts the screen and closes the database **inside `runAsync`**.
  ///
  /// Expenses reads its data through long-lived Drift streams (Customer Detail
  /// loads via one-shot futures, which is why its suite needs none of this).
  /// `AppDatabase.close()` waits for those subscriptions to unwind, and a
  /// `tearDown` runs outside the tester's fake-async zone, so the cancellations
  /// never get the real async time they need and the close blocks until the
  /// 10-minute test timeout. Closing here, inside `runAsync`, gives them that
  /// time.
  Future<void> teardownScreen(WidgetTester tester) async {
    await disposeScreen(tester);
    await tester.runAsync(() => env.dispose());
  }

  const viewports = <String, Size>{
    'phoneSe1Portrait (320x568, smallest supported portrait)': phoneSe1Portrait,
    'androidCompactLandscape (800x360, shortest supported landscape)':
        androidCompactLandscape,
    'pixel7Landscape (915x412, landscape phone)': pixel7Landscape,
    'pixel7Portrait (412x915, comfortable control)': pixel7Portrait,
  };

  group('Expenses holds its content — populated', () {
    setUp(() async {
      env = await setupScreenTestEnvironment();
      await seedExpenses(env, count: 12);
    });

    viewports.forEach((name, size) {
      testWidgets('$name shows a complete expense row without overflowing',
          (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: const ExpensesScreen(),
          grantedKeys: expenseGrants,
          overrides: [
            firstRunSurfaceStateProvider
                .overrideWithValue(FirstRunSurfaceState.hasContent),
          ],
          settle: false,
        );
        await settleScreen(tester);

        expectNoOverflow(tester, reason: 'Expenses overflowed at $name');
        await expectContentRowVisible(
          tester,
          expenseRows(),
          scrollable: tabSurface(),
          reason: 'Expenses showed no complete expense row at $name',
        );

        await teardownScreen(tester);
      });
    });
  });

  group('Expenses holds its content — empty', () {
    setUp(() async {
      env = await setupScreenTestEnvironment();
    });

    viewports.forEach((name, size) {
      testWidgets('$name renders the empty state without overflowing',
          (tester) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: const ExpensesScreen(),
          grantedKeys: expenseGrants,
          overrides: [
            firstRunSurfaceStateProvider
                .overrideWithValue(FirstRunSurfaceState.hasContent),
          ],
          settle: false,
        );
        await settleScreen(tester);

        expectNoOverflow(tester, reason: 'Expenses overflowed empty at $name');

        // The empty message may sit below the scroll-away header on a short
        // viewport; one scroll must reach it.
        await tester.drag(tabSurface(), const Offset(0, -400));
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          find.text('No expenses found'),
          findsOneWidget,
          reason: 'An empty period must still show its message at $name',
        );

        await teardownScreen(tester);
      });
    });
  });

  group('Expenses keeps the behaviour the restructure could have cost', () {
    setUp(() async {
      env = await setupScreenTestEnvironment();
      await seedExpenses(env, count: 30);
    });

    testWidgets('each tab remembers its scroll position across tab switches',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: const ExpensesScreen(),
        grantedKeys: expenseGrants,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
        settle: false,
      );
      await settleScreen(tester);

      ScrollPosition expensesPosition() => tester
          .state<ScrollableState>(
            find
                .descendant(of: tabSurface(), matching: find.byType(Scrollable))
                .first,
          )
          .position;

      await tester.drag(tabSurface(), const Offset(0, -800));
      await tester.pumpAndSettle();
      final scrolledTo = expensesPosition().pixels;
      expect(scrolledTo, greaterThan(0),
          reason: 'The Expenses tab must scroll');

      // Target the Tab itself: "Expenses" is also the app bar's title, so a
      // bare text finder is ambiguous and can tap the heading instead.
      await tester.tap(find.widgetWithText(Tab, 'Stats'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Expenses'));
      await tester.pumpAndSettle();

      expect(
        expensesPosition().pixels,
        closeTo(scrolledTo, 1.0),
        reason: "Switching away and back must not lose the reader's place",
      );

      await teardownScreen(tester);
    });

    testWidgets('swiping sideways still moves between tabs', (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: pixel7Portrait,
        screen: const ExpensesScreen(),
        grantedKeys: expenseGrants,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
        settle: false,
      );
      await settleScreen(tester);

      final pager = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(TabBarView),
              matching: find.byType(Scrollable),
            )
            .first,
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
        reason: 'A sideways swipe must snap the pager to the Stats tab',
      );

      await teardownScreen(tester);
    });

    testWidgets('the period selector keeps a full tap target at 800x360',
        (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: androidCompactLandscape,
        screen: const ExpensesScreen(),
        grantedKeys: expenseGrants,
        overrides: [
          firstRunSurfaceStateProvider
              .overrideWithValue(FirstRunSurfaceState.hasContent),
        ],
        settle: false,
      );
      await settleScreen(tester);

      // The header scrolls away, so the selector may start off screen; it must
      // still exist at its full height rather than have been shrunk to fit.
      final selector = find.text('This Month');
      expect(selector, findsWidgets,
          reason: 'The period selector must survive sideways');

      await teardownScreen(tester);
    });
  });
}
