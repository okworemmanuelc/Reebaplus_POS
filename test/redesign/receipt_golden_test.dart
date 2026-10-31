// Golden for the phone receipt (#605 slice 1): a sale with discount, VAT,
// deposit, crates and change. Regenerate with:
//
//     flutter test --update-goldens test/redesign/receipt_golden_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';

void main() {
  setUpAll(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDownAll(() => WidgetsApp.debugAllowBannerOverride = true);

  testWidgets('phone receipt golden', (tester) async {
    tester.view.physicalSize = const Size(390, 1060);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: RepaintBoundary(
              key: const Key('receipt'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ReceiptWidget(
                  orderId: 'ORD-000482-A1B2C3',
                  cart: const [
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
                  ],
                  subtotal: 20900,
                  discount: 1000,
                  crateDeposit: 2000,
                  total: 21900,
                  paymentMethod: 'Cash',
                  customerName: 'Chinedu Okafor',
                  cashReceived: 25000,
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
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await expectLater(
      find.byKey(const Key('receipt')),
      matchesGoldenFile('goldens/receipt_phone.png'),
    );
  });
}
