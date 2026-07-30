/// Stock-adjustment approval-gate Golden Suite (ADR 0009, issue #50).
///
/// Pins the request-vs-apply rule identical across the two implementations:
///   * the Dart DAO path (mobile)  — StockAdjustmentRequestsDao.requestStock
///     Adjustment / approveRequest / rejectRequest (+ InventoryDao.adjustStock)
///   * the SQL RPCs (web)          — request_stock_adjustment / approve_stock_
///     adjustment (migration 0141)
///
/// The rule (§16.6.1, v34): a pending request makes NO inventory change; an
/// approval applies the delta; a rejection makes no change. Any drift between
/// the two arms on status + inventory fails the build.
///
/// The stock-keeper → pending path is pinned on the DART arm only: the Tier-2 RPC
/// identity is the business CEO, whom the server routes to immediate-apply — so
/// 'request' scenarios SKIP on the RPC arm (same precedent as the discount clamp
/// in the checkout suite). 'approve'/'reject' run on both.
///
/// Money-integrity #7a (#170, PRD #155) gives the approval its COST semantics on
/// the mobile DAO: an approved increase creates a Cost Batch, and an approved
/// decrease draws the FIFO queue down and SNAPSHOTS the drawn value onto the
/// adjustment. What that batch costs runs down a three-step ladder:
///   1. #197 (US 22) — the cost the REQUEST captured (`unit_cost_kobo`), stated
///      by the person holding the invoice. It always wins.
///   2. #189 — else the product's RECORDED scalar cost, the derived cache over
///      the batch queue (ADR 0005).
///   3. Uncosted (0) — only when neither is on file. Batching at 0 with a price
///      on file sold those units at 0 COGS forever (#41's backfill fires only on
///      a 0 → positive cost edit, which such a product can never make again).
/// The web RPC arm walks the SAME ladder as of #201 / migration 0170
/// (`_apply_stock_adjustment` mints or draws the layer; `request_stock_adjustment`
/// captures the stated cost; `approve_stock_adjustment` reads it back off the
/// request row). The cost scenarios stay `dartArmOnly` until that migration is
/// DEPLOYED — the RPC arm runs against live Supabase and would fail against a
/// cloud that predates it — and un-flagging them also needs the RPC arm to seed
/// `unit_cost_kobo` / `buying_price_kobo` / the starting batch and to read the
/// cost back (it asserts only status + inventory today). status + inventory stay
/// pinned on BOTH arms meanwhile.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class StockAdjScenario {
  final String name;

  /// 'request' — a stock keeper files a pending request (no change);
  /// 'approve'  — a pending request is approved (delta applied);
  /// 'reject'   — a pending request is rejected (no change).
  final String operation;

  final int startQty;
  final int quantityDiff;
  final String reason;

  final String expectedStatus; // 'pending' | 'approved' | 'rejected'
  final int expectedInventoryAfter;

  /// #7a: seed a costed Cost Batch of [startQty] @ this cost before the op, so a
  /// decrease has real cost to draw. Null → no batch seeded (an unpriced start).
  final int? inflowCostKobo;

  /// #189 (dartArmOnly): seed the product's scalar `buying_price_kobo` at this
  /// value — the cost basis an approved increase falls back to when the request
  /// captured none. Null → no cost on file (a genuinely Uncosted increase). The
  /// RPC arm reads the same column as of migration 0170, but does not seed it
  /// yet, so every scenario using it stays `dartArmOnly` until that lands.
  final int? productBuyingPriceKobo;

  /// #197 (dartArmOnly): the per-unit cost the REQUEST captures
  /// (`stock_adjustment_requests.unit_cost_kobo`, US 22) — what the goods
  /// actually cost, stated by the person holding the invoice. Null → the request
  /// states nothing, and the approval falls back to
  /// [productBuyingPriceKobo] (#189). A stated cost WINS over that fallback,
  /// which is the whole point of the column. The web
  /// `request_stock_adjustment` gained a `p_unit_cost_kobo` parameter in
  /// migration 0170 (#201) and `approve_stock_adjustment` reads the column back,
  /// but the RPC arm here still seeds its request without one.
  final int? requestUnitCostKobo;

  /// #7a (dartArmOnly): the value_kobo the approved DECREASE must snapshot.
  final int? expectedSnapshotValueKobo;

  /// #7a (dartArmOnly): the cost_kobo of the Cost Batch an approved INCREASE
  /// must create — the cost the request captured (#197), else the product's
  /// recorded cost (#189), else 0 = Uncosted when neither is on file.
  final int? expectedNewBatchCostKobo;

  /// Skips the RPC arm: the web cost pass exists as of migration 0170 but is not
  /// deployed and not yet seeded here. status + inventory still run on both arms
  /// for non-dartArmOnly scenarios.
  final bool dartArmOnly;

  StockAdjScenario._({
    required this.name,
    required this.operation,
    required this.startQty,
    required this.quantityDiff,
    required this.reason,
    required this.expectedStatus,
    required this.expectedInventoryAfter,
    this.inflowCostKobo,
    this.productBuyingPriceKobo,
    this.requestUnitCostKobo,
    this.expectedSnapshotValueKobo,
    this.expectedNewBatchCostKobo,
    this.dartArmOnly = false,
  });

  factory StockAdjScenario._fromJson(Map<String, dynamic> j) {
    final exp = j['expected'] as Map<String, dynamic>;
    return StockAdjScenario._(
      name: j['name'] as String,
      operation: j['operation'] as String,
      startQty: j['start_qty'] as int,
      quantityDiff: j['quantity_diff'] as int,
      reason: j['reason'] as String? ?? 'adjustment',
      expectedStatus: exp['status'] as String,
      expectedInventoryAfter: exp['inventory_after'] as int,
      inflowCostKobo: j['inflow_cost_kobo'] as int?,
      productBuyingPriceKobo: j['product_buying_price_kobo'] as int?,
      requestUnitCostKobo: j['request_unit_cost_kobo'] as int?,
      expectedSnapshotValueKobo: exp['dart_snapshot_value_kobo'] as int?,
      expectedNewBatchCostKobo: exp['dart_new_batch_cost_kobo'] as int?,
      dartArmOnly: j['dart_arm_only'] as bool? ?? false,
    );
  }
}

