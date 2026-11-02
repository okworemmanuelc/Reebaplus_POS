import 'package:flutter/widgets.dart';

import 'package:reebaplus_pos/core/theme/app_icons.dart';

/// One tile in Add Expense's "What was it for?" grid (#652).
class ExpenseCategoryChoice {
  const ExpenseCategoryChoice({required this.name, required this.icon});

  /// The saved category name (`expense_categories.name`).
  final String name;
  final IconData icon;
}

/// The fixed category grid, in mockup order, three to a row. The saved name is
/// the label, so an old expense under one of these names lights the same tile.
/// Salary is not here: salaries belong to Payroll (#661), so no new expense can
/// count one twice.
const List<ExpenseCategoryChoice> kExpenseCategoryChoices = [
  ExpenseCategoryChoice(name: 'Fuel', icon: AppIcons.fuel),
  ExpenseCategoryChoice(name: 'Transport', icon: AppIcons.vanDelivery),
  ExpenseCategoryChoice(name: 'Labour', icon: AppIcons.labour),
  ExpenseCategoryChoice(name: 'Electricity', icon: AppIcons.electricity),
  ExpenseCategoryChoice(name: 'Repairs', icon: AppIcons.maintenance),
  ExpenseCategoryChoice(name: 'Rent', icon: AppIcons.storefront),
  ExpenseCategoryChoice(name: 'Food', icon: AppIcons.restaurant),
  ExpenseCategoryChoice(name: 'Other', icon: AppIcons.moreHorizontal),
];

/// The icon for a saved category name. Covers the grid plus the names the old
/// free-text form seeded (Maintenance, Utilities, Supplies, Others) and the
/// retired Salary tile, so old expenses keep a sensible icon; anything else gets
/// the receipt.
IconData expenseCategoryIcon(String name) {
  final key = name.trim().toLowerCase();
  for (final c in kExpenseCategoryChoices) {
    if (c.name.toLowerCase() == key) return c.icon;
  }
  return switch (key) {
    'maintenance' => AppIcons.maintenance,
    'utilities' => AppIcons.electricity,
    'supplies' => AppIcons.box,
    'others' => AppIcons.moreHorizontal,
    'salary' => AppIcons.cash,
    _ => AppIcons.receipt,
  };
}

/// True when the category is the grid's catch-all, which needs a note.
bool isOtherExpenseCategory(String? name) {
  final key = name?.trim().toLowerCase();
  return key == 'other' || key == 'others';
}

/// True for an old Salary expense, where the money went to a staff member
/// (relabels "Paid to"). New salaries are not expenses (#661).
bool isSalaryExpenseCategory(String? name) =>
    name?.trim().toLowerCase() == 'salary';
