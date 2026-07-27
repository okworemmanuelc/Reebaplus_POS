// receipt_discount_line_test.dart
//
// PRD #155 US 33 (#200) — a discounted order's REPRINT must be the same piece of
// paper as the original.
//
// Before #200 the original print passed the pre-discount gross as Subtotal while
// a reprint passed the post-discount goods net, and NEITHER renderer printed a
// discount line — so one sale produced two different Subtotals, and the figure
// that explained the gap appeared on neither copy. (#176 had already fixed the
// goods/deposit split at the four reprint sites; the discount was what was left.)
//
// The fix is one shared derivation (`receiptTotalsFromOrder`) plus a Discount
// line on both renderers. These tests pin all three halves:
//   1. the derivation ties to the recorded order by construction,
//   2. the on-screen receipt renders identical Subtotal / Discount / TOTAL for
//      the original's arguments and its reprint's arguments,
//   3. the thermal receipt prints the same block.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/shared/models/receipt_totals.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // One discounted, crate-deposit-bearing sale, in kobo:
  //   goods at full price  ₦2,000  (2 × ₦1,000)
  //   discount given         ₦500
  //   crate deposit         ₦300
  //   the customer pays   ₦1,800
  const grossKobo = 200000;
  const discountKobo = 50000;
  const depositKobo = 30000;
  const paidKobo = 180000;

  final cart = [
    {'name': 'Star Lager', 'price': 1000.0, 'qty': 2.0},
  ];

  group('receiptTotalsFromOrder — the reprint derivation', () {
    test('rebuilds the pre-discount goods figure and ties back to the order', () {
      // What the DB holds for the sale above: total_amount is already NET of the
      // discount and INCLUSIVE of the deposit.
      final t = receiptTotalsFromOrder(
        totalAmountKobo: paidKobo,
        crateDepositPaidKobo: depositKobo,
        discountKobo: discountKobo,
      );

      expect(t.subtotalKobo, grossKobo, reason: 'goods at FULL price');
      expect(t.discountKobo, discountKobo);
      expect(t.depositKobo, depositKobo);
      // The identity that makes a reprint trustworthy: the printed lines add
      // back up to exactly what the customer was charged.
      expect(t.totalKobo, paidKobo);
    });

    test('reproduces the ORIGINAL print\'s figures, not the goods net', () {
      final reprint = receiptTotalsFromOrder(
        totalAmountKobo: paidKobo,
        crateDepositPaidKobo: depositKobo,
        discountKobo: discountKobo,
      );
      // The original's Subtotal is the cart's pre-discount gross.
      expect(reprint.subtotalKobo, grossKobo);
      // The pre-#200 reprint printed the goods NET (₦1,500) as Subtotal — lower
      // than the original by exactly the discount. That is the bug.
      expect(reprint.subtotalKobo, isNot(paidKobo - depositKobo));
      expect(reprint.subtotalKobo - (paidKobo - depositKobo), discountKobo);
    });

    test('an undiscounted order needs no discount line', () {
      final t = receiptTotalsFromOrder(
        totalAmountKobo: 230000,
        crateDepositPaidKobo: depositKobo,
        discountKobo: 0,
      );
      expect(t.discountKobo, 0);
      expect(t.subtotalKobo, 200000);
      expect(t.totalKobo, 230000);
    });

    test('a fully-discounted order still ties', () {
      final t = receiptTotalsFromOrder(
        totalAmountKobo: depositKobo, // goods free, deposit still collected
        crateDepositPaidKobo: depositKobo,
        discountKobo: grossKobo,
      );
      expect(t.subtotalKobo, grossKobo);
      expect(t.discountKobo, grossKobo);
      expect(t.totalKobo, depositKobo);
    });
  });

  group('ReceiptWidget — the on-screen receipt', () {
    Future<List<String>> moneyLines(
      WidgetTester tester, {
      required double subtotal,
      required double discount,
      required double crateDeposit,
      required double total,
      DateTime? reprintDate,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReceiptWidget(
                orderId: 'ORD-000009',
                cart: cart,
                subtotal: subtotal,
                discount: discount,
                crateDeposit: crateDeposit,
                total: total,
                paymentMethod: 'Cash',
                reprintDate: reprintDate,
              ),
            ),
          ),
        ),
      );
      // Every rendered Text, in tree order — enough to compare the two copies.
      return tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
    }

    testWidgets('prints Subtotal, a Discount line, the deposit and TOTAL',
        (tester) async {
      final lines = await moneyLines(
        tester,
        subtotal: grossKobo / 100.0,
        discount: discountKobo / 100.0,
        crateDeposit: depositKobo / 100.0,
        total: paidKobo / 100.0,
      );
      expect(lines, contains('Subtotal'));
      expect(lines, contains('₦2,000'));
      expect(lines, contains('Discount'));
      // The discount reads as a deduction, so Subtotal → Total is an addition.
      expect(lines, contains('-₦500'));
      expect(lines, contains('Crate Deposit'));
      expect(lines, contains('₦300'));
      expect(lines, contains('TOTAL'));
      expect(lines, contains('₦1,800'));
    });

    testWidgets('a reprint renders the IDENTICAL money block as the original',
        (tester) async {
      // The original, as CheckoutPage passes it: cart gross + summed line
      // discounts + captured deposit.
      final original = await moneyLines(
        tester,
        subtotal: grossKobo / 100.0,
        discount: discountKobo / 100.0,
        crateDeposit: depositKobo / 100.0,
        total: paidKobo / 100.0,
      );

      // The reprint, as the four reprint sites now pass it: derived from the
      // recorded order alone. Nothing about the cart is available any more.
      final t = receiptTotalsFromOrder(
        totalAmountKobo: paidKobo,
        crateDepositPaidKobo: depositKobo,
        discountKobo: discountKobo,
      );
      final reprint = await moneyLines(
        tester,
        subtotal: t.subtotalKobo / 100.0,
        discount: t.discountKobo / 100.0,
        crateDeposit: t.depositKobo / 100.0,
        total: t.totalKobo / 100.0,
        reprintDate: DateTime(2026, 7, 27),
      );

      // The REPRINTED stamp and its date are the only things that may differ.
      String money(List<String> lines, String label) =>
          lines[lines.indexOf(label) + 1];
      for (final label in ['Subtotal', 'Discount', 'Crate Deposit', 'TOTAL']) {
        expect(
          money(reprint, label),
          money(original, label),
          reason: 'reprint must agree with the original on $label',
        );
      }
    });

    testWidgets('no discount line when nothing was discounted', (tester) async {
      final lines = await moneyLines(
        tester,
        subtotal: grossKobo / 100.0,
        discount: 0,
        crateDeposit: 0,
        total: grossKobo / 100.0,
      );
      expect(lines, isNot(contains('Discount')));
    });
  });

  group('ThermalReceiptService — the paper receipt', () {
    Future<String> printed({
      required double subtotal,
      required double discount,
      required double crateDeposit,
      required double total,
    }) async {
      final bytes = await ThermalReceiptService.buildReceipt(
        orderId: 'ORD-000009',
        cart: cart,
        subtotal: subtotal,
        discount: discount,
        crateDeposit: crateDeposit,
        total: total,
        paymentMethod: 'Cash',
      );
      return latin1.decode(bytes, allowInvalid: true);
    }

    test('prints the discount between Subtotal and the deposit', () async {
      final text = await printed(
        subtotal: grossKobo / 100.0,
        discount: discountKobo / 100.0,
        crateDeposit: depositKobo / 100.0,
        total: paidKobo / 100.0,
      );
      expect(text, contains('Subtotal'));
      expect(text, contains('Discount'));
      expect(text, contains('-N500')); // '₦' is transliterated for the printer
      expect(text, contains('Crate Deposit'));
      expect(text.indexOf('Discount'), greaterThan(text.indexOf('Subtotal')));
      expect(
        text.indexOf('Crate Deposit'),
        greaterThan(text.indexOf('Discount')),
      );
      expect(text.indexOf('TOTAL'), greaterThan(text.indexOf('Crate Deposit')));
    });

    test('a reprint prints the same figures as the original', () async {
      final original = await printed(
        subtotal: grossKobo / 100.0,
        discount: discountKobo / 100.0,
        crateDeposit: depositKobo / 100.0,
        total: paidKobo / 100.0,
      );
      final t = receiptTotalsFromOrder(
        totalAmountKobo: paidKobo,
        crateDepositPaidKobo: depositKobo,
        discountKobo: discountKobo,
      );
      final reprint = await printed(
        subtotal: t.subtotalKobo / 100.0,
        discount: t.discountKobo / 100.0,
        crateDeposit: t.depositKobo / 100.0,
        total: t.totalKobo / 100.0,
      );
      for (final row in [
        'Subtotal',
        'Discount',
        'Crate Deposit',
      ]) {
        // The padded two-column row is byte-identical on both copies.
        final line = (String text) {
          final i = text.indexOf(row);
          return text.substring(i, text.indexOf('\n', i));
        };
        expect(line(reprint), line(original), reason: row);
      }
    });

    test('no discount row when nothing was discounted', () async {
      final text = await printed(
        subtotal: grossKobo / 100.0,
        discount: 0,
        crateDeposit: 0,
        total: grossKobo / 100.0,
      );
      expect(text, isNot(contains('Discount')));
    });
  });
}