List<StockAdjScenario> loadStockAdjScenarios() {
  final raw = File('test/golden/fixtures/stock_adjustment_scenarios.json')
      .readAsStringSync();
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return (json['scenarios'] as List)
      .map((s) => StockAdjScenario._fromJson(s as Map<String, dynamic>))
      .toList();
}

class StockAdjOutcome {
  final String status;
  final int inventoryAfter;

  /// #7a (dartArmOnly): the value_kobo snapshotted onto the applied adjustment
  /// (null for a non-decrease or when the arm doesn't track cost).
  final int? snapshotValueKobo;

  /// #7a (dartArmOnly): the cost_kobo of the batch created by an applied
  /// increase (null when no batch was created).
  final int? newBatchCostKobo;

  StockAdjOutcome({
    required this.status,
    required this.inventoryAfter,
    this.snapshotValueKobo,
    this.newBatchCostKobo,
  });
}

void expectStockAdjGolden(StockAdjScenario s, StockAdjOutcome actual) {
  expect(actual.status, s.expectedStatus, reason: '${s.name}: request status');
  expect(actual.inventoryAfter, s.expectedInventoryAfter,
      reason: '${s.name}: inventory on-hand after the operation');
  // #7a cost pins — asserted only where the scenario declares them (the dart
  // arm; the RPC arm skips dartArmOnly scenarios entirely).
  if (s.expectedSnapshotValueKobo != null) {
    expect(actual.snapshotValueKobo, s.expectedSnapshotValueKobo,
        reason: '${s.name}: loss value snapshotted onto the adjustment');
  }
  if (s.expectedNewBatchCostKobo != null) {
    expect(actual.newBatchCostKobo, s.expectedNewBatchCostKobo,
        reason: '${s.name}: cost of the batch the increase created');
  }
}
