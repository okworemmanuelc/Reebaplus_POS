// Shared sample data for the Cart restyle tests and goldens (#385), as in
// `docs/redesign/mockups/tablet-cart-panel-*.png`: Star Lager ×2, Hero Lager
// ×1, Eva Water ×2.
//
// The lines are Quick-Sale-shaped maps (no product id), so they need no rows in
// the test database and `CartCrateSync` leaves their crate config alone.

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reebaplus_pos/shared/services/cart_service.dart';

/// A mockup line. [crateKobo] > 0 or [crateValueMissing] makes it a crate
/// bottle (unit Bottle, trackEmpties on).
Map<String, dynamic> mockupLine({
  required String name,
  required double price,
  required String subtitle,
  String? category,
  bool bottle = false,
  int crateKobo = 0,
  String? manufacturerId,
}) => {
  'name': name,
  'price': price,
  'subtitle': subtitle,
  'category': category,
  'unit': bottle ? 'Bottle' : 'Pack',
  'trackEmpties': bottle,
  'emptyCrateValueKobo': crateKobo,
  'manufacturerId': manufacturerId,
};

/// Star Lager ×2 (₦9,600), Hero Lager ×1 (₦8,400), Eva Water ×2 (₦2,700).
///
/// With [crates], both lagers are crate bottles: Star Lager under
/// [starManufacturerId] at ₦1,000 a crate, Hero Lager with no crate value
/// (the "No crate value set" warning). Without it, no line tracks empties.
void fillMockupCart(
  CartService cart, {
  bool crates = false,
  String? starManufacturerId,
}) {
  cart.addItem(
    mockupLine(
      name: 'Star Lager',
      price: 9600,
      subtitle: '60cl · Crate of 12',
      category: 'Beer',
      bottle: crates,
      crateKobo: crates ? 100000 : 0,
      manufacturerId: crates ? starManufacturerId : null,
    ),
    qty: 2,
  );
  cart.addItem(
    mockupLine(
      name: 'Hero Lager',
      price: 8400,
      subtitle: '60cl · Crate of 12',
      category: 'Beer',
      bottle: crates,
    ),
  );
  cart.addItem(
    mockupLine(
      name: 'Eva Water',
      price: 2700,
      subtitle: '75cl · Pack of 12',
      category: 'Water',
    ),
    qty: 2,
  );
}

/// Asserts [finder]'s text is drawn whole: not ellipsized, not clipped and not
/// scaled down (e.g. by a `FittedBox`, which turns a squeezed title into a
/// dot). With [allowWrap] it may wrap onto more lines (every word still
/// shows); otherwise it must sit on one line.
void expectTextWhole(
  WidgetTester tester,
  Finder finder, {
  String? at,
  bool allowWrap = false,
}) {
  final p = tester.renderObject<RenderParagraph>(finder);
  final label = p.text.toPlainText();
  final where = at == null ? '' : ' at $at';
  expect(p.didExceedMaxLines, isFalse, reason: '"$label" was cut short$where');
  final intrinsic = p.getMaxIntrinsicWidth(double.infinity);
  expect(
    allowWrap || p.size.width + 0.5 >= intrinsic,
    isTrue,
    reason: '"$label" got ${p.size.width} of the $intrinsic it needs$where',
  );
  final onScreen = tester.getRect(finder);
  expect(
    (onScreen.width - p.size.width).abs() < 0.5,
    isTrue,
    reason:
        '"$label" was scaled to ${onScreen.width} from ${p.size.width}$where',
  );
}
