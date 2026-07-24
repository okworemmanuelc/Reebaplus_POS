import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/settings/vat_settings.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';

/// Shared aggregation engine for the Daily Reconciliation (§25.9).
///
/// The report is store-scoped (the §12.1 active-store picker) and groupable by
/// Day / Week / Month / Year. This file holds the date-bucket math and the
/// roll-up compute both the list and the detail screens read, so the money math
/// lives in exactly one place (the former separate Business Statement, §25.10,
/// was merged here on 2026-06-07).

// ── Grouping ─────────────────────────────────────────────────────────────────

enum ReconGrouping { day, week, month, year }

extension ReconGroupingX on ReconGrouping {
  String get label => switch (this) {
    ReconGrouping.day => 'Day',
    ReconGrouping.week => 'Week',
    ReconGrouping.month => 'Month',
    ReconGrouping.year => 'Year',
  };

  /// The next-finer grouping the drill-down descends into (null at Day, the leaf).
  ReconGrouping? get finer => switch (this) {
    ReconGrouping.year => ReconGrouping.month,
    ReconGrouping.month => ReconGrouping.week,
    ReconGrouping.week => ReconGrouping.day,
    ReconGrouping.day => null,
  };

  /// Inclusive start of the bucket [d] falls in. Weeks start Sunday (matches
  /// `date_period.dart` / §30.11).
  DateTime startOf(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    switch (this) {
      case ReconGrouping.day:
        return day;
      case ReconGrouping.week:
        return day.subtract(Duration(days: day.weekday % 7)); // Sun=0…Sat=6
      case ReconGrouping.month:
        return DateTime(d.year, d.month, 1);
      case ReconGrouping.year:
        return DateTime(d.year, 1, 1);
    }
  }

  /// Exclusive end of a bucket that began at [start].
  DateTime endOf(DateTime start) {
    switch (this) {
      case ReconGrouping.day:
        return start.add(const Duration(days: 1));
      case ReconGrouping.week:
        return start.add(const Duration(days: 7));
      case ReconGrouping.month:
        return DateTime(start.year, start.month + 1, 1);
      case ReconGrouping.year:
        return DateTime(start.year + 1, 1, 1);
    }
  }

  /// Human label for the bucket beginning at [start].
  String labelFor(DateTime start) {
    switch (this) {
      case ReconGrouping.day:
        return DateFormat('EEE, d MMM yyyy').format(start);
      case ReconGrouping.week:
        final end = start.add(const Duration(days: 6));
        return 'Week of ${DateFormat('d MMM').format(start)} – '
            '${DateFormat('d MMM yyyy').format(end)}';
      case ReconGrouping.month:
        return DateFormat('MMMM yyyy').format(start);
      case ReconGrouping.year:
        return DateFormat('yyyy').format(start);
    }
  }
}

/// The store-scope predicate shared by every reconciliation read: the §12.1
/// active store (a concrete store), else the viewer's full selectable set
/// ("All Stores" for an all-stores viewer; a confined Manager's assigned stores).
bool Function(String?) reconStoreFilter(WidgetRef ref) {
  final selectableIds = ref
      .watch(selectableStoresProvider)
      .map((s) => s.id)
      .toSet();
  final canAll = ref.watch(canViewAllStoresProvider);
  final active = ref.watch(lockedStoreProvider).value;
  return (storeId) {
    if (active != null) return storeId == active;
    if (canAll) return true; // All-Stores aggregate (incl. legacy null-store)
    return storeId != null && selectableIds.contains(storeId);
  };
}

/// A stock adjustment is a damage/loss when its reason names one. Catches both
/// recording paths (§17.2): Record Damages stamps `damage:<key>`; a Manager/CEO
/// manual removal stores the free-text reason ("Theft", "Damage"…). Excludes
/// count reconciliations ("Daily stock count adjustment"), deletion sweeps and
/// `initial_stock`, so a shortage is never double-counted as a damage.
bool isDamageReason(String reason) {
  final r = reason.toLowerCase();
  return r.startsWith('damage') ||
      r.startsWith('theft') ||
      r.startsWith('expired') ||
      r.startsWith('spilled') ||
      r.startsWith('broken');
}

/// A damage/loss reason that specifically names expiry (spoilage past date).
/// The ADR 0014 stock flow-equation card breaks **Expired** out of Damages as
/// its own line. Record Damages stamps `damage:expired` (`stock_count_screen`);
/// a Manager/CEO free-text removal stores "Expired". Both contain "expired", so
/// match on that, case-insensitively. Callers pair this with [isDamageReason]:
/// a non-expired damage is `isDamageReason(r) && !isExpiredReason(r)`.
bool isExpiredReason(String reason) => reason.toLowerCase().contains('expired');

/// A stock-increment reason that names a goods RECEIPT (stock coming in), for
/// the ADR 0014 flow-equation "Goods received" line. Both Receive Stock and Add
/// Product opening stock route through `adjustStock` with the reason "Stock
/// received"; a few synonyms are accepted for robustness. Count reconciliations
/// ("Daily stock count adjustment") and manual removals are deliberately NOT
/// receipts — they fall to the "other movements" residual.
bool isReceiptReason(String reason) {
  final r = reason.toLowerCase();
  return r.contains('received') ||
      r.contains('receipt') ||
      r.contains('restock') ||
      r.contains('opening') ||
      r.contains('initial');
}

