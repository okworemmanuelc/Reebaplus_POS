import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../helpers/dispatch_test_utils.dart';

/// §20 Expenses — approval flow + Funds Register debit (data layer).
/// Locks in: auto-approved tracked expenses post a debit immediately; pending
/// expenses move no money until approved; 'other' never touches funds;
/// soft-delete reverses a posted debit; and the per-scope budget upsert.
void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String userId;
  late String tillId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
    storeId = UuidV7.generate();
    await db.into(db.stores).insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    userId = UuidV7.generate();
    await db.into(db.users).insert(
          UsersCompanion.insert(
            id: Value(userId),
            businessId: businessId,
            name: 'Tester',
            pin: '0000',
          ),
        );
    final till = await db.fundsAccountsDao.ensureCashTill(storeId);
    tillId = till.id;
  });

  tearDown(() => db.close());

  group('Expense approval + funds debit (§20.4/§20.5)', () {
    test('auto-approved tracked expense posts a funds debit', () async {
      await db.expensesDao.addExpense(
        categoryName: 'Fuel',
        amountKobo: 5000,
        description: 'Diesel',
        paymentMethod: 'cash',
        storeId: storeId,
        recordedBy: userId,
        fundsAccountId: tillId,
        status: 'approved',
        businessDate: '2026-06-02',
      );

      final fts = await db.select(db.fundTransactions).get();
      expect(fts.length, 1);
      expect(fts.first.type, 'debit');
      expect(fts.first.referenceType, 'expense');
      expect(fts.first.signedAmountKobo, -5000);
      expect(fts.first.businessDate, '2026-06-02');
      expect(fts.first.fundsAccountId, tillId);
    });

    test('pending expense posts no funds debit until it is approved', () async {
      await db.expensesDao.addExpense(
        categoryName: 'Rent',
        amountKobo: 9000,
        description: 'Shop rent',
        paymentMethod: 'cash',
        storeId: storeId,
        recordedBy: userId,
        fundsAccountId: tillId,
        status: 'pending',
      );

      expect((await db.select(db.fundTransactions).get()).length, 0);
      final pending = (await db.select(db.expenses).get()).single;
      expect(pending.status, 'pending');

      await db.expensesDao.approveExpense(
        expenseId: pending.id,
        approverId: userId,
        businessDate: '2026-06-03',
      );

      final fts = await db.select(db.fundTransactions).get();
      expect(fts.length, 1);
      expect(fts.first.type, 'debit');
      expect(fts.first.signedAmountKobo, -9000);
      expect(fts.first.businessDate, '2026-06-03');

      final approved = (await db.select(db.expenses).get()).single;
      expect(approved.status, 'approved');
      expect(approved.approvedBy, userId);
    });

    test('rejecting a pending expense never touches funds', () async {
      await db.expensesDao.addExpense(
        categoryName: 'Rent',
        amountKobo: 9000,
        description: 'Shop rent',
        paymentMethod: 'cash',
        storeId: storeId,
        recordedBy: userId,
        fundsAccountId: tillId,
        status: 'pending',
      );
      final pending = (await db.select(db.expenses).get()).single;

      await db.expensesDao.rejectExpense(
        expenseId: pending.id,
        approverId: userId,
        reason: 'Not budgeted',
      );

      expect((await db.select(db.fundTransactions).get()).length, 0);
      final rejected = (await db.select(db.expenses).get()).single;
      expect(rejected.status, 'rejected');
      expect(rejected.rejectionReason, 'Not budgeted');
    });

    test("'other'-method expense never touches funds", () async {
      await db.expensesDao.addExpense(
        categoryName: 'Misc',
        amountKobo: 3000,
        description: 'Sundry',
        paymentMethod: 'other',
        storeId: storeId,
        recordedBy: userId,
        status: 'approved',
        businessDate: '2026-06-02',
      );
      expect((await db.select(db.fundTransactions).get()).length, 0);
    });

    test('soft-deleting an approved tracked expense reverses the debit',
        () async {
      await db.expensesDao.addExpense(
        categoryName: 'Fuel',
        amountKobo: 5000,
        description: 'Diesel',
        paymentMethod: 'cash',
        storeId: storeId,
        recordedBy: userId,
        fundsAccountId: tillId,
        status: 'approved',
        businessDate: '2026-06-02',
      );
      final exp = (await db.select(db.expenses).get()).single;

      await db.expensesDao.softDeleteExpense(
        expenseId: exp.id,
        performedBy: userId,
        businessDate: '2026-06-04',
      );

      final fts = await db.select(db.fundTransactions).get();
      expect(fts.length, 2);
      // The debit (-5000) and its compensating credit (+5000) net to zero.
      final net = fts.fold<int>(0, (s, t) => s + t.signedAmountKobo);
      expect(net, 0);
      final credit = fts.firstWhere((t) => t.type == 'credit');
      expect(credit.referenceType, 'void');
      expect(credit.businessDate, '2026-06-04');

      final deleted = (await db.select(db.expenses).get()).single;
      expect(deleted.isDeleted, true);
    });

    test('double approve posts only ONE funds debit (TOCTOU guard)', () async {
      await db.expensesDao.addExpense(
        categoryName: 'Fuel',
        amountKobo: 5000,
        description: 'Diesel',
        paymentMethod: 'cash',
        storeId: storeId,
        recordedBy: userId,
        fundsAccountId: tillId,
        status: 'pending',
      );
      final exp = (await db.select(db.expenses).get()).single;

      // Two approvals racing on the same pending expense.
      await Future.wait([
        db.expensesDao.approveExpense(
            expenseId: exp.id, approverId: userId, businessDate: '2026-06-03'),
        db.expensesDao.approveExpense(
            expenseId: exp.id, approverId: userId, businessDate: '2026-06-03'),
      ]);

      final debits = await (db.select(db.fundTransactions)
            ..where((t) => t.referenceType.equals('expense')))
          .get();
      expect(debits.length, 1, reason: 'second approve must be a no-op');
      expect((await db.select(db.expenses).get()).single.status, 'approved');
    });

    test('double delete posts only ONE reversal credit (TOCTOU guard)',
        () async {
      await db.expensesDao.addExpense(
        categoryName: 'Fuel',
        amountKobo: 5000,
        description: 'Diesel',
        paymentMethod: 'cash',
        storeId: storeId,
        recordedBy: userId,
        fundsAccountId: tillId,
        status: 'approved',
        businessDate: '2026-06-02',
      );
      final exp = (await db.select(db.expenses).get()).single;

      await Future.wait([
        db.expensesDao.softDeleteExpense(
            expenseId: exp.id, performedBy: userId, businessDate: '2026-06-04'),
        db.expensesDao.softDeleteExpense(
            expenseId: exp.id, performedBy: userId, businessDate: '2026-06-04'),
      ]);

      final credits = await (db.select(db.fundTransactions)
            ..where((t) => t.type.equals('credit')))
          .get();
      expect(credits.length, 1, reason: 'second delete must be a no-op');
      // Net of debit (-5000) + single reversal (+5000) = 0.
      final net = (await db.select(db.fundTransactions).get())
          .fold<int>(0, (s, t) => s + t.signedAmountKobo);
      expect(net, 0);
    });
  });

  group('ExpenseBudgetsDao (§20.1/§20.3)', () {
    test('setBudget keeps one live row per scope and updates in place',
        () async {
      await db.expenseBudgetsDao.setBudget(amountKobo: 100000); // business-wide
      await db.expenseBudgetsDao.setBudget(storeId: storeId, amountKobo: 50000);
      expect((await db.select(db.expenseBudgets).get()).length, 2);

      // Re-setting the business-wide goal updates, not inserts.
      await db.expenseBudgetsDao.setBudget(amountKobo: 120000);
      final rows = await db.select(db.expenseBudgets).get();
      expect(rows.length, 2);
      expect(rows.firstWhere((r) => r.storeId == null).amountKobo, 120000);
      expect(rows.firstWhere((r) => r.storeId == storeId).amountKobo, 50000);
    });
  });
}
