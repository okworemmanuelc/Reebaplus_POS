import 'package:flutter_test/flutter_test.dart';
import 'package:reebaplus_pos/shared/services/orders/sale_totals.dart';

/// #571 — the Sale totals module, tested at its interface (no page, no DB).
void main() {
  const crates = [
    SaleCrateLine(manufacturerId: 'a', crates: 2, rateKobo: 150000),
    SaleCrateLine(manufacturerId: 'b', crates: 1, rateKobo: 100000),
  ];

  SaleTotals totals({
    double goods = 5000,
    List<int> discounts = const [],
    List<SaleCrateLine> lines = crates,
    bool walkIn = false,
    bool cash = true,
    bool crateBusiness = true,
    Map<String, int> deposit = const {'a': 300000, 'b': 100000},
  }) => SaleTotals.compute(
    goodsTotalNaira: goods,
    lineDiscountsKobo: discounts,
    crateLines: lines,
    isWalkIn: walkIn,
    isCashTransfer: cash,
    isCrateBusiness: crateBusiness,
    depositByManufacturer: deposit,
  );

  test('walk-in: no deposit even with crates', () {
    final t = totals(walkIn: true);
    expect(t.depositApplies, isFalse);
    expect(t.depositKobo, 0);
    expect(t.payableKobo, 500000);
    expect(t.fullDepositKobo, 400000); // reference only
  });

  test('registered customer paying cash: deposit added to payable', () {
    final t = totals();
    expect(t.depositApplies, isTrue);
    expect(t.goodsKobo, 500000);
    expect(t.depositKobo, 400000);
    expect(t.payableKobo, 900000);
  });

  test('part deposit counts only what was entered', () {
    final t = totals(deposit: const {'a': 100000});
    expect(t.depositKobo, 100000);
    expect(t.fullDepositKobo, 400000);
    expect(t.payableKobo, 600000);
  });

  test('wallet / credit mode: no deposit', () {
    final t = totals(cash: false);
    expect(t.depositApplies, isFalse);
    expect(t.depositKobo, 0);
    expect(t.payableKobo, 500000);
  });

  test('non-crate business: no deposit', () {
    final t = totals(crateBusiness: false);
    expect(t.depositApplies, isFalse);
    expect(t.payableKobo, 500000);
  });

  test('no crate lines: deposit does not apply', () {
    final t = totals(lines: const [], deposit: const {'a': 5});
    expect(t.depositApplies, isFalse);
    expect(t.depositKobo, 0);
    expect(t.fullDepositKobo, 0);
  });

  test('discounts are summed and not deducted again from goods', () {
    final t = totals(goods: 4500, discounts: const [30000, 20000]);
    expect(t.discountKobo, 50000);
    expect(t.goodsKobo, 450000);
    expect(t.payableKobo, 850000);
  });

  test('change due: positive = excess, negative = shortfall, zero = exact', () {
    final t = totals();
    expect(t.changeKobo(1000000), 100000);
    expect(t.changeKobo(900000), 0);
    expect(t.changeKobo(400000), -500000);
  });

  test('fractional crates round half up per brand, then sum', () {
    const lines = [
      SaleCrateLine(manufacturerId: 'a', crates: 0.5, rateKobo: 150001),
      SaleCrateLine(manufacturerId: 'b', crates: 1.5, rateKobo: 3),
    ];
    // 0.5 × 150001 = 75000.5 → 75001; 1.5 × 3 = 4.5 → 5.
    expect(lines[0].fullDepositKobo, 75001);
    expect(lines[1].fullDepositKobo, 5);
    expect(totals(lines: lines).fullDepositKobo, 75006);
  });

  test('goods rounds the naira double to the nearest kobo', () {
    expect(totals(goods: 0.1 + 0.2).goodsKobo, 30); // 30.000000000000004
    expect(totals(goods: 1234.565).goodsKobo, koboFromNaira(1234.565));
    expect(koboFromNaira(10.5), 1050);
  });

  test('SaleCrateLine.fromMap tolerates missing fields', () {
    final l = SaleCrateLine.fromMap({'manufacturerId': 'm', 'crates': 3});
    expect(l.rateKobo, 0);
    expect(l.crates, 3);
    expect(l.fullDepositKobo, 0);
  });

  test('saleLineTotal truncates price × qty (display behaviour kept)', () {
    expect(saleLineTotal(price: 250, qty: 3), 750);
    expect(saleLineTotal(price: 99.99, qty: 2), 199);
  });
}
