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
///
/// #206 adds a SECOND step to the contract: a scenario may carry a [FxCancel]
/// block, in which case the runner cancels the order it just created and calls
/// [expectGoldenCancel] on the resulting rows. That pins #172's compensating
/// cash-out rule — the most consequential money change in PRD #155 — which had
/// no cross-implementation contract at all before.
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

  /// #206 (#176/#183): the price actually CHARGED for this line when the
  /// cashier overrode the tier list price — a custom-price concession. The
  /// product's own [FxProduct.unitPriceKobo] stays the CATALOGUE (tier list)
  /// price, and the line records the difference on
  /// `order_items.catalogue_price_kobo`. Null ⇒ a full-price line: charged ==
  /// catalogue, so the concession column stays NULL (no phantom concession).
  final int? chargedUnitPriceKobo;
  FxCheckoutLine(this.productKey, this.quantity, {this.chargedUnitPriceKobo});
}

class FxCheckout {
  final String paymentMethod; // 'cash' | 'transfer' | 'credit' | 'wallet'
  final int discountKobo;
  final int amountPaidKobo;
  final List<FxCheckoutLine> items;

  /// #175 (money integrity #5): the crate deposit actually paid at checkout, per
  /// manufacturer key (kobo). Empty for the Slice 2–4 fixtures (the web
  /// crate-track path collects no deposit money). When set, the runner carves it
  /// out into its own `crate_deposit` payment row and adds it to the order total.
  final Map<String, int> depositPaidByManufacturer;
  FxCheckout(this.paymentMethod, this.discountKobo, this.amountPaidKobo,
      this.items,
      {this.depositPaidByManufacturer = const {}});
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

  /// #206 (#176/#183): the expected `order_items.catalogue_price_kobo` — the
  /// tier list price the CHARGED price deviated from. Absent in the fixture ⇒
  /// null ⇒ the line must record NO concession, which is what every full-price
  /// scenario asserts.
  final int? cataloguePriceKobo;
  ExpectedItem(Map<String, dynamic> j)
      : productKey = j['product'] as String,
        quantity = j['quantity'] as int,
        unitPriceKobo = j['unit_price_kobo'] as int,
        totalKobo = j['total_kobo'] as int,
        buyingPriceKobo = j['buying_price_kobo'] as int,
        cataloguePriceKobo = j['catalogue_price_kobo'] as int?;

  String get signature =>
      '$productKey|$quantity|$unitPriceKobo|$totalKobo|$buyingPriceKobo'
      '|catalogue=${cataloguePriceKobo ?? 'none'}';
}

class ExpectedPayment {
  final String method;
  final int amountKobo;
  ExpectedPayment(Map<String, dynamic> j)
      : method = j['method'] as String,
        amountKobo = j['amount_kobo'] as int;
}

/// One expected `payment_transactions` row, in fixture terms. Two uses:
///   * #175 — the NON-`sale` money rows a checkout posts (a `crate_deposit`
///     held, or a `wallet_topup` for an overpayment's excess);
///   * #206 — EVERY row on the order after a cancel, originals included, where
///     [amountKobo] is SIGNED (an in-family reversal is negative) and
///     [isVoided] must be false on all of them.
/// Compared as a multiset by [signature].
class ExpectedTypedPayment {
  final String type;
  final String method;
  final int amountKobo;
  final bool isVoided;
  ExpectedTypedPayment(Map<String, dynamic> j)
      : type = j['type'] as String,
        method = j['method'] as String,
        amountKobo = j['amount_kobo'] as int,
        isVoided = j['voided'] as bool? ?? false;

  String get signature => '$type|$method|$amountKobo|voided=$isVoided';
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

/// #206 — a FIFO layer the cancel APPENDED (#170 #7c): the returned units come
/// back costed at the per-unit COGS the sale snapshotted, never as phantom
/// 0-cost stock. Matched as a multiset against every cost batch that was not
/// seeded by the fixture.
class ExpectedRestoredLayer {
  final String productKey;
  final int qty;
  final int costKobo;
  ExpectedRestoredLayer(Map<String, dynamic> j)
      : productKey = j['product'] as String,
        qty = j['qty'] as int,
        costKobo = j['cost_kobo'] as int;

