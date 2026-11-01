// Expenses + Add Expense (#412 restyle, remade from the owner's mockups in
// #652): every control renders and works, permission-hidden controls stay
// hidden, nothing overflows at the supported sizes, text-box pop-ups hold
// above the keyboard and the lists cap at 720dp on wide screens.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/core/providers/first_run_surface_state.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
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
    // The harness signs in as 'test-user-id'; approve / reject write it as the
    // approver, so the row must exist (FK).
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: const Value('test-user-id'),
            businessId: env.businessId,
            name: 'Test Admin',
            pin: '1234',
          ),
        );
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
    expect(find.text('Track what your business spends'), findsOneWidget);
    expect(find.text('Spent today'), findsOneWidget);
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.text('1 expense'), findsOneWidget);
    expect(find.byKey(ExpenseKeys.budgetCard), findsOneWidget);
    expect(find.text('Set budget'), findsOneWidget);
    expect(find.text('Record Expense'), findsOneWidget);
    expect(find.text('Waiting for approval (1)'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('Stats'), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a lower role keeps approve / add / budget hidden', (
    tester,
  ) async {
    await pumpList(tester, grants: _lowGrants, ceo: false);
    expect(find.text('Spent today'), findsOneWidget);
    expect(find.text('Record Expense'), findsNothing);
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Reject'), findsNothing);
    expect(find.text('Set budget'), findsNothing);
    expect(find.byKey(ExpenseKeys.budgetCard), findsNothing);
    await close(tester);
  });

  testWidgets('summary counts waiting money as spent today', (tester) async {
    await pumpList(tester);
    // 250 waiting + 500 + 750 + 1,000 approved, all today.
    expect(find.text(formatCurrency(2500)), findsWidgets);
    await close(tester);
  });

  testWidgets('the Waiting filter shows only waiting expenses', (tester) async {
    await pumpList(tester);
    expect(find.text('Generator diesel 2'), findsOneWidget);
    await tester.tap(find.byKey(ExpenseKeys.filterWaiting));
    await settle(tester);
    expect(find.text('Generator diesel 1'), findsOneWidget);
    expect(find.text('Generator diesel 2'), findsNothing);
    await close(tester);
  });

  testWidgets('tapping a row opens its details with Edit and Delete', (
    tester,
  ) async {
    await pumpList(tester);
    await tester.tap(find.text('Generator diesel 2'));
    await settle(tester);
    expect(find.byKey(ExpenseKeys.detailSheet), findsOneWidget);
    expect(find.text('Recorded by'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Edit'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Delete'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  Future<String?> statusOf(WidgetTester tester, String description) async {
    final db = env.db;
    final row = await tester.runAsync(
      () => (db.select(
        db.expenses,
      )..where((t) => t.description.equals(description))).getSingle(),
    );
    return row?.status;
  }

  testWidgets('Approve marks the pending expense approved', (tester) async {
    await pumpList(tester);
    expect(await statusOf(tester, 'Generator diesel 1'), 'pending');
    await tester.tap(find.widgetWithText(AppButton, 'Approve'));
    await settle(tester);
    await settle(tester);
    expect(await statusOf(tester, 'Generator diesel 1'), 'approved');
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('Reject needs a reason, then marks the expense rejected', (
    tester,
  ) async {
    await pumpList(tester);
    // The waiting row's Reject.
    await tester.tap(find.widgetWithText(AppButton, 'Reject').first);
    await settle(tester);
    expect(find.byKey(ExpenseKeys.rejectField), findsOneWidget);
    final dialogReject = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(AppButton, 'Reject'),
    );
    // Empty reason: the confirm button is disabled.
    expect(tester.widget<AppButton>(dialogReject).onPressed, isNull);
    await tester.enterText(
      find.descendant(
        of: find.byKey(ExpenseKeys.rejectField),
        matching: find.byType(TextField),
      ),
      'No receipt',
    );
    await tester.pump();
    await tester.tap(dialogReject);
    await settle(tester);
    expect(await statusOf(tester, 'Generator diesel 1'), 'rejected');
    // Let the success toast's timer run out before the tree is disposed.
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  // No overflow: 360dp @1.3, 390x844, 844x390 with insets, 800x1280, 1280x800.
  final sizes = <(String, Size, EdgeInsets, double)>[
    (
      '360@1.3',
      const Size(360, 640),
      const EdgeInsets.only(top: 24, bottom: 48),
      1.3,
    ),
    (
      '390x844',
      const Size(390, 844),
      const EdgeInsets.only(top: 24, bottom: 24),
      1.0,
    ),
    (
      '844x390',
      const Size(844, 390),
      const EdgeInsets.only(top: 24, right: 48),
      1.0,
    ),
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
    await pumpList(
      tester,
      size: const Size(1280, 800),
      padding: EdgeInsets.zero,
    );
    final w = tester.getSize(find.byKey(ExpenseKeys.summaryCard)).width;
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

  Future<void> pumpForm(WidgetTester tester) async {
    await pumpScreen(
      tester,
      env: env,
      // Tall, so the whole form is built; overflow at real sizes is covered
      // by the sweep above.
      size: const Size(390, 1500),
      // Pushed from a host page, as the app does, so Save can pop back.
      screen: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => AddExpenseScreen.show(context),
            child: const Text('open form'),
          ),
        ),
      ),
      grantedKeys: _ceoGrants,
      roleSlug: 'ceo',
      roleName: 'CEO',
      roleRank: 0,
      bottomNavHeight: 0,
      settle: false,
    );
    await settle(tester);
    await tester.tap(find.text('open form'));
    await settle(tester);
  }

  Future<ExpenseData?> savedExpense(WidgetTester tester, String note) =>
      tester.runAsync<ExpenseData?>(
        () => (env.db.select(
          env.db.expenses,
        )..where((t) => t.description.equals(note))).getSingleOrNull(),
      );

  testWidgets('Add Expense renders its controls', (tester) async {
    await pumpForm(tester);
    expect(find.byKey(ExpenseKeys.addTopBar), findsOneWidget);
    expect(find.byKey(ExpenseKeys.addClose), findsOneWidget);
    expect(find.byKey(ExpenseKeys.addClear), findsOneWidget);
    expect(find.text('Add Expense'), findsOneWidget);
    expect(find.text('Record money spent for the business'), findsOneWidget);
    expect(find.text('Amount spent'), findsOneWidget);
    expect(find.text('+${formatCurrency(500)}'), findsOneWidget);
    expect(find.text('What was it for?'), findsOneWidget);
    for (final name in ['Fuel', 'Salary', 'Food', 'Other']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('Paid to'), findsNothing); // rich text: label + optional
    expect(find.text('When did you spend it?'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Save Expense'), findsOneWidget);
    expect(find.text('Payment Method'), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('saving an empty form lists what to fix', (tester) async {
    await pumpForm(tester);
    expect(find.byKey(ExpenseKeys.errorBanner), findsNothing);
    await tester.tap(find.byKey(ExpenseKeys.saveButton));
    await settle(tester);
    expect(
      find.text('Please fix 2 things below before saving.'),
      findsOneWidget,
    );
    expect(find.text('Enter how much you spent.'), findsOneWidget);
    expect(find.text('Pick what the money was for.'), findsOneWidget);
    // Salary does not make "Staff member paid" required.
    await tester.tap(find.text('Salary'));
    await settle(tester);
    expect(
      find.text('Please fix 1 thing below before saving.'),
      findsOneWidget,
    );
    expect(find.text('For example, Musa Bello'), findsOneWidget);
    await close(tester);
  });

  testWidgets('Other needs a note before it saves', (tester) async {
    await pumpForm(tester);
    await tester.tap(find.text('+${formatCurrency(500)}'));
    await tester.tap(find.text('Other'));
    await settle(tester);
    await tester.tap(find.byKey(ExpenseKeys.saveButton));
    await settle(tester);
    expect(find.text('Add a note to say what it was for.'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a filled form saves the expense as cash with Paid to', (
    tester,
  ) async {
    await pumpForm(tester);
    await tester.tap(find.text('+${formatCurrency(5000)}'));
    await tester.tap(find.text('+${formatCurrency(500)}'));
    await settle(tester);
    expect(find.text('−${formatCurrency(5500)}'), findsOneWidget);
    await tester.tap(find.text('Fuel'));
    await tester.enterText(
      find.descendant(
        of: find.byKey(ExpenseKeys.paidToField),
        matching: find.byType(TextField),
      ),
      'Total filling station, Kubwa',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(ExpenseKeys.noteField),
        matching: find.byType(TextField),
      ),
      'Diesel for delivery van',
    );
    await tester.tap(find.text('Yesterday'));
    await settle(tester);
    await tester.ensureVisible(find.byKey(ExpenseKeys.saveButton));
    await tester.tap(find.byKey(ExpenseKeys.saveButton));
    await settle(tester);
    await settle(tester);
    final row = await savedExpense(tester, 'Diesel for delivery van');
    expect(row, isNotNull);
    expect(row!.amountKobo, 550000);
    expect(row.reference, 'Total filling station, Kubwa');
    expect(row.paymentMethod, 'cash');
    expect(row.status, 'approved');
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    expect(row.expenseDate.day, yesterday.day);
    final names = await tester.runAsync(
      () => env.db.select(env.db.expenseCategories).get(),
    );
    final cat = names!.firstWhere((c) => c.id == row.categoryId);
    expect(cat.name, 'Fuel');
    expect(find.text('open form'), findsOneWidget); // popped back
    await tester.pump(const Duration(seconds: 10));
    await close(tester);
  });

  testWidgets('Clear empties the form', (tester) async {
    await pumpForm(tester);
    await tester.tap(find.text('+${formatCurrency(1000)}'));
    await tester.tap(find.text('Rent'));
    await settle(tester);
    expect(find.text('−${formatCurrency(1000)}'), findsOneWidget);
    await tester.tap(find.byKey(ExpenseKeys.addClear));
    await settle(tester);
    expect(find.text('−${formatCurrency(1000)}'), findsNothing);
    await close(tester);
  });
}
