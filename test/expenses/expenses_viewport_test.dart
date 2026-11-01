import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';

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
///   1. One scroll view (since #652; was the shared tabbed scaffold).
///   2. No body holds a fixed-height band above a flexible remainder.
///   3. Pumped at the smallest supported portrait phone (320x568), the shortest
///      supported landscape phone (800x360), and a comfortable portrait control.
///   4. Every test asserts **both** no overflow *and* one complete expense row
///      laid out and hit-testable.
///   5. Both an empty and a populated data state.
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

  /// The screen's one scroll view (#652).
  Finder scrollSurface() => find.byType(CustomScrollView).first;

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
    await db
        .into(db.expenseCategories)
        .insert(
          ExpenseCategoriesCompanion.insert(
            id: Value(categoryId),
            businessId: env.businessId,
            name: 'Fuel',
          ),
        );

    final now = seedAnchorToday();
    for (var i = 1; i <= count; i++) {
      await db
          .into(db.expenses)
          .insert(
            ExpensesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              categoryId: Value(categoryId),
              storeId: Value(env.storeId),
              amountKobo: 25000 * i,
              description: 'Expense $i',
              paymentMethod: const Value('cash'),
              status: Value(status),
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
      testWidgets('$name shows a complete expense row without overflowing', (
        tester,
      ) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: const ExpensesScreen(),
          grantedKeys: expenseGrants,
          overrides: [
            firstRunSurfaceStateProvider.overrideWithValue(
              FirstRunSurfaceState.hasContent,
            ),
          ],
          settle: false,
        );
        await settleScreen(tester);

        expectNoOverflow(tester, reason: 'Expenses overflowed at $name');
        await expectContentRowVisible(
          tester,
          expenseRows(),
          scrollable: scrollSurface(),
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
      testWidgets('$name renders the empty state without overflowing', (
        tester,
      ) async {
        await pumpScreen(
          tester,
          env: env,
          size: size,
          screen: const ExpensesScreen(),
          grantedKeys: expenseGrants,
          overrides: [
            firstRunSurfaceStateProvider.overrideWithValue(
              FirstRunSurfaceState.hasContent,
            ),
          ],
          settle: false,
        );
        await settleScreen(tester);

        expectNoOverflow(tester, reason: 'Expenses overflowed empty at $name');

        // The empty message may sit below the scroll-away header on a short
        // viewport; one scroll must reach it.
        await tester.drag(scrollSurface(), const Offset(0, -400));
        await tester.pump(const Duration(milliseconds: 250));

        expect(
          find.text('No expenses found'),
          findsOneWidget,
          reason: 'An empty list must still show its message at $name',
        );

        await teardownScreen(tester);
      });
    });
  });
}