  String get signature => '$productKey|$qty|$costKobo';
}

/// #206 — the CANCEL step of a scenario: cancel the order the checkout just
/// created, then assert the compensated state. Present ⇒ the runner performs the
/// cancel after [expectGolden] has passed on the checkout, so every reversal is
/// asserted against a sale whose own rows are already pinned.
class FxCancel {
  final String reason;
  final String expectedStatus;
  final bool expectedCancelledAtNull;

  /// EVERY payment row expected on the order after the cancel, originals
  /// included. The MULTISET of these is the whole #172/#190/#201 contract in one
  /// assertion: the originals must still be there, unvoided and at their
  /// original amount, and exactly one compensating row must have been APPENDED
  /// per reversible original. A missing row, an extra row, a mutated original,
  /// or a reversal of the wrong type/sign all fail it.
  final List<ExpectedTypedPayment> payments;
  final List<ExpectedWalletLeg> walletLegs;
  final int? customerBalanceAfterKobo;

  /// productKey → on-hand after the cancel (the sale's units are back).
  final Map<String, int> inventoryAfter;

  /// key "productKey|receivedAt" → the SEEDED batch's qty_remaining after the
  /// cancel. The restore APPENDS a layer, so a drawn-down seeded batch stays
  /// drawn down — topping it back up would double-restore (#187).
  final Map<String, int> batchRemaining;
  final List<ExpectedRestoredLayer> restoredCostLayers;

  FxCancel._({
    required this.reason,
    required this.expectedStatus,
    required this.expectedCancelledAtNull,
    required this.payments,
    required this.walletLegs,
    required this.customerBalanceAfterKobo,
    required this.inventoryAfter,
    required this.batchRemaining,
    required this.restoredCostLayers,
  });

  factory FxCancel._fromJson(Map<String, dynamic> j) {
    final exp = j['expected'] as Map<String, dynamic>;
    final order = exp['order'] as Map<String, dynamic>;
    final batchRemaining = <String, int>{};
    for (final b in ((exp['batches_remaining'] as List?) ?? const [])) {
      final m = b as Map<String, dynamic>;
      batchRemaining['${m['product']}|${m['received_at']}'] =
          m['qty_remaining'] as int;
    }
    final inv = <String, int>{};
    for (final r in ((exp['inventory_after'] as List?) ?? const [])) {
      final m = r as Map<String, dynamic>;
      inv[m['product'] as String] = m['quantity'] as int;
    }
    return FxCancel._(
      reason: j['reason'] as String,
      expectedStatus: order['status'] as String,
      expectedCancelledAtNull: order['cancelled_at_null'] as bool,
      payments: ((exp['payments'] as List?) ?? const [])
          .map((p) => ExpectedTypedPayment(p as Map<String, dynamic>))
          .toList(),
      walletLegs: ((exp['wallet_legs'] as List?) ?? const [])
          .map((l) => ExpectedWalletLeg(l as Map<String, dynamic>))
          .toList(),
      customerBalanceAfterKobo: exp['customer_balance_after_kobo'] as int?,
      inventoryAfter: inv,
      batchRemaining: batchRemaining,
      restoredCostLayers: ((exp['restored_cost_layers'] as List?) ?? const [])
          .map((l) => ExpectedRestoredLayer(l as Map<String, dynamic>))
          .toList(),
    );
  }
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

  /// The caller's role discount cap (§12.6/§13.2 max_discount_percent). When set,
  /// the runners clamp the requested checkout discount to `gross * pct ~/ 100`
  /// (integer division, mirroring the RPC's `(v_gross * v_max_pct) / 100`); null ⇒
  /// no cap modelled (CEO / within-cap) and the requested discount applies as-is.
  /// NOTE: the RPC clamp keys off the CALLER's role, and 0135 short-circuits the
  /// CEO slug to 100 — so a clamp can only bite for a non-CEO caller. The Tier-2
  /// RPC runner is signed in as the business CEO, so it SKIPS clamp scenarios; the
  /// clamp rule is pinned on the Dart (mobile) arm.
  final int? maxDiscountPercent;

