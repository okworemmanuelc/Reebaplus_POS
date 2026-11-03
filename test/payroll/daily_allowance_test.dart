// daily_allowance_test.dart — #669 (PRD #666, ADR 0034): the automatic Daily
// Allowance, its per-day change / cancel, and the combined "Daily allowances"
// line every phone reads (Daily Reconciliation, Expenses, Profit).
// Fixture names are made up — never real pay data (the repo is public).
//
// Calendar used throughout: 2026-11-01 is a Sunday, 2026-11-03 a Tuesday.

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/expenses/expense_summary.dart';
import 'package:reebaplus_pos/features/payroll/allowance_day.dart';

// Fixed ids so two in-memory "phones" describe the same business.
const _biz = '00000000-0000-7000-8000-0000000000b1';
const _storeA = '00000000-0000-7000-8000-0000000000a1';
const _storeB = '00000000-0000-7000-8000-0000000000a2';
const _mgrRole = '00000000-0000-7000-8000-0000000000c1';
const _cashRole = '00000000-0000-7000-8000-0000000000c2';
const _manager = '00000000-0000-7000-8000-0000000000d1';
const _cashier = '00000000-0000-7000-8000-0000000000d2';
const _ada = '00000000-0000-7000-8000-0000000000e1';
const _bayo = '00000000-0000-7000-8000-0000000000e2';
const _chidi = '00000000-0000-7000-8000-0000000000e3';

final _tuesday = DateTime(2026, 11, 3, 9);

/// One phone: an in-memory database seeded with the shared business, two
/// stores, a Manager holding Payroll and a Cashier without it.
class _Phone {
  _Phone._(this.db);
  final AppDatabase db;
  String? signedIn = _manager;

  static Future<_Phone> open() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final phone = _Phone._(db);
    db.businessIdResolver = () => _biz;
    db.userIdResolver = () => phone.signedIn;
    await db
        .into(db.businesses)
        .insert(
          BusinessesCompanion.insert(id: const Value(_biz), name: 'Shop'),
        );
    for (final (id, name) in [(_storeA, 'Main Store'), (_storeB, 'Annex')]) {
      await db
          .into(db.stores)
          .insert(
            StoresCompanion.insert(id: Value(id), businessId: _biz, name: name),
          );
    }
    for (final (id, slug) in [(_mgrRole, 'manager'), (_cashRole, 'cashier')]) {
      await db
          .into(db.roles)
          .insert(
            RolesCompanion.insert(
              id: Value(id),
              businessId: _biz,
              name: slug,
              slug: slug,
            ),
          );
    }
    await db
        .into(db.rolePermissions)
        .insert(
          RolePermissionsCompanion.insert(
            businessId: _biz,
            roleId: _mgrRole,
            permissionKey: kPayrollPermissionKey,
          ),
        );
    for (final (id, role) in [(_manager, _mgrRole), (_cashier, _cashRole)]) {
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              id: Value(id),
              businessId: _biz,
              name: 'Test $id',
              pin: kSetupRequiredPin,
            ),
          );
      await db
          .into(db.userBusinesses)
          .insert(
            UserBusinessesCompanion.insert(
              businessId: _biz,
              userId: id,
              roleId: role,
            ),
          );
    }
    return phone;
  }

  Future<void> addWorker(
    String id,
    String name, {
    String storeId = _storeA,
    int allowanceKobo = 150000,
    String start = '2026-10-29',
    DateTime? removedAt,
  }) => db
      .into(db.payrollWorkers)
      .insert(
        PayrollWorkersCompanion.insert(
          id: Value(id),
          businessId: _biz,
          storeId: storeId,
          name: name,
          dailyAllowanceKobo: Value(allowanceKobo),
          allowanceStartDate: Value(start),
          isRemoved: Value(removedAt != null),
          removedAt: Value(removedAt),
        ),
      );

  Future<List<PayrollEntryData>> entries() =>
      (db.select(db.payrollEntries)..orderBy([
            (e) => OrderingTerm.asc(e.entryDate),
            (e) => OrderingTerm.asc(e.createdAt),
          ]))
          .get();

  Future<List<StaffPayTotalData>> totals() => (db.select(
    db.staffPayTotals,
  )..orderBy([(t) => OrderingTerm.asc(t.totalDate)])).get();

  Future<int> queued(String table) async =>
      (await db
              .customSelect(
                'SELECT COUNT(*) AS c FROM sync_queue WHERE action_type = ?',
                variables: [Variable.withString('$table:upsert')],
              )
              .getSingle())
          .read<int>('c');

  Future<List<String>> queuedPayloads(String table) async => [
    for (final r
        in await db
            .customSelect(
              'SELECT payload FROM sync_queue WHERE action_type = ?',
              variables: [Variable.withString('$table:upsert')],
            )
            .get())
      r.read<String>('payload'),
  ];
}

