// Home Reports button attention dot (issue #119).
//
// Three layers, all asserting external behaviour (mirrors the Seam 3
// get-started checklist tests):
//   1. `computeReportsAttentionDot` — the pure derivation, exhaustive over
//      approvals / latest-count / last-reviewed.
//   2. `reportsAttentionDotProvider` — the live wiring, driven purely through
//      input overrides in a ProviderContainer (no widget tree), proving each
//      signal maps to the dot.
//   3. `ReconReviewMarkerNotifier` — the per-user, device-local marker: opening
//      Daily Reconciliation (markOpenedNow) clears the dot, persists across a
//      simulated restart, and is independent per device user.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/features/dashboard/reports_attention.dart';

// ── Test factories ───────────────────────────────────────────────────────────

StockCountData _count(DateTime createdAt) => StockCountData(
      id: 'sc-${createdAt.microsecondsSinceEpoch}',
      businessId: 'biz1',
      storeId: null,
      businessDate: '2026-01-01',
      productsCounted: 5,
      shortageCount: 0,
      surplusCount: 0,
      shortageUnits: 0,
      surplusUnits: 0,
      linesJson: '[]',
      countedBy: null,
      createdAt: createdAt,
      lastUpdatedAt: createdAt,
    );

StockAdjustmentRequestData _stockReq(String id) => StockAdjustmentRequestData(
      id: id,
      businessId: 'biz1',
      productId: 'p1',
      storeId: 's1',
      quantityDiff: 5,
      reason: 'restock',
      summary: 'Add 5',
      requestedBy: 'u1',
      status: 'pending',
      approvedBy: null,
      approvedAt: null,
      createdAt: DateTime(2026, 1, 1),
      lastUpdatedAt: DateTime(2026, 1, 1),
    );

QuickSaleRequestData _quickSaleReq(String id) => QuickSaleRequestData(
      id: id,
      businessId: 'biz1',
      storeId: 's1',
      itemName: 'Bottled Water',
      quantity: 3,
      unitPriceKobo: 50000,
      summary: '3 x Bottled Water',
      requestedBy: 'u1',
      status: 'pending',
      approvedBy: null,
      approvedAt: null,
      createdAt: DateTime(2026, 1, 1),
      lastUpdatedAt: DateTime(2026, 1, 1),
    );

/// A marker notifier that skips SharedPreferences and reports a fixed value —
/// lets the wiring tests inject a "last reviewed" instant deterministically.
class _StubMarker extends ReconReviewMarkerNotifier {
  _StubMarker(this._value);
  final DateTime? _value;
  @override
  DateTime? build() => _value;
}

/// Drives [reportsAttentionDotProvider] through its input providers only.
Future<bool> _evaluateDot({
  List<StockAdjustmentRequestData> stockRequests = const [],
  List<QuickSaleRequestData> quickSaleRequests = const [],
  List<StockCountData> counts = const [],
  DateTime? lastReviewedAt,
}) async {
  final container = ProviderContainer(
    overrides: [
      viewerScopedPendingStockRequestsProvider
          .overrideWith((ref) => stockRequests),
      viewerScopedPendingQuickSaleRequestsProvider
          .overrideWith((ref) => quickSaleRequests),
      allStockCountsProvider.overrideWith((ref) => Stream.value(counts)),
      reconReviewMarkerProvider.overrideWith(() => _StubMarker(lastReviewedAt)),
    ],
  );
  addTearDown(container.dispose);
  // Let the overridden stream emit before reading the derived provider.
  await container.read(allStockCountsProvider.future);
  return container.read(reportsAttentionDotProvider);
}

