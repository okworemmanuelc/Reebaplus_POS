/// The Golden-Scenario Suite model + comparator (ADR 0009, issue #43).
///
/// One set of fixtures (input state → expected resulting rows) drives BOTH
/// implementations of the cash/transfer checkout money rule:
///   * the Dart DAO path (mobile)      — test/golden/dart_dao_golden_test.dart
///   * the SQL `checkout_order` RPC     — test/integration/rpcs/checkout_order_golden_test.dart
/// Each runner seeds the fixture, performs its own checkout, collects the
/// resulting rows into a [CheckoutOutcome], and calls [expectGolden]. Any drift
/// between the two implementations fails the build — the anti-divergence
/// mechanism that keeps the money math identical across clients.
///
/// The order NUMBER scheme is deliberately divergent per client (mobile
/// `ORD-…`, web `WEB-…`, both collision-proof against the other), so the
/// comparator asserts each runner's own [orderNumberScheme] regex, never
/// equality. Everything else — totals, per-line FIFO COGS, batch remainders,
/// stock levels, the scalar cost cache, revenue status — must match exactly.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ─── Fixtures (input) ────────────────────────────────────────────────────────

class FxProduct {
  final String key;
  final String name;
  final int unitPriceKobo;
  final int scalarCostKobo;

  /// Crate fixtures only (Slice 4, #45): the manufacturer whose returnable
  /// empties this product carries. When set, the runners seed the product as a
  /// crate-eligible bottle (unit 'Bottle', track_empties on) with this
  /// manufacturer; null (the cash/credit fixtures) ⇒ a plain non-crate product.
  final String? manufacturerKey;
  FxProduct(this.key, this.name, this.unitPriceKobo, this.scalarCostKobo,
      {this.manufacturerKey});
}

/// A manufacturer with a per-crate deposit rate (Manufacturers.depositAmountKobo).
/// The crate scenarios snapshot this rate onto order_crate_lines at sale time.
class FxManufacturer {
  final String key;
  final String name;
  final int depositRateKobo;
  FxManufacturer(this.key, this.name, this.depositRateKobo);
}

class FxInventory {
  final String productKey;
  final int quantity;
  FxInventory(this.productKey, this.quantity);
}

class FxBatch {
  final String productKey;
  final int qty;
  final int costKobo;

  /// Date-only string, e.g. "2026-01-01" — unique per product within a fixture,
  /// so it doubles as the batch's stable key for the remainder assertion.
  final String receivedAt;
  FxBatch(this.productKey, this.qty, this.costKobo, this.receivedAt);

  DateTime get receivedAtUtc {
    final parts = receivedAt.split('-').map(int.parse).toList();
    return DateTime.utc(parts[0], parts[1], parts[2]);
  }
}

class FxCheckoutLine {
  final String productKey;
  final int quantity;
  FxCheckoutLine(this.productKey, this.quantity);
}

class FxCheckout {
  final String paymentMethod; // 'cash' | 'transfer' | 'credit' | 'wallet'
  final int discountKobo;
  final int amountPaidKobo;
  final List<FxCheckoutLine> items;
  FxCheckout(this.paymentMethod, this.discountKobo, this.amountPaidKobo,
      this.items);
}

/// A registered customer attached to a credit/wallet scenario (Slice 3, #44).
/// [openingBalanceKobo] is seeded as one `topup_cash` credit BEFORE the sale, so
/// a Pay-with-Credit draw has an existing balance to spend. Absent ⇒ walk-in.
class FxCustomer {
  final int openingBalanceKobo;
  final int debtLimitKobo;
  FxCustomer(this.openingBalanceKobo, this.debtLimitKobo);
}

// ─── Expected (output) ───────────────────────────────────────────────────────

