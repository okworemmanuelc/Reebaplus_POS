// payroll_screen_test.dart — #668 (PRD #666): the Payroll menu item and the
// worker list. Fixture names are made up — never real pay data (public repo).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_screen.dart';
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

  Future<void> pumpPayroll(WidgetTester tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: androidCompactPortrait,
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
    expect(find.text('No workers on Payroll yet'), findsOneWidget);
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
    await tester.tap(find.byKey(PayrollKeys.workerRow(id)));
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
    expect(find.byKey(PayrollKeys.workerRow(id)), findsNothing);
    await disposeScreen(tester);
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
