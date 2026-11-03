// payroll_worker_money_screen_test.dart — #670 (PRD #666): the worker's
// Bonus, Advance and Staff Loan screen, and the CEO's approve on Payroll.
// Fixture names are made up — never real pay data (the repo is public).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_screen.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_worker_money_screen.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

void main() {
  late ScreenTestEnvironment env;
  late String ceoId;
  late String managerId;
  late String workerId;

  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 1);
    NavigationService().resetNavigation();
  });

  tearDown(() async {
    await env.dispose();
    NavigationService().resetNavigation();
  });

  Future<String> addRole(String name, String slug) async {
    final id = UuidV7.generate();
    await env.db
        .into(env.db.roles)
        .insert(
          RolesCompanion.insert(
            id: Value(id),
            businessId: env.businessId,
            name: name,
            slug: slug,
          ),
        );
    return id;
  }

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

  Future<void> seed() async {
    ceoId = await addUser('Test Owner', await addRole('CEO', 'ceo'));
    final mgrRole = await addRole('Manager', 'manager');
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
    env.db.userIdResolver = () => ceoId;
    workerId = await env.db.payrollDao.addWorker(
      storeId: env.storeId,
      name: 'Ada Example',
      monthlySalaryKobo: 10000000, // ₦100,000
    );
  }

  Future<void> pause(WidgetTester tester, [int ms = 100]) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<List<PayrollEntryData>> entries(WidgetTester tester) async =>
      (await tester.runAsync(
        () => env.db.select(env.db.payrollEntries).get(),
      ))!;

  Future<void> pumpMoney(WidgetTester tester, {String as = 'ceo'}) async {
    await pumpScreen(
      tester,
      env: env,
      size: androidCompactPortrait,
      screen: PayrollWorkerMoneyScreen(workerId: workerId),
      grantedKeys: {'payroll.manage'},
      roleSlug: as,
    );
    env.db.userIdResolver = () => as == 'ceo' ? ceoId : managerId;
    await pause(tester, 50);
  }

  Future<void> give(WidgetTester tester, String type, String amount) async {
    await tester.tap(find.byKey(PayrollMoneyKeys.action(type)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(PayrollMoneyKeys.amountField), amount);
    await tester.tap(find.byKey(PayrollMoneyKeys.saveButton));
    await pause(tester);
    await pause(tester);
  }

  testWidgets('an advance above what is left of the month is refused', (
    tester,
  ) async {
    await tester.runAsync(seed);
    await pumpMoney(tester);
    await give(tester, 'advance', '100,001');
    expect(await entries(tester), isEmpty);
    expect(find.textContaining('Give a staff loan instead'), findsWidgets);
    // Let the error toast run out before tearing down.
    await tester.pump(const Duration(seconds: 6));
    await disposeScreen(tester);
  });

  testWidgets('a loan shows what is still owed', (tester) async {
    await tester.runAsync(seed);
    await pumpMoney(tester);
    await give(tester, 'loan_given', '20,000');
    final saved = (await entries(tester)).single;
    expect(saved.type, 'loan_given');
    expect(saved.amountKobo, 2000000);
    expect(saved.paymentMethod, 'cash');
    expect(saved.status, 'approved');
    expect(
      find.descendant(
        of: find.byKey(PayrollMoneyKeys.loanOwed),
        matching: find.text('₦20,000'),
      ),
      findsOneWidget,
    );
    await disposeScreen(tester);
  });

  testWidgets('the CEO approves a waiting entry from Payroll', (tester) async {
    await tester.runAsync(seed);
    final pending = (await tester.runAsync(() async {
      env.db.userIdResolver = () => managerId;
      return env.db.payrollDao.recordMoneyEntry(
        workerId: workerId,
        type: 'bonus',
        amountKobo: 100, // no Manager limit stored → waits
        paymentMethod: 'transfer',
      );
    }))!;
    expect(pending.status, 'pending');
    await pumpScreen(
      tester,
      env: env,
      size: androidCompactPortrait,
      screen: const PayrollScreen(),
      grantedKeys: {'payroll.manage'},
    );
    env.db.userIdResolver = () => ceoId;
    await pause(tester);
    expect(find.text('Waiting for your approval (1)'), findsOneWidget);
    await tester.tap(find.byKey(PayrollMoneyKeys.approve(pending.id)));
    await pause(tester);
    await pause(tester);
    expect((await entries(tester)).single.status, 'approved');
    expect(find.text('Waiting for your approval (1)'), findsNothing);
    await disposeScreen(tester);
  });
}