/// §17.2 crate-aware damages — FULL crate lost. When a damaged tracked-bottle
/// product also forfeits its refundable crate deposit because the full crate
/// (item + its container) was lost, Record Damages appends this suffix to the
/// `damage:<key>` reason. The held-empties pool is untouched — that container
/// was never a returned empty — so only the deposit is forfeited on the
/// Statement. The suffix keeps the `damage:` prefix so [isDamageReason] still
/// classifies the row. Deposit basis is 1 tracked bottle unit = 1 crate (the
/// same basis `watchFullCratesByManufacturer`/`createOrder` use).
///
/// The other fate — a STORED empty was damaged — is a crate-only loss: no drink
/// is involved, so it removes no bottle stock and writes no stock_adjustment. It
/// is recorded purely as a `damaged` crate_ledger movement
/// ([InventoryDao.recordEmptyCrateDamage]); its forfeited deposit is summed from
/// that ledger in [computeReconData], not from a damage reason.
const String kCrateLostSuffix = '+cratelost';

/// True when a damage reason forfeits the per-crate deposit (a full crate lost).
bool damageForfeitsFullCrate(String reason) =>
    reason.toLowerCase().contains(kCrateLostSuffix);

// ── Buckets (list cards + drill-down breakdown) ──────────────────────────────

class ReconBucket {
  ReconBucket({
    required this.start,
    required this.endExclusive,
    required this.grouping,
    required this.label,
    required this.itemsSold,
    required this.hasShortage,
  });

  final DateTime start;
  final DateTime endExclusive;
  final ReconGrouping grouping;
  final String label;
  final int itemsSold;
  final bool hasShortage;
}

class _BucketAccum {
  _BucketAccum(this.start, this.end);
  final DateTime start;
  final DateTime end;
  int itemsSold = 0;
  bool hasShortage = false;
}

/// Buckets (at [grouping]) that have data within `[start, endExclusive)` — one
/// per Day/Week/Month/Year that recorded sales or a stock count in the active
/// store scope, newest first. `start`/`end` null = unbounded (the top-level list).
List<ReconBucket> buildReconBuckets(
  WidgetRef ref, {
  DateTime? start,
  DateTime? endExclusive,
  required ReconGrouping grouping,
}) {
  final orders = ref.watch(allOrdersProvider).valueOrNull ?? const [];
  final counts = ref.watch(allStockCountsProvider).valueOrNull ?? const [];
  final inScope = reconStoreFilter(ref);
  bool inSpan(DateTime t) =>
      (start == null || !t.isBefore(start)) &&
      (endExclusive == null || t.isBefore(endExclusive));

  final byBucket = <int, _BucketAccum>{};
  _BucketAccum bucketOf(DateTime d) {
    final s = grouping.startOf(d);
    return byBucket.putIfAbsent(
      s.millisecondsSinceEpoch,
      () => _BucketAccum(s, grouping.endOf(s)),
    );
  }

  for (final o in orders) {
    // Revenue is recognized at checkout (status 'pending'), not at the
    // ceremonial Confirm ('completed'). Count any non-reversed sale.
    if (!orderCountsAsSale(o.order.status) || !inSpan(o.order.createdAt)) {
      continue;
    }
    _BucketAccum? acc;
    for (final i in o.items) {
      if (!inScope(i.item.storeId)) continue;
      acc ??= bucketOf(o.order.createdAt);
      acc.itemsSold += i.item.quantity;
    }
  }

  // Collapse re-saved counts to the latest session per (store, date) so a
  // shortage corrected in a later count of the same day stops flagging.
  final sorted = [...counts]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final seen = <String>{};
  for (final c in sorted) {
    if (!inScope(c.storeId)) continue;
    final day = DateTime.tryParse(c.businessDate);
    if (day == null || !inSpan(day)) continue;
    if (!seen.add('${c.businessDate}|${c.storeId}')) continue;
    final acc = bucketOf(day);
    if (c.shortageUnits > 0) acc.hasShortage = true;
  }

  return byBucket.values
      .map(
        (a) => ReconBucket(
          start: a.start,
          endExclusive: a.end,
          grouping: grouping,
          label: grouping.labelFor(a.start),
          itemsSold: a.itemsSold,
          hasShortage: a.hasShortage,
        ),
      )
      .toList()
    ..sort((a, b) => b.start.compareTo(a.start));
}

// ── Full roll-up (detail screen) ─────────────────────────────────────────────

class ReconShortLine {
  ReconShortLine({
    required this.name,
    required this.system,
    required this.actual,
    required this.diff,
  });
  final String name;
  final int system;
  final int actual;
  final int diff;
}

class ReconData {
  ReconData({
    required this.totalRevenueKobo,
    required this.costedRevenueKobo,
    required this.cogsKobo,
    required this.discountsKobo,
    required this.vatEnabled,
    required this.vatRateBps,
    required this.vatKobo,
    required this.itemsSold,
    required this.skus,
    required this.uncostedItems,
    required this.refundsKobo,
    required this.cashSalesKobo,
    required this.cashDebtsCollectedKobo,
    required this.cashRefundsKobo,
    required this.cashExpensesKobo,
    required this.cashSupplierPaidKobo,
    required this.bestStaff,
    required this.bestStaffKobo,
    required this.expensesKobo,
    required this.expensesCount,
    required this.damageUnits,
    required this.damageCostKobo,
    required this.damageRetailKobo,
    required this.crateDamageDepositKobo,
    required this.hasStockCount,
    required this.productsCounted,
    required this.shortageCount,
    required this.shortageUnits,
    required this.surplusCount,
    required this.surplusUnits,
    required this.shortageCostKobo,
    required this.shortageRetailKobo,
    required this.shortages,
    required this.goodsReceivedKobo,
    required this.supplierPaidKobo,
    required this.totalOwedKobo,
    required this.showCrates,
    required this.crateUnits,
    required this.crateDepositKobo,
    required this.heldCrateDepositsKobo,
    required this.supplierCrateDebtKobo,
    required this.supplierPayableKobo,
    required this.inventoryOnHandKobo,
    required this.uncostedInventoryItems,
    required this.surplusCostKobo,
    required this.stockOpeningKobo,
    required this.stockReceivedKobo,
    required this.stockCogsKobo,
    required this.stockDamagesKobo,
    required this.stockExpiredKobo,
    required this.stockOtherMovementsKobo,
    required this.stockExpectedClosingKobo,
    required this.topItems,
    required this.manufacturerEmpties,
  });

