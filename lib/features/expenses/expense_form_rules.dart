import 'package:reebaplus_pos/features/expenses/expense_categories.dart';

/// Something Add Expense needs fixed before it can save (#652).
enum ExpenseFormProblem {
  noAmount('Enter how much you spent.'),
  noCategory('Pick what the money was for.'),
  noNote('Add a note to say what it was for.');

  const ExpenseFormProblem(this.message);

  /// The line shown under the field.
  final String message;
}

/// The problems blocking a save. "Paid to" is always optional (owner,
/// 2026-11-01), an old Salary expense included. The amount is not checked on edit because
/// it cannot be changed there.
Set<ExpenseFormProblem> validateExpenseForm({
  required int amountKobo,
  required String? category,
  required String note,
  bool amountLocked = false,
}) {
  return {
    if (!amountLocked && amountKobo <= 0) ExpenseFormProblem.noAmount,
    if (category == null || category.trim().isEmpty)
      ExpenseFormProblem.noCategory,
    if (isOtherExpenseCategory(category) && note.trim().isEmpty)
      ExpenseFormProblem.noNote,
  };
}

/// The banner line over the form: "Please fix 2 things below before saving."
String expenseFormBannerText(int count) => count == 1
    ? 'Please fix 1 thing below before saving.'
    : 'Please fix $count things below before saving.';