class ExpectedOrder {
  final String status;
  final String paymentType;
  final int totalAmountKobo;
  final int discountKobo;
  final int netAmountKobo;
  final int amountPaidKobo;
  final bool completedAtNull;
  ExpectedOrder(Map<String, dynamic> j)
      : status = j['status'] as String,
        paymentType = j['payment_type'] as String,
        totalAmountKobo = j['total_amount_kobo'] as int,
        discountKobo = j['discount_kobo'] as int,
        netAmountKobo = j['net_amount_kobo'] as int,
        amountPaidKobo = j['amount_paid_kobo'] as int,
        completedAtNull = j['completed_at_null'] as bool;
}

/// A per-line money tuple, order-independent — the runners may return lines in
/// any order, so [expectGolden] compares the multiset of these.
class ExpectedItem {
  final String productKey;
  final int quantity;
  final int unitPriceKobo;
  final int totalKobo;
  final int buyingPriceKobo;
  ExpectedItem(Map<String, dynamic> j)
      : productKey = j['product'] as String,
        quantity = j['quantity'] as int,
        unitPriceKobo = j['unit_price_kobo'] as int,
        totalKobo = j['total_kobo'] as int,
        buyingPriceKobo = j['buying_price_kobo'] as int;

  String get signature =>
      '$productKey|$quantity|$unitPriceKobo|$totalKobo|$buyingPriceKobo';
}

class ExpectedPayment {
  final String method;
  final int amountKobo;
  ExpectedPayment(Map<String, dynamic> j)
      : method = j['method'] as String,
        amountKobo = j['amount_kobo'] as int;
}

/// One wallet ledger leg the checkout is expected to post (Slice 3). Compared as
/// a multiset by [signature] — the two runners may return legs in any order. The
/// seeded opening-balance leg is excluded (runners collect only legs whose
/// order_id is this sale's).
class ExpectedWalletLeg {
  final String referenceType;
  final int signedAmountKobo;
  ExpectedWalletLeg(Map<String, dynamic> j)
      : referenceType = j['reference_type'] as String,
        signedAmountKobo = j['signed_amount_kobo'] as int;

  String get signature => '$referenceType|$signedAmountKobo';
}

/// One expected order_crate_lines row (Slice 4, #45): the crates the customer
/// took for a manufacturer, the deposit RATE snapshot (from the manufacturer),
/// and the deposit PAID (0 on the web crate-track path). Keyed by manufacturer.
class ExpectedCrateLine {
  final int cratesTaken;
  final int depositRateKobo;
  final int depositPaidKobo;
  ExpectedCrateLine(Map<String, dynamic> j)
      : cratesTaken = j['crates_taken'] as int,
        depositRateKobo = j['deposit_rate_kobo'] as int,
        depositPaidKobo = j['deposit_paid_kobo'] as int;

  String get signature => '$cratesTaken|$depositRateKobo|$depositPaidKobo';
}

class GoldenScenario {
  final String name;

  /// The attached registered customer, or null for a walk-in cash sale (the
  /// Slice 2 fixtures). When set, the runners seed a customer + wallet and assert
  /// the wallet legs + derived balance.
  final FxCustomer? customer;

  /// Crate fixtures (Slice 4, #45). [businessType] drives isCrateBusiness and
  /// [tracksEmptyCrates] the opt-in — together the crate gate. [manufacturers]
  /// carry the per-crate deposit rates. Cash/credit fixtures leave these at the
  /// non-crate defaults (null type ⇒ crate block never fires).
  final String? businessType;
  final bool tracksEmptyCrates;
  final List<FxManufacturer> manufacturers;
  final List<FxProduct> products;
  final List<FxInventory> inventory;
  final List<FxBatch> batches;
  final FxCheckout checkout;
  final ExpectedOrder expectedOrder;
  final List<ExpectedItem> expectedItems;

  /// key "productKey|receivedAt" → expected qty_remaining.
  final Map<String, int> expectedBatchRemaining;

  /// productKey → expected on-hand after the sale.
  final Map<String, int> expectedInventory;

