import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/core/crates/crate_bearing_sale.dart';

/// PRD #337 — the pure crate-bearing-sale rule (§13.4 / rule #13).
void main() {
  const bottle = (unit: 'bottle', trackEmpties: true);
  const plain = (unit: 'Piece', trackEmpties: false);

  bool rule({
    String? type = 'Bar',
    bool? tracks = true,
    List<CrateProductFacts> products = const [bottle],
  }) => isCrateBearingSale(
    businessType: type,
    tracksEmptyCrates: tracks,
    products: products,
  );

  test('crate business + tracked bottle → crate-bearing', () {
    expect(rule(), isTrue);
  });

  test('unit is compared case-insensitively', () {
    expect(rule(products: [(unit: 'Bottle', trackEmpties: true)]), isTrue);
    expect(rule(products: [(unit: 'BOTTLE', trackEmpties: true)]), isTrue);
  });

  test('mixed cart → crate-bearing (the whole order waits)', () {
    expect(rule(products: [plain, bottle]), isTrue);
  });

  test('bottle with trackEmpties off → not crate-bearing', () {
    expect(rule(products: [(unit: 'bottle', trackEmpties: false)]), isFalse);
  });

  test('tracked flag on a non-bottle unit → not crate-bearing', () {
    expect(rule(products: [(unit: 'Piece', trackEmpties: true)]), isFalse);
    expect(rule(products: [(unit: null, trackEmpties: true)]), isFalse);
  });

  test('no products (Quick Sale only) → not crate-bearing', () {
    expect(rule(products: const []), isFalse);
  });

  test('non-crate business type → not crate-bearing, even with a bottle', () {
    expect(rule(type: 'Supermarket'), isFalse);
    expect(rule(type: null), isFalse);
  });

  test('crate business with tracksEmptyCrates off → not crate-bearing', () {
    expect(rule(tracks: false), isFalse);
  });

  test('tracksEmptyCrates null is treated as on', () {
    expect(rule(tracks: null), isTrue);
  });
}
