// payroll_till_cash_test.dart — #696 (PRD #666, ADR 0034): bonuses, advances
// and staff loans paid at the till. Against an in-memory Drift DB:
//   * one combined line per store, day and kind (bonuses / advances /
//     loans_given / loans_repaid), no worker named;
//   * Daily Reconciliation: cash bonuses, advances and loans given leave the
//     drawer; a loan repaid at the till comes back;
//   * Profit / Expenses: bonuses only — never advances or loans;
//   * pending and rejected entries never count; Transfer never touches the
//     drawer; a payday repayment (kept back from salary) is not till cash;
//   * the home-screen staff-pay cost matches Daily Reconciliation.
// Fixture names are made up — never real pay data (the repo is public).

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/expenses/expense_summary.dart';

const _sig = 'iVBORw0KGgo=';
const _day = '2026-11-02';
final _now = DateTime(2026, 11, 3, 10);

void main() {
  late AppDatabase db;
  late String businessId;
  late String storeId;
  late String ceoId;
  late String managerId;
  late String workerId;
  String? signedIn;

  Future<String> addRole(String name, String slug) async {
    final id = UuidV7.generate();
    await db
        .into(db.roles)
        .insert(
          RolesCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            slug: slug,
          ),
        );
    return id;
  }

  Future<String> addUser(String name, String roleId) async {
    final id = UuidV7.generate();
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(id),
            businessId: businessId,
            name: name,
            pin: kSetupRequiredPin,
          ),
        );
    await db
        .into(db.userBusinesses)
        .insert(
          UserBusinessesCompanion.insert(
            businessId: businessId,
            userId: id,
            roleId: roleId,
          ),
        );
    return id;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    businessId = UuidV7.generate();
    storeId = UuidV7.generate();
    db.businessIdResolver = () => businessId;
    db.userIdResolver = () => signedIn;
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: Value(businessId), name: 'Test Shop'),
        );
    await db
        .into(db.stores)
        .insert(
          StoresCompanion.insert(
            id: Value(storeId),
            businessId: businessId,
            name: 'Main Store',
          ),
        );
    final ceoRole = await addRole('CEO', 'ceo');
    final managerRole = await addRole('Manager', 'manager');
    await db
        .into(db.rolePermissions)
        .insert(
          RolePermissionsCompanion.insert(
            businessId: businessId,
            roleId: managerRole,
            permissionKey: kPayrollPermissionKey,
          ),
        );
    ceoId = await addUser('Test Owner', ceoRole);
    managerId = await addUser('Test Manager', managerRole);
    await db
        .into(db.roleSettings)
        .insertOnConflictUpdate(
          RoleSettingsCompanion.insert(
            businessId: businessId,
            roleId: managerRole,
            settingKey: 'max_expense_approval_kobo',
            settingValue: const Value('5000000'), // ₦50,000
          ),
        );
    signedIn = ceoId;
    workerId = await db.payrollDao.addWorker(
      storeId: storeId,
      name: 'Ada Example',
      monthlySalaryKobo: 10000000, // ₦100,000
    );
  });

  tearDown(() => db.close());

  Future<PayrollEntryData> give(
    String type,
    int kobo, {
    String method = 'cash',
    String? month,
  }) => db.payrollDao.recordMoneyEntry(
    workerId: workerId,
    type: type,
    amountKobo: kobo,
    paymentMethod: method,
    salaryMonth: month,
    entryDate: _day,
  );

  Future<List<StaffPayTotalData>> lines() => db.select(db.staffPayTotals).get();

  Future<StaffPayTotalData?> line(String kind) async {
    final all = (await lines()).where((t) => t.kind == kind).toList();
    expect(all.length, lessThanOrEqualTo(1));
    return all.firstOrNull;
  }

  ReconData recon(List<StaffPayTotalData> t) => reconDataFrom(
    ReconInputs(
      staffPayTotals: t,
      start: DateTime(2026, 11, 2),
      endExclusive: DateTime(2026, 11, 3),
    ),
  );

  final none = recon(const []);

  group('the combined lines', () {
    test(
      'one line per store, day and kind, under a deterministic id',
      () async {
        await give('bonus', 200000);
        await give('bonus', 300000);
        final l = (await line(kStaffPayKindBonuses))!;
        expect(
          l.id,
          staffPayTotalId(businessId, storeId, kStaffPayKindBonuses, _day),
        );
        expect(l.totalDate, _day);
        expect(l.amountKobo, 500000);
        expect(l.cashKobo, 500000);
      },
    );

    test('name no worker, in the table or the outbox', () async {
      await give('bonus', 200000);
      await give('advance', 100000, month: '2026-11');
      await give('loan_given', 400000);
      await give('loan_repaid', 100000);
      final rows = await lines();
      expect(rows.map((t) => t.kind).toSet(), {
        kStaffPayKindBonuses,
        kStaffPayKindAdvances,
        kStaffPayKindLoansGiven,
        kStaffPayKindLoansRepaid,
      });
      final queued = (await db.select(db.syncQueue).get())
          .where((q) => q.actionType.contains('staff_pay_totals'))
          .map((q) => q.payload)
          .join('\n');
      expect(queued, isNotEmpty);
      final text = '${rows.map((r) => r.toJson()).join()}\n$queued';
      for (final secret in ['Ada', 'Example', workerId]) {
        expect(text, isNot(contains(secret)));
      }
    });

    test('a correction lands on its own day and nets', () async {
      final b = await give('bonus', 500000);
      await db.payrollDao.recordMoneyEntry(
        workerId: workerId,
        type: 'bonus',
        amountKobo: -200000,
        paymentMethod: 'cash',
        correctsEntryId: b.id,
        entryDate: _day,
      );
      expect((await line(kStaffPayKindBonuses))!.amountKobo, 300000);
    });
  });

  group('Daily Reconciliation drawer and profit', () {
    test('a cash bonus leaves the drawer and is a cost', () async {
      await give('bonus', 200000);
      final d = recon(await lines());
      expect(d.cashBonusesKobo, 200000);
      expect(d.bonusesKobo, 200000);
      expect(d.cashOutKobo, none.cashOutKobo + 200000);
      expect(d.netProfitKobo, none.netProfitKobo - 200000);
      expect(d.periodNetResultKobo, none.periodNetResultKobo - 200000);
      expect(d.isEmpty, isFalse);
    });

    test('a cash advance leaves the drawer, never profit', () async {
      await give('advance', 300000, month: '2026-11');
      final d = recon(await lines());
      expect(d.cashAdvancesKobo, 300000);
      expect(d.cashOutKobo, none.cashOutKobo + 300000);
      expect(d.netProfitKobo, none.netProfitKobo);
      expect(d.periodNetResultKobo, none.periodNetResultKobo);
    });

    test('a cash loan given leaves the drawer, never profit', () async {
      await give('loan_given', 400000);
      final d = recon(await lines());
      expect(d.cashLoansGivenKobo, 400000);
      expect(d.cashOutKobo, none.cashOutKobo + 400000);
      expect(d.netProfitKobo, none.netProfitKobo);
    });

    test('a loan repaid in cash at the till comes back', () async {
      await give('loan_given', 400000);
      await give('loan_repaid', 150000);
      final d = recon(await lines());
      expect(d.cashLoansRepaidKobo, 150000);
      expect(d.cashInKobo, none.cashInKobo + 150000);
      expect(d.netCashMovementKobo, none.netCashMovementKobo - 250000);
      expect(d.netProfitKobo, none.netProfitKobo);
    });

    test(
      'a payday repayment is kept back from salary, not till cash',
      () async {
        await give('loan_given', 400000);
        await db.payrollDao.paySalary(
          workerId: workerId,
          salaryMonth: '2026-10',
          loanRepaymentKobo: 100000,
          paymentMethod: 'cash',
          paydayDate: _day,
          workerSignaturePng: _sig,
          payerSignaturePng: _sig,
          now: _now,
        );
        await db.payrollDao.refreshMoneyTotals();
        expect(await line(kStaffPayKindLoansRepaid), isNull);
      },
    );

    test(
      'Transfer never touches the drawer; a transfer bonus is a cost',
      () async {
        await give('bonus', 200000, method: 'transfer');
        await give('advance', 300000, method: 'transfer', month: '2026-11');
        await give('loan_given', 400000, method: 'other');
        final d = recon(await lines());
        expect(d.cashOutKobo, none.cashOutKobo);
        expect(d.cashBonusesKobo, 0);
        expect(d.bonusesKobo, 200000);
        expect(d.netProfitKobo, none.netProfitKobo - 200000);
      },
    );
  });

  group('approval', () {
    test('pending never counts; it counts once approved', () async {
      signedIn = managerId;
      final e = await give('bonus', 6000000); // above the ₦50,000 limit
      expect(e.status, 'pending');
      expect(await line(kStaffPayKindBonuses), isNull);
      expect(recon(await lines()).cashOutKobo, none.cashOutKobo);
      signedIn = ceoId;
      await db.payrollDao.approveEntry(e.id);
      expect((await line(kStaffPayKindBonuses))!.cashKobo, 6000000);
    });

    test('rejected never counts', () async {
      signedIn = managerId;
      final e = await give('loan_given', 6000000);
      signedIn = ceoId;
      await db.payrollDao.rejectEntry(e.id, reason: 'Not now');
      await db.payrollDao.refreshMoneyTotals();
      expect(await line(kStaffPayKindLoansGiven), isNull);
    });
  });

  group('Expenses and home profit', () {
    test('Expenses lists Bonuses, never advances or loans', () async {
      await give('bonus', 200000);
      await give('advance', 300000, month: '2026-11');
      await give('loan_given', 400000);
      final shown = staffPayLinesInScope(await lines(), null);
      expect(shown.map(staffPayLineTitle).toList(), ['Bonuses']);
      final s = summarizeExpenses(
        const [],
        now: DateTime(2026, 11, 2, 12),
        allowanceLines: await lines(),
      );
      expect(s.spentTodayKobo, 200000);
    });

    test('home staff-pay cost matches Daily Reconciliation', () {
      StaffPayTotalData l(String kind, int amount, int cash) =>
          StaffPayTotalData(
            id: kind,
            businessId: 'b',
            storeId: 's',
            kind: kind,
            totalDate: _day,
            amountKobo: amount,
            cashKobo: cash,
            createdAt: _now,
            lastUpdatedAt: _now,
          );
      final all = [
        l(kStaffPayKindDailyAllowances, 30000, 30000),
        l(kStaffPayKindSalaries, 10000000, 6000000),
        l(kStaffPayKindBonuses, 200000, 100000),
        l(kStaffPayKindAdvances, 300000, 300000),
        l(kStaffPayKindLoansGiven, 400000, 400000),
        l(kStaffPayKindLoansRepaid, 100000, 100000),
      ];
      final cost = staffPayCostInPeriod(
        all,
        inSpan: (d) => d == DateTime(2026, 11, 2),
        inScope: (_) => true,
      );
      expect(cost, 30000 + 10000000 + 200000);
      expect(recon(all).netProfitKobo, none.netProfitKobo - cost);
      expect(
        staffPayCostInPeriod(
          all,
          inSpan: (_) => true,
          inScope: (s) => s == 'other',
        ),
        0,
      );
    });
  });
}
