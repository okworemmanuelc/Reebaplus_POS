import 'package:flutter/foundation.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/features/expenses/data/models/expense.dart';
import 'package:reebaplus_pos/shared/services/notification_service.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';

class ExpenseService extends ValueNotifier<List<Expense>> {
  final NotificationService _notifications;

  ExpenseService(this._notifications) : super(_initialExpenses);

  static final List<Expense> _initialExpenses = [];

  List<Expense> getAll() => List.unmodifiable(value);

  List<Expense> getByPeriod(String period) {
    final window = datePeriodFromLabel(period);
    if (window == DatePeriod.toDate) return getAll();
    final now = DateTime.now();
    return value.where((e) => window.includes(e.date, now: now)).toList();
  }

  List<Expense> getByCategory(String category) {
    return value.where((e) => e.category == category).toList();
  }

  double getTotalForPeriod(String period) {
    return getByPeriod(period).fold(0.0, (sum, e) => sum + e.amount);
  }

  double getTotalByCategory(String category, String period) {
    return getByPeriod(period)
        .where((e) => e.category == category)
        .fold(0.0, (sum, e) => sum + e.amount);
  }

  double getAnnualProjection() {
    final now = DateTime.now();
    final currentYearExpenses = value.where((e) => e.date.year == now.year);
    if (currentYearExpenses.isEmpty) return 0.0;

    final totalSpentThisYear = currentYearExpenses.fold(
      0.0,
      (sum, e) => sum + e.amount,
    );

    // We assume 1 month elapsed if it's January to avoid division by zero or overly high projections.
    final monthsElapsed = now.month.toDouble();
    return (totalSpentThisYear / monthsElapsed) * 12;
  }

  Future<void> addExpense(Expense expense) async {
    value = [...value, expense];
    if (expense.amount >= 50000) {
      await _notifications.createNotification(
        'large_expense',
        'Large expense recorded: ${formatCurrency(expense.amount)} for ${expense.category}',
        linkedRecordId: expense.id,
      );
    }
  }

  void deleteExpense(String id) {
    value = value.where((e) => e.id != id).toList();
  }
}

