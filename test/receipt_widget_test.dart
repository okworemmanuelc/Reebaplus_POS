// receipt_widget_test.dart
//
// Covers the §14.1 / §15.1 "Add wallet info to receipt" gate and the §15.3
// QR-code removal (CLAUDE.md hard rule #8). ReceiptWidget is a pure
// StatelessWidget, so it tests without the provider/DB harness that skips the
// CheckoutPage widget test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';

void main() {
  final cart = [
    {'name': 'Star Lager', 'price': 1000.0, 'qty': 2.0},
  ];

  Widget host({required bool showWalletInfo, double? walletBalance}) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReceiptWidget(
            orderId: 'ORD-000002',
            cart: cart,
            subtotal: 2000,
            crateDeposit: 0,
            total: 2000,
            paymentMethod: 'Full Cash / Card',
            customerName: 'Ada Obi',
            walletBalance: walletBalance,
            showWalletInfo: showWalletInfo,
          ),
        ),
      ),
    );
  }

  testWidgets('wallet info is hidden by default (checkbox off)', (tester) async {
    await tester.pumpWidget(host(showWalletInfo: false, walletBalance: -500));
    expect(find.textContaining('Wallet Balance'), findsNothing);
  });

  testWidgets('wallet info shows when ticked, with debt tag', (tester) async {
    await tester.pumpWidget(host(showWalletInfo: true, walletBalance: -500));
    expect(find.textContaining('Wallet Balance'), findsOneWidget);
    expect(find.textContaining('(debt)'), findsOneWidget);
  });

  testWidgets('wallet info shows credit tag for positive balance',
      (tester) async {
    await tester.pumpWidget(host(showWalletInfo: true, walletBalance: 1500));
    expect(find.textContaining('(credit)'), findsOneWidget);
  });

  testWidgets('ticked but null balance renders nothing', (tester) async {
    await tester.pumpWidget(host(showWalletInfo: true, walletBalance: null));
    expect(find.textContaining('Wallet Balance'), findsNothing);
  });

  testWidgets('QR code is removed (§15.3 / hard rule #8)', (tester) async {
    await tester.pumpWidget(host(showWalletInfo: false, walletBalance: null));
    // The QR widget came from package:barcode_widget. Its type name must not
    // appear anywhere in the receipt's widget tree.
    final hasBarcode = tester
        .allWidgets
        .any((w) => w.runtimeType.toString().contains('Barcode'));
    expect(hasBarcode, isFalse, reason: 'QR/barcode must not be on the receipt');
  });
}