  /// When set, the scenario is a REJECTION: the checkout must be refused with this
  /// error token and NOTHING persisted. The success expectations below are absent.
  /// Mirrors the RPC guard raise (e.g. 'debt_limit_exceeded', P0001) and mobile's
  /// hide-don't-write. Only the debt-limit guard is modelled today.
  final String? expectRejection;

  /// #175: true ⇒ the SQL `checkout_order` RPC arm SKIPS this scenario. The
  /// tender/deposit/overpayment row split is implemented on the mobile (Dart)
  /// arm; the web RPC must add the matching split before it can honour these —
  /// flagged to the web repo, out of scope for the mobile issue. The Dart arm
  /// always runs them.
  final bool dartArmOnly;

  /// The expected order header, or null for a rejection scenario (no rows).
  final ExpectedOrder? expectedOrder;
  final List<ExpectedItem> expectedItems;

  /// key "productKey|receivedAt" → expected qty_remaining.
  final Map<String, int> expectedBatchRemaining;

  /// productKey → expected on-hand after the sale.
  final Map<String, int> expectedInventory;

  /// productKey → expected recomputed scalar buying_price_kobo cache.
  final Map<String, int> expectedScalarCost;

  /// The expected cash `sale` payment row, or null when the sale settled no cash
  /// (a pay-with-credit / pure credit sale posts no `sale` row).
  final ExpectedPayment? expectedPayment;

  /// #175: the NON-`sale` money rows the checkout is expected to post — the
  /// `crate_deposit` (held) and/or `wallet_topup` (overpayment excess) rows.
  /// Empty for the Slice 2–4 fixtures, so the multiset assertion is a no-op
  /// there. Compared order-independently.
  final List<ExpectedTypedPayment> expectedExtraPayments;

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

