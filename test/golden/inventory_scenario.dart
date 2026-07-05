/// The batch-creation Golden-Scenario Suite (ADR 0009, issue #48).
///
/// A second golden dimension beside the checkout suite (golden_scenario.dart):
/// it pins the FIFO **Cost Batch producer** rule identical across the two
/// implementations of inventory inflow —
///   * the Dart DAO path (mobile)  — test/golden/inventory_dart_dao_golden_test.dart
///     (CostBatchesDao.recordInflowBatch + inventory + SupplierAccountService)
///   * the SQL RPCs (web)          — test/integration/rpcs/web_inventory_golden_test.dart
///     (add_product / receive_stock, migration 0140)
///
/// The rule under test (F1/F6, ADR 0005): one inflow ⇒ one fresh Cost Batch
/// {qty_remaining = qty_original = quantity, cost_kobo = max(cost, 0),
/// received_at}, never merged with another; cost 0 ⇒ an UNCOSTED batch. Add
/// Product writes opening stock straight to inventory with no supplier; Receive
/// Stock posts a supplier invoice (debit) + optional payment (credit) and a
/// receipt-dated batch per line. Any drift between the two arms fails the build.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ─── Fixtures (input) ────────────────────────────────────────────────────────

/// A cost batch already on the queue before the operation runs (Receive Stock
/// scenarios seed these so the assertion covers pre-existing layers too).
class FxInvExistingBatch {
  final int qty;
  final int costKobo;
  final String receivedAt; // date-only, unique per product ⇒ doubles as the key
  FxInvExistingBatch(this.qty, this.costKobo, this.receivedAt);

  DateTime get receivedAtUtc {
    final p = receivedAt.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }
}

/// One Receive Stock line: units received at a per-unit cost, receipt-dated.
class FxReceiveLine {
  final int quantity;
  final int buyingPriceKobo;
  final String receivedAt;
  FxReceiveLine(this.quantity, this.buyingPriceKobo, this.receivedAt);

  DateTime get receivedAtUtc {
    final p = receivedAt.split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }
}

/// One expected cost_batches row, keyed by receivedAt (unique per scenario).
class ExpectedInvBatch {
  final String receivedAt;
  final int qtyRemaining;
  final int qtyOriginal;
  final int costKobo;
  ExpectedInvBatch(Map<String, dynamic> j)
      : receivedAt = j['received_at'] as String,
        qtyRemaining = j['qty_remaining'] as int,
        qtyOriginal = j['qty_original'] as int,
        costKobo = j['cost_kobo'] as int;

  String get signature => '$qtyRemaining|$qtyOriginal|$costKobo';
}

class InventoryScenario {
  final String name;

  /// 'add_product' — creates a product with opening stock; or
  /// 'receive'      — receives a supplier delivery for an existing product.
  final String operation;

  // Product under test.
  final String productName;
  final String unit;
  final int retailerPriceKobo;
  final int wholesalerPriceKobo;
  final int buyingPriceKobo;

  // add_product only: opening stock valued at buyingPriceKobo.
  final int openingStock;

  // receive only:
  final int existingStock;
  final List<FxInvExistingBatch> existingBatches;
  final List<FxReceiveLine> lines;
  final int amountPaidKobo;
  final String paymentMethod;

  // Expected results (the contract).
  final Map<String, ExpectedInvBatch> expectedBatches; // receivedAt → row
  final int expectedInventoryAfter;
  final int? expectedSupplierBalanceAfterKobo; // receive only; null for add

  InventoryScenario._({
    required this.name,
    required this.operation,
    required this.productName,
    required this.unit,
    required this.retailerPriceKobo,
    required this.wholesalerPriceKobo,
    required this.buyingPriceKobo,
    required this.openingStock,
    required this.existingStock,
    required this.existingBatches,
    required this.lines,
    required this.amountPaidKobo,
    required this.paymentMethod,
    required this.expectedBatches,
    required this.expectedInventoryAfter,
    required this.expectedSupplierBalanceAfterKobo,
  });

  factory InventoryScenario._fromJson(Map<String, dynamic> j) {
    final exp = j['expected'] as Map<String, dynamic>;
    final batches = <String, ExpectedInvBatch>{};
    for (final b in (exp['batches'] as List)) {
      final e = ExpectedInvBatch(b as Map<String, dynamic>);
      batches[e.receivedAt] = e;
    }
    final receive = j['receive'] as Map<String, dynamic>?;
    return InventoryScenario._(
      name: j['name'] as String,
      operation: j['operation'] as String,
      productName: j['product']['name'] as String,
      unit: j['product']['unit'] as String? ?? 'Piece',
      retailerPriceKobo: j['product']['retailer_price_kobo'] as int? ?? 0,
      wholesalerPriceKobo: j['product']['wholesaler_price_kobo'] as int? ?? 0,
      buyingPriceKobo: j['product']['buying_price_kobo'] as int? ?? 0,
      openingStock: j['opening_stock'] as int? ?? 0,
      existingStock: receive?['existing_stock'] as int? ?? 0,
      existingBatches: ((receive?['existing_batches'] as List?) ?? const [])
          .map((b) => FxInvExistingBatch(
              b['qty'] as int, b['cost_kobo'] as int, b['received_at'] as String))
          .toList(),
      lines: ((receive?['lines'] as List?) ?? const [])
          .map((l) => FxReceiveLine(l['quantity'] as int,
              l['buying_price_kobo'] as int, l['received_at'] as String))
          .toList(),
      amountPaidKobo: receive?['amount_paid_kobo'] as int? ?? 0,
      paymentMethod: receive?['payment_method'] as String? ?? 'cash',
      expectedBatches: batches,
      expectedInventoryAfter: exp['inventory_after'] as int,
      expectedSupplierBalanceAfterKobo:
          exp['supplier_balance_after_kobo'] as int?,
    );
  }
}

List<InventoryScenario> loadInventoryScenarios() {
  final raw =
      File('test/golden/fixtures/inventory_scenarios.json').readAsStringSync();
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return (json['scenarios'] as List)
      .map((s) => InventoryScenario._fromJson(s as Map<String, dynamic>))
      .toList();
}

// ─── Actual (a runner's result, in fixture terms) ────────────────────────────

class InventoryOutcome {
  /// receivedAt (date-only) → {qty_remaining, qty_original, cost_kobo}.
  final Map<String, ExpectedInvBatch> batches;
  final int inventoryAfter;
  final int? supplierBalanceAfterKobo;
  InventoryOutcome({
    required this.batches,
    required this.inventoryAfter,
    this.supplierBalanceAfterKobo,
  });
}

/// The shared assertion. Both runners collect their resulting rows into an
/// [InventoryOutcome] and call this; drift on either arm fails the build.
void expectInventoryGolden(InventoryScenario s, InventoryOutcome actual) {
  final expectedSigs = {
    for (final e in s.expectedBatches.entries) e.key: e.value.signature
  };
  final actualSigs = {
    for (final e in actual.batches.entries) e.key: e.value.signature
  };
  expect(actualSigs, equals(expectedSigs),
      reason:
          '${s.name}: cost_batches produced (receivedAt → qty_remaining|qty_original|cost)');
  expect(actual.inventoryAfter, s.expectedInventoryAfter,
      reason: '${s.name}: inventory on-hand after the inflow');
  expect(actual.supplierBalanceAfterKobo, s.expectedSupplierBalanceAfterKobo,
      reason: '${s.name}: supplier ledger balance after the delivery');
}
