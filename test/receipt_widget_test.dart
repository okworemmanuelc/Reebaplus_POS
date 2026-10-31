// receipt_widget_test.dart
//
// Covers the §14.1 / §15.1 "Add wallet info to receipt" gate and the §15.3
// QR-code removal (CLAUDE.md hard rule #8). ReceiptWidget is a pure
// StatelessWidget, so it tests without the provider/DB harness that skips the
// CheckoutPage widget test.

import 'dart:convert';
import 'dart:io';

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
    expect(find.textContaining('Credits balance'), findsNothing);
  });

  testWidgets('credits info shows when ticked, with negative amount for debt', (tester) async {
    await tester.pumpWidget(host(showWalletInfo: true, walletBalance: -500));
    expect(find.textContaining('Credits balance'), findsOneWidget);
    expect(find.textContaining('-₦500'), findsOneWidget);
  });

  testWidgets('credits info shows positive amount for credit',
      (tester) async {
    await tester.pumpWidget(host(showWalletInfo: true, walletBalance: 1500));
    expect(find.textContaining('Credits balance'), findsOneWidget);
    expect(find.textContaining('₦1,500'), findsOneWidget);
  });

  testWidgets('ticked but null balance renders nothing', (tester) async {
    await tester.pumpWidget(host(showWalletInfo: true, walletBalance: null));
    expect(find.textContaining('Credits balance'), findsNothing);
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
    expect(find.text('Bottle Cough Syrup'), findsOneWidget);
    expect(find.textContaining('Bottle Crate'), findsNothing);
  });

  testWidgets('a shop that counts crates shows "Bottle Crate"', (
    tester,
  ) async {
    await tester.pumpWidget(bottleReceipt(tracksCrates: true));
    expect(find.text('Bottle Crate Cough Syrup'), findsOneWidget);
  });

  Widget hostWith({
    String? customerName,
    double total = 2000,
    double? cashReceived,
    String paymentMethod = 'Cash',
    double crateDeposit = 0,
    List<Map<String, dynamic>>? items,
    String? logoPath,
    int? vatRateBps,
    double? vatIncluded,
    Map<String, double>? owed,
    double width = 390,
    String? businessName,
  }) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: width,
          child: ReceiptWidget(
            orderId: 'ORD-000010',
            cart: items ?? cart,
            subtotal: total,
            crateDeposit: crateDeposit,
            total: total,
            paymentMethod: paymentMethod,
            customerName: customerName,
            cashReceived: cashReceived,
            logoPath: logoPath,
            vatRateBps: vatRateBps,
            vatIncluded: vatIncluded,
            cratesOwedByManufacturer: owed,
            manufacturerNames: const {'m1': 'Lager Beer'},
            businessName: businessName,
            tracksCrates: false,
          ),
        ),
      ),
    ),
  );

  final crateItems = <Map<String, dynamic>>[
    {
      'name': 'Lager',
      'unit': 'Bottle',
      'price': 1000.0,
      'qty': 2.0,
      'trackEmpties': true,
      'manufacturerId': 'm1',
    },
  ];

  testWidgets('no logo renders no logo box', (tester) async {
    await tester.pumpWidget(hostWith());
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a missing logo file renders no box', (tester) async {
    await tester.pumpWidget(hostWith(logoPath: '/nope/missing.png'));
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('logo present renders the outlined box with the image',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('rcpt');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/l.png')
      ..writeAsBytesSync(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='));
    await tester.pumpWidget(hostWith(logoPath: f.path));
    expect(find.byType(Image), findsOneWidget);
    final img = tester.widget<Image>(find.byType(Image));
    expect(img.fit, BoxFit.contain);
  });

  testWidgets('walk-in hides the Customer detail; a named customer shows it',
      (tester) async {
    await tester.pumpWidget(hostWith(customerName: 'WALK-IN CUSTOMER'));
    expect(find.text('Customer'), findsNothing);
    await tester.pumpWidget(hostWith(customerName: 'ada obi'));
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Ada Obi'), findsOneWidget);
  });

  testWidgets('overpayment shows Change, not Balance owed', (tester) async {
    await tester.pumpWidget(hostWith(total: 2000, cashReceived: 2500));
    expect(find.text('Change'), findsOneWidget);
    expect(find.text('₦500'), findsOneWidget);
    expect(find.text('Balance owed'), findsNothing);
  });

  testWidgets('short payment shows Balance owed, not Change', (tester) async {
    await tester.pumpWidget(hostWith(total: 2000, cashReceived: 1500));
    expect(find.text('Balance owed'), findsOneWidget);
    expect(find.text('Change'), findsNothing);
  });

  testWidgets('exact payment shows neither', (tester) async {
    await tester.pumpWidget(hostWith(total: 2000, cashReceived: 2000));
    expect(find.text('Change'), findsNothing);
    expect(find.text('Balance owed'), findsNothing);
  });

  testWidgets('wallet method reads Credit', (tester) async {
    await tester.pumpWidget(hostWith(paymentMethod: 'Wallet Payment'));
    expect(find.text('Credit'), findsOneWidget);
  });

  testWidgets('VAT row only when provided', (tester) async {
    await tester.pumpWidget(hostWith());
    expect(find.textContaining('VAT'), findsNothing);
    await tester.pumpWidget(hostWith(vatRateBps: 750, vatIncluded: 150));
    expect(find.text('VAT (7.5%) included'), findsOneWidget);
    expect(find.text('₦150'), findsOneWidget);
  });

  testWidgets('crate panel: deposit note only when deposit > 0, Owed fallback',
      (tester) async {
    await tester.pumpWidget(hostWith(items: crateItems));
    expect(find.text('Empty Crates'), findsOneWidget);
    expect(find.textContaining('deposit is refunded'), findsNothing);
    await tester.pumpWidget(hostWith(
      items: crateItems,
      crateDeposit: 300,
      owed: const {'m1': 5},
    ));
    expect(find.textContaining('₦300 deposit is refunded'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('no crate panel without crate lines', (tester) async {
    await tester.pumpWidget(hostWith());
    expect(find.text('Empty Crates'), findsNothing);
  });

  testWidgets('long names and amounts do not overflow at 320px, 1.15 scale',
      (tester) async {
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(
        size: Size(320, 800),
        textScaler: TextScaler.linear(1.15),
      ),
      child: hostWith(
        width: 320,
        total: 123456789,
        businessName: 'A Really Long Business Name Supermarket And Sons Ltd',
        items: [
          {
            'name': 'An extremely long product name that must wrap nicely',
            'price': 99999999.0,
            'qty': 1.0,
          },
        ],
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
