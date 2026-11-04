// #732 (PR C) — the crate deposit in an edit's money step: shown only when added
// crates need it, auto-filled, editable down to zero, and in the amount due.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/orders/widgets/edit_sale_sheet.dart';
import 'package:reebaplus_pos/shared/services/orders/sale_totals.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';

import '../helpers/screen_harness.dart';
import 'orders_fixture.dart';

const _brand = 'brand-1';
const List<({SaleCrateLine line, String name})> _crates = [
  (
    line: SaleCrateLine(manufacturerId: _brand, crates: 2, rateKobo: 50000),
    name: 'Star',
  ),
];

EditSettlement _settlement({int goods = 200000, int paidBack = 0}) =>
    EditSettlement(
      goodsDueKobo: goods,
      depositKobo: 0,
      paidBackKobo: paidBack,
      depositBackKobo: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenTestEnvironment env;

  setUp(() async {
    env = await setupScreenTestEnvironment(
      productCount: 1,
      manufacturerCount: 1,
      businessType: 'Bar',
    );
  });
  tearDown(() async => env.dispose());

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await disposeScreen(tester);
  }

  String money(int kobo) => formatCurrency(kobo / 100.0);

  /// Opens the pop-up; the returned list gets the choice when it closes.
  Future<List<EditMoneyChoice?>> open(
    WidgetTester tester, {
    EditSettlement? settlement,
    bool hasCustomer = true,
    List<({SaleCrateLine line, String name})> crates = const [],
  }) async {
    final results = <EditMoneyChoice?>[];
    await pumpScreen(
      tester,
      env: env,
      size: const Size(390, 844),
      settle: false,
      screen: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async => results.add(
              await showEditMoneyDialog(
                context,
                settlement: settlement ?? _settlement(),
                hasCustomer: hasCustomer,
                crateBrands: crates,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settleOrders(tester);
    return results;
  }

  String amountDue(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(EditSaleKeys.amountDue)).data!;

  testWidgets('no added crates: no section, the goods alone are due',
      (tester) async {
    await open(tester);
    expect(find.byKey(EditSaleKeys.depositSection), findsNothing);
    expect(amountDue(tester), contains(money(200000)));
    await finish(tester);
  });

  testWidgets('added crates: the section shows, filled to the full deposit, '
      'and the deposit is in the amount due', (tester) async {
    final results = await open(tester, crates: _crates);
    expect(find.byKey(EditSaleKeys.depositSection), findsOneWidget);
    expect(find.byKey(EditSaleKeys.depositRow(_brand)), findsOneWidget);
    expect(amountDue(tester), contains(money(300000)));

    await tester.ensureVisible(find.byKey(EditSaleKeys.moneyConfirm));
    await tester.tap(find.byKey(EditSaleKeys.moneyConfirm));
    await settleOrders(tester);
    expect(results.single!.depositByManufacturer, {_brand: 100000});
    expect(results.single!.paidKobo, 300000);
    await finish(tester);
  });

  testWidgets('a walk-in never sees the section', (tester) async {
    await open(tester, crates: _crates, hasCustomer: false);
    expect(find.byKey(EditSaleKeys.depositSection), findsNothing);
    expect(amountDue(tester), contains(money(200000)));
    await finish(tester);
  });

  testWidgets('On balance takes no deposit, as a Credit Sale at Checkout',
      (tester) async {
    final results = await open(tester, crates: _crates);
    await tester.tap(find.byKey(EditSaleKeys.onBalance));
    await settleOrders(tester);
    expect(find.byKey(EditSaleKeys.depositSection), findsNothing);
    expect(amountDue(tester), contains(money(200000)));

    await tester.ensureVisible(find.byKey(EditSaleKeys.moneyConfirm));
    await tester.tap(find.byKey(EditSaleKeys.moneyConfirm));
    await settleOrders(tester);
    expect(results.single!.depositByManufacturer, isEmpty);
    expect(results.single!.paidKobo, 0);
    await finish(tester);
  });

  testWidgets('editing a brand to zero takes it out of the amount due',
      (tester) async {
    final results = await open(tester, crates: _crates);
    await tester.tap(find.byKey(EditSaleKeys.depositRow(_brand)));
    await settleOrders(tester);
    expect(find.byKey(EditSaleKeys.depositSheet), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byKey(EditSaleKeys.depositSheet),
        matching: find.byType(TextField),
      ),
      '0',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Save'));
    await settleOrders(tester);

    expect(amountDue(tester), contains(money(200000)));
    await tester.ensureVisible(find.byKey(EditSaleKeys.moneyConfirm));
    await tester.tap(find.byKey(EditSaleKeys.moneyConfirm));
    await settleOrders(tester);
    expect(results.single!.depositByManufacturer, {_brand: 0});
    await finish(tester);
  });

  testWidgets('paying less than the deposit is stopped', (tester) async {
    final results = await open(tester, crates: _crates);
    await tester.enterText(
      find.descendant(
        of: find.byKey(EditSaleKeys.moneyDialog),
        matching: find.byType(TextField),
      ),
      '999',
    );
    await tester.pump();
    expect(find.byKey(EditSaleKeys.depositNotCovered), findsOneWidget);

    await tester.ensureVisible(find.byKey(EditSaleKeys.moneyConfirm));
    await tester.tap(find.byKey(EditSaleKeys.moneyConfirm));
    await settleOrders(tester);
    expect(results, isEmpty, reason: 'the pop-up stays open');
    await finish(tester);
  });

  testWidgets('a refund bigger than the deposit: the customer gets the rest',
      (tester) async {
    await open(
      tester,
      settlement: _settlement(goods: 0, paidBack: 150000),
      crates: _crates,
    );
    expect(find.byKey(EditSaleKeys.depositSection), findsOneWidget);
    expect(amountDue(tester), contains('gets back'));
    expect(amountDue(tester), contains(money(50000)));
    expect(find.text('Continue'), findsOneWidget);
    await finish(tester);
  });
}