void main() {
  group('computeReportsAttentionDot (pure)', () {
    final t0 = DateTime(2026, 1, 1, 8);
    final t1 = DateTime(2026, 1, 1, 9);

    test('pending approvals light the dot even with no counts', () {
      expect(
        computeReportsAttentionDot(
          pendingApprovals: 1,
          latestStockCountAt: null,
          lastReviewedAt: null,
        ),
        isTrue,
      );
    });

    test('pending approvals dominate an already-reviewed count', () {
      expect(
        computeReportsAttentionDot(
          pendingApprovals: 2,
          latestStockCountAt: t0,
          lastReviewedAt: t1,
        ),
        isTrue,
      );
    });

    test('a count recorded after the last review is un-reviewed → on', () {
      expect(
        computeReportsAttentionDot(
          pendingApprovals: 0,
          latestStockCountAt: t1,
          lastReviewedAt: t0,
        ),
        isTrue,
      );
    });

    test('a count never reviewed on this device (null marker) → on', () {
      expect(
        computeReportsAttentionDot(
          pendingApprovals: 0,
          latestStockCountAt: t0,
          lastReviewedAt: null,
        ),
        isTrue,
      );
    });

    test('a count reviewed at/after the latest count → off', () {
      expect(
        computeReportsAttentionDot(
          pendingApprovals: 0,
          latestStockCountAt: t0,
          lastReviewedAt: t1,
        ),
        isFalse,
      );
      // The review instant equalling the count instant counts as reviewed
      // (isAfter is strict) — a count is un-reviewed only if strictly newer.
      expect(
        computeReportsAttentionDot(
          pendingApprovals: 0,
          latestStockCountAt: t0,
          lastReviewedAt: t0,
        ),
        isFalse,
      );
    });

    test('no approvals and no counts → off', () {
      expect(
        computeReportsAttentionDot(
          pendingApprovals: 0,
          latestStockCountAt: null,
          lastReviewedAt: null,
        ),
        isFalse,
      );
      expect(
        computeReportsAttentionDot(
          pendingApprovals: 0,
          latestStockCountAt: null,
          lastReviewedAt: t0,
        ),
        isFalse,
      );
    });
  });

  group('reportsAttentionDotProvider (input overrides)', () {
    test('a pending stock-adjustment approval lights the dot', () async {
      expect(await _evaluateDot(stockRequests: [_stockReq('r1')]), isTrue);
    });

    test('a pending quick-sale approval lights the dot', () async {
      expect(
        await _evaluateDot(quickSaleRequests: [_quickSaleReq('q1')]),
        isTrue,
      );
    });

    test('an un-reviewed stock count lights the dot', () async {
      expect(
        await _evaluateDot(
          counts: [_count(DateTime(2026, 1, 1))],
          lastReviewedAt: null,
        ),
        isTrue,
      );
    });

    test('a stock count reviewed later clears the dot', () async {
      expect(
        await _evaluateDot(
          counts: [_count(DateTime(2026, 1, 1, 8))],
          lastReviewedAt: DateTime(2026, 1, 1, 9),
        ),
        isFalse,
      );
    });

    test('no approvals and no counts → dot off', () async {
      expect(await _evaluateDot(), isFalse);
    });

    test('the newest of several counts drives the comparison', () async {
      // Reviewed at 10:00 but a 12:00 count exists → still un-reviewed → on.
      // (watchAllForBusiness orders by businessDate first, so the provider must
      // take the max createdAt, not the list head.)
      expect(
        await _evaluateDot(
          counts: [
            _count(DateTime(2026, 1, 1, 8)),
            _count(DateTime(2026, 1, 1, 12)),
          ],
          lastReviewedAt: DateTime(2026, 1, 1, 10),
        ),
        isTrue,
      );
    });
  });

  group('ReconReviewMarkerNotifier (per-user device-local marker)', () {
    setUp(TestWidgetsFlutterBinding.ensureInitialized);

    test('opening Daily Reconciliation stamps the marker and clears the dot',
        () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          currentUserIdProvider.overrideWith((ref) => 'user-1'),
          viewerScopedPendingStockRequestsProvider.overrideWith((ref) => const []),
          viewerScopedPendingQuickSaleRequestsProvider
              .overrideWith((ref) => const []),
          allStockCountsProvider
              .overrideWith((ref) => Stream.value([_count(DateTime(2026, 1, 1))])),
        ],
      );
      addTearDown(container.dispose);
      await container.read(allStockCountsProvider.future);

      // A count exists and was never reviewed → dot on.
      expect(container.read(reportsAttentionDotProvider), isTrue);

      // Opening the report stamps "now" (which is after the 2026-01-01 count)
      // → the stock-count reason clears and the dot turns off.
      await container.read(reconReviewMarkerProvider.notifier).markOpenedNow();
      expect(container.read(reportsAttentionDotProvider), isFalse);
    });

    test('the marker persists across a restart and is independent per user',
        () async {
      SharedPreferences.setMockInitialValues({});

      final c1 = ProviderContainer(
        overrides: [currentUserIdProvider.overrideWith((ref) => 'user-1')],
      );
      addTearDown(c1.dispose);
      expect(c1.read(reconReviewMarkerProvider), isNull);
      await c1.read(reconReviewMarkerProvider.notifier).markOpenedNow();
      expect(c1.read(reconReviewMarkerProvider), isNotNull);

      // Simulate a restart: a fresh container re-hydrates user-1 from prefs.
      final c2 = ProviderContainer(
        overrides: [currentUserIdProvider.overrideWith((ref) => 'user-1')],
      );
      addTearDown(c2.dispose);
      expect(c2.read(reconReviewMarkerProvider), isNull); // before hydrate
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c2.read(reconReviewMarkerProvider), isNotNull); // hydrated

      // A different user on the same device has an independent (empty) marker.
      final c3 = ProviderContainer(
        overrides: [currentUserIdProvider.overrideWith((ref) => 'user-2')],
      );
      addTearDown(c3.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        c3.read(reconReviewMarkerProvider),
        isNull,
        reason: 'per-user: user-2 has not opened Daily Reconciliation',
      );
    });
  });
}
