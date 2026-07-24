// expense_reversal_test.dart
//
// #173 / PRD #155 — rejecting or soft-deleting an expense posts a compensating
// reversal payment row (through the #169 seam) so the reconciliation cash card
// nets that expense's cash OUT to zero. Asserted at the DAO / in-memory-Drift
// transaction boundary.
//
// The cash card (recon_data.dart) sums `cashExpensesKobo` as: for each
// `payment_transactions` row with `voidedAt == null`, `method == 'cash'` and
// `type == 'expense'` on its own `created_at` day, `+= amountKobo`. These tests
// reproduce that exact predicate to prove the net after a correction is zero.

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String staffId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    staffId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(staffId),
            businessId: businessId,
            name: 'Manager',
            pin: '0000',
          ),
        );
  });

  tearDown(() => db.close());

  /// The reconciliation's `cashExpensesKobo` contribution: cash-method,
  /// non-voided `expense` payment rows summed on amount. Zero ⇒ nets out.
  Future<int> cashExpensesNet() async {
    final rows = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('expense')))
        .get();
    return rows
        .where((p) => p.voidedAt == null && p.method.toLowerCase() == 'cash')
        .fold<int>(0, (s, p) => s + p.amountKobo);
  }

  Future<ExpenseData> onlyExpense() async {
    return (db.select(db.expenses)..where((e) => e.isDeleted.not()))
        .get()
        .then((rows) => rows.single);
  }

  test('rejecting an expense posts a −amount reversal and nets the cash to zero',
      () async {
    await db.expensesDao.addExpense(
      categoryName: 'Fuel',
      amountKobo: 5000,
      description: 'Generator fuel',
      paymentMethod: 'cash',
      recordedBy: staffId,
      status: 'pending',
    );
    final exp = await onlyExpense();

    // Before reject: the single 'expense' cash row drains the card.
    expect(await cashExpensesNet(), 5000);

    await db.expensesDao.rejectExpense(
      expenseId: exp.id,
      approverId: staffId,
      reason: 'wrong category',
    );

    // After reject: original (+5000) + reversal (−5000) net to zero.
    expect(await cashExpensesNet(), 0,
        reason: '"No money moves on a reject" must be true on the cash card');

    final expenseRows = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('expense')))
        .get();
    expect(expenseRows, hasLength(2),
        reason: 'original + one compensating reversal');
    final reversal = expenseRows.firstWhere((p) => p.amountKobo < 0);
    expect(reversal.amountKobo, -5000);
    expect(reversal.type, 'expense',
        reason: 'reversal stays in the SAME cash bucket so it cancels');
    expect(reversal.expenseId, exp.id,
        reason: 'reversal copies the original typed reference (expense_id)');
    expect(reversal.method, 'cash',
        reason: 'reversal inherits the original method so it nets in-bucket');
    expect(reversal.voidedAt, isNull,
        reason: 'a live compensating entry, not a voided row');

    // The original expense row is untouched (append-only discipline).
    final original = expenseRows.firstWhere((p) => p.amountKobo > 0);
    expect(original.amountKobo, 5000);
    expect(original.voidedAt, isNull);
  });

  test('the reversal row is enqueued for sync', () async {
    await db.expensesDao.addExpense(
      categoryName: 'Fuel',
      amountKobo: 5000,
      description: 'Fuel',
      paymentMethod: 'cash',
      recordedBy: staffId,
      status: 'pending',
    );
    final exp = await onlyExpense();
    await db.expensesDao.rejectExpense(
      expenseId: exp.id,
      approverId: staffId,
      reason: 'x',
    );

    final reversal = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('expense') & p.amountKobo.isSmallerThanValue(0)))
        .getSingle();
    final pending = await getPendingQueue(db);
    final enqueued = pending
        .where((r) => r.actionType == 'payment_transactions:upsert')
        .map(decodePayload)
        .where((p) => p['id'] == reversal.id)
        .toList();
    expect(enqueued, hasLength(1),
        reason: 'the reversal must sync so peers converge');
    expect(enqueued.single['amount_kobo'], -5000);
  });

  test('soft-deleting an expense posts a reversal and nets the cash to zero',
      () async {
    await db.expensesDao.addExpense(
      categoryName: 'Rent',
      amountKobo: 8000,
      description: 'Shop rent',
      paymentMethod: 'cash',
      recordedBy: staffId,
    );
    final exp = await onlyExpense();
    expect(await cashExpensesNet(), 8000);

    await db.expensesDao.softDeleteExpense(
      expenseId: exp.id,
      performedBy: staffId,
    );

    expect(await cashExpensesNet(), 0);
    final rows = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('expense')))
        .get();
    expect(rows, hasLength(2));
    expect(rows.firstWhere((p) => p.amountKobo < 0).amountKobo, -8000);
  });

  test('delete-then-re-create does NOT double-count cash out', () async {
    // Wrong amount entered.
    await db.expensesDao.addExpense(
      categoryName: 'Rent',
      amountKobo: 8000,
      description: 'Shop rent (typo)',
      paymentMethod: 'cash',
      recordedBy: staffId,
    );
    final wrong = await onlyExpense();

    // Sanctioned fix: soft-delete, then re-enter the correct amount.
    await db.expensesDao.softDeleteExpense(
      expenseId: wrong.id,
      performedBy: staffId,
    );
    await db.expensesDao.addExpense(
      categoryName: 'Rent',
      amountKobo: 3000,
      description: 'Shop rent (correct)',
      paymentMethod: 'cash',
      recordedBy: staffId,
    );

    // The cash card must reflect ONLY the correct 3,000 — not 8,000, not 11,000.
    expect(await cashExpensesNet(), 3000);
  });

  test('reject then delete reverses at most once (idempotent)', () async {
    await db.expensesDao.addExpense(
      categoryName: 'Fuel',
      amountKobo: 5000,
      description: 'Fuel',
      paymentMethod: 'cash',
      recordedBy: staffId,
      status: 'pending',
    );
    final exp = await onlyExpense();

    await db.expensesDao.rejectExpense(
      expenseId: exp.id,
      approverId: staffId,
      reason: 'wrong',
    );
    // A rejected expense can then be soft-deleted — it must not over-reverse.
    await db.expensesDao.softDeleteExpense(
      expenseId: exp.id,
      performedBy: staffId,
    );

    expect(await cashExpensesNet(), 0);
    final rows = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('expense')))
        .get();
    expect(rows, hasLength(2),
        reason: 'exactly one reversal — the delete sees net 0 and adds none');
  });

  test('a transfer-method expense reverses without touching the cash card',
      () async {
    await db.expensesDao.addExpense(
      categoryName: 'Supplies',
      amountKobo: 4000,
      description: 'Bank transfer expense',
      paymentMethod: 'transfer',
      recordedBy: staffId,
    );
    final exp = await onlyExpense();
    // A transfer expense never hit the cash card in the first place.
    expect(await cashExpensesNet(), 0);

    await db.expensesDao.softDeleteExpense(
      expenseId: exp.id,
      performedBy: staffId,
    );

    // Still zero on the cash card, and the reversal mirrors the method so the
    // full-expense ledger nets out too.
    expect(await cashExpensesNet(), 0);
    final rows = await (db.select(db.paymentTransactions)
          ..where((p) => p.type.equals('expense')))
        .get();
    final net = rows.fold<int>(0, (s, p) => s + p.amountKobo);
    expect(net, 0);
    expect(rows.firstWhere((p) => p.amountKobo < 0).method, 'transfer');
  });
}
