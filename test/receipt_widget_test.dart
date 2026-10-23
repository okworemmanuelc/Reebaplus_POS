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

  Widget host({
    required bool showWalletInfo,
    double? walletBalance,
    String? storeAddress,
  }) {
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
            storeAddress: storeAddress,
            tracksCrates: false,
          ),
        ),
      ),
    );
  }

  testWidgets('credits info is hidden by default (checkbox off)', (tester) async {
    await tester.pumpWidget(host(showWalletInfo: false, walletBalance: -500));
    expect(find.textContaining('Credits Balance'), findsNothing);
  });

  testWidgets('credits info shows when ticked, with negative amount for debt', (tester) async {
    await tester.pumpWidget(host(showWalletInfo: true, walletBalance: -500));
    expect(find.textContaining('Credits Balance'), findsOneWidget);
    expect(find.textContaining('-₦500'), findsOneWidget);
  });

  testWidgets('credits info shows positive amount for credit',
      (tester) async {
    await tester.pumpWidget(host(showWalletInfo: true, walletBalance: 1500));
    expect(find.textContaining('Credits Balance'), findsOneWidget);
    expect(find.textContaining('₦1,500'), findsOneWidget);
  });

  testWidgets('ticked but null balance renders nothing', (tester) async {
    await tester.pumpWidget(host(showWalletInfo: true, walletBalance: null));
    expect(find.textContaining('Credits Balance'), findsNothing);
  });

  testWidgets('store address shows and the old "Branch:" line is gone (§15.1)',
      (tester) async {
    await tester.pumpWidget(host(
      showWalletInfo: false,
      storeAddress: '14 Market Road, Lagos Island',
    ));
    expect(find.text('14 Market Road, Lagos Island'), findsOneWidget);
    expect(find.textContaining('Branch:'), findsNothing);
  });

  testWidgets('no store address line when storeAddress is null', (tester) async {
    await tester.pumpWidget(host(showWalletInfo: false, storeAddress: null));
    expect(find.textContaining('Branch:'), findsNothing);
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

  testWidgets('walk-in customer is not shown on receipt', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReceiptWidget(
            orderId: 'ORD-000002',
            cart: cart,
            subtotal: 2000,
            crateDeposit: 0,
            total: 2000,
            paymentMethod: 'Full Cash / Card',
            customerName: 'Walk-in Customer',
            showWalletInfo: false,
            tracksCrates: false,
          ),
        ),
      ),
    ));
    expect(find.textContaining('Walk-in Customer'), findsNothing);
  });

  testWidgets('null/empty customer is not shown on receipt', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReceiptWidget(
            orderId: 'ORD-000002',
            cart: cart,
            subtotal: 2000,
            crateDeposit: 0,
            total: 2000,
            paymentMethod: 'Full Cash / Card',
            customerName: '',
            showWalletInfo: false,
            tracksCrates: false,
          ),
        ),
      ),
    ));
    expect(find.textContaining('Walk-in Customer'), findsNothing);
  });

  // #487: "Bottle Crate" only on a receipt from a shop that counts empty
  // crates; every other shop shows its Bottle product as "Bottle".
  Widget bottleReceipt({required bool tracksCrates}) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ReceiptWidget(
          orderId: 'ORD-000003',
          cart: const [
            {'name': 'Cough Syrup', 'unit': 'Bottle', 'price': 500.0, 'qty': 1.0},
          ],
          subtotal: 500,
          crateDeposit: 0,
          total: 500,
          paymentMethod: 'Full Cash / Card',
          tracksCrates: tracksCrates,
        ),
      ),
    ),
  );

  testWidgets('a shop that does not count crates shows "Bottle"', (
    tester,
  ) async {
    await tester.pumpWidget(bottleReceipt(tracksCrates: false));
    expect(find.text('Bottle Cough Syrup  ×1.0'), findsOneWidget);
    expect(find.textContaining('Bottle Crate'), findsNothing);
  });

  testWidgets('a shop that counts crates shows "Bottle Crate"', (
    tester,
  ) async {
    await tester.pumpWidget(bottleReceipt(tracksCrates: true));
    expect(find.text('Bottle Crate Cough Syrup  ×1.0'), findsOneWidget);
  });
}
