// #652 — the Expenses summary figures and the Add Expense form checks.

import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/features/expenses/expense_categories.dart';
import 'package:reebaplus_pos/features/expenses/expense_form_rules.dart';
import 'package:reebaplus_pos/features/expenses/expense_summary.dart';

ExpenseData _expense(int naira, String status, DateTime date) => ExpenseData(
  id: '$naira-$status-${date.toIso8601String()}',
  businessId: 'b',
  amountKobo: naira * 100,
  description: '',
  status: status,
  expenseDate: date,
  isDeleted: false,
  createdAt: date,
  lastUpdatedAt: date,
);

void main() {
  group('summarizeExpenses', () {
    // Wednesday 28 Oct 2026, 3 PM. The week starts Sunday 25 Oct.
    final now = DateTime(2026, 10, 28, 15);

    test('the mockup figures: waiting counts as spent, rejected never', () {
      final s = summarizeExpenses([
        _expense(18500, 'pending', DateTime(2026, 10, 28, 9, 42)),
        _expense(6000, 'approved', DateTime(2026, 10, 28, 8, 15)),
        _expense(4500, 'approved', DateTime(2026, 10, 27, 18, 30)),
        _expense(25000, 'rejected', DateTime(2026, 10, 27, 14, 10)),
      ], now: now);
      expect(s.spentTodayKobo, 2450000);
      expect(s.spentThisWeekKobo, 2900000);
      expect(s.waitingCount, 1);
    });

    test('the budget compares approved spend this month; waiting is apart', () {
      final s = summarizeExpenses([
        _expense(18500, 'pending', DateTime(2026, 10, 28, 9)),
        _expense(6000, 'approved', DateTime(2026, 10, 28, 8)),
        _expense(10000, 'approved', DateTime(2026, 10, 1, 8)),
        _expense(1000, 'approved', DateTime(2026, 9, 30, 8)),
        _expense(7000, 'rejected', DateTime(2026, 10, 2, 8)),
      ], now: now);
      expect(s.budgetSpentKobo, 1600000);
      expect(s.budgetPendingKobo, 1850000);
      expect(s.spentThisWeekKobo, 2450000);
    });

    test('an old waiting expense still counts as waiting', () {
      final s = summarizeExpenses([
        _expense(500, 'pending', DateTime(2026, 8, 1)),
      ], now: now);
      expect(s.waitingCount, 1);
      expect(s.spentTodayKobo, 0);
      expect(s.budgetPendingKobo, 0);
    });
  });

  group('validateExpenseForm', () {
    test('nothing filled in: amount and category', () {
      expect(validateExpenseForm(amountKobo: 0, category: null, note: ''), {
        ExpenseFormProblem.noAmount,
        ExpenseFormProblem.noCategory,
      });
    });

    test('Paid to is never required, Salary included', () {
      expect(
        validateExpenseForm(amountKobo: 100, category: 'Salary', note: ''),
        isEmpty,
      );
    });

    test('Other needs a note', () {
      expect(
        validateExpenseForm(amountKobo: 100, category: 'Other', note: ' '),
        {ExpenseFormProblem.noNote},
      );
      expect(
        validateExpenseForm(amountKobo: 100, category: 'Other', note: 'Soap'),
        isEmpty,
      );
    });

    test('an edit never checks the locked amount', () {
      expect(
        validateExpenseForm(
          amountKobo: 0,
          category: 'Fuel',
          note: '',
          amountLocked: true,
        ),
        isEmpty,
      );
    });

    test('banner wording', () {
      expect(
        expenseFormBannerText(1),
        'Please fix 1 thing below before saving.',
      );
      expect(
        expenseFormBannerText(2),
        'Please fix 2 things below before saving.',
      );
    });
  });

  group('categories', () {
    test('the grid is the nine mockup tiles, in order', () {
      expect(kExpenseCategoryChoices.map((c) => c.name), [
        'Fuel',
        'Transport',
        'Labour',
        'Salary',
        'Electricity',
        'Repairs',
        'Rent',
        'Food',
        'Other',
      ]);
    });

    test('old category names keep an icon', () {
      expect(expenseCategoryIcon('fuel'), AppIcons.fuel);
      expect(expenseCategoryIcon('Maintenance'), AppIcons.maintenance);
      expect(expenseCategoryIcon('Others'), AppIcons.moreHorizontal);
      expect(expenseCategoryIcon('Something new'), AppIcons.receipt);
    });
  });
}