  /// #206: when set, the runner CANCELS the order after the checkout assertions
  /// pass and asserts this second block via [expectGoldenCancel]. Null ⇒ a
  /// checkout-only scenario (every fixture that predates #206).
  final FxCancel? cancel;

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
    required this.maxDiscountPercent,
    required this.expectRejection,
    required this.dartArmOnly,
    required this.expectedOrder,
    required this.expectedItems,
    required this.expectedBatchRemaining,
    required this.expectedInventory,
    required this.expectedScalarCost,
    required this.expectedPayment,
    required this.expectedExtraPayments,
    required this.expectedWalletLegs,
    required this.expectedCustomerBalanceAfterKobo,
    required this.expectedCrateLines,
    required this.expectedCrateLedgerIssued,
    required this.expectedCrateBalances,
    required this.cancel,
  });

  FxProduct product(String key) => products.firstWhere((p) => p.key == key);

  /// The price a checkout line is actually CHARGED at: its own custom price when
  /// the cashier overrode the tier list price, else the product's catalogue
  /// price. Shared so both arms compute the line total — and the concession —
  /// from one definition (ADR 0009).
  int chargedKobo(FxCheckoutLine line) =>
      line.chargedUnitPriceKobo ?? product(line.productKey).unitPriceKobo;

  factory GoldenScenario._fromJson(Map<String, dynamic> j) {
    final rejectedWith =
        (j['expect'] as Map<String, dynamic>?)?['rejected_with'] as String?;
    // A rejection scenario carries no `expected` block; tolerate its absence.
    final exp = (j['expected'] as Map<String, dynamic>?) ?? const <String, dynamic>{};

    final batchRemaining = <String, int>{};
    for (final b in ((exp['batches_remaining'] as List?) ?? const [])) {
      final m = b as Map<String, dynamic>;
      batchRemaining['${m['product']}|${m['received_at']}'] =
          m['qty_remaining'] as int;
    }
    final inv = <String, int>{};
    for (final r in ((exp['inventory_after'] as List?) ?? const [])) {
      final m = r as Map<String, dynamic>;
      inv[m['product'] as String] = m['quantity'] as int;
    }
    final scalar = <String, int>{};
    for (final r in ((exp['product_scalar_cost'] as List?) ?? const [])) {
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
            .map((i) => FxCheckoutLine(
                  i['product'] as String,
                  i['quantity'] as int,
                  chargedUnitPriceKobo: i['charged_unit_price_kobo'] as int?,
                ))
            .toList(),
        depositPaidByManufacturer: {
          for (final e in ((j['checkout']['deposit_paid_by_manufacturer']
                  as Map<String, dynamic>?) ??
              const <String, dynamic>{}).entries)
            e.key: e.value as int,
        },
      ),
      maxDiscountPercent: j['max_discount_percent'] as int?,
      expectRejection: rejectedWith,
      dartArmOnly: j['dart_arm_only'] as bool? ?? false,
      expectedOrder: exp['order'] == null
          ? null
          : ExpectedOrder(exp['order'] as Map<String, dynamic>),
      expectedItems: ((exp['items'] as List?) ?? const [])
          .map((i) => ExpectedItem(i as Map<String, dynamic>))
          .toList(),
      expectedBatchRemaining: batchRemaining,
      expectedInventory: inv,
      expectedScalarCost: scalar,
      expectedPayment:
          paymentJson == null ? null : ExpectedPayment(paymentJson),
      expectedExtraPayments: ((exp['extra_payments'] as List?) ?? const [])
          .map((p) => ExpectedTypedPayment(p as Map<String, dynamic>))
          .toList(),
      expectedWalletLegs: ((exp['wallet_legs'] as List?) ?? const [])
          .map((l) => ExpectedWalletLeg(l as Map<String, dynamic>))
          .toList(),
      expectedCustomerBalanceAfterKobo:
          exp['customer_balance_after_kobo'] as int?,
      expectedCrateLines: crateLines,
      expectedCrateLedgerIssued: crateLedger,
      expectedCrateBalances: crateBalances,
      cancel: j['cancel'] == null
          ? null
          : FxCancel._fromJson(j['cancel'] as Map<String, dynamic>),
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

/// The cancel/refund scenarios (#206). Each is a checkout followed by a CANCEL,
/// pinning #172's compensating cash-out rule and #190/#201's in-family reversal
/// of a released deposit / a reversed overpayment.
List<GoldenScenario> loadCancelScenarios() =>
    _loadScenarios('cancel_scenarios.json');

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

  /// The recorded `order_items.catalogue_price_kobo` (#176/#183): the tier list
  /// price a custom-priced line deviated from, or null on a full-price line.
  final int? cataloguePriceKobo;
  ActualItem({
    required this.productKey,
    required this.quantity,
    required this.unitPriceKobo,
    required this.totalKobo,
    required this.buyingPriceKobo,
    this.cataloguePriceKobo,
  });
  String get signature =>
      '$productKey|$quantity|$unitPriceKobo|$totalKobo|$buyingPriceKobo'
      '|catalogue=${cataloguePriceKobo ?? 'none'}';
}

class ActualPayment {
  final String method;
  final int amountKobo;
  ActualPayment({required this.method, required this.amountKobo});
}

/// One posted `payment_transactions` row, in fixture terms — the #175 split rows
/// a checkout writes, or (#206) every row on a cancelled order. Compared by
/// [signature].
class ActualTypedPayment {
  final String type;
  final String method;
  final int amountKobo;
  final bool isVoided;
  ActualTypedPayment({
    required this.type,
    required this.method,
    required this.amountKobo,
    this.isVoided = false,
  });
  String get signature => '$type|$method|$amountKobo|voided=$isVoided';
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

/// One cost batch the cancel APPENDED, in fixture terms (#206). Compared by
/// [signature].
class ActualRestoredLayer {
  final String productKey;
  final int qty;
  final int costKobo;
  ActualRestoredLayer({
    required this.productKey,
    required this.qty,
    required this.costKobo,
  });
  String get signature => '$productKey|$qty|$costKobo';
}

/// One cancel's resulting rows, translated back into fixture terms (#206).
class CancelOutcome {
  final String orderStatus;
  final bool cancelledAtNull;

  /// EVERY payment row on the order after the cancel — originals included, so
  /// the multiset proves the originals survived untouched.
  final List<ActualTypedPayment> payments;

