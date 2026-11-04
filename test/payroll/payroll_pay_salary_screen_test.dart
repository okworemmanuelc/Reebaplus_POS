// payroll_pay_salary_screen_test.dart — #723: Pay Salary, the signature step
// and Add Pay Record. Fixture names are made up (public repo).

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/database/uuid_v7.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_add_record_screen.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_pay_salary_screen.dart';
import 'package:reebaplus_pos/features/payroll/screens/payroll_worker_screen.dart';
import 'package:reebaplus_pos/features/payroll/widgets/payroll_worker_dialog.dart';
import 'package:reebaplus_pos/shared/services/navigation_service.dart';

import '../helpers/screen_harness.dart';
import '../helpers/viewports.dart';

void main() {
  late ScreenTestEnvironment env;
  late String ceoId;
  late String workerId;
  final month = payrollMonthKey(DateTime.now());

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
      paydayDay: 28,
      monthlySalaryKobo: 10000000, // ₦100,000
    );
  }

  Future<void> pause(WidgetTester tester, [int ms = 100]) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> pump(WidgetTester tester, Widget screen, {Size? size}) async {
    await pumpScreen(
      tester,
      env: env,
      size: size ?? androidCompactPortrait,
      screen: screen,
      grantedKeys: {'payroll.manage'},
      roleSlug: 'ceo',
    );
    env.db.userIdResolver = () => ceoId;
    await pause(tester, 50);
  }

  Future<List<PayrollEntryData>> entries(WidgetTester tester) async =>
      (await tester.runAsync(
        () => env.db.select(env.db.payrollEntries).get(),
      ))!;

  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(
      f,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  group('Pay Salary', () {
    testWidgets('takes the advance and the loan plan off the salary', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await seed();
        final dao = env.db.payrollDao;
        await dao.recordMoneyEntry(
          workerId: workerId,
          type: 'advance',
          amountKobo: 1500000,
          paymentMethod: 'cash',
        );
        await dao.recordMoneyEntry(
          workerId: workerId,
          type: 'loan_given',
          amountKobo: 6000000,
          paymentMethod: 'cash',
          monthlyRepaymentKobo: 1000000,
        );
      });
      await pump(
        tester,
        PayrollPaySalaryScreen(workerId: workerId, month: month),
      );
      expect(
        tester.widget<Text>(find.byKey(PaySalaryKeys.salaryDue)).data,
        '₦75,000',
      );
      expect(find.text('Loan repayment, part 1 of 6'), findsOneWidget);
      expect(find.text('Confirm Payment of ₦75,000'), findsOneWidget);
      expect(find.byKey(PaySalaryKeys.reasonField), findsNothing);
      await disposeScreen(tester);
    });

    testWidgets('a different amount asks why; nothing saves unsigned', (
      tester,
    ) async {
      await tester.runAsync(seed);
      await pump(
        tester,
        PayrollPaySalaryScreen(workerId: workerId, month: month),
      );
      await tester.enterText(find.byKey(PaySalaryKeys.amountField), '80,000');
      await tester.pump();
      await scrollTo(tester, find.byKey(PaySalaryKeys.reasonField));
      await tester.enterText(
        find.byKey(PaySalaryKeys.reasonField),
        'Away a week',
      );
      await tester.pump();

      await tester.tap(find.byKey(PaySalaryKeys.confirm));
      await tester.pumpAndSettle();
      expect(find.text('Sign to confirm'), findsOneWidget);
      await tester.tap(find.byKey(PaySalaryKeys.saveSigned));
      await pause(tester);
      expect(
        find.textContaining('Both the worker and the payer must sign'),
        findsWidgets,
      );
      expect(await entries(tester), isEmpty);
      await tester.pump(const Duration(seconds: 6));
      await disposeScreen(tester);
    });

    testWidgets('offers no part-payment or split method', (tester) async {
      await tester.runAsync(seed);
      await pump(
        tester,
        PayrollPaySalaryScreen(workerId: workerId, month: month),
      );
      expect(find.text('Part cash, part transfer'), findsNothing);
      expect(
        find.byKey(const ValueKey('payroll-method-other')),
        findsOneWidget,
      );
      await disposeScreen(tester);
    });

    testWidgets('a month already paid says so', (tester) async {
      await tester.runAsync(() async {
        await seed();
        await env.db.payrollDao.paySalary(
          workerId: workerId,
          salaryMonth: month,
          paymentMethod: 'cash',
          workerSignaturePng: 'x',
          payerSignaturePng: 'x',
        );
      });
      await pump(
        tester,
        PayrollPaySalaryScreen(workerId: workerId, month: month),
      );
      expect(find.textContaining('has already been paid'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('Add Pay Record', () {
    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.byKey(AddPayRecordKeys.saveButton));
      await pause(tester);
      await pause(tester);
    }

    testWidgets('a bonus keeps its reason and note', (tester) async {
      await tester.runAsync(seed);
      await pump(tester, PayrollAddRecordScreen(workerId: workerId));
      await tester.enterText(find.byKey(AddPayRecordKeys.amountField), '2,000');
      await scrollTo(tester, find.byKey(AddPayRecordKeys.noteField));
      await tester.enterText(
        find.byKey(AddPayRecordKeys.noteField),
        'Test truck',
      );
      expect(find.text('Save Bonus'), findsOneWidget);
      await save(tester);
      final e = (await entries(tester)).single;
      expect(e.type, 'bonus');
      expect(e.amountKobo, 200000);
      expect(e.note, 'Offloading: Test truck');
      await disposeScreen(tester);
    });

    testWidgets('a new loan needs a monthly amount and saves the plan', (
      tester,
    ) async {
      await tester.runAsync(seed);
      await pump(tester, PayrollAddRecordScreen(workerId: workerId));
      await tester.tap(find.byKey(AddPayRecordKeys.type(PayRecordType.loan)));
      await tester.pump();
      await tester.enterText(
        find.byKey(AddPayRecordKeys.amountField),
        '60,000',
      );
      await tester.pump();
      await save(tester);
      expect(await entries(tester), isEmpty);
      await tester.pump(const Duration(seconds: 6));
      await scrollTo(tester, find.byKey(AddPayRecordKeys.planField));
      await tester.enterText(find.byKey(AddPayRecordKeys.planField), '10,000');
      await tester.pump();
      await save(tester);
      final e = (await entries(tester)).single;
      expect(e.type, 'loan_given');
      expect(e.monthlyRepaymentKobo, 1000000);
      await disposeScreen(tester);
    });

    testWidgets('a repayment is a loan_repaid entry with no plan', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await seed();
        await env.db.payrollDao.recordMoneyEntry(
          workerId: workerId,
          type: 'loan_given',
          amountKobo: 6000000,
          paymentMethod: 'cash',
        );
      });
      await pump(tester, PayrollAddRecordScreen(workerId: workerId));
      await tester.tap(find.byKey(AddPayRecordKeys.type(PayRecordType.loan)));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('add-pay-record-chip-Paid back')),
      );
      await tester.pump();
      expect(find.byKey(AddPayRecordKeys.planField), findsNothing);
      await tester.enterText(find.byKey(AddPayRecordKeys.amountField), '5,000');
      await save(tester);
      final repaid = (await entries(
        tester,
      )).where((e) => e.type == 'loan_repaid').single;
      expect(repaid.amountKobo, 500000);
      expect(repaid.monthlyRepaymentKobo, isNull);
      await disposeScreen(tester);
    });

    testWidgets('an advance above the salary says use a loan', (tester) async {
      await tester.runAsync(seed);
      await pump(tester, PayrollAddRecordScreen(workerId: workerId));
      await tester.tap(
        find.byKey(AddPayRecordKeys.type(PayRecordType.advance)),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(AddPayRecordKeys.amountField),
        '100,001',
      );
      await save(tester);
      expect(await entries(tester), isEmpty);
      expect(find.textContaining('Give a staff loan instead'), findsWidgets);
      await tester.pump(const Duration(seconds: 6));
      await disposeScreen(tester);
    });
  });

  group('Pay profile', () {
    testWidgets('shows the plan, the payday and a Pay Salary button', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await seed();
        await env.db.payrollDao.recordMoneyEntry(
          workerId: workerId,
          type: 'loan_given',
          amountKobo: 6000000,
          paymentMethod: 'cash',
          monthlyRepaymentKobo: 1000000,
        );
      });
      await pump(
        tester,
        PayrollWorkerScreen(workerId: workerId, month: month),
        size: pixel7Portrait,
      );
      expect(find.text('28th'), findsOneWidget);
      expect(find.text('Loan repayment, part 1 of 6'), findsOneWidget);
      expect(find.byKey(PayrollKeys.paySalary), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('₦10,000 a month'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('₦10,000 a month'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('a paid month offers the payslip instead', (tester) async {
      await tester.runAsync(() async {
        await seed();
        await env.db.payrollDao.paySalary(
          workerId: workerId,
          salaryMonth: month,
          paymentMethod: 'cash',
          workerSignaturePng: 'x',
          payerSignaturePng: 'x',
        );
      });
      await pump(tester, PayrollWorkerScreen(workerId: workerId, month: month));
      await pause(tester);
      expect(find.text('View Payslip'), findsOneWidget);
      await disposeScreen(tester);
    });
  });
}
