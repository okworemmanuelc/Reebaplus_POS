// Visual goldens for Expenses and Add Expense (#412, PRD #346 Wave 2 B). No
// mockup: built from the shared parts and the Wave 1 / batch A patterns.
//
// - `expenses_*`: the list at 390x844 (gesture nav), 844x390 with a 24dp
//   status bar and 3-button navigation on the right, 800x1280 and 1280x800,
//   light + dark. Dates are fixed (a Custom period), never "now".
// - `add_expense_*`: the Edit Expense form (fixed date), same sizes.
//
// Sample data only. Regenerate with:
//
//     flutter test --update-goldens test/redesign/expenses_golden_test.dart

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/permissions/gate.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/expenses/screens/add_expense_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';

import '../helpers/screen_harness.dart';

const _grants = {
  'reports.see_expenses',
  'expenses.create',
  'expenses.approve',
  'sales.make',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScreenTestEnvironment env;
  late ExpenseData editing;

  final period =
      'Custom:${DateTime(2026, 3, 1).toIso8601String()}:${DateTime(2026, 3, 31).toIso8601String()}';

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 0,
      businessName: 'Stallion Global',
    );
    final db = env.db;
    await db.customStatement(
      "UPDATE stores SET name = 'Abuja HQ' WHERE id = '${env.storeId}'",
    );
    for (var i = 0; i < 8; i++) {
      await db.notificationsDao.create('info', 'Notification $i');
    }
    final cats = <String, String>{};
    for (final n in ['Fuel', 'Rent', 'Supplies']) {
      final id = UuidV7.generate();
      cats[n] = id;
      await db
          .into(db.expenseCategories)
          .insert(
            ExpenseCategoriesCompanion.insert(
              id: Value(id),
              businessId: env.businessId,
              name: n,
            ),
          );
    }
    Future<String> add(
      String cat,
      String desc,
      int kobo,
      String status,
      int day, {
      String method = 'cash',
      String? reason,
    }) async {
      final id = UuidV7.generate();
      await db
          .into(db.expenses)
          .insert(
            ExpensesCompanion.insert(
              id: Value(id),
              businessId: env.businessId,
              categoryId: Value(cats[cat]),
              storeId: Value(env.storeId),
              amountKobo: kobo,
              description: desc,
              paymentMethod: Value(method),
              status: Value(status),
              rejectionReason: Value(reason),
              expenseDate: Value(DateTime(2026, 3, day, 10, 30)),
            ),
          );
      return id;
    }

    final first = await add(
      'Fuel',
      'Generator diesel',
      4500000,
      'approved',
      12,
    );
    await add('Fuel', 'Delivery van fuel', 1800000, 'pending', 14);
    await add(
      'Rent',
      'Warehouse rent',
      25000000,
      'approved',
      3,
      method: 'transfer',
    );
    await add(
      'Supplies',
      'Packing nylon',
      650000,
      'rejected',
      9,
      reason: 'No receipt',
    );
    editing = await (db.select(
      db.expenses,
    )..where((t) => t.id.equals(first))).getSingle();
  });

  tearDown(() => env.dispose());

  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  Future<void> deliver(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  void setInsets(WidgetTester tester, FakeViewPadding insets) {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
  }

  for (final brightness in Brightness.values) {
    final themeName = brightness == Brightness.light ? 'light' : 'dark';
    final theme = brightness == Brightness.light
        ? AppTheme.light()
        : AppTheme.dark();
    for (final (sizeName, size, insets) in const [
      ('390x844', Size(390, 844), FakeViewPadding(top: 24, bottom: 24)),
      ('844x390', Size(844, 390), FakeViewPadding(top: 24, right: 48)),
      ('800x1280', Size(800, 1280), FakeViewPadding()),
      ('1280x800', Size(1280, 800), FakeViewPadding()),
    ]) {
      for (final form in [false, true]) {
        final name = form ? 'add_expense' : 'expenses';
        testWidgets('$name $sizeName $themeName', (tester) async {
          setInsets(tester, insets);
          await pumpScreen(
            tester,
            env: env,
            size: size,
            padding: EdgeInsets.fromLTRB(
              insets.left,
              insets.top,
              insets.right,
              insets.bottom,
            ),
            screen: form
                ? AddExpenseScreen(editing: editing)
                : ExpensesScreen(initialPeriod: period),
            bottomNavHeight: (!form && size.width >= 600)
                ? kBottomNavBodyHeight
                : 0,
            grantedKeys: _grants,
            roleRank: GateTier.ceo,
            theme: theme,
            overrides: [
              currentBusinessNameProvider.overrideWithValue('Stallion Global'),
              firstRunSurfaceStateProvider.overrideWithValue(
                FirstRunSurfaceState.hasContent,
              ),
            ],
            settle: false,
          );
          await deliver(tester);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(form ? AddExpenseScreen : ExpensesScreen),
            matchesGoldenFile('goldens/${name}_${sizeName}_$themeName.png'),
          );
          await disposeScreen(tester);
        });
      }
    }
  }
}