  /// One human-readable entry per ORIGINAL payment row the cancel changed or
  /// deleted, comparing each row's full state (type, method, amount,
  /// `created_at`, `voided_at`) across the cancel. It must come back EMPTY.
  ///
  /// This is the half of #172 the fixture cannot express: "the reversal lands on
  /// the CANCEL day" is only meaningful because the original keeps ITS OWN
  /// `created_at`, and a golden run happens in a single instant, so the dates
  /// cannot be compared to each other — only to themselves before and after.
  /// Each runner computes this against its own storage.
  final List<String> mutatedOriginals;

  /// EVERY wallet leg on the order after the cancel — originals included.
  final List<ActualWalletLeg> walletLegs;
  final int? customerBalanceAfter;
  final Map<String, int> inventoryAfter;

  /// key "productKey|receivedAt" → the SEEDED batch's qty_remaining.
  final Map<String, int> batchRemaining;

  /// The cost batches that were NOT seeded by the fixture — i.e. the layers the
  /// cancel restored.
  final List<ActualRestoredLayer> restoredCostLayers;

  CancelOutcome({
    required this.orderStatus,
    required this.cancelledAtNull,
    required this.payments,
    required this.mutatedOriginals,
    required this.walletLegs,
    required this.customerBalanceAfter,
    required this.inventoryAfter,
    required this.batchRemaining,
    required this.restoredCostLayers,
  });
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

  /// The cash `sale` payment row, or null when the sale settled no cash.
  final ActualPayment? payment;