  final int totalRevenueKobo;
  final int costedRevenueKobo;
  final int cogsKobo;
  /// Period discounts given on counted sales (`orders.discountKobo`, summed in
  /// scope + span). `order_items.unitPriceKobo` is the GROSS list price, so the
  /// revenue sums above are gross of discount; this is subtracted in the P&L so
  /// profit isn't overstated by the discount given (the order's real payable is
  /// `netAmountKobo = gross − discount`). Contra-revenue, not an expense.
  final int discountsKobo;

  // ── VAT (opt-in, per-business — OFF by default) ──────────────────────────
  // Surfaced only when the business has enabled VAT in Settings (§10.1). Phase 1
  // reports the VAT **due on the period's net sales** (gross − discounts) at the
  // configured rate — it is a pass-through liability, NOT revenue or an expense,
  // so it does not enter the P&L profit math. Adding VAT to the cart/receipt at
  // checkout is a later slice; until then this is the obligation on recorded
  // sales, computed by [computeVatKobo].
  final bool vatEnabled;
  final int vatRateBps; // basis points (750 = 7.5%)
  final int vatKobo; // VAT due on net sales this period (0 when disabled)

  final int itemsSold;
  final int skus;
  final int uncostedItems;
  final int refundsKobo;
  // ── Cash-flow summary (ADR 0014, business-wide) ──────────────────────────
  // Derived cash MOVEMENT for the period from tender-tagged flows (`method ==
  // 'cash'`), NOT a drawer count (Hard Rule #8: no cash balance, no float, no
  // Close Day). `payment_transactions` is the unified physical-cash ledger and
  // has no storeId, so these are business-wide (like outstanding customer debt).
  final int cashSalesKobo; // IN — payment_transactions type 'sale'
  final int cashDebtsCollectedKobo; // IN — type 'wallet_topup' (debt paid in cash)
  final int cashRefundsKobo; // OUT — type 'refund'
  final int cashExpensesKobo; // OUT — type 'expense'
  final int cashSupplierPaidKobo; // OUT — supplier_ledger payment_* (not in pay-txns)
  final String? bestStaff;
  final int bestStaffKobo;
  final int expensesKobo;
  final int expensesCount;
  final int damageUnits;
  final int damageCostKobo;
  final int damageRetailKobo;
  /// §17.2 crate-aware: refundable crate deposit forfeited by damages flagged
  /// "crate lost with item" / "stored empty damaged", valued at the
  /// per-manufacturer deposit rate. A realized loss, separate from the bottle's
  /// own cost (`damageCostKobo`).
  final int crateDamageDepositKobo;
  final bool hasStockCount;
  final int productsCounted;
  final int shortageCount;
  final int shortageUnits;
  final int surplusCount;
  final int surplusUnits;
  final int shortageCostKobo;
  final int shortageRetailKobo;
  final List<ReconShortLine> shortages;
  final int goodsReceivedKobo;
  final int supplierPaidKobo;
  final int totalOwedKobo;
  final bool showCrates;
  final int crateUnits;
  final int crateDepositKobo;

  /// §13.4 / #163 — crate-deposit money the business is still HOLDING for
  /// customers: the `crate_deposit` wallet family net (taken − refunded −
  /// forfeited), business-wide. A liability the net position nets out — it is
  /// owed back the moment a customer returns their crates, so counting the
  /// physical empties as an asset without subtracting it overstates worth. 0 for
  /// a non-crate business (no deposit-family rows exist).
  final int heldCrateDepositsKobo;

  /// #163 — crate debt the business owes SUPPLIERS for the full crates they
  /// delivered, valued at the current per-manufacturer deposit rate (derived
  /// `SUM(quantity_delta × depositAmountKobo)` over `supplier_crate_ledger`). A
  /// liability the net position nets out — the crate-side analogue of the
  /// money-side [supplierPayableKobo]. 0 for a non-crate business.
  final int supplierCrateDebtKobo;

  final int supplierPayableKobo;
  final int inventoryOnHandKobo;
  final int uncostedInventoryItems;
  final int surplusCostKobo;

  // ── Stock flow-equation card (ADR 0014, at current cost) ─────────────────
  // Opening@cost + Goods received − COGS − Damages − Expired (± Other) =
  // Expected closing (the perpetual SYSTEM figure), then Variance = Physical
  // count − Expected. Reconstructed from the `stock_transactions` ledger by
  // rewinding recorded deltas from the current on-hand figure, so the equation
  // ties out by construction (see [computeReconData]). Every term is valued at
  // the product's CURRENT buying price — cost is time-varying under FIFO (ADR
  // 0005) and only current stock is valued today, so this states a current-cost
  // basis rather than pretending to historical-cost precision. CEO-only (§25.3).
  final int stockOpeningKobo; // system stock at period start × current cost
  final int stockReceivedKobo; // goods received in period × current cost
  final int stockCogsKobo; // units sold in period × current cost
  final int stockDamagesKobo; // non-expired damages in period × current cost
  final int stockExpiredKobo; // expired removals in period × current cost
  /// Signed residual: transfers, count reconciliations, and any adjustment not
  /// classified as a sale / receipt / damage / expiry. Keeps the flow equation
  /// tying to the system figure without silently folding these into opening.
  final int stockOtherMovementsKobo;
  final int stockExpectedClosingKobo; // system stock at period end × current cost

  final List<({String name, int qty})> topItems;
  final List<({String manufacturerName, int count, int valueKobo})> manufacturerEmpties;

  /// The configured VAT rate as a display percentage ("7.5"), for card labels.
  String get vatRateLabel =>
      VatConfig(enabled: vatEnabled, rateBps: vatRateBps).ratePercentLabel;

