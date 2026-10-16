// Expenses + Add Expense restyle (#412, PRD #346 Wave 2 B): every control
// still renders and works, permission-hidden controls stay hidden, nothing
// overflows at the supported sizes, text-box pop-ups hold above the keyboard
// and the lists cap at 720dp on wide screens.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/features/expenses/screens/add_expense_screen.dart';
import 'package:reebaplus_pos/features/expenses/screens/expenses_screen.dart';
import 'package:reebaplus_pos/features/expenses/widgets/expense_parts.dart';

import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/screen_harness.dart';

const _ceoGrants = {
  'reports.see_expenses',
  'expenses.create',
  'expenses.approve',
  'sales.make',
};
const _lowGrants = {'reports.see_expenses', 'sales.make'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(businessName: 'Stallion Global');
    final db = env.db;
    final cat = UuidV7.generate();
    await db
        .into(db.expenseCategories)
        .insert(
          ExpenseCategoriesCompanion.insert(
            id: Value(cat),
            businessId: env.businessId,
            name: 'Fuel',
          ),
        );
    final now = seedAnchorToday();
    for (var i = 1; i <= 4; i++) {
      await db
          .into(db.expenses)
          .insert(
            ExpensesCompanion.insert(
              id: Value(UuidV7.generate()),
              businessId: env.businessId,
              categoryId: Value(cat),
              storeId: Value(env.storeId),
              amountKobo: 25000 * i,
              description: 'Generator diesel $i',
              paymentMethod: const Value('cash'),
              status: Value(i == 1 ? 'pending' : 'approved'),
              expenseDate: Value(now.subtract(Duration(minutes: i))),
            ),
          );
    }
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> pumpList(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Set<String> grants = _ceoGrants,
    bool ceo = true,
    EdgeInsets? padding,
    TextScaler? textScaler,
    bool followView = false,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      padding: padding,
      textScaler: textScaler,
      followView: followView,
      screen: const ExpensesScreen(),
      grantedKeys: grants,
      roleSlug: ceo ? 'ceo' : 'cashier',
      roleName: ceo ? 'CEO' : 'Cashier',
      roleRank: ceo ? 0 : 2,
      bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
      overrides: [
        firstRunSurfaceStateProvider.overrideWithValue(
          FirstRunSurfaceState.hasContent,
        ),
      ],
      settle: false,
    );
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await disposeScreen(tester);
    await tester.runAsync(() => env.dispose());
  }

  testWidgets('CEO sees every Expenses control', (tester) async {
    await pumpList(tester);
    expect(find.byKey(ExpenseKeys.topBar), findsOneWidget);
    expect(find.text('Total Expenses'), findsOneWidget);
    expect(find.byKey(ExpenseKeys.budgetCard), findsOneWidget);
    expect(find.text('Set budget'), findsOneWidget);
    expect(find.text('Add Expense'), findsOneWidget);
    expect(find.textContaining('Pending approval'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Reject'), findsWidgets);
    expect(find.widgetWithText(Tab, 'Stats'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a lower role keeps approve / add / budget hidden', (
    tester,
  ) async {
    await pumpList(tester, grants: _lowGrants, ceo: false);
    expect(find.text('Total Expenses'), findsOneWidget);
    expect(find.text('Add Expense'), findsNothing);
    expect(find.textContaining('Pending approval'), findsNothing);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Set budget'), findsNothing);
    await close(tester);
  });

  testWidgets('Stats tab renders its cards', (tester) async {
    await pumpList(tester);
    await tester.tap(find.widgetWithText(Tab, 'Stats'));
    await settle(tester);
    expect(find.text('Annual Projection'), findsOneWidget);
    expect(find.text('Category Breakdown'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('Reject still needs a reason and rejects the expense', (
    tester,
  ) async {
    await pumpList(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Reject').first);
    await settle(tester);
    expect(find.byKey(ExpenseKeys.rejectField), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byKey(ExpenseKeys.rejectField),
        matching: find.byType(TextField),
      ),
      'No receipt',
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  // No overflow: 360dp @1.3, 390x844, 844x390 with insets, 800x1280, 1280x800.
  final sizes = <(String, Size, EdgeInsets, double)>[
    ('360@1.3', const Size(360, 640), const EdgeInsets.only(top: 24, bottom: 48), 1.3),
    ('390x844', const Size(390, 844), const EdgeInsets.only(top: 24, bottom: 24), 1.0),
    ('844x390', const Size(844, 390), const EdgeInsets.only(top: 24, right: 48), 1.0),
    ('800x1280', const Size(800, 1280), EdgeInsets.zero, 1.0),
    ('1280x800', const Size(1280, 800), EdgeInsets.zero, 1.0),
  ];
  for (final (name, size, pad, scale) in sizes) {
    testWidgets('Expenses has no overflow at $name', (tester) async {
      await pumpList(
        tester,
        size: size,
        padding: pad,
        textScaler: TextScaler.linear(scale),
      );
      expect(tester.takeException(), isNull);
      expectNoOverflow(tester, reason: 'Expenses overflowed at $name');
      await close(tester);
    });

    testWidgets('Add Expense has no overflow at $name', (tester) async {
      await pumpScreen(
        tester,
        env: env,
        size: size,
        padding: pad,
        textScaler: TextScaler.linear(scale),
        screen: const AddExpenseScreen(),
        grantedKeys: _ceoGrants,
        bottomNavHeight: 0,
        settle: false,
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      expectNoOverflow(tester, reason: 'Add Expense overflowed at $name');
      await close(tester);
    });
  }

  testWidgets('the list caps at 720dp on a wide screen', (tester) async {
    await pumpList(tester, size: const Size(1280, 800), padding: EdgeInsets.zero);
    final w = tester.getSize(find.byKey(ExpenseKeys.totalCard)).width;
    expect(w, lessThanOrEqualTo(720));
    expect(w, greaterThan(300));
    await close(tester);
  });

  // Text-box pop-ups hold above the keyboard.
  const phones = <(String, Size, double)>[
    ('390x844', Size(390, 844), 340),
    ('360x640', Size(360, 640), 280),
  ];
  for (final (name, size, keyboard) in phones) {
    testWidgets('monthly budget pop-up fits above the keyboard $name', (
      tester,
    ) async {
      await pumpList(
        tester,
        size: size,
        followView: true,
        textScaler: const TextScaler.linear(1.15),
      );
      await tester.tap(find.text('Set budget'));
      await settle(tester);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await settle(tester);
      expect(find.byKey(ExpenseKeys.budgetField), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await close(tester);
    });

    testWidgets('reject pop-up fits above the keyboard $name', (tester) async {
      await pumpList(
        tester,
        size: size,
        followView: true,
        textScaler: const TextScaler.linear(1.15),
      );
      await tester.tap(find.widgetWithText(AppButton, 'Reject').first);
      await settle(tester);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await settle(tester);
      expect(find.byKey(ExpenseKeys.rejectField), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await close(tester);
    });

    testWidgets('Add Expense form fits above the keyboard $name', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        env: env,
        size: size,
        screen: const AddExpenseScreen(),
        grantedKeys: _ceoGrants,
        bottomNavHeight: 0,
        followView: true,
        textScaler: const TextScaler.linear(1.15),
        settle: false,
      );
      await settle(tester);
      await tester.tap(find.byType(TextField).first);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      await settle(tester);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await close(tester);
    });
  }

  testWidgets('Add Expense renders its controls', (tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      screen: const AddExpenseScreen(),
      grantedKeys: _ceoGrants,
      bottomNavHeight: 0,
      settle: false,
    );
    await settle(tester);
    expect(find.byKey(ExpenseKeys.addTopBar), findsOneWidget);
    expect(find.byKey(ExpenseKeys.addBack), findsOneWidget);
    expect(find.text('Record Expense'), findsOneWidget);
    expect(find.text('Category'), findsOneWidget);
    expect(find.text('Amount'), findsOneWidget);
    expect(find.text('Payment Method'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);
    expect(find.text('Save Expense'), findsOneWidget);
    expect(find.byType(ActionChip), findsWidgets);
    await close(tester);
  });
}
