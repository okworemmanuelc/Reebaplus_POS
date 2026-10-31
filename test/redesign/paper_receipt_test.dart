// PaperReceipt (#605 slice 2): goldens for 58mm + 80mm and behaviour rules.
// Regenerate goldens with:
//
//     flutter test --update-goldens test/redesign/paper_receipt_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_paper_size.dart';
import 'package:reebaplus_pos/features/pos/widgets/paper_receipt.dart';

const _cart = <Map<String, dynamic>>[
  {'name': 'Spaghetti 500g', 'price': 1200.0, 'qty': 4.0},
  {'name': 'Vegetable Oil 1L', 'price': 3500.0, 'qty': 1.0},
  {
    'name': 'Lager Beer',
    'size': '60cl',
    'unit': 'Bottle',
    'price': 9600.0,
    'qty': 1.0,
    'trackEmpties': true,
    'manufacturerId': 'm1',
  },
  {'name': 'Malt Drink 33cl', 'price': 500.0, 'qty': 6.0},
];

PaperReceipt _receipt(
  ReceiptPaperSize size, {
  List<Map<String, dynamic>> cart = _cart,
  String? customerName = 'Chinedu Okafor',
  double? cashReceived = 25000,
  double total = 21900,
}) =>
    PaperReceipt(
      paperSize: size,
      orderId: 'ORD-000482-A1B2C3',
      cart: cart,
      subtotal: 20900,
      discount: 1000,
      crateDeposit: 2000,
      total: total,
      paymentMethod: 'Cash',
      customerName: customerName,
      cashReceived: cashReceived,
      businessName: 'FreshMart Supermarket',
      storeAddress: 'Plot 14, Market Road, Wuse II, Abuja',
      businessPhone: '0803 123 4567',
      businessEmail: 'hello@freshmart.ng',
      cashierName: 'Amina Bello',
      saleDate: DateTime(2026, 10, 31, 16, 52),
      vatRateBps: 750,
      vatIncluded: 1342.5,
      manufacturerNames: const {'m1': 'Lager Beer 60cl'},
      tracksCrates: false,
    );

Future<void> _pump(WidgetTester tester, Widget w) async {
  tester.view.physicalSize = const Size(600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(key: const Key('receipt'), child: w),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  testWidgets('58mm golden', (tester) async {
    await _pump(tester, _receipt(ReceiptPaperSize.mm58));
    await expectLater(find.byKey(const Key('receipt')),
        matchesGoldenFile('goldens/paper_receipt_58.png'));
  });

  testWidgets('80mm golden', (tester) async {
    await _pump(tester, _receipt(ReceiptPaperSize.mm80));
    await expectLater(find.byKey(const Key('receipt')),
        matchesGoldenFile('goldens/paper_receipt_80.png'));
  });

  testWidgets('logical width is half the raster width', (tester) async {
    await _pump(tester, _receipt(ReceiptPaperSize.mm58));
    expect(tester.getSize(find.byType(PaperReceipt)).width, 192);
    await _pump(tester, _receipt(ReceiptPaperSize.mm80));
    expect(tester.getSize(find.byType(PaperReceipt)).width, 288);
  });

  testWidgets('no logo: no outlined box', (tester) async {
    await _pump(tester, _receipt(ReceiptPaperSize.mm58));
    expect(find.byType(Image), findsNothing);
    final boxed = find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).borderRadius ==
            BorderRadius.circular(8));
    expect(boxed, findsNothing);
  });

  testWidgets('walk-in hides Customer', (tester) async {
    await _pump(
        tester, _receipt(ReceiptPaperSize.mm58, customerName: 'Walk-in Customer'));
    expect(find.text('Customer'), findsNothing);
    expect(find.text('Cashier'), findsOneWidget);
  });

  testWidgets('short payment shows Balance owed, over-payment Change',
      (tester) async {
    await _pump(
        tester, _receipt(ReceiptPaperSize.mm58, cashReceived: 10000));
    expect(find.text('Balance owed'), findsOneWidget);
    expect(find.text('Change'), findsNothing);
    await _pump(tester, _receipt(ReceiptPaperSize.mm58));
    expect(find.text('Change'), findsOneWidget);
    expect(find.text('Balance owed'), findsNothing);
  });

  testWidgets('80mm long name wraps without overflow', (tester) async {
    await _pump(
      tester,
      _receipt(ReceiptPaperSize.mm80, cart: const [
        {
          'name': 'Extra Long Premium Imported Lager Beer Special Edition',
          'size': '60cl (crate of 12)',
          'price': 9600.0,
          'qty': 1.0,
        },
      ]),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('business name is capitalised', (tester) async {
    await _pump(tester, _receipt(ReceiptPaperSize.mm80));
    expect(find.text('FRESHMART SUPERMARKET'), findsOneWidget);
  });
}