  /// Costed revenue net of discounts given — the real money earned on costed
  /// lines. `costedRevenueKobo` is gross (Σ qty × gross unitPrice), so we
  /// subtract the period's discounts to get what was actually charged.
  int get netRevenueKobo => costedRevenueKobo - discountsKobo;
  int get grossProfitKobo => netRevenueKobo - cogsKobo;
  int get netProfitKobo =>
      grossProfitKobo - expensesKobo - damageCostKobo - crateDamageDepositKobo;

  // ── Cash-flow summary getters (ADR 0014) ─────────────────────────────────
  int get cashInKobo => cashSalesKobo + cashDebtsCollectedKobo;
  int get cashOutKobo =>
      cashRefundsKobo + cashExpensesKobo + cashSupplierPaidKobo;
  /// Expected net cash movement for the period (in − out). Not a cash balance —
  /// there is no opening float to add it to (Hard Rule #8).
  int get netCashMovementKobo => cashInKobo - cashOutKobo;
  bool get hasCashActivity => cashInKobo != 0 || cashOutKobo != 0;

  // ── Stock flow-equation getters (ADR 0014) ───────────────────────────────
  /// Expected closing rebuilt from the flow lines the card renders. Equal to
  /// [stockExpectedClosingKobo] by construction (opening is the rewind of the
  /// period's deltas from the system closing), so displaying both proves the
  /// equation ties out.
  int get stockDerivedClosingKobo =>
      stockOpeningKobo +
      stockReceivedKobo -
      stockCogsKobo -
      stockDamagesKobo -
      stockExpiredKobo +
      stockOtherMovementsKobo;

  /// Variance = Physical count − Expected closing, valued at current cost:
  /// a surplus (physical over system) is positive, a shortage negative. This is
  /// the count discrepancy the recorded flows did NOT explain — the independent
  /// signal the closing report surfaces. Uses the same count figures as the
  /// stock audit (`surplus`/`shortage` at cost). Meaningful only when a physical
  /// count exists in the period ([hasStockCount]).
  int get stockVarianceKobo => surplusCostKobo - shortageCostKobo;

  // ── Integrity flag (ADR 0014 slice 3) ────────────────────────────────────
  // Reconciles reported P&L profit against the independent physical stock
  // count, deriving the gap entirely from recorded flows + the count — no new
  // persistence. A true "Δ net position = profit" identity can't close (no cash
  // leg under Hard Rule #8, no stored period-start snapshot), so the flag
  // instead surfaces the one thing the flows did NOT record: the stock-count
  // variance. Reported profit is built only from sales / COGS / discounts /
  // expenses / damages, so a count shortfall is a RECORDING error (unbooked
  // shrinkage / theft / miscount) the profit figure never reflected — not a
  // separate real loss.

  /// Reported net profit reconciled against the physical count: P&L profit plus
  /// the stock-count variance the flows never booked. Equals [netProfitKobo]
  /// when the count matches the flows (a surplus lifts it, a shortage cuts it).
  int get integrityAdjustedProfitKobo => netProfitKobo + stockVarianceKobo;

  /// True when a physical count was taken and it does not match the recorded
  /// flows — an unexplained gap worth flagging. Without a count there is nothing
  /// independent to reconcile against, so this is false.
  bool get hasIntegrityGap => hasStockCount && stockVarianceKobo != 0;

  /// Whether any stock movement or on-hand value exists to render the card.
  bool get hasStockFlow =>
      stockOpeningKobo != 0 ||
      stockExpectedClosingKobo != 0 ||
      stockReceivedKobo != 0 ||
      stockCogsKobo != 0 ||
      stockDamagesKobo != 0 ||
      stockExpiredKobo != 0 ||
      stockOtherMovementsKobo != 0;

  /// Net result for the period (flow). Folds the inventory-on-hand asset and the
  /// supplier flows (goods received / paid to suppliers / refunds) that used to
  /// sit in the separate "Business worth" and "Other context flows" cards into a
  /// single roll-up, then nets out the period's expenses and losses. The
  /// _netResultCard renders this exact breakdown line-for-line.
  int get periodNetResultKobo =>
      inventoryOnHandKobo +
      goodsReceivedKobo -
      supplierPaidKobo -
      refundsKobo -
      expensesKobo -
      damageCostKobo -
      crateDamageDepositKobo -
      shortageCostKobo;
  /// Point-in-time net worth, honest about crate liabilities (#163). ASSETS:
  /// inventory at cost, the empty crates we physically hold ([crateDepositKobo],
  /// valued at deposit), and money customers owe us. LIABILITIES netted out:
  /// what we owe suppliers for goods ([supplierPayableKobo]), the crate deposits
  /// we still hold for customers ([heldCrateDepositsKobo] — owed back on return),
  /// and the crate debt we owe suppliers ([supplierCrateDebtKobo]). Booking the
  /// crate asset while ignoring the matching deposit/supplier liabilities
  /// overstated worth; both legs are now subtracted.
  int get businessNetPositionKobo =>
      inventoryOnHandKobo +
      totalOwedKobo +
      crateDepositKobo -
      supplierPayableKobo -
      heldCrateDepositsKobo -
      supplierCrateDebtKobo;

  /// Supplier account position (§21): all payments made to suppliers minus all
  /// goods received, point-in-time. The inverse of [supplierPayableKobo] and
  /// identical to `SupplierLedgerDao.getBalanceKobo` (SUM of signed entries).
  ///   • positive (green) → money we paid the supplier IN ADVANCE (a
  ///     prepayment) — NOT money we hold on their behalf;
  ///   • negative (red)   → a debt WE owe the supplier for unpaid goods.
  /// Display this signed value — never relabel an advance payment as "owed".
  int get supplierAccountBalanceKobo => -supplierPayableKobo;

