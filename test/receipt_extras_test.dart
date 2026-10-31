// #605 slice 3: the receipt real-data resolver + part-deposit wording.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_extras.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/features/pos/widgets/paper_receipt.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';

const _vat = VatConfig(enabled: true, rateBps: 750);

void main() {
  group('composeReceiptExtras', () {
    test('VAT is inclusive: N10,750 goods at 7.5% -> N750', () {
      final x = composeReceiptExtras(vat: _vat, totalKobo: 1075000);
      expect(x.vatRateBps, 750);
      expect(x.vatIncluded, 750.0);
    });

    test('VAT ignores an exclusive basis setting and excludes the deposit', () {
      final x = composeReceiptExtras(
        vat: const VatConfig(
          enabled: true,
          rateBps: 750,
          basis: VatBasis.exclusive,
        ),
        totalKobo: 1275000, // 10,750 goods + 2,000 deposit
        depositKobo: 200000,
      );
      expect(x.vatIncluded, 750.0);
    });

    test('VAT off, or enabled with a zero rate -> null', () {
      for (final v in [
        VatConfig.off,
        const VatConfig(enabled: true, rateBps: 0),
      ]) {
        final x = composeReceiptExtras(vat: v, totalKobo: 1075000);
        expect(x.vatRateBps, isNull);
        expect(x.vatIncluded, isNull);
      }
    });

    test('blank phone / email / cashier -> null', () {
      final x = composeReceiptExtras(
        businessPhone: '  ',
        businessEmail: '',
        cashierName: ' ',
        totalKobo: 1000,
      );
      expect(x.businessPhone, isNull);
      expect(x.businessEmail, isNull);
      expect(x.cashierName, isNull);
      final y = composeReceiptExtras(
        businessPhone: ' 0803 ',
        businessEmail: 'a@b.ng',
        cashierName: 'amina bello',
        totalKobo: 1000,
      );
      expect(y.businessPhone, '0803');
      expect(y.businessEmail, 'a@b.ng');
      expect(y.cashierName, 'Amina Bello');
    });

    test('crate balance: positive = owed, credit floored at 0, none = null', () {
      final x = composeReceiptExtras(
        totalKobo: 1000,
        crateBalances: [
          CrateBalanceEntry(manufacturerId: 'a', manufacturerName: 'A', balance: 7),
          CrateBalanceEntry(manufacturerId: 'b', manufacturerName: 'B', balance: -3),
        ],
      );
      expect(x.cratesOwedByManufacturer, {'a': 7.0, 'b': 0.0});
      expect(composeReceiptExtras(totalKobo: 1000).cratesOwedByManufacturer, isNull);
    });

    test('owed adds the crates this sale took under a deposit', () {
      // The ledger only records no-deposit crates, so a deposit sale must still
      // show its own crates as "still to bring back" (#605 owner decision).
      final x = composeReceiptExtras(
        totalKobo: 1000,
        crateBalances: [
          CrateBalanceEntry(manufacturerId: 'a', manufacturerName: 'A', balance: 2),
          CrateBalanceEntry(manufacturerId: 'b', manufacturerName: 'B', balance: -3),
        ],
        depositCrates: {'a': 1, 'b': 1, 'c': 4},
      );
      expect(x.cratesOwedByManufacturer, {'a': 3.0, 'b': 1.0, 'c': 4.0});
    });

    test('full deposit only when above what was paid', () {
      expect(
        composeReceiptExtras(totalKobo: 1, depositKobo: 100000, fullDepositKobo: 300000)
            .crateDepositFull,
        3000.0,
      );
      expect(
        composeReceiptExtras(totalKobo: 1, depositKobo: 300000, fullDepositKobo: 300000)
            .crateDepositFull,
        isNull,
      );
    });

    test('sale date is the order time in local time', () {
      final utc = DateTime.utc(2026, 3, 1, 9);
      expect(composeReceiptExtras(totalKobo: 1, saleDate: utc).saleDate!.isUtc, isFalse);
    });
  });

  const cart = <Map<String, dynamic>>[
    {
      'name': 'Lager',
      'unit': 'Bottle',
      'price': 1000.0,
      'qty': 2.0,
      'trackEmpties': true,
      'manufacturerId': 'm1',
    },
  ];
  final partNote =
      'Deposit paid ${formatCurrency(1000)} of ${formatCurrency(3000)}.';
  final fullNote =
      'The ${formatCurrency(1000)} deposit is refunded when the crates are returned.';

  Widget phone({double? full, DateTime? saleDate, DateTime? reprint}) =>
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReceiptWidget(
              orderId: 'ORD-1',
              cart: cart,
              subtotal: 2000,
              crateDeposit: 1000,
              total: 3000,
              paymentMethod: 'Cash',
              customerName: 'Ada',
              manufacturerNames: const {'m1': 'Lager'},
              crateDepositFull: full,
              saleDate: saleDate,
              reprintDate: reprint,
              tracksCrates: true,
            ),
          ),
        ),
      );

  Widget paper(ReceiptPaperSize size, {double? full}) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: PaperReceipt(
          paperSize: size,
          orderId: 'ORD-1',
          cart: cart,
          subtotal: 2000,
          crateDeposit: 1000,
          total: 3000,
          paymentMethod: 'Cash',
          customerName: 'Ada',
          manufacturerNames: const {'m1': 'Lager'},
          crateDepositFull: full,
          tracksCrates: true,
        ),
      ),
    ),
  );

  testWidgets('phone receipt: part deposit wording', (tester) async {
    await tester.pumpWidget(phone(full: 3000));
    expect(find.text(partNote), findsOneWidget);
    expect(find.text(fullNote), findsNothing);
  });

  testWidgets('phone receipt: full deposit keeps the refund sentence', (tester) async {
    await tester.pumpWidget(phone(full: 1000));
    expect(find.text(fullNote), findsOneWidget);
    await tester.pumpWidget(phone());
    expect(find.text(fullNote), findsOneWidget);
  });

  for (final size in ReceiptPaperSize.values) {
    testWidgets('paper ${size.name}: part deposit wording', (tester) async {
      await tester.pumpWidget(paper(size, full: 3000));
      expect(find.text(partNote), findsOneWidget);
      expect(find.text(fullNote), findsNothing);
    });
  }

  testWidgets('a reprint shows the order date, not now', (tester) async {
    await tester.pumpWidget(
      phone(saleDate: DateTime(2025, 3, 4, 9, 5), reprint: DateTime.now()),
    );
    expect(find.textContaining('4 Mar 2025'), findsOneWidget);
    expect(find.textContaining('${DateTime.now().year + 1}'), findsNothing);
    expect(find.textContaining('REPRINTED'), findsWidgets);
  });
}