PayrollWorkerData _worker({
  int allowanceKobo = 100000,
  String? start = '2026-10-29',
  DateTime? removedAt,
}) => PayrollWorkerData(
  id: _ada,
  businessId: _biz,
  storeId: _storeA,
  name: 'Ada Test',
  monthlySalaryKobo: 0,
  dailyAllowanceKobo: allowanceKobo,
  allowanceStartDate: start,
  isRemoved: removedAt != null,
  removedAt: removedAt,
  createdAt: DateTime(2026, 10, 29),
  lastUpdatedAt: DateTime(2026, 10, 29),
);

void main() {
  late _Phone phone;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    phone = await _Phone.open();
  });

  tearDown(() => phone.db.close());

  group('which days are owed', () {
    test('Monday to Saturday only — Sunday is skipped', () {
      expect(allowanceDueDays(_worker(), _tuesday), [
        '2026-10-29',
        '2026-10-30',
        '2026-10-31',
        '2026-11-02',
        '2026-11-03',
      ]);
      expect(isAllowanceDay(_worker(), DateTime(2026, 11, 1)), isFalse);
    });

    test('never before the start date, and nothing without one', () {
      expect(allowanceDueDays(_worker(start: '2026-11-03'), _tuesday), [
        '2026-11-03',
      ]);
      expect(allowanceDueDays(_worker(start: '2026-11-04'), _tuesday), isEmpty);
      expect(allowanceDueDays(_worker(start: null), _tuesday), isEmpty);
      expect(allowanceDueDays(_worker(allowanceKobo: 0), _tuesday), isEmpty);
    });

    test('never after the removal day (the removal day itself counts)', () {
      final removed = _worker(removedAt: DateTime(2026, 10, 30, 15));
      expect(allowanceDueDays(removed, _tuesday), ['2026-10-29', '2026-10-30']);
    });
  });

  group('runDailyAllowances', () {
    test('posts every owed day under its own date as till cash', () async {
      await phone.addWorker(_ada, 'Ada Test');
      expect(await phone.db.payrollDao.runDailyAllowances(now: _tuesday), 5);
      final rows = await phone.entries();
      expect(rows.map((e) => e.entryDate), [
        '2026-10-29',
        '2026-10-30',
        '2026-10-31',
        '2026-11-02',
        '2026-11-03',
      ]);
      for (final e in rows) {
        expect(e.id, payrollAllowanceId(_ada, e.entryDate));
        expect(e.type, 'allowance');
        expect(e.paymentMethod, 'cash');
        expect(e.storeId, _storeA);
        expect(e.amountKobo, 150000);
      }
      expect(await phone.queued('payroll_entries'), 5);
    });

    test('a removed worker is filled in only up to the removal day', () async {
      await phone.addWorker(
        _ada,
        'Ada Test',
        removedAt: DateTime(2026, 10, 30, 15),
      );
      await phone.db.payrollDao.runDailyAllowances(now: _tuesday);
      expect((await phone.entries()).map((e) => e.entryDate), [
        '2026-10-29',
        '2026-10-30',
      ]);
    });

    test('a second run (or day) only adds the missing days', () async {
      await phone.addWorker(_ada, 'Ada Test');
      final dao = phone.db.payrollDao;
      expect(await dao.runDailyAllowances(now: DateTime(2026, 10, 31)), 3);
      expect(await dao.runDailyAllowances(now: DateTime(2026, 10, 31)), 0);
      // Missed Monday is filled in on Tuesday under its own date.
      expect(await dao.runDailyAllowances(now: _tuesday), 2);
      expect(await dao.runDailyAllowances(now: _tuesday), 0);
      expect((await phone.entries()).length, 5);
      expect(await phone.queued('payroll_entries'), 5);
    });

    test('two phones mint the SAME rows (one per worker per day)', () async {
      final other = await _Phone.open();
      addTearDown(other.db.close);
      await phone.addWorker(_ada, 'Ada Test');
      await other.addWorker(_ada, 'Ada Test');
      await phone.db.payrollDao.runDailyAllowances(now: _tuesday);
      await other.db.payrollDao.runDailyAllowances(now: _tuesday);
      final a = (await phone.entries()).map((e) => e.id).toSet();
      final b = (await other.entries()).map((e) => e.id).toSet();
      expect(a, hasLength(5));
      expect(b, a);
      // And their combined lines share ids too, so the cloud keeps one each.
      final ta = (await phone.totals()).map((t) => t.id).toSet();
      final tb = (await other.totals()).map((t) => t.id).toSet();
      expect(tb, ta);
    });

    test('a phone without Payroll posts nothing and queues nothing', () async {
      await phone.addWorker(_ada, 'Ada Test');
      phone.signedIn = _cashier;
      expect(await phone.db.payrollDao.runDailyAllowances(now: _tuesday), 0);
      expect(await phone.entries(), isEmpty);
      expect(await phone.queued('payroll_entries'), 0);
      expect(await phone.queued('staff_pay_totals'), 0);
    });
  });

  group('change or cancel one worker on one day', () {
    test(
      'a change BEFORE the post is the posted row and survives the run',
      () async {
        await phone.addWorker(_ada, 'Ada Test', start: '2026-11-03');
        final dao = phone.db.payrollDao;
        await dao.setAllowanceForDay(
          workerId: _ada,
          entryDate: '2026-11-03',
          amountKobo: 50000,
          now: _tuesday,
        );
        expect(await dao.runDailyAllowances(now: _tuesday), 0);
        final rows = await phone.entries();
        expect(rows, hasLength(1));
        expect(rows.single.id, payrollAllowanceId(_ada, '2026-11-03'));
        expect(rows.single.amountKobo, 50000);
        expect(rows.single.correctsEntryId, isNull);
      },
    );

    test('a cancel BEFORE the post holds the day at zero', () async {
      await phone.addWorker(_ada, 'Ada Test', start: '2026-11-03');
      final dao = phone.db.payrollDao;
      await dao.setAllowanceForDay(
        workerId: _ada,
        entryDate: '2026-11-03',
        amountKobo: 0,
        now: _tuesday,
      );
      await dao.runDailyAllowances(now: _tuesday);
      final rows = await phone.entries();
      expect(rows.single.amountKobo, 0);
      final day = await dao.allowanceForDay(_ada, '2026-11-03');
      expect(day.netKobo, 0);
      // A zero day writes no combined line.
      expect(await phone.totals(), isEmpty);
    });

    test(
      'a LATE change is a new entry dated today correcting the original',
      () async {
        await phone.addWorker(_ada, 'Ada Test');
        final dao = phone.db.payrollDao;
        await dao.runDailyAllowances(now: _tuesday);
        final original = payrollAllowanceId(_ada, '2026-10-30');
        await dao.setAllowanceForDay(
          workerId: _ada,
          entryDate: '2026-10-30',
          amountKobo: 100000,
          now: _tuesday,
        );
        final fix = (await phone.entries()).firstWhere(
          (e) => e.correctsEntryId != null,
        );
        expect(fix.correctsEntryId, original);
        expect(fix.entryDate, '2026-11-03');
        expect(fix.amountKobo, -50000);
        expect((await dao.allowanceForDay(_ada, '2026-10-30')).netKobo, 100000);
        // Then cancelled: a second correction brings the day to zero.
        await dao.setAllowanceForDay(
          workerId: _ada,
          entryDate: '2026-10-30',
          amountKobo: 0,
          now: _tuesday,
        );
        expect((await dao.allowanceForDay(_ada, '2026-10-30')).netKobo, 0);
        // The reviewed day's line is untouched; the correction lands today.
        final totals = {
          for (final t in await phone.totals()) t.totalDate: t.amountKobo,
        };
        expect(totals['2026-10-30'], 150000);
        expect(totals['2026-11-03'], 150000 - 150000);
        // Setting the same amount again changes nothing.
        expect(
          await dao.setAllowanceForDay(
            workerId: _ada,
            entryDate: '2026-10-30',
            amountKobo: 0,
            now: _tuesday,
          ),
          isFalse,
        );
      },
    );

    test(
      'a Sunday, a future day or a day before the start is refused',
      () async {
        await phone.addWorker(_ada, 'Ada Test');
        final dao = phone.db.payrollDao;
        for (final day in ['2026-11-01', '2026-11-04', '2026-10-28']) {
          await expectLater(
            dao.setAllowanceForDay(
              workerId: _ada,
              entryDate: day,
              amountKobo: 1000,
              now: _tuesday,
            ),
            throwsArgumentError,
          );
        }
      },
    );

    test('a user without Payroll cannot change one', () async {
      await phone.addWorker(_ada, 'Ada Test');
      phone.signedIn = _cashier;
      await expectLater(
        phone.db.payrollDao.setAllowanceForDay(
          workerId: _ada,
          entryDate: '2026-11-03',
          amountKobo: 0,
          now: _tuesday,
        ),
        throwsA(isA<PayrollAccessDenied>()),
      );
    });
  });

  group('the combined "Daily allowances" line', () {
    test('one line per store per day with the store total', () async {
      await phone.addWorker(_ada, 'Ada Test', start: '2026-11-03');
      await phone.addWorker(
        _bayo,
        'Bayo Test',
        start: '2026-11-03',
        allowanceKobo: 70000,
      );
      await phone.addWorker(
        _chidi,
        'Chidi Test',
        storeId: _storeB,
        start: '2026-11-03',
        allowanceKobo: 30000,
      );
      await phone.db.payrollDao.runDailyAllowances(now: _tuesday);
      final totals = await phone.totals();
      expect(totals, hasLength(2));
      final byStore = {for (final t in totals) t.storeId: t};
      expect(byStore[_storeA]!.amountKobo, 220000);
      expect(byStore[_storeA]!.cashKobo, 220000);
      expect(byStore[_storeB]!.amountKobo, 30000);
      for (final t in totals) {
        expect(t.kind, kStaffPayKindDailyAllowances);
        expect(t.totalDate, '2026-11-03');
        expect(
          t.id,
          staffPayTotalId(
            _biz,
            t.storeId,
            kStaffPayKindDailyAllowances,
            t.totalDate,
          ),
        );
      }
      expect(await phone.queued('staff_pay_totals'), 2);
    });

    test(
      'names no worker — not in the row and not in what it uploads',
      () async {
        await phone.addWorker(_ada, 'Ada Test', start: '2026-11-03');
        await phone.addWorker(_bayo, 'Bayo Test', start: '2026-11-03');
        await phone.db.payrollDao.runDailyAllowances(now: _tuesday);
        final row = (await phone.totals()).single;
        final text =
            '${row.toJson()} ${await phone.queuedPayloads('staff_pay_totals')}';
        for (final secret in ['Ada', 'Bayo', _ada, _bayo]) {
          expect(text, isNot(contains(secret)));
        }
      },
    );

    test(
      'a line only rewrites (and re-queues) when its figure moves',
      () async {
        await phone.addWorker(_ada, 'Ada Test', start: '2026-11-03');
        final dao = phone.db.payrollDao;
        await dao.runDailyAllowances(now: _tuesday);
        await dao.refreshAllowanceTotals();
        expect(await phone.queued('staff_pay_totals'), 1);
        await dao.setAllowanceForDay(
          workerId: _ada,
          entryDate: '2026-11-03',
          amountKobo: 20000,
          now: _tuesday,
        );
        expect((await phone.totals()).single.amountKobo, 20000);
      },
    );
  });

  group('reports read the combined line', () {
    StaffPayTotalData line(String store, String day, int kobo) =>
        StaffPayTotalData(
          id: staffPayTotalId(_biz, store, kStaffPayKindDailyAllowances, day),
          businessId: _biz,
          storeId: store,
          kind: kStaffPayKindDailyAllowances,
          totalDate: day,
          amountKobo: kobo,
          cashKobo: kobo,
          createdAt: DateTime(2026, 11, 3),
          lastUpdatedAt: DateTime(2026, 11, 3),
        );

    final lines = [
      line(_storeA, '2026-11-03', 220000),
      line(_storeB, '2026-11-03', 30000),
      line(_storeA, '2026-11-02', 99900),
    ];

    test('Daily Reconciliation: in the cash card total and in profit', () {
      final none = reconDataFrom(
        ReconInputs(
          start: DateTime(2026, 11, 3),
          endExclusive: DateTime(2026, 11, 4),
        ),
      );
      final d = reconDataFrom(
        ReconInputs(
          staffPayTotals: lines,
          start: DateTime(2026, 11, 3),
          endExclusive: DateTime(2026, 11, 4),
        ),
      );
      expect(d.dailyAllowancesKobo, 250000);
      expect(d.cashOutKobo, none.cashOutKobo + 250000);
      expect(d.netCashMovementKobo, none.netCashMovementKobo - 250000);
      expect(d.netProfitKobo, none.netProfitKobo - 250000);
      expect(d.periodNetResultKobo, none.periodNetResultKobo - 250000);
      expect(d.isEmpty, isFalse);
    });

    test('Daily Reconciliation: one store in scope', () {
      final d = reconDataFrom(
        ReconInputs(
          staffPayTotals: lines,
          inScope: (s) => s == _storeB,
          start: DateTime(2026, 11, 3),
          endExclusive: DateTime(2026, 11, 4),
        ),
      );
      expect(d.dailyAllowancesKobo, 30000);
    });

    test('Expenses: lines in scope, and in Spent today / this month', () {
      expect(dailyAllowanceLinesInScope(lines, null), hasLength(3));
      expect(
        dailyAllowanceLinesInScope(lines, _storeA).map((t) => t.totalDate),
        ['2026-11-03', '2026-11-02'],
      );
      final s = summarizeExpenses(
        const [],
        now: _tuesday,
        allowanceLines: dailyAllowanceLinesInScope(lines, _storeA),
      );
      expect(s.spentTodayKobo, 220000);
      expect(s.budgetSpentKobo, 220000 + 99900);
      expect(s.waitingCount, 0);
    });
  });

  group('the Payroll day view', () {
    test('shows due, posted, changed and cancelled', () async {
      await phone.addWorker(_ada, 'Ada Test');
      await phone.addWorker(_bayo, 'Bayo Test');
      await phone.addWorker(_chidi, 'Chidi Test', start: '2026-11-03');
      final dao = phone.db.payrollDao;
      // Only Monday's run happened; then Bayo's Monday is cancelled late.
      await dao.runDailyAllowances(now: DateTime(2026, 11, 2, 9));
      await dao.setAllowanceForDay(
        workerId: _bayo,
        entryDate: '2026-11-02',
        amountKobo: 0,
        now: _tuesday,
      );
      final workers = await phone.db.select(phone.db.payrollWorkers).get();
      final entries = await phone.entries();
      final monday = allowanceDayRows(
        workers: workers,
        entries: entries,
        day: DateTime(2026, 11, 2),
      );
      expect(
        {for (final r in monday) r.worker.id: r.status},
        {_ada: AllowanceDayStatus.posted, _bayo: AllowanceDayStatus.cancelled},
      );
      final tuesday = allowanceDayRows(
        workers: workers,
        entries: entries,
        day: DateTime(2026, 11, 3),
      );
      expect(tuesday.map((r) => r.status).toSet(), {AllowanceDayStatus.due});
      expect(tuesday, hasLength(3));
      expect(
        allowanceDayRows(
          workers: workers,
          entries: entries,
          day: DateTime(2026, 11, 1),
        ),
        isEmpty,
      );
    });
  });
}