  /// Gross margin as a 1-dp percentage string ("0.0" when there's no net
  /// revenue). Measured against net revenue (after discounts), so the margin
  /// reflects money actually earned. Shared by the P&L card and the CSV export.
  String get grossMarginPct => netRevenueKobo > 0
      ? (grossProfitKobo / netRevenueKobo * 100).toStringAsFixed(1)
      : '0.0';

  bool get isEmpty =>
      totalRevenueKobo == 0 &&
      expensesKobo == 0 &&
      damageUnits == 0 &&
      shortageUnits == 0 &&
      !hasStockCount &&
      goodsReceivedKobo == 0 &&
      supplierPaidKobo == 0 &&
      refundsKobo == 0 &&
      totalOwedKobo == 0 &&
      crateUnits == 0;
}

/// Full reconciliation roll-up for `[start, endExclusive)` in the active store
/// scope. `isCeo` only gates the supplier-ledger flows (the rest is computed
/// either way; the screen decides which figures to show per the cost wall).
ReconData computeReconData(
  WidgetRef ref, {
  DateTime? start,
  DateTime? endExclusive,
  required bool isCeo,
}) {
  final orders = ref.watch(allOrdersProvider).valueOrNull ?? const [];
  final expenses = ref.watch(allExpensesProvider).valueOrNull ?? const [];
  final adjustments =
      ref.watch(allStockAdjustmentsProvider).valueOrNull ?? const [];
  final ledger =
      ref.watch(allSupplierLedgerEntriesProvider).valueOrNull ?? const [];
  final payments =
      ref.watch(allPaymentTransactionsProvider).valueOrNull ?? const [];
  final stockTxns =
      ref.watch(allStockTransactionsProvider).valueOrNull ?? const [];
  final counts = ref.watch(allStockCountsProvider).valueOrNull ?? const [];
  // Inventory-on-hand must honour the active-store scope like every other
  // figure here (§12.1): pass the locked store so a single-store view doesn't
  // sum every store's stock (null = All Stores). The products list itself is
  // unaffected — only the stock totals are store-filtered — so `productById`
  // (used for damage/shortage/surplus cost lookups) stays complete.
  final activeStoreId = ref.watch(lockedStoreProvider).value;
  final productsWS =
      ref.watch(productsWithStockProvider(activeStoreId)).valueOrNull ??
      const [];
  final balances =
      ref.watch(creditBalancesKoboProvider).valueOrNull ?? const {};
  final manufacturers =
      ref.watch(allManufacturersProvider).valueOrNull ?? const [];
  final crateCounts =
      ref.watch(emptyCratesByManufacturerProvider).valueOrNull ?? const {};
  // §17.2 crate-aware: `damaged` crate_ledger rows are the stored-empty fate —
  // a crate-only loss that writes no stock_adjustment. Drives the forfeited
  // deposit below.
  final crateDamages =
      ref.watch(allCrateDamagesProvider).valueOrNull ?? const [];
  final users = ref.watch(usersByBusinessProvider).valueOrNull ?? const {};
  final vat = ref.watch(vatConfigProvider).valueOrNull ?? VatConfig.off;

  final productById = {for (final p in productsWS) p.product.id: p.product};
  final inScope = reconStoreFilter(ref);
  bool inSpan(DateTime t) =>
      (start == null || !t.isBefore(start)) &&
      (endExclusive == null || t.isBefore(endExclusive));

  // ── Sales / P&L (mirrors the Profit Report's costed-line model) ──────────
  var totalRevenueKobo = 0;
  var costedRevenueKobo = 0;
  var cogsKobo = 0;
  var discountsKobo = 0;
  var itemsSold = 0;
  var uncostedItems = 0;
  var refundsKobo = 0;
  final skuSet = <String>{};
  final byStaff = <String?, int>{};
  final byProduct = <String, ({String name, int qty})>{};
  for (final o in orders) {
    if (o.order.status == 'refunded') {
      if (inSpan(o.order.createdAt) && inScope(o.order.storeId)) {
        refundsKobo += o.order.amountPaidKobo;
      }
      continue;
    }
    // Recognized at checkout ('pending'), not at Confirm ('completed').
    if (!orderCountsAsSale(o.order.status) || !inSpan(o.order.createdAt)) {
      continue;
    }
    // Order-level discount (contra-revenue). Scoped by the order's store to
    // match refunds above; lines carry the same storeId in practice.
    if (inScope(o.order.storeId)) discountsKobo += o.order.discountKobo;
    var orderRevenue = 0;
    for (final i in o.items) {
      if (!inScope(i.item.storeId)) continue;
      final lineRev = i.item.quantity * i.item.unitPriceKobo;
      totalRevenueKobo += lineRev;
      orderRevenue += lineRev;
      itemsSold += i.item.quantity;
      final product = i.product;
      if (product == null || i.item.buyingPriceKobo <= 0) {
        uncostedItems += i.item.quantity;
      } else {
        costedRevenueKobo += lineRev;
        cogsKobo += i.item.quantity * i.item.buyingPriceKobo;
        skuSet.add(product.id);
      }
      // Rank top items by units sold across every identifiable product —
      // including ones with no recorded buying price. Truly ad-hoc lines (no
      // linked product) carry no SKU/name to rank, so they're omitted.
      if (product != null) {
        final cur = byProduct[product.id];
        byProduct[product.id] = (
          name: product.name,
          qty: (cur?.qty ?? 0) + i.item.quantity,
        );
      }
    }
    if (orderRevenue > 0) {
      byStaff.update(
        o.order.staffId,
        (v) => v + orderRevenue,
        ifAbsent: () => orderRevenue,
      );
    }
  }
  String? bestStaff;
  var bestStaffKobo = 0;
  byStaff.forEach((staffId, v) {
    if (v > bestStaffKobo) {
      bestStaffKobo = v;
      bestStaff = staffId == null
          ? 'Unassigned'
          : (users[staffId]?.name ?? 'Staff');
    }
  });
  final topItemsList = byProduct.entries
      .map((e) => (name: e.value.name, qty: e.value.qty))
      .toList()
    ..sort((a, b) => b.qty.compareTo(a.qty));
  final topItems = topItemsList.take(3).toList();

  // ── VAT due on net sales (only when the business has enabled VAT) ─────────
  // Base = gross sales − discounts (scope-consistent with the sums above). A
  // pass-through liability computed on recorded sales; it does not affect the
  // P&L profit lines.
  final vatKobo = vat.enabled
      ? computeVatKobo(totalRevenueKobo - discountsKobo, vat.rateBps)
      : 0;

  // ── Inventory on hand at cost (point-in-time) ────────────────────────────
  var inventoryOnHandKobo = 0;
  var uncostedInventoryItems = 0;
  for (final p in productsWS) {
    if (p.product.buyingPriceKobo <= 0) {
      uncostedInventoryItems += p.totalStock;
    } else {
      inventoryOnHandKobo += p.totalStock * p.product.buyingPriceKobo;
    }
  }

  // ── Stock flow-equation at current cost (ADR 0014) ───────────────────────
  // Opening@cost + Goods received − COGS − Damages − Expired (± Other) =
  // Expected closing (the perpetual SYSTEM figure), then Variance = Physical −
  // Expected (the stock-count discrepancy). Opening and expected-closing are
  // reconstructed by rewinding the recorded `stock_transactions` deltas from
  // the current on-hand figure, so the equation ties to the system by
  // construction. Every term is valued at the product's CURRENT buying price —
  // cost is time-varying under FIFO (ADR 0005) and only current stock is valued
  // today, so this states a current-cost basis rather than faking historical
  // precision. Store scope is applied per row's `locationId` like every figure
  // here. Receipts (Receive Stock / opening stock) and manual adjustments share
  // movementType 'adjustment', so they're split by the linked reason; anything
  // unclassified (transfers, count reconciliations) is kept in an "other
  // movements" residual so nothing is silently folded into opening.
  final reasonByAdjustmentId = {for (final a in adjustments) a.id: a.reason};
  final currentUnits = {
    for (final p in productsWS) p.product.id: p.totalStock,
  };
  final afterEndUnits = <String, int>{}; // deltas at/after period end (rewind)
  final periodDelta = <String, int>{}; // net delta within the period
  final receivedUnits = <String, int>{};
  final soldUnits = <String, int>{};
  final damagedUnits = <String, int>{};
  final expiredUnits = <String, int>{};
  final otherDelta = <String, int>{}; // signed residual within the period
  void add(Map<String, int> m, String k, int v) => m[k] = (m[k] ?? 0) + v;
  for (final t in stockTxns) {
    if (t.voidedAt != null || !inScope(t.locationId)) continue;
    final pid = t.productId;
    final delta = t.quantityDelta;
    if (endExclusive != null && !t.createdAt.isBefore(endExclusive)) {
      add(afterEndUnits, pid, delta);
    }
    if (!inSpan(t.createdAt)) continue;
    add(periodDelta, pid, delta);
    final mt = t.movementType;
    if (mt == 'sale' || mt == 'return') {
      // A return (stock restored) nets against units sold.
      add(soldUnits, pid, -delta);
    } else if (mt == 'received' || mt == 'restock') {
      add(receivedUnits, pid, delta);
    } else if (mt == 'adjustment' || mt == 'adjusted') {
      final reason = t.adjustmentId == null
          ? ''
          : (reasonByAdjustmentId[t.adjustmentId] ?? '');
      if (isExpiredReason(reason)) {
        add(expiredUnits, pid, -delta);
      } else if (isDamageReason(reason)) {
        add(damagedUnits, pid, -delta);
      } else if (isReceiptReason(reason)) {
        add(receivedUnits, pid, delta);
      } else {
        add(otherDelta, pid, delta);
      }
    } else {
      // transfer_in / transfer_out / anything unclassified
      add(otherDelta, pid, delta);
    }
  }
  var stockOpeningKobo = 0;
  var stockReceivedKobo = 0;
  var stockCogsKobo = 0;
  var stockDamagesKobo = 0;
  var stockExpiredKobo = 0;
  var stockOtherMovementsKobo = 0;
  var stockExpectedClosingKobo = 0;
  final flowPids = <String>{
    ...currentUnits.keys,
    ...periodDelta.keys,
    ...afterEndUnits.keys,
  };
  for (final pid in flowPids) {
    final cost = productById[pid]?.buyingPriceKobo ?? 0;
    if (cost <= 0) continue; // uncosted units carry no value (P&L footnote)
    final closing = (currentUnits[pid] ?? 0) - (afterEndUnits[pid] ?? 0);
    final opening = closing - (periodDelta[pid] ?? 0);
    stockOpeningKobo += opening * cost;
    stockExpectedClosingKobo += closing * cost;
    stockReceivedKobo += (receivedUnits[pid] ?? 0) * cost;
    stockCogsKobo += (soldUnits[pid] ?? 0) * cost;
    stockDamagesKobo += (damagedUnits[pid] ?? 0) * cost;
    stockExpiredKobo += (expiredUnits[pid] ?? 0) * cost;
    stockOtherMovementsKobo += (otherDelta[pid] ?? 0) * cost;
  }

  // ── Expenses (approved, in span, in scope) ───────────────────────────────
  var expensesKobo = 0;
  var expensesCount = 0;
  for (final e in expenses) {
    if (e.expense.isDeleted || e.expense.status != 'approved') continue;
    if (!inSpan(e.expense.createdAt) || !inScope(e.expense.storeId)) continue;
    expensesKobo += e.expense.amountKobo;
    expensesCount++;
  }

  // ── Damages (reason names a loss; a removal) ─────────────────────────────
  // §17.2 crate-aware: a damage flagged +cratelost / +crateempty also forfeits
  // the per-crate refundable deposit (1 tracked bottle unit = 1 crate). The
  // deposit rate is per-manufacturer (Manufacturers.depositAmountKobo).
  final depositByMfr = {for (final m in manufacturers) m.id: m.depositAmountKobo};
  var damageUnits = 0;
  var damageCostKobo = 0;
  var damageRetailKobo = 0;
  var crateDamageDepositKobo = 0;
  for (final a in adjustments) {
    if (!isDamageReason(a.reason) || a.quantityDiff >= 0) continue;
    if (!inSpan(a.createdAt) || !inScope(a.storeId)) continue;
    final units = -a.quantityDiff;
    final p = productById[a.productId];
    damageUnits += units;
    damageCostKobo += units * (p?.buyingPriceKobo ?? 0);
    damageRetailKobo += units * (p?.retailerPriceKobo ?? 0);
    if (damageForfeitsFullCrate(a.reason)) {
      crateDamageDepositKobo += units * (depositByMfr[p?.manufacturerId] ?? 0);
    }
  }
  // §17.2 crate-aware: a STORED empty damaged writes no stock_adjustment (no
  // drink lost) — only a `damaged` crate_ledger movement. Forfeit its deposit
  // here so the Statement still recognises the loss. The pool debit it also
  // makes is reflected separately in "Empty crates held" (the stock view), so
  // the period P&L (flow) and the held-empties asset (stock) never double-count
  // the same crate.
  for (final c in crateDamages) {
    if (c.voidedAt != null) continue;
    if (!inSpan(c.createdAt) || !inScope(c.storeId)) continue;
    final lostEmpties = -c.quantityDelta;
    if (lostEmpties <= 0) continue;
    crateDamageDepositKobo +=
        lostEmpties * (depositByMfr[c.manufacturerId] ?? 0);
  }

  // ── Stock audit + shortage value (latest count per store/date in span) ───
  final dayCounts =
      counts
          .where(
            (c) =>
                inScope(c.storeId) &&
                inSpan(DateTime.tryParse(c.businessDate) ?? DateTime(0)),
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final seenCount = <String>{};
  var hasStockCount = false;
  var productsCounted = 0;
  var shortageCount = 0;
  var shortageUnits = 0;
  var surplusCount = 0;
  var surplusUnits = 0;
  var surplusCostKobo = 0;
  var shortageCostKobo = 0;
  var shortageRetailKobo = 0;
  final shortages = <ReconShortLine>[];
  for (final c in dayCounts) {
    if (!seenCount.add('${c.businessDate}|${c.storeId}')) continue;
    hasStockCount = true;
    productsCounted += c.productsCounted;
    shortageCount += c.shortageCount;
    shortageUnits += c.shortageUnits;
    surplusCount += c.surplusCount;
    surplusUnits += c.surplusUnits;
    for (final l
        in (jsonDecode(c.linesJson) as List).cast<Map<String, dynamic>>()) {
      final diff = (l['d'] as num).toInt();
      final p = productById[l['p'] as String?];
      if (diff > 0) {
        surplusCostKobo += diff * (p?.buyingPriceKobo ?? 0);
      }
      if (diff >= 0) continue;
      final units = -diff;
      shortageCostKobo += units * (p?.buyingPriceKobo ?? 0);
      shortageRetailKobo += units * (p?.retailerPriceKobo ?? 0);
      shortages.add(
        ReconShortLine(
          name: l['n'] as String? ?? 'Product',
          system: (l['s'] as num).toInt(),
          actual: (l['a'] as num).toInt(),
          diff: diff,
        ),
      );
    }
  }

  // ── Supplier ledger flows (CEO only) ─────────────────────────────────────
  var goodsReceivedKobo = 0;
  var supplierPaidKobo = 0;
  var supplierPayableKobo = 0;
  if (isCeo) {
    for (final l in ledger) {
      // Skip both halves of a voided pair (original carries voidedAt; the
      // compensating reversal is referenceType 'void') for clean gross flows.
      if (l.voidedAt != null || l.referenceType == 'void') continue;
      if (!inScope(l.storeId)) continue;
      
      if (l.referenceType == 'invoice') {
        supplierPayableKobo += l.amountKobo;
      } else if (l.referenceType.startsWith('payment_')) {
        supplierPayableKobo -= l.amountKobo;
      }

      if (!inSpan(l.activityDate)) continue;
      if (l.referenceType == 'invoice') {
        goodsReceivedKobo += l.amountKobo;
      } else if (l.referenceType.startsWith('payment_')) {
        supplierPaidKobo += l.amountKobo;
      }
    }
  }

  // ── Cash-flow summary (ADR 0014; business-wide, tender-tagged) ───────────
  // Expected cash MOVEMENT for the period from recorded cash tenders — NOT a
  // drawer count (Hard Rule #8: no float, no counted cash). payment_transactions
  // is the unified physical-cash ledger (sale / wallet_topup / refund / expense,
  // each with a `method`) and has no storeId, so this card is business-wide.
  // Crate deposits (a refundable held liability) are deliberately excluded — the
  // ask is operating cash (sales + debts collected). `method` casing drifts
  // ('Cash'/'cash'), so match case-insensitively.
  var cashSalesKobo = 0;
  var cashDebtsCollectedKobo = 0;
  var cashRefundsKobo = 0;
  var cashExpensesKobo = 0;
  for (final p in payments) {
    if (p.voidedAt != null) continue;
    if (p.method.toLowerCase() != 'cash') continue;
    if (!inSpan(p.createdAt)) continue;
    if (p.type == 'sale') {
      cashSalesKobo += p.amountKobo;
    } else if (p.type == 'wallet_topup') {
      cashDebtsCollectedKobo += p.amountKobo;
    } else if (p.type == 'refund') {
      cashRefundsKobo += p.amountKobo;
    } else if (p.type == 'expense') {
      cashExpensesKobo += p.amountKobo;
    }
  }
  // Supplier payments made in cash — the one cash-out NOT in payment_transactions
  // (recorded only on the supplier ledger). Business-wide, in span, to match the
  // rest of the cash card.
  var cashSupplierPaidKobo = 0;
  for (final l in ledger) {
    if (l.voidedAt != null || l.referenceType == 'void') continue;
    if (!l.referenceType.startsWith('payment_')) continue;
    if (!inSpan(l.activityDate)) continue;
    if ((l.paymentMethod ?? '').toLowerCase() != 'cash') continue;
    cashSupplierPaidKobo += l.amountKobo;
  }

  // ── Outstanding customer debt (business-wide — wallets aren't per store) ──
  final totalOwedKobo = balances.values
      .where((b) => b < 0)
      .fold<int>(0, (s, b) => s - b);

  // ── Empty crates held (Bar / Beer Distributor only; point-in-time) ───────
  final showCrates = businessTracksCrates(ref.watch(currentBusinessProvider));
  var crateUnits = 0;
  var crateDepositKobo = 0;
  final manufacturerEmpties = <({String manufacturerName, int count, int valueKobo})>[];
  if (showCrates) {
    final depositById = {
      for (final m in manufacturers) m.id: m.depositAmountKobo,
    };
    final mfrNameById = {
      for (final m in manufacturers) m.id: m.name,
    };
    crateCounts.forEach((mfrId, count) {
      if (count > 0) {
        crateUnits += count;
        final value = count * (depositById[mfrId] ?? 0);
        crateDepositKobo += value;
        manufacturerEmpties.add((
          manufacturerName: mfrNameById[mfrId] ?? 'Unknown',
          count: count,
          valueKobo: value,
        ));
      }
    });
  }

  // ── Crate liabilities (#163) — netted against the empties asset above ────
  // The empties we physically hold ([crateDepositKobo]) are only ours to the
  // extent we don't owe them elsewhere: we owe customers back the deposits they
  // paid ([crate_deposit] wallet family net), and we owe suppliers empties for
  // the full crates they delivered (derived supplier crate ledger × current
  // deposit rate). Both are business-wide (wallets / supplier crate debt aren't
  // per store, like [totalOwedKobo]) and ledger-derived — trustworthy only now
  // that #158–#162 made the balances the ledger's, not a stored cache. Gated on
  // [showCrates] so a non-crate business carries no crate legs (they're 0
  // anyway — no deposit-family rows, no supplier crate ledger).
  var heldCrateDepositsKobo = 0;
  var supplierCrateDebtKobo = 0;
  if (showCrates) {
    heldCrateDepositsKobo =
        ref.watch(crateDepositSummaryProvider).valueOrNull?.heldKobo ?? 0;
    supplierCrateDebtKobo =
        ref.watch(supplierCrateDebtValueKoboProvider).valueOrNull ?? 0;
  }

  return ReconData(
    totalRevenueKobo: totalRevenueKobo,
    costedRevenueKobo: costedRevenueKobo,
    cogsKobo: cogsKobo,
    discountsKobo: discountsKobo,
    vatEnabled: vat.enabled,
    vatRateBps: vat.rateBps,
    vatKobo: vatKobo,
    itemsSold: itemsSold,
    skus: skuSet.length,
    uncostedItems: uncostedItems,
    refundsKobo: refundsKobo,
    cashSalesKobo: cashSalesKobo,
    cashDebtsCollectedKobo: cashDebtsCollectedKobo,
    cashRefundsKobo: cashRefundsKobo,
    cashExpensesKobo: cashExpensesKobo,
    cashSupplierPaidKobo: cashSupplierPaidKobo,
    bestStaff: bestStaff,
    bestStaffKobo: bestStaffKobo,
    expensesKobo: expensesKobo,
    expensesCount: expensesCount,
    damageUnits: damageUnits,
    damageCostKobo: damageCostKobo,
    damageRetailKobo: damageRetailKobo,
    crateDamageDepositKobo: crateDamageDepositKobo,
    hasStockCount: hasStockCount,
    productsCounted: productsCounted,
    shortageCount: shortageCount,
    shortageUnits: shortageUnits,
    surplusCount: surplusCount,
    surplusUnits: surplusUnits,
    shortageCostKobo: shortageCostKobo,
    shortageRetailKobo: shortageRetailKobo,
    shortages: shortages,
    goodsReceivedKobo: goodsReceivedKobo,
    supplierPaidKobo: supplierPaidKobo,
    totalOwedKobo: totalOwedKobo,
    showCrates: showCrates,
    crateUnits: crateUnits,
    crateDepositKobo: crateDepositKobo,
    heldCrateDepositsKobo: heldCrateDepositsKobo,
    supplierCrateDebtKobo: supplierCrateDebtKobo,
    supplierPayableKobo: supplierPayableKobo,
    inventoryOnHandKobo: inventoryOnHandKobo,
    uncostedInventoryItems: uncostedInventoryItems,
    surplusCostKobo: surplusCostKobo,
    stockOpeningKobo: stockOpeningKobo,
    stockReceivedKobo: stockReceivedKobo,
    stockCogsKobo: stockCogsKobo,
    stockDamagesKobo: stockDamagesKobo,
    stockExpiredKobo: stockExpiredKobo,
    stockOtherMovementsKobo: stockOtherMovementsKobo,
    stockExpectedClosingKobo: stockExpectedClosingKobo,
    topItems: topItems,
    manufacturerEmpties: manufacturerEmpties,
  );
}
