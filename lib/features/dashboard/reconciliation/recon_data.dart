import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';

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
    if (o.order.status != 'completed' || !inSpan(o.order.createdAt)) continue;
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
    required this.itemsSold,
    required this.skus,
    required this.uncostedItems,
    required this.refundsKobo,
    required this.bestStaff,
    required this.bestStaffKobo,
    required this.topItem,
    required this.topItemQty,
    required this.expensesKobo,
    required this.expensesCount,
    required this.damageUnits,
    required this.damageCostKobo,
    required this.damageRetailKobo,
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
  });

  final int totalRevenueKobo;
  final int costedRevenueKobo;
  final int cogsKobo;
  final int itemsSold;
  final int skus;
  final int uncostedItems;
  final int refundsKobo;
  final String? bestStaff;
  final int bestStaffKobo;
  final String? topItem;
  final int topItemQty;
  final int expensesKobo;
  final int expensesCount;
  final int damageUnits;
  final int damageCostKobo;
  final int damageRetailKobo;
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

  int get grossProfitKobo => costedRevenueKobo - cogsKobo;
  int get netProfitKobo => grossProfitKobo - expensesKobo - damageCostKobo;

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
  final counts = ref.watch(allStockCountsProvider).valueOrNull ?? const [];
  final productsWS =
      ref.watch(productsWithStockProvider(null)).valueOrNull ?? const [];
  final balances =
      ref.watch(walletBalancesKoboProvider).valueOrNull ?? const {};
  final manufacturers =
      ref.watch(allManufacturersProvider).valueOrNull ?? const [];
  final crateCounts =
      ref.watch(emptyCratesByManufacturerProvider).valueOrNull ?? const {};
  final businesses = ref.watch(localBusinessesProvider).valueOrNull ?? const [];
  final users = ref.watch(usersByBusinessProvider).valueOrNull ?? const {};

  final productById = {for (final p in productsWS) p.product.id: p.product};
  final inScope = reconStoreFilter(ref);
  bool inSpan(DateTime t) =>
      (start == null || !t.isBefore(start)) &&
      (endExclusive == null || t.isBefore(endExclusive));

  // ── Sales / P&L (mirrors the Profit Report's costed-line model) ──────────
  var totalRevenueKobo = 0;
  var costedRevenueKobo = 0;
  var cogsKobo = 0;
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
    if (o.order.status != 'completed' || !inSpan(o.order.createdAt)) continue;
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
  String? topItem;
  var topItemQty = 0;
  byProduct.forEach((_, p) {
    if (p.qty > topItemQty) {
      topItemQty = p.qty;
      topItem = p.name;
    }
  });

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
  var damageUnits = 0;
  var damageCostKobo = 0;
  var damageRetailKobo = 0;
  for (final a in adjustments) {
    if (!isDamageReason(a.reason) || a.quantityDiff >= 0) continue;
    if (!inSpan(a.createdAt) || !inScope(a.storeId)) continue;
    final units = -a.quantityDiff;
    final p = productById[a.productId];
    damageUnits += units;
    damageCostKobo += units * (p?.buyingPriceKobo ?? 0);
    damageRetailKobo += units * (p?.retailerPriceKobo ?? 0);
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
      if (diff >= 0) continue;
      final units = -diff;
      final p = productById[l['p'] as String?];
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
  if (isCeo) {
    for (final l in ledger) {
      // Skip both halves of a voided pair (original carries voidedAt; the
      // compensating reversal is referenceType 'void') for clean gross flows.
      if (l.voidedAt != null || l.referenceType == 'void') continue;
      if (!inSpan(l.activityDate) || !inScope(l.storeId)) continue;
      if (l.referenceType == 'invoice') {
        goodsReceivedKobo += l.amountKobo;
      } else if (l.referenceType.startsWith('payment_')) {
        supplierPaidKobo += l.amountKobo;
      }
    }
  }

  // ── Outstanding customer debt (business-wide — wallets aren't per store) ──
  final totalOwedKobo = balances.values
      .where((b) => b < 0)
      .fold<int>(0, (s, b) => s - b);

  // ── Empty crates held (Bar / Beer Distributor only; point-in-time) ───────
  final bizId = ref.watch(databaseProvider).currentBusinessId;
  String? bizType;
  for (final b in businesses) {
    if (b.id == bizId) {
      bizType = b.type;
      break;
    }
  }
  final showCrates = isCrateBusiness(bizType);
  var crateUnits = 0;
  var crateDepositKobo = 0;
  if (showCrates) {
    final depositById = {
      for (final m in manufacturers) m.id: m.depositAmountKobo,
    };
    crateCounts.forEach((mfrId, count) {
      if (count > 0) {
        crateUnits += count;
        crateDepositKobo += count * (depositById[mfrId] ?? 0);
      }
    });
  }

  return ReconData(
    totalRevenueKobo: totalRevenueKobo,
    costedRevenueKobo: costedRevenueKobo,
    cogsKobo: cogsKobo,
    itemsSold: itemsSold,
    skus: skuSet.length,
    uncostedItems: uncostedItems,
    refundsKobo: refundsKobo,
    bestStaff: bestStaff,
    bestStaffKobo: bestStaffKobo,
    topItem: topItem,
    topItemQty: topItemQty,
    expensesKobo: expensesKobo,
    expensesCount: expensesCount,
    damageUnits: damageUnits,
    damageCostKobo: damageCostKobo,
    damageRetailKobo: damageRetailKobo,
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
  );
}