  /// productKey → expected recomputed scalar buying_price_kobo cache.
  final Map<String, int> expectedScalarCost;

  /// The expected cash payment row, or null when the sale settled no cash (a
  /// pay-with-credit / pure credit sale posts no payment_transactions row).
  final ExpectedPayment? expectedPayment;

  /// The wallet legs the sale is expected to post (empty for a walk-in).
  final List<ExpectedWalletLeg> expectedWalletLegs;

  /// The customer's derived spendable balance after the sale, or null (walk-in).
  final int? expectedCustomerBalanceAfterKobo;

  /// Crate expectations (Slice 4, #45), all keyed by manufacturer (a scenario has
  /// one customer). Empty for cash/credit fixtures — the runners collect empty
  /// maps too, so the assertion is a no-op there.
  ///   manufacturerKey → expected order_crate_lines row.
  final Map<String, ExpectedCrateLine> expectedCrateLines;

  /// manufacturerKey → expected summed 'issued' crate_ledger quantity_delta.
  final Map<String, int> expectedCrateLedgerIssued;

  /// manufacturerKey → expected customer_crate_balances.balance after the sale.
  final Map<String, int> expectedCrateBalances;

  GoldenScenario._({
    required this.name,
    required this.customer,
    required this.businessType,
    required this.tracksEmptyCrates,
    required this.manufacturers,
    required this.products,
    required this.inventory,
    required this.batches,
    required this.checkout,
    required this.expectedOrder,
    required this.expectedItems,
    required this.expectedBatchRemaining,
    required this.expectedInventory,
    required this.expectedScalarCost,
    required this.expectedPayment,
    required this.expectedWalletLegs,
    required this.expectedCustomerBalanceAfterKobo,
    required this.expectedCrateLines,
    required this.expectedCrateLedgerIssued,
    required this.expectedCrateBalances,
  });

  FxProduct product(String key) => products.firstWhere((p) => p.key == key);

