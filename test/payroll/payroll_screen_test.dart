// payroll_screen_test.dart — #668 + #723: the Payroll menu item, the staff list
// and the phone / tablet layouts. Fixture names are made up — never real pay
// data (public repo).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart' show Scrollable, Size;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_allowances_screen.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_history_view.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_screen.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_entry_parts.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

import '../helpers/drawer_harness.dart';
import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

void main() {
  late ScreenTestEnvironment env;
  String? ceoId;

  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 1);
    NavigationService().resetNavigation();
  });

  tearDown(() async {
    await env.dispose();
    NavigationService().resetNavigation();
  });

  Future<String> addUser(String name, String roleId) async {
    final id = UuidV7.generate();
    await env.db
        .into(env.db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            name: name,
            pin: kSetupRequiredPin,
          ),
        );
    await env.db
        .into(env.db.userBusinesses)
        .insert(
          UserBusinessesCompanion.insert(
            businessId: env.businessId,
            userId: id,
            roleId: roleId,
          ),
        );
    return id;
  }

  /// A signed-in CEO (holds Payroll, as the cloud does) plus "Test Staff".
  Future<String> seedPeople() async {
    final roleId = UuidV7.generate();
    await env.db
        .into(env.db.roles)
        .insert(
          RolesCompanion.insert(
            id: Value(roleId),
            businessId: env.businessId,
            name: 'CEO',
            slug: 'ceo',
          ),
        );
    final ceo = await addUser('Test Owner', roleId);
    ceoId = ceo;
    env.db.userIdResolver = () => ceo;
    return addUser('Test Staff', roleId);
  }

  Future<void> pause(WidgetTester tester, [int ms = 100]) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<List<PayrollWorkerData>> workers(WidgetTester tester) async =>
      (await tester.runAsync(
        () => env.db.select(env.db.payrollWorkers).get(),
      ))!;

  Future<void> pumpPayroll(
    WidgetTester tester, {
    Size size = androidCompactPortrait,
  }) async {
    await pumpScreen(
      tester,
      env: env,
      size: size,
      screen: const PayrollScreen(),
      grantedKeys: {'payroll.manage'},
    );
    // Sign-in wiring points the resolver at the harness user; use the CEO.
    env.db.userIdResolver = () => ceoId;
    await pause(tester, 50);
  }

  testWidgets('the menu item is hidden without the permission', (tester) async {
    await pumpOpenDrawer(tester, env: env, size: phoneMaxPortrait);
    expect(find.text('Payroll', skipOffstage: false), findsNothing);
    await disposeScreen(tester);
  });

  testWidgets('the menu item shows with the permission', (tester) async {
    await pumpOpenDrawer(
      tester,
      env: env,
      size: phoneMaxPortrait,
      grants: {...kDrawerCeoGrants, 'payroll.manage'},
    );
    expect(find.text('Payroll', skipOffstage: false), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('shows the empty state with nobody added', (tester) async {
    await tester.runAsync(seedPeople);
    await pumpPayroll(tester);
    expect(find.text('No staff on Payroll yet'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('adds a worker by typed name, saved in name case', (
    tester,
  ) async {
    await tester.runAsync(seedPeople);
    await pumpPayroll(tester);
    await tester.tap(find.byKey(PayrollKeys.addButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(PayrollKeys.nameField), 'test WORKER');
    await tester.enterText(find.byKey(PayrollKeys.jobField), 'Driver');
    await tester.enterText(find.byKey(PayrollKeys.salaryField), '50,000');
    await tester.enterText(find.byKey(PayrollKeys.allowanceField), '1,000');
    await tester.tap(find.byKey(PayrollKeys.saveButton));
    await pause(tester);
    await pause(tester);

    final rows = await workers(tester);
    expect(rows, hasLength(1));
    final w = rows.single;
    expect(w.name, 'Test Worker');
    expect(w.userId, isNull);
    expect(w.storeId, env.storeId);
    expect(w.monthlySalaryKobo, 5000000);
    expect(w.dailyAllowanceKobo, 100000);
    expect(w.allowanceStartDate, isNotNull);
    expect(w.jobTitle, 'Driver');
    expect(w.paydayDay, isNull);
    await tester.scrollUntilVisible(
      find.byKey(PayrollKeys.workerRow(w.id)),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Test Worker'), findsOneWidget);
    await disposeScreen(tester);
  });

  testWidgets('adds a worker picked from Staff Management', (tester) async {
    final staffId = (await tester.runAsync(seedPeople))!;
    await pumpPayroll(tester);
    await tester.tap(find.byKey(PayrollKeys.addButton));
    await tester.pumpAndSettle();
    await pause(tester);
    await tester.tap(find.byKey(PayrollKeys.pickStaff));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PayrollKeys.staffOption(staffId)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PayrollKeys.saveButton));
    await pause(tester);
    await pause(tester);

    final rows = await workers(tester);
    expect(rows.single.userId, staffId);
    expect(rows.single.name, 'Test Staff');
    expect(rows.single.allowanceStartDate, isNull); // no allowance set
    await disposeScreen(tester);
  });

  testWidgets('removing a worker keeps the row and hides it', (tester) async {
    await tester.runAsync(seedPeople);
    final id = (await tester.runAsync(
      () => env.db.payrollDao.addWorker(
        storeId: env.storeId,
        name: 'Test Worker',
        monthlySalaryKobo: 100000,
      ),
    ))!;
    await pumpPayroll(tester);
    await pause(tester);
    await tester.scrollUntilVisible(
      find.byKey(PayrollKeys.workerRow(id)),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PayrollKeys.workerRow(id)));
    await tester.pumpAndSettle();
    await pause(tester);
    await tester.tap(find.byKey(PayrollKeys.editWorker));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(PayrollKeys.removeButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await pause(tester);
    await pause(tester);

    final rows = await workers(tester);
    expect(rows, hasLength(1));
    expect(rows.single.isRemoved, isTrue);
    expect(rows.single.removedAt, isNotNull);
    await disposeScreen(tester);
  });

  testWidgets('a waiting entry can be approved from the Overview', (
    tester,
  ) async {
    await tester.runAsync(seedPeople);
    late String managerId;
    final pending = (await tester.runAsync(() async {
      final mgrRole = UuidV7.generate();
      await env.db
          .into(env.db.roles)
          .insert(
            RolesCompanion.insert(
              id: Value(mgrRole),
              businessId: env.businessId,
              name: 'Manager',
              slug: 'manager',
            ),
          );
      await env.db
          .into(env.db.rolePermissions)
          .insert(
            RolePermissionsCompanion.insert(
              businessId: env.businessId,
              roleId: mgrRole,
              permissionKey: kPayrollPermissionKey,
            ),
          );
      managerId = await addUser('Test Manager', mgrRole);
      final workerId = await env.db.payrollDao.addWorker(
        storeId: env.storeId,
        name: 'Test Worker',
        monthlySalaryKobo: 10000000,
      );
      env.db.userIdResolver = () => managerId;
      return env.db.payrollDao.recordMoneyEntry(
        workerId: workerId,
        type: 'bonus',
        amountKobo: 100, // no Manager limit stored, so it waits
        paymentMethod: 'transfer',
      );
    }))!;
    expect(pending.status, 'pending');
    await pumpPayroll(tester);
    await pause(tester);
    expect(find.text('Waiting for your approval (1)'), findsOneWidget);
    await tester.tap(find.byKey(PayrollMoneyKeys.approve(pending.id)));
    await pause(tester);
    await pause(tester);
    final saved = (await tester.runAsync(
      () => env.db.select(env.db.payrollEntries).getSingle(),
    ))!;
    expect(saved.status, 'approved');
    await disposeScreen(tester);
  });

  group('#723 layouts', () {
    late String workerId;

    Future<void> seedPay() async {
      await seedPeople();
      final dao = env.db.payrollDao;
      workerId = await dao.addWorker(
        storeId: env.storeId,
        name: 'Ada Example',
        jobTitle: 'Driver',
        paydayDay: 28,
        monthlySalaryKobo: 9000000,
      );
      final other = await dao.addWorker(
        storeId: env.storeId,
        name: 'Ben Sample',
        monthlySalaryKobo: 5000000,
      );
      await dao.recordMoneyEntry(
        workerId: workerId,
        type: 'advance',
        amountKobo: 1500000,
        paymentMethod: 'cash',
      );
      await dao.recordMoneyEntry(
        workerId: workerId,
        type: 'bonus',
        amountKobo: 200000,
        paymentMethod: 'cash',
        note: 'Offloading: Test truck',
      );
      await dao.recordMoneyEntry(
        workerId: other,
        type: 'bonus',
        amountKobo: 200000,
        paymentMethod: 'cash',
        note: 'Offloading: Test truck',
      );
    }

    for (final (label, size) in [
      ('small phone', phoneSe1Portrait),
      ('compact phone', androidCompactPortrait),
      ('large phone', phoneMaxPortrait),
      ('phone sideways', pixel7Landscape),
      ('small tablet upright', tabletMiniPortrait),
      ('small tablet sideways', tabletMiniLandscape),
      ('tablet upright', tablet109Portrait),
      ('tablet sideways', tablet109Landscape),
      ('big tablet upright', tabletProPortrait),
      ('big tablet sideways', tabletProLandscape),
    ]) {
      testWidgets('Overview and History draw without overflow: $label', (
        tester,
      ) async {
        await tester.runAsync(seedPay);
        await pumpPayroll(tester, size: size);
        await pause(tester);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(PayrollKeys.tabHistory));
        await pause(tester);
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }

    testWidgets('a wide screen shows the chosen worker beside the list', (
      tester,
    ) async {
      await tester.runAsync(seedPay);
      await pumpPayroll(tester, size: tabletProLandscape);
      await pause(tester);
      // Ada owes the most and sorts first, so she is chosen.
      expect(find.text("Ada's payment history"), findsOneWidget);
      expect(find.byKey(PayrollKeys.paySalary), findsOneWidget);
      await tester.tap(
        find.byKey(
          PayrollKeys.workerRow(
            (await workers(tester)).firstWhere((w) => w.id != workerId).id,
          ),
        ),
      );
      await pause(tester);
      expect(find.text("Ben's payment history"), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('History collapses the same bonus for several staff', (
      tester,
    ) async {
      await tester.runAsync(seedPay);
      await pumpPayroll(tester);
      await pause(tester);
      await tester.tap(find.byKey(PayrollKeys.tabHistory));
      await pause(tester);
      expect(find.text('Offloading bonus, 2 staff'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(PayrollHistoryKeys.total),
          matching: find.text('₦19,000'),
        ),
        findsNothing,
      );
      await disposeScreen(tester);
    });

    testWidgets('the next month arrow stops at this month', (tester) async {
      await tester.runAsync(seedPay);
      await pumpPayroll(tester);
      await pause(tester);
      final before = find.text('6 staff on payroll');
      expect(before, findsNothing);
      await tester.tap(find.byKey(PayrollKeys.nextMonth));
      await pause(tester);
      expect(find.text('2 staff on payroll'), findsOneWidget);
      await tester.tap(find.byKey(PayrollKeys.previousMonth));
      await pause(tester);
      expect(find.text('0 staff on payroll'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('Change opens the day\'s allowances', (tester) async {
      await tester.runAsync(seedPay);
      await pumpPayroll(tester);
      await pause(tester);
      await tester.tap(find.byKey(PayrollKeys.changeAllowances));
      await pause(tester);
      await tester.pumpAndSettle();
      expect(find.byType(PayrollAllowancesScreen), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  testWidgets('editing moves the allowance start only when there was none', (
    tester,
  ) async {
    await tester.runAsync(seedPeople);
    final dao = env.db.payrollDao;
    final result = await tester.runAsync(() async {
      final id = await dao.addWorker(
        storeId: env.storeId,
        name: 'Test Worker',
        dailyAllowanceKobo: 50000,
        allowanceStartDate: '2026-01-05',
      );
      await dao.updateWorker(
        workerId: id,
        storeId: env.storeId,
        monthlySalaryKobo: 200000,
        dailyAllowanceKobo: 80000,
      );
      final none = await dao.addWorker(
        storeId: env.storeId,
        name: 'Other Worker',
      );
      await dao.updateWorker(
        workerId: none,
        storeId: env.storeId,
        monthlySalaryKobo: 0,
        dailyAllowanceKobo: 10000,
      );
      return [id, none];
    });
    final rows = await workers(tester);
    final kept = rows.firstWhere((w) => w.id == result![0]);
    expect(kept.allowanceStartDate, '2026-01-05');
    expect(kept.dailyAllowanceKobo, 80000);
    final set = rows.firstWhere((w) => w.id == result![1]);
    expect(set.allowanceStartDate, PayrollDao.payrollToday());
  });
}