  /// The NON-`sale` money rows THIS sale posted (#175) — crate_deposit /
  /// wallet_topup; empty for a plain sale.
  final List<ActualTypedPayment> extraPayments;

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
    this.extraPayments = const [],
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
/// The applied order discount after the role cap (§12.6/§13.2): the requested
/// amount, never negative, floored to `gross * maxPct ~/ 100` — mirroring the
/// RPC's `LEAST(GREATEST(p_discount, 0), (v_gross * v_max_pct) / 100)`. [maxPct]
/// null ⇒ no cap modelled (the request applies as-is). Shared so both golden arms
/// clamp identically.
int clampDiscountKobo(int requestedKobo, int? maxPct, int grossKobo) {
  final nonNeg = requestedKobo < 0 ? 0 : requestedKobo;
  if (maxPct == null) return nonNeg;
  final cap = (grossKobo * maxPct) ~/ 100;
  return nonNeg > cap ? cap : nonNeg;
}

/// The "record only a REAL concession" rule (#176/#183): the catalogue (tier
/// list) price is snapshotted onto the line only when it is known AND differs
/// from the price actually charged; NULL otherwise, so a full-price line records
/// no phantom concession. Shared so both golden arms apply it identically — the
/// Dart twin of `OrderCommands._buildOrderItems` and of the SQL
/// `public._catalogue_price_snapshot` (migration 0160).
int? catalogueSnapshotKobo({
  required int? catalogueKobo,
  required int chargedKobo,
}) =>
    (catalogueKobo != null && catalogueKobo != chargedKobo)
        ? catalogueKobo
        : null;

void expectGolden(
  GoldenScenario s,
  CheckoutOutcome actual, {
  required RegExp orderNumberScheme,
}) {
  final e = s.expectedOrder!;
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

  // #175 — the non-`sale` money rows (crate_deposit / wallet_topup), compared as
  // a multiset by type|method|amount. Empty for the Slice 2–4 fixtures.
  final expectedExtraSigs =
      s.expectedExtraPayments.map((p) => p.signature).toList()..sort();
  final actualExtraSigs =
      actual.extraPayments.map((p) => p.signature).toList()..sort();
  expect(actualExtraSigs, equals(expectedExtraSigs),
      reason: '${s.name}: split money rows (type|method|amount)');

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

/// The shared CANCEL assertion (#206). Compares a runner's [CancelOutcome] to
/// the scenario's [GoldenScenario.cancel] block.
///
/// The rule being pinned, as migration 0170's header states it: *a cancel
/// APPENDS one compensating row per reversible original, dated on the cancel
/// day, and mutates nothing.* Concretely (#172 / #190 / #201):
///   • every ORIGINAL payment row survives, unvoided, at its original amount —
///     a reviewed and banked sale day never shrinks behind the owner;
///   • `sale`          → a POSITIVE `refund` for the same amount;
///   • `crate_deposit` → a NEGATIVE `crate_deposit` (in-family, NOT a `refund`:
///     the collection was never in Cash sales, so its release must not land in
///     Cash refunds);
///   • `wallet_topup`  → a NEGATIVE `wallet_topup`, so "Debts collected" nets
///     to zero;
///   • every wallet leg the sale posted is reversed by an APPENDED opposite leg
///     (goods debit → `refund` credit, payment credit → `void` debit, held
///     `crate_deposit` credit → a deposit-family `crate_deposit_refunded`
///     debit), returning the customer to their exact pre-sale balance;
///   • the shelf and the FIFO queue come back together: inventory is restored
///     and one fresh cost layer is APPENDED per line at the COGS the sale
///     snapshotted (#170 #7c) — the seeded batch stays drawn down, because
///     topping it back up would double-restore (#187).
void expectGoldenCancel(GoldenScenario s, CancelOutcome actual) {
  final c = s.cancel!;
  expect(actual.orderStatus, c.expectedStatus,
      reason: '${s.name}: order status after the cancel');
  expect(actual.cancelledAtNull, c.expectedCancelledAtNull,
      reason: '${s.name}: cancelled_at stamped');

  // The whole payment contract in one multiset: originals untouched + exactly
  // one appended compensating row per reversible original.
  final expectedPaySigs = c.payments.map((p) => p.signature).toList()..sort();
  final actualPaySigs = actual.payments.map((p) => p.signature).toList()..sort();
  expect(actualPaySigs, equals(expectedPaySigs),
      reason: '${s.name}: payment rows after the cancel '
          '(type|method|signed amount|voided) — originals must survive '
          'untouched and one compensating row must be appended per reversible '
          'original');
  expect(actual.mutatedOriginals, isEmpty,
      reason: '${s.name}: the cancel must mutate NO original payment row — not '
          'its amount, not its type, not its created_at (the sale stays on the '
          'sale day, so a reviewed and banked day never shrinks behind the '
          'owner), and never an in-place void');

  final expectedLegSigs = c.walletLegs.map((l) => l.signature).toList()..sort();
  final actualLegSigs = actual.walletLegs.map((l) => l.signature).toList()
    ..sort();
  expect(actualLegSigs, equals(expectedLegSigs),
      reason: '${s.name}: wallet legs after the cancel '
          '(reference_type|signed_amount)');
  expect(actual.customerBalanceAfter, c.customerBalanceAfterKobo,
      reason: '${s.name}: derived customer balance after the cancel');

  expect(actual.inventoryAfter, equals(c.inventoryAfter),
      reason: '${s.name}: inventory restored by the cancel');
  expect(actual.batchRemaining, equals(c.batchRemaining),
      reason: '${s.name}: the SEEDED FIFO batches stay drawn down '
          '(the restore appends a layer, it never tops the old one back up)');

  final expectedLayerSigs =
      c.restoredCostLayers.map((l) => l.signature).toList()..sort();
  final actualLayerSigs =
      actual.restoredCostLayers.map((l) => l.signature).toList()..sort();
  expect(actualLayerSigs, equals(expectedLayerSigs),
      reason: '${s.name}: FIFO layers the cancel restored '
          '(product|qty|cost) — the units come back COSTED, not free');
}

/// The mobile order-number scheme: `ORD-NNNNNN-XXXXXX` (Crockford base32 tag).
final RegExp mobileOrderNumberScheme = RegExp(r'^ORD-\d{6}-[0-9A-HJKMNP-TV-Z]{6}$');

/// The web (server-minted) scheme: `WEB-NNNNNN-XXXXXX` (hex tail). The `WEB-`
/// prefix makes collision with any mobile `ORD-…` number impossible.
final RegExp webOrderNumberScheme = RegExp(r'^WEB-\d{6}-[0-9A-F]{6}$');