  factory GoldenScenario._fromJson(Map<String, dynamic> j) {
    final exp = j['expected'] as Map<String, dynamic>;

    final batchRemaining = <String, int>{};
    for (final b in (exp['batches_remaining'] as List)) {
      final m = b as Map<String, dynamic>;
      batchRemaining['${m['product']}|${m['received_at']}'] =
          m['qty_remaining'] as int;
    }
    final inv = <String, int>{};
    for (final r in (exp['inventory_after'] as List)) {
      final m = r as Map<String, dynamic>;
      inv[m['product'] as String] = m['quantity'] as int;
    }
    final scalar = <String, int>{};
    for (final r in (exp['product_scalar_cost'] as List)) {
      final m = r as Map<String, dynamic>;
      scalar[m['product'] as String] = m['buying_price_kobo'] as int;
    }

    final customerJson = j['customer'] as Map<String, dynamic>?;
    final paymentJson = exp['payment'] as Map<String, dynamic>?;

    final crateLines = <String, ExpectedCrateLine>{};
    for (final r in ((exp['crate_lines'] as List?) ?? const [])) {
      final m = r as Map<String, dynamic>;
      crateLines[m['manufacturer'] as String] = ExpectedCrateLine(m);
    }
    final crateLedger = <String, int>{};
    for (final r in ((exp['crate_ledger'] as List?) ?? const [])) {
      final m = r as Map<String, dynamic>;
      crateLedger[m['manufacturer'] as String] = m['quantity_delta'] as int;
    }
    final crateBalances = <String, int>{};
    for (final r in ((exp['crate_balances'] as List?) ?? const [])) {
      final m = r as Map<String, dynamic>;
      crateBalances[m['manufacturer'] as String] = m['balance'] as int;
    }

    return GoldenScenario._(
      name: j['name'] as String,
      customer: customerJson == null
          ? null
          : FxCustomer(customerJson['opening_balance_kobo'] as int,
              customerJson['debt_limit_kobo'] as int),
      businessType: j['business_type'] as String?,
      tracksEmptyCrates: j['tracks_empty_crates'] as bool? ?? true,
      manufacturers: ((j['manufacturers'] as List?) ?? const [])
          .map((m) => FxManufacturer(m['key'] as String, m['name'] as String,
              m['deposit_rate_kobo'] as int))
          .toList(),
      products: (j['products'] as List)
          .map((p) => FxProduct(p['key'] as String, p['name'] as String,
              p['unit_price_kobo'] as int, p['scalar_cost_kobo'] as int,
              manufacturerKey: p['manufacturer'] as String?))
          .toList(),
      inventory: (j['inventory'] as List)
          .map((r) =>
              FxInventory(r['product'] as String, r['quantity'] as int))
          .toList(),
      batches: (j['batches'] as List)
          .map((b) => FxBatch(b['product'] as String, b['qty'] as int,
              b['cost_kobo'] as int, b['received_at'] as String))
          .toList(),
      checkout: FxCheckout(
        j['checkout']['payment_method'] as String,
        j['checkout']['discount_kobo'] as int,
        j['checkout']['amount_paid_kobo'] as int,
        (j['checkout']['items'] as List)
            .map((i) =>
                FxCheckoutLine(i['product'] as String, i['quantity'] as int))
            .toList(),
      ),
      expectedOrder: ExpectedOrder(exp['order'] as Map<String, dynamic>),
      expectedItems: (exp['items'] as List)
          .map((i) => ExpectedItem(i as Map<String, dynamic>))
          .toList(),
      expectedBatchRemaining: batchRemaining,
      expectedInventory: inv,
      expectedScalarCost: scalar,
      expectedPayment:
          paymentJson == null ? null : ExpectedPayment(paymentJson),
      expectedWalletLegs: ((exp['wallet_legs'] as List?) ?? const [])
          .map((l) => ExpectedWalletLeg(l as Map<String, dynamic>))
          .toList(),
      expectedCustomerBalanceAfterKobo:
          exp['customer_balance_after_kobo'] as int?,
      expectedCrateLines: crateLines,
      expectedCrateLedgerIssued: crateLedger,
      expectedCrateBalances: crateBalances,
    );
  }
}

/// Loads every scenario from a fixtures file under test/golden/fixtures/.
/// Relative to the package root, where `flutter test` runs.
List<GoldenScenario> _loadScenarios(String fileName) {
  final raw =
      File('test/golden/fixtures/$fileName').readAsStringSync();
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return (json['scenarios'] as List)
      .map((s) => GoldenScenario._fromJson(s as Map<String, dynamic>))
      .toList();
}

/// The cash/credit/wallet scenarios (Slices 2–3).
List<GoldenScenario> loadCashSaleScenarios() =>
    _loadScenarios('cash_sale_scenarios.json');

/// The empty-crate scenarios (Slice 4, #45). Each attaches a registered customer
/// at a crate-eligible business and asserts the crate ledger movements.
List<GoldenScenario> loadCrateSaleScenarios() =>
    _loadScenarios('crate_sale_scenarios.json');

// ─── Actual (a runner's result, in fixture terms) ────────────────────────────

class ActualOrder {
  final String status;
  final String paymentType;
  final int totalAmountKobo;
  final int discountKobo;
  final int netAmountKobo;
  final int amountPaidKobo;
  final bool completedAtNull;
  ActualOrder({
    required this.status,
    required this.paymentType,
    required this.totalAmountKobo,
    required this.discountKobo,
    required this.netAmountKobo,
    required this.amountPaidKobo,
    required this.completedAtNull,
  });
}

class ActualItem {
  final String productKey;
  final int quantity;
  final int unitPriceKobo;
  final int totalKobo;
  final int buyingPriceKobo;
  ActualItem({
    required this.productKey,
    required this.quantity,
    required this.unitPriceKobo,
    required this.totalKobo,
    required this.buyingPriceKobo,
  });
  String get signature =>
      '$productKey|$quantity|$unitPriceKobo|$totalKobo|$buyingPriceKobo';
}

