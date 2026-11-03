// payroll_payday_screen_test.dart — #671 (PRD #666): the Pay salary screen.
// Fixture names are made up — never real pay data (the repo is public).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_payday_screen.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_worker_money_screen.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

void main() {
  late ScreenTestEnvironment env;
  late String ceoId;
  late String workerId;

  setUp(() async {
    env = await setupScreenTestEnvironment(productCount: 1);
    NavigationService().resetNavigation();
  });

  tearDown(() async {
    await env.dispose();
    NavigationService().resetNavigation();
  });

  Future<void> seed() async {
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
    ceoId = UuidV7.generate();
    await env.db
        .into(env.db.users)
        .insert(
          UsersCompanion.insert(
            id: Value(ceoId),
            businessId: env.businessId,
            name: 'Test Owner',
            pin: kSetupRequiredPin,
          ),
        );
    await env.db
        .into(env.db.userBusinesses)
        .insert(
          UserBusinessesCompanion.insert(
            businessId: env.businessId,
            userId: ceoId,
            roleId: roleId,
          ),
        );
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

  Future<void> pumpPayday(WidgetTester tester) async {
    await pumpScreen(
      tester,
      env: env,
      size: androidCompactPortrait,
      screen: PayrollPaydayScreen(workerId: workerId),
      grantedKeys: {'payroll.manage'},
      roleSlug: 'ceo',
    );
    env.db.userIdResolver = () => ceoId;
    await pause(tester, 50);
  }

  testWidgets('shows the cash and Total Pay, and will not save unsigned', (
    tester,
  ) async {
    await tester.runAsync(seed);
    await pumpPayday(tester);
    expect(
      find.descendant(
        of: find.byKey(PaydayKeys.cashPaid),
        matching: find.text('₦100,000'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(PaydayKeys.reasonField), findsNothing);

    // A different amount asks for a reason.
    await tester.enterText(find.byKey(PaydayKeys.salaryField), '80,000');
    await tester.pump();
    expect(find.byKey(PaydayKeys.reasonField), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(PaydayKeys.totalPay),
        matching: find.text('₦80,000'),
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(PaydayKeys.reasonField), 'Away a week');
    await tester.pump();

    final save = find.byKey(PaydayKeys.saveButton);
    await tester.scrollUntilVisible(
      save,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(save);
    await pause(tester);
    expect(
      find.textContaining('Both the worker and the payer must sign'),
      findsWidgets,
    );
    final statements = await tester.runAsync(
      () => env.db.select(env.db.payrollStatements).get(),
    );
    expect(statements, isEmpty);
    await tester.pump(const Duration(seconds: 6));
    await disposeScreen(tester);
  });

  testWidgets('the worker screen shows Total Pay and a Pay salary button', (
    tester,
  ) async {
    await tester.runAsync(seed);
    await pumpScreen(
      tester,
      env: env,
      size: androidCompactPortrait,
      screen: PayrollWorkerMoneyScreen(workerId: workerId),
      grantedKeys: {'payroll.manage'},
      roleSlug: 'ceo',
    );
    await pause(tester, 50);
    expect(
      find.descendant(
        of: find.byKey(PayrollMoneyKeys.totalPay),
        matching: find.text('₦100,000'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(PayrollMoneyKeys.paySalary), findsOneWidget);
    await disposeScreen(tester);
  });
}
