import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';

import '../../helpers/dispatch_test_utils.dart';

/// Seeds a staff user (FK target for `recorded_by` and `activity_logs.user_id`)
/// plus a warehouse (so the optional `p_warehouse_id` linkage test has a
/// real id to point at). Returns the ids.
Future<({String staffId, String warehouseId})> _seedExpenseFixtures(
  AppDatabase db,
  String businessId,
) async {
  final staffId = UuidV7.generate();
  final warehouseId = UuidV7.generate();

  await db.into(db.users).insert(
        UsersCompanion.insert(
          id: Value(staffId),
          businessId: businessId,
          name: 'Expense Staff',
          role: 'ceo',
          pin: '0000',
        ),
      );
  await db.into(db.warehouses).insert(
        WarehousesCompanion.insert(
          id: Value(warehouseId),
          businessId: businessId,
          name: 'Main Warehouse',
        ),
      );
  return (staffId: staffId, warehouseId: warehouseId);
}

void main() {
  late AppDatabase db;
  late String businessId;

  setUp(() async {
    final boot = await bootstrapTestDb();
    db = boot.db;
    businessId = boot.businessId;
  });

  tearDown(() => db.close());

  group('ExpensesDao.addExpense dispatch', () {
    test(
        'flag OFF: enqueues expense + activity_log + payment + category, '
        'no domain envelope', () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_expense', on: false);
      final fx = await _seedExpenseFixtures(db, businessId);

      await db.expensesDao.addExpense(
        categoryName: 'Office Supplies',
        amountKobo: 25000,
        description: 'Pens and notebooks',
        paymentMethod: 'cash',
        recordedBy: fx.staffId,
      );

      // Local rows present.
      expect(await db.select(db.expenses).get(), hasLength(1));
      expect(await db.select(db.activityLogs).get(), hasLength(1));
      expect(await db.select(db.paymentTransactions).get(), hasLength(1));

      final pending = await getPendingQueue(db);
      final actionTypes = pending.map((r) => r.actionType).toList()..sort();
      // expense_categories enqueue comes from resolveCategoryId's first-time
      // insertion path — it lives outside the v1/v2 branch and runs for
      // both. Asserted here so the v2-on test can mirror the comparison.
      expect(actionTypes, [
        'activity_logs:upsert',
        'expense_categories:upsert',
        'expenses:upsert',
        'payment_transactions:upsert',
      ]);
    });

    test('flag ON: one envelope with thin payload + ids match local rows',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_expense', on: true);
      final fx = await _seedExpenseFixtures(db, businessId);

      await db.expensesDao.addExpense(
        categoryName: 'Fuel',
        amountKobo: 80000,
        description: 'Generator diesel',
        paymentMethod: 'transfer',
        recordedBy: fx.staffId,
      );

      // Local mirrors are present (UI-immediate).
      final expenseRows = await db.select(db.expenses).get();
      final activityRows = await db.select(db.activityLogs).get();
      final payRows = await db.select(db.paymentTransactions).get();
      expect(expenseRows, hasLength(1));
      expect(activityRows, hasLength(1));
      expect(payRows, hasLength(1));

      // Queue: one envelope for the multi-table action + the
      // expense_categories upsert (resolveCategoryId still needs to push
      // the new category even on the v2 path — categories aren't part of
      // the domain RPC).
      final pending = await getPendingQueue(db);
      final domain =
          pending.where((r) => r.actionType.startsWith('domain:')).toList();
      expect(domain, hasLength(1));
      expect(domain.first.actionType, 'domain:pos_record_expense');

      final payload = decodePayload(domain.first);
      expect(payload['p_business_id'], businessId);
      expect(payload['p_actor_id'], fx.staffId);
      expect(payload['p_amount_kobo'], 80000);
      expect(payload['p_description'], 'Generator diesel');
      expect(payload['p_payment_method'], 'transfer');

      // Idempotency uuids must match the local rows so a server replay
      // recognises retries instead of double-recording.
      expect(payload['p_expense_id'], expenseRows.first.id);
      expect(payload['p_payment_id'], payRows.first.id);
      expect(payload['p_activity_log_id'], activityRows.first.id);

      // Category id was resolved before envelope construction.
      expect(payload['p_category_id'], isA<String>());

      // Optionals not provided → not in payload.
      expect(payload.containsKey('p_reference'), isFalse);
      expect(payload.containsKey('p_warehouse_id'), isFalse);
    });

    test('flag ON: null paymentMethod still sends p_payment_method=other',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_expense', on: true);
      final fx = await _seedExpenseFixtures(db, businessId);

      await db.expensesDao.addExpense(
        categoryName: 'Misc',
        amountKobo: 5000,
        description: 'Tip jar',
        paymentMethod: null,
        recordedBy: fx.staffId,
      );

      final pending = await getPendingQueue(db);
      final domain = pending.firstWhere(
        (r) => r.actionType == 'domain:pos_record_expense',
      );
      final payload = decodePayload(domain);
      // Parity with v1: a payment row was always created with method='other'
      // when the caller didn't specify. v2 must preserve that contract so
      // analytics/reporting don't drift across the flag flip.
      expect(payload['p_payment_method'], 'other');

      // Local payment row also written with method=other.
      final payRows = await db.select(db.paymentTransactions).get();
      expect(payRows.first.method, 'other');
    });

    test('flag ON: warehouseId + reference flow through to payload',
        () async {
      await setFlag(db, 'feature.domain_rpcs_v2.record_expense', on: true);
      final fx = await _seedExpenseFixtures(db, businessId);

      await db.expensesDao.addExpense(
        categoryName: 'Repairs',
        amountKobo: 150000,
        description: 'Generator service',
        paymentMethod: 'cash',
        reference: 'INV-2026-00042',
        warehouseId: fx.warehouseId,
        recordedBy: fx.staffId,
      );

      final pending = await getPendingQueue(db);
      final domain = pending.firstWhere(
        (r) => r.actionType == 'domain:pos_record_expense',
      );
      final payload = decodePayload(domain);
      expect(payload['p_reference'], 'INV-2026-00042');
      expect(payload['p_warehouse_id'], fx.warehouseId);
    });
  });
}