class ActualPayment {
  final String method;
  final int amountKobo;
  ActualPayment({required this.method, required this.amountKobo});
}

/// One posted wallet leg, in fixture terms. Compared by [signature].
class ActualWalletLeg {
  final String referenceType;
  final int signedAmountKobo;
  ActualWalletLeg(
      {required this.referenceType, required this.signedAmountKobo});
  String get signature => '$referenceType|$signedAmountKobo';
}

/// One posted order_crate_lines row, in fixture terms (Slice 4).
class ActualCrateLine {
  final int cratesTaken;
  final int depositRateKobo;
  final int depositPaidKobo;
  ActualCrateLine({
    required this.cratesTaken,
    required this.depositRateKobo,
    required this.depositPaidKobo,
  });
  String get signature => '$cratesTaken|$depositRateKobo|$depositPaidKobo';
}

/// One checkout's resulting rows, translated back into fixture terms (product
/// keys, not real ids) so it can be compared to a [GoldenScenario].
class CheckoutOutcome {
  final String orderNumber;
  final ActualOrder order;
  final List<ActualItem> items;

  /// key "productKey|receivedAt" → qty_remaining.
  final Map<String, int> batchRemaining;

  /// productKey → on-hand after the sale.
  final Map<String, int> inventoryAfter;

  /// productKey → scalar buying_price_kobo cache.
  final Map<String, int> productScalarCost;

  /// The cash payment row, or null when the sale settled no cash.
  final ActualPayment? payment;

  /// The wallet legs THIS sale posted (order_id == this order); empty walk-in.
  final List<ActualWalletLeg> walletLegs;

  /// The customer's derived spendable balance after the sale, or null (walk-in).
  final int? customerBalanceAfter;

  /// Crate rows THIS sale posted, keyed by manufacturerKey (Slice 4). Empty for
  /// non-crate sales.
  ///   manufacturerKey → the order_crate_lines row.
  final Map<String, ActualCrateLine> crateLines;

  /// manufacturerKey → summed 'issued' crate_ledger quantity_delta for this order.
  final Map<String, int> crateLedgerIssued;

  /// manufacturerKey → customer_crate_balances.balance after the sale.
  final Map<String, int> crateBalances;

  CheckoutOutcome({
    required this.orderNumber,
    required this.order,
    required this.items,
    required this.batchRemaining,
    required this.inventoryAfter,
    required this.productScalarCost,
    required this.payment,
    this.walletLegs = const [],
    this.customerBalanceAfter,
    this.crateLines = const {},
    this.crateLedgerIssued = const {},
    this.crateBalances = const {},
  });
}

