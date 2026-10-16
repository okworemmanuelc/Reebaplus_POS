// Shared Checkout set-up for the restyle tests and goldens (#393): Checkout
// pumped on its own with the Cart's sample lines, as `CartScreen._openCheckout`
// builds it (the money pin test drives the real Cart → Checkout hand-off).
//
// Sample data only: Star Lager ×2 (Nigerian Breweries, ₦1,000 a crate) with a
// ₦500 discount, Hero Lager ×1 (Hero Breweries, no crate value), Eva Water ×2.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/features/customers/data/models/customer.dart';
import 'package:reebaplus_pos/features/pos/screens/checkout_page.dart';

import '../helpers/screen_harness.dart';

final checkoutCustomer = Customer(
  id: 'cust-1',
  name: 'Chinedu Okafor',
  addressText: '',
  googleMapsLocation: '',
  walletLimitKobo: 5000000,
);

/// The cart lines Checkout receives (largest quantity first, as the Cart
/// sorts them for checkout).
List<Map<String, dynamic>> checkoutLines() => [
  {
    'name': 'Star Lager',
    'price': 9600.0,
    'qty': 2.0,
    'subtitle': '60cl',
    'category': 'Beer',
    'unit': 'Bottle',
    'discountKobo': 50000,
  },
  {
    'name': 'Eva Water',
    'price': 2700.0,
    'qty': 2.0,
    'subtitle': '75cl',
    'category': 'Water',
    'unit': 'Pack',
  },
  {
    'name': 'Hero Lager',
    'price': 8400.0,
    'qty': 1.0,
    'subtitle': '60cl',
    'category': 'Beer',
    'unit': 'Bottle',
  },
];

/// Per-brand crate lines as the Cart's quote passes them.
List<Map<String, dynamic>> checkoutCrateLines() => const [
  {
    'manufacturerId': 'mfr-hero',
    'name': 'Hero Breweries',
    'crates': 1.0,
    'rateKobo': 0,
  },
  {
    'manufacturerId': 'mfr-nb',
    'name': 'Nigerian Breweries',
    'crates': 2.0,
    'rateKobo': 100000,
  },
];

/// Pumps Checkout at [size]. A registered [customer] with [creditKobo]; crate
/// lines only with [crates] (pass a crate business to the environment), or
/// exactly [crateLines] when given.
/// Under 600dp Checkout is a pushed page (no bottom bar); at 600dp+ the rail
/// stays beside it.
Future<BuildContext> pumpCheckout(
  WidgetTester tester, {
  required ScreenTestEnvironment env,
  Size size = const Size(390, 844),
  EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 48),
  EdgeInsets viewInsets = EdgeInsets.zero,
  TextScaler? textScaler,
  Brightness brightness = Brightness.light,
  Customer? customer,
  int creditKobo = 0,
  bool crates = false,
  List<Map<String, dynamic>>? crateLines,
  Set<String> grantedKeys = const {'sales.make'},
}) async {
  final context = await pumpScreen(
    tester,
    env: env,
    size: size,
    padding: padding,
    viewInsets: viewInsets,
    textScaler: textScaler,
    bottomNavHeight: size.width >= 600 ? kBottomNavBodyHeight : 0,
    theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
    grantedKeys: grantedKeys,
    // Checkout reads the business type once (`ref.read`); in the app it is
    // loaded long before a sale. Wait for it here the same way.
    screen: Consumer(
      builder: (context, ref, _) => ref.watch(currentBusinessProvider) == null
          ? const SizedBox.shrink()
          : CheckoutPage(
              cart: checkoutLines(),
              subtotal: 33000,
              total: 32500,
              crateLines:
                  crateLines ?? (crates ? checkoutCrateLines() : const []),
              customer: customer,
            ),
    ),
    overrides: [
      creditBalancesKoboProvider.overrideWith(
        (ref) => Stream.value({'cust-1': creditKobo}),
      ),
    ],
    settle: false,
  );
  await settleCheckout(tester);
  return context;
}

Future<void> settleCheckout(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 250));
  }
}
