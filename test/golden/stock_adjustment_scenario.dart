/// Stock-adjustment approval-gate Golden Suite (ADR 0009, issue #50).
///
/// Pins the request-vs-apply rule identical across the two implementations:
///   * the Dart DAO path (mobile)  — StockAdjustmentRequestsDao.requestStock
///     Adjustment / approveRequest / rejectRequest (+ InventoryDao.adjustStock)
///   * the SQL RPCs (web)          — request_stock_adjustment / approve_stock_
///     adjustment (migration 0141)
///
/// The rule (§16.6.1, v34): a pending request makes NO inventory change; an
/// approval applies the delta (adjustStock semantics — no Cost Batch, an
/// adjustment is a correction not an inflow); a rejection makes no change. Any
/// drift between the two arms fails the build.
///
/// The stock-keeper → pending path is pinned on the DART arm only: the Tier-2 RPC
/// identity is the business CEO, whom the server routes to immediate-apply — so
/// 'request' scenarios SKIP on the RPC arm (same precedent as the discount clamp
/// in the checkout suite). 'approve'/'reject' run on both.
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

  StockAdjScenario._({
    required this.name,
    required this.operation,
    required this.startQty,
    required this.quantityDiff,
    required this.reason,
    required this.expectedStatus,
    required this.expectedInventoryAfter,
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
  StockAdjOutcome({required this.status, required this.inventoryAfter});
}

void expectStockAdjGolden(StockAdjScenario s, StockAdjOutcome actual) {
  expect(actual.status, s.expectedStatus, reason: '${s.name}: request status');
  expect(actual.inventoryAfter, s.expectedInventoryAfter,
      reason: '${s.name}: inventory on-hand after the operation');
}
