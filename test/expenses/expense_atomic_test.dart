import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

void main() {
  late AppDatabase db;
  late String businessId;
  late String staffId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    staffId = UuidV7.generate();
    db.businessIdResolver = () => businessId;

    await db.into(db.businesses).insert(BusinessesCompanion.insert(
          id: Value(businessId),
          name: 'Test Biz',
        ));

    await db.into(db.users).insert(UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Staff One',
          pin: '1234',
        ));
  });

  tearDown(() => db.close());

  group('ExpensesDao Atomicity', () {
    test('addExpense happy path inserts to expenses, activity_logs, and payment_transactions', () async {
      await db.expensesDao.addExpense(
        categoryName: 'Fuel',
        amountKobo: 5000,
        description: 'Generator fuel',
        paymentMethod: 'cash',
        recordedBy: staffId,
      );

      // Verify expense
      final expenseRows = await db.select(db.expenses).get();
      expect(expenseRows.length, equals(1));
      final expense = expenseRows.first;
      expect(expense.amountKobo, equals(5000));
      expect(expense.description, equals('Generator fuel'));

      // Verify activity log
      final logRows = await db.activityLogDao.getForExpense(expense.id);
      expect(logRows.length, equals(1));
      expect(logRows.first.action, equals('expense_created'));
      expect(logRows.first.entityType, equals('expense'));
      expect(logRows.first.entityId, equals(expense.id));

      // Verify payment transaction
      final paymentRows = await db.select(db.paymentTransactions).get();
      expect(paymentRows.length, equals(1));
      expect(paymentRows.first.type, equals('expense'));
      expect(paymentRows.first.expenseId, equals(expense.id));
      expect(paymentRows.first.amountKobo, equals(5000));
    });

    test('addExpense rollback on failure (e.g. invalid recordedBy FK)', () async {
      // We expect this to fail if we use a non-existent staffId and there is an FK constraint.
      // Note: Drift in-memory sqlite has FKs enabled by default if configured in AppDatabase.
      
      final invalidStaffId = UuidV7.generate();
      
      try {
        await db.expensesDao.addExpense(
          categoryName: 'Fuel',
          amountKobo: 5000,
          description: 'Failed expense',
          recordedBy: invalidStaffId,
        );
        fail('Should have thrown an exception');
      } catch (e) {
        // Expected
      }

      // Verify zero rows in all tables
      expect((await db.select(db.expenses).get()).length, equals(0));
      expect((await db.select(db.activityLogs).get()).length, equals(0));
      expect((await db.select(db.paymentTransactions).get()).length, equals(0));
    });

    test('resolveCategoryId is race-free and idempotent', () async {
      const name = ' Utilities ';
      final id1 = await db.expensesDao.resolveCategoryId(name);
      final id2 = await db.expensesDao.resolveCategoryId('Utilities');

      expect(id1, equals(id2));

      final categories = await db.select(db.expenseCategories).get();
      expect(categories.length, equals(1));
      expect(categories.first.name, equals('Utilities'));
    });
  });
}