/// The shared assertion. Compares a runner's [CheckoutOutcome] to the fixture's
/// expectations. [orderNumberScheme] is the runner's own numbering regex
/// (mobile / web) — the one axis that is meant to differ.
void expectGolden(
  GoldenScenario s,
  CheckoutOutcome actual, {
  required RegExp orderNumberScheme,
}) {
  final e = s.expectedOrder;
  expect(actual.orderNumber, matches(orderNumberScheme),
      reason: '${s.name}: order number must match this client\'s scheme');
  expect(actual.order.status, e.status, reason: '${s.name}: order status');
  expect(actual.order.paymentType, e.paymentType,
      reason: '${s.name}: payment_type');
  expect(actual.order.totalAmountKobo, e.totalAmountKobo,
      reason: '${s.name}: total_amount_kobo (gross)');
  expect(actual.order.discountKobo, e.discountKobo,
      reason: '${s.name}: discount_kobo');
  expect(actual.order.netAmountKobo, e.netAmountKobo,
      reason: '${s.name}: net_amount_kobo');
  expect(actual.order.amountPaidKobo, e.amountPaidKobo,
      reason: '${s.name}: amount_paid_kobo');
  expect(actual.order.completedAtNull, e.completedAtNull,
      reason: '${s.name}: revenue recognized at checkout → completed_at NULL');

  // Per-line money tuples compared as a multiset (order-independent).
  final expectedSigs = s.expectedItems.map((i) => i.signature).toList()..sort();
  final actualSigs = actual.items.map((i) => i.signature).toList()..sort();
  expect(actualSigs, equals(expectedSigs),
      reason: '${s.name}: order line COGS/totals (product|qty|unit|total|cogs)');

  expect(actual.batchRemaining, equals(s.expectedBatchRemaining),
      reason: '${s.name}: FIFO batch remainders');
  expect(actual.inventoryAfter, equals(s.expectedInventory),
      reason: '${s.name}: inventory after sale');
  expect(actual.productScalarCost, equals(s.expectedScalarCost),
      reason: '${s.name}: scalar buying_price_kobo cache');

  // Payment row — a no-cash sale (pay-with-credit / pure credit) posts none.
  if (s.expectedPayment == null) {
    expect(actual.payment, isNull,
        reason: '${s.name}: no cash settled → no payment_transactions row');
  } else {
    expect(actual.payment, isNotNull,
        reason: '${s.name}: expected a payment_transactions row');
    expect(actual.payment!.method, s.expectedPayment!.method,
        reason: '${s.name}: payment method');
    expect(actual.payment!.amountKobo, s.expectedPayment!.amountKobo,
        reason: '${s.name}: payment amount');
  }

  // Wallet ledger legs (multiset) + the derived balance — the Slice 3 credit
  // contract. Walk-in scenarios have no customer and assert neither.
  final expectedLegSigs = s.expectedWalletLegs.map((l) => l.signature).toList()
    ..sort();
  final actualLegSigs = actual.walletLegs.map((l) => l.signature).toList()
    ..sort();
  expect(actualLegSigs, equals(expectedLegSigs),
      reason: '${s.name}: wallet ledger legs (reference_type|signed_amount)');
  expect(actual.customerBalanceAfter, s.expectedCustomerBalanceAfterKobo,
      reason: '${s.name}: derived customer balance after the sale');

  // Empty-crate legs (Slice 4, #45) — order_crate_lines, the 'issued' crate
  // ledger, and the customer_crate_balances, all keyed by manufacturer. Empty
  // maps for a non-crate sale, so this is a no-op there. order_crate_lines is
  // compared field-for-field (crates + deposit rate snapshot + deposit paid).
  final expectedLineSigs = {
    for (final e in s.expectedCrateLines.entries) e.key: e.value.signature
  };
  final actualLineSigs = {
    for (final e in actual.crateLines.entries) e.key: e.value.signature
  };
  expect(actualLineSigs, equals(expectedLineSigs),
      reason: '${s.name}: order_crate_lines (mfr → crates|rate|paid)');
  expect(actual.crateLedgerIssued, equals(s.expectedCrateLedgerIssued),
      reason: '${s.name}: crate_ledger issued movements (mfr → +qty)');
  expect(actual.crateBalances, equals(s.expectedCrateBalances),
      reason: '${s.name}: customer_crate_balances after the sale (mfr → balance)');
}

/// The mobile order-number scheme: `ORD-NNNNNN-XXXXXX` (Crockford base32 tag).
final RegExp mobileOrderNumberScheme = RegExp(r'^ORD-\d{6}-[0-9A-HJKMNP-TV-Z]{6}$');

/// The web (server-minted) scheme: `WEB-NNNNNN-XXXXXX` (hex tail). The `WEB-`
/// prefix makes collision with any mobile `ORD-…` number impossible.
final RegExp webOrderNumberScheme = RegExp(r'^WEB-\d{6}-[0-9A-F]{6}$');
