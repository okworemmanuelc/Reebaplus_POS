import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/data/business_types.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/business_time.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';

/// One calendar day's full reconciliation (§25.2 / §25.9). Rolls up, for the
/// given business date: the day's sales summary (SKUs / items sold / value /
/// best staff / top item), the Close Day cash audit per account (expected vs
/// counted, variance flagged), the saved stock count (shortage / surplus +
/// itemised), the current outstanding customer debt and empty-crate holdings
/// (summaries from the existing subsystems, not duplicates), and the approved
/// expenses recorded that day. Read-only; role-gated upstream (CEO/Manager).
class DailyReconciliationDetailScreen extends ConsumerStatefulWidget {
  const DailyReconciliationDetailScreen({super.key, required this.businessDate});

  /// `YYYY-MM-DD` business day this screen reconciles.
  final String businessDate;

  @override
  ConsumerState<DailyReconciliationDetailScreen> createState() =>
      _DailyReconciliationDetailScreenState();
}

class _DailyReconciliationDetailScreenState
    extends ConsumerState<DailyReconciliationDetailScreen> {
  String get _date => widget.businessDate;

  String _prettyDate() {
    final d = DateTime.tryParse(_date);
    return d == null ? _date : DateFormat('EEE, d MMM yyyy').format(d);
  }

  Future<void> _exportCsv(_ReconData d) async {
    final rows = <List<String>>[
      ['Sales — items sold', '${d.items}'],
      ['Sales — SKUs sold', '${d.skus}'],
      ['Sales — total value', (d.salesKobo / 100.0).toStringAsFixed(2)],
      ['Sales — best staff', d.bestStaff ?? ''],
      ['Sales — top item', d.topItem ?? ''],
      // Cash/funds rows only for `funds.view` holders (hard rule #6) — mirrors
      // the gated cash card so the CSV can't leak balances the screen hides.
      if (hasPermission(ref, 'funds.view')) ...[
        for (final c in d.cash)
          ['Cash: ${c.account}', 'expected ${(c.expectedKobo / 100.0).toStringAsFixed(2)}; '
              'counted ${(c.countedKobo / 100.0).toStringAsFixed(2)}; '
              'variance ${(c.varianceKobo / 100.0).toStringAsFixed(2)}'],
        ['Cash — net variance', (d.netVarianceKobo / 100.0).toStringAsFixed(2)],
      ],
      ['Stock — products counted', '${d.productsCounted}'],
      ['Stock — short (products/units)', '${d.shortageCount} / ${d.shortageUnits}'],
      ['Stock — surplus (products/units)', '${d.surplusCount} / ${d.surplusUnits}'],
      ['Outstanding customer debt', (d.totalOwedKobo / 100.0).toStringAsFixed(2)],
      ['Expenses recorded (approved)', (d.expensesKobo / 100.0).toStringAsFixed(2)],
    ];
    try {
      await shareCsv(
        csv: buildCsv(['Metric', 'Value'], rows),
        fileName: 'reconciliation_$_date',
        subject: 'Daily Reconciliation — $_date',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money displays when currency changes
    final theme = Theme.of(context);
    final tz = ref.watch(businessTimezoneProvider).valueOrNull;
    final data = _compute(tz);

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reconciliation',
                style: context.h3.copyWith(fontWeight: FontWeight.bold)),
            Text(_prettyDate(),
                style: context.bodySmall.copyWith(color: theme.hintColor)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: Icon(FontAwesomeIcons.fileCsv,
                size: 18, color: context.primaryColor),
            onPressed: () => _exportCsv(data),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(context.spacingM).copyWith(
          bottom: context.spacingM + context.deviceBottomInset,
        ),
        children: [
          _salesCard(theme, data),
          // The cash/funds section exposes per-account balances — the data
          // `funds.view` protects (hard rule #6). §25.3 keeps the rest of the
          // reconciliation report Manager-accessible; only this block is gated.
          if (hasPermission(ref, 'funds.view')) ...[
            SizedBox(height: context.spacingM),
            _cashCard(theme, data),
          ],
          SizedBox(height: context.spacingM),
          _stockCard(theme, data),
          SizedBox(height: context.spacingM),
          _moneyCard(theme, data),
          if (data.showCrates) ...[
            SizedBox(height: context.spacingM),
            _cratesCard(theme, data),
          ],
        ],
      ),
    );
  }

  _ReconData _compute(String? tz) {
    final orders = ref.watch(allOrdersProvider).valueOrNull ?? const [];
    final closings = ref.watch(allFundDayClosingsProvider).valueOrNull ?? const [];
    final accounts = ref.watch(allFundsAccountsProvider).valueOrNull ?? const [];
    final stockCounts = ref.watch(allStockCountsProvider).valueOrNull ?? const [];
    final balances =
        ref.watch(walletBalancesKoboProvider).valueOrNull ?? const {};
    final expenses = ref.watch(allExpensesProvider).valueOrNull ?? const [];
    final users = ref.watch(usersByBusinessProvider).valueOrNull ?? const {};
    final businesses = ref.watch(localBusinessesProvider).valueOrNull ?? const [];
    final crateCounts =
        ref.watch(emptyCratesByManufacturerProvider).valueOrNull ?? const {};
    final manufacturers =
        ref.watch(allManufacturersProvider).valueOrNull ?? const [];

    // ── Sales summary (day-bucketed by the business timezone) ──────────────
    final skus = <String>{};
    var items = 0;
    var salesKobo = 0;
    final byStaff = <String?, int>{};
    final byProduct = <String, ({String name, int qty})>{};
    final salesReady = tz != null;
    if (salesReady) {
      for (final o in orders) {
        if (o.order.status != 'completed') continue;
        if (businessDateString(o.order.createdAt, tz) != _date) continue;
        var orderRevenue = 0;
        for (final i in o.items) {
          orderRevenue += i.item.quantity * i.item.unitPriceKobo;
          items += i.item.quantity;
          // Quick-sale lines (§12.3) count toward revenue + items sold, but
          // have no product → excluded from the SKU set and top-item breakdown.
          final product = i.product;
          if (product != null) {
            skus.add(product.id);
            final cur = byProduct[product.id];
            byProduct[product.id] =
                (name: product.name, qty: (cur?.qty ?? 0) + i.item.quantity);
          }
        }
        salesKobo += orderRevenue;
        byStaff.update(o.order.staffId, (v) => v + orderRevenue,
            ifAbsent: () => orderRevenue);
      }
    }
    String? bestStaff;
    var bestStaffKobo = 0;
    byStaff.forEach((staffId, value) {
      if (value > bestStaffKobo) {
        bestStaffKobo = value;
        bestStaff = staffId == null ? 'Unassigned' : (users[staffId]?.name ?? 'Staff');
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

    // ── Cash audit (Close Day snapshot, keyed by business date) ────────────
    final accountById = {for (final a in accounts) a.id: a};
    final dayClosings =
        closings.where((c) => c.businessDate == _date).toList();
    final cash = [
      for (final c in dayClosings)
        _CashRow(
          account: accountById[c.fundsAccountId]?.name ?? _typeLabel(c.accountType),
          expectedKobo: c.expectedKobo,
          countedKobo: c.countedKobo,
          varianceKobo: c.varianceKobo,
        ),
    ];
    final netVarianceKobo =
        dayClosings.fold<int>(0, (s, c) => s + c.varianceKobo);

    // ── Stock audit (saved stock count(s), keyed by business date) ─────────
    // A Save Count inserts a fresh session row, so re-counting a store the same
    // day produces several rows for one (store, date). Collapse to the LATEST
    // session per store (newest createdAt) before rolling up — genuinely
    // distinct stores still aggregate, but a re-save replaces rather than
    // double-counts the figures (rule #4).
    final dayCounts = stockCounts.where((c) => c.businessDate == _date).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final seenStores = <String?>{};
    var productsCounted = 0;
    var shortageCount = 0;
    var shortageUnits = 0;
    var surplusCount = 0;
    var surplusUnits = 0;
    final shortages = <_ShortLine>[];
    for (final c in dayCounts) {
      if (!seenStores.add(c.storeId)) continue; // older re-save of this store
      productsCounted += c.productsCounted;
      shortageCount += c.shortageCount;
      shortageUnits += c.shortageUnits;
      surplusCount += c.surplusCount;
      surplusUnits += c.surplusUnits;
      for (final l in (jsonDecode(c.linesJson) as List)
          .cast<Map<String, dynamic>>()) {
        final diff = (l['d'] as num).toInt();
        if (diff < 0) {
          shortages.add(_ShortLine(
            name: l['n'] as String? ?? 'Product',
            system: (l['s'] as num).toInt(),
            actual: (l['a'] as num).toInt(),
            diff: diff,
          ));
        }
      }
    }

    // ── Debts (current outstanding — summary of the wallet ledger) ─────────
    final totalOwedKobo =
        balances.values.where((b) => b < 0).fold<int>(0, (s, b) => s - b);

    // ── Expenses recorded that day (approved only) ─────────────────────────
    var expensesKobo = 0;
    var expensesCount = 0;
    if (salesReady) {
      for (final e in expenses) {
        if (e.expense.isDeleted) continue;
        if (e.expense.status != 'approved') continue;
        if (businessDateString(e.expense.createdAt, tz) != _date) continue;
        expensesKobo += e.expense.amountKobo;
        expensesCount++;
      }
    }

    // ── Empty crates (Bar / Beer Distributor only; current holdings) ───────
    final bizId = ref.watch(databaseProvider).currentBusinessId;
    String? bizType;
    for (final b in businesses) {
      if (b.id == bizId) {
        bizType = b.type;
        break;
      }
    }
    final showCrates = isCrateBusiness(bizType);
    final crates = <_CrateRow>[];
    if (showCrates) {
      final nameById = {for (final m in manufacturers) m.id: m.name};
      crateCounts.forEach((mfrId, count) {
        if (count > 0) {
          crates.add(_CrateRow(name: nameById[mfrId] ?? 'Manufacturer', count: count));
        }
      });
      crates.sort((a, b) => b.count.compareTo(a.count));
    }

    return _ReconData(
      salesReady: salesReady,
      skus: skus.length,
      items: items,
      salesKobo: salesKobo,
      bestStaff: bestStaff,
      bestStaffKobo: bestStaffKobo,
      topItem: topItem,
      topItemQty: topItemQty,
      cash: cash,
      netVarianceKobo: netVarianceKobo,
      hasStockCount: dayCounts.isNotEmpty,
      productsCounted: productsCounted,
      shortageCount: shortageCount,
      shortageUnits: shortageUnits,
      surplusCount: surplusCount,
      surplusUnits: surplusUnits,
      shortages: shortages,
      totalOwedKobo: totalOwedKobo,
      expensesKobo: expensesKobo,
      expensesCount: expensesCount,
      showCrates: showCrates,
      crates: crates,
    );
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'cash_till':
        return 'Cash Till';
      case 'pos_machine':
        return 'POS machine';
      case 'bank':
        return 'Bank';
      default:
        return type;
    }
  }

  // ── Section widgets ──────────────────────────────────────────────────────

  Widget _card(ThemeData theme, String title, IconData icon, Color color,
      List<Widget> children,
      {bool danger = false}) {
    return Container(
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(
          color: danger
              ? theme.colorScheme.error.withValues(alpha: 0.35)
              : theme.dividerColor.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 8),
              Text(title,
                  style:
                      context.bodyMedium.copyWith(fontWeight: FontWeight.bold)),
            ],
          ),
          SizedBox(height: context.spacingS),
          ...children,
        ],
      ),
    );
  }

  Widget _line(ThemeData theme, String label, String value,
      {bool danger = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label,
                style: context.bodySmall.copyWith(color: theme.hintColor)),
          ),
          const SizedBox(width: 8),
          Text(value,
              style: context.bodySmall.copyWith(
                fontWeight: danger ? FontWeight.bold : FontWeight.w600,
                color: danger ? theme.colorScheme.error : null,
              )),
        ],
      ),
    );
  }

  Widget _salesCard(ThemeData theme, _ReconData d) {
    return _card(theme, 'Sales summary', FontAwesomeIcons.chartLine,
        context.primaryColor, [
      if (!d.salesReady)
        Text('Loading…',
            style: context.bodySmall.copyWith(color: theme.hintColor))
      else ...[
        _line(theme, 'Items sold', fmtNumber(d.items)),
        _line(theme, 'Products (SKUs) sold', fmtNumber(d.skus)),
        _line(theme, 'Total sales', formatCurrency(d.salesKobo / 100.0)),
        _line(theme, 'Best staff',
            d.bestStaff == null ? '—' : '${d.bestStaff} (${formatCurrency(d.bestStaffKobo / 100.0)})'),
        _line(theme, 'Top item',
            d.topItem == null ? '—' : '${d.topItem} (×${d.topItemQty})'),
      ],
    ]);
  }

  Widget _cashCard(ThemeData theme, _ReconData d) {
    final mismatch = d.netVarianceKobo != 0;
    return _card(
      theme,
      'Close Day cash audit',
      FontAwesomeIcons.vault,
      Colors.teal,
      [
        if (d.cash.isEmpty)
          Text('Day not closed.',
              style: context.bodySmall.copyWith(color: theme.hintColor))
        else ...[
          for (final c in d.cash) ...[
            Text(c.account,
                style:
                    context.bodySmall.copyWith(fontWeight: FontWeight.w700)),
            _line(theme, 'Expected', formatCurrency(c.expectedKobo / 100.0)),
            _line(theme, 'Counted', formatCurrency(c.countedKobo / 100.0)),
            _line(theme, 'Variance', formatCurrency(c.varianceKobo / 100.0),
                danger: c.varianceKobo != 0),
            const SizedBox(height: 6),
          ],
          Divider(color: theme.dividerColor.withValues(alpha: 0.2)),
          _line(theme, 'Net variance',
              formatCurrency(d.netVarianceKobo / 100.0),
              danger: mismatch),
          if (mismatch)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Fund shortage / unaccounted funds flagged.',
                style: context.bodySmall
                    .copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ],
      danger: mismatch,
    );
  }

  Widget _stockCard(ThemeData theme, _ReconData d) {
    final hasShortage = d.shortageUnits > 0;
    return _card(
      theme,
      'Stock audit',
      FontAwesomeIcons.boxesStacked,
      Colors.blueAccent,
      [
        if (!d.hasStockCount)
          Text('No stock count taken.',
              style: context.bodySmall.copyWith(color: theme.hintColor))
        else ...[
          _line(theme, 'Products counted', fmtNumber(d.productsCounted)),
          _line(theme, 'Short',
              '${fmtNumber(d.shortageCount)} products · ${fmtNumber(d.shortageUnits)} units',
              danger: hasShortage),
          _line(theme, 'Surplus',
              '${fmtNumber(d.surplusCount)} products · ${fmtNumber(d.surplusUnits)} units'),
          if (d.shortages.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Shortages',
                style:
                    context.bodySmall.copyWith(fontWeight: FontWeight.w700)),
            for (final s in d.shortages)
              _line(theme, s.name, '${s.diff} (had ${s.system}, counted ${s.actual})',
                  danger: true),
          ],
        ],
      ],
      danger: hasShortage,
    );
  }

  Widget _moneyCard(ThemeData theme, _ReconData d) {
    return _card(theme, 'Debts & expenses', FontAwesomeIcons.moneyBillWave,
        Colors.redAccent, [
      _line(theme, 'Outstanding customer debt',
          formatCurrency(d.totalOwedKobo / 100.0),
          danger: d.totalOwedKobo > 0),
      if (!d.salesReady)
        _line(theme, 'Expenses recorded', 'Loading…')
      else
        _line(theme, 'Expenses recorded (${d.expensesCount})',
            formatCurrency(d.expensesKobo / 100.0)),
    ]);
  }

  Widget _cratesCard(ThemeData theme, _ReconData d) {
    return _card(theme, 'Empty crates (held now)', FontAwesomeIcons.boxOpen,
        Colors.brown, [
      if (d.crates.isEmpty)
        Text('No empty crates held.',
            style: context.bodySmall.copyWith(color: theme.hintColor))
      else
        for (final c in d.crates) _line(theme, c.name, fmtNumber(c.count)),
    ]);
  }
}

class _ReconData {
  _ReconData({
    required this.salesReady,
    required this.skus,
    required this.items,
    required this.salesKobo,
    required this.bestStaff,
    required this.bestStaffKobo,
    required this.topItem,
    required this.topItemQty,
    required this.cash,
    required this.netVarianceKobo,
    required this.hasStockCount,
    required this.productsCounted,
    required this.shortageCount,
    required this.shortageUnits,
    required this.surplusCount,
    required this.surplusUnits,
    required this.shortages,
    required this.totalOwedKobo,
    required this.expensesKobo,
    required this.expensesCount,
    required this.showCrates,
    required this.crates,
  });

  final bool salesReady;
  final int skus;
  final int items;
  final int salesKobo;
  final String? bestStaff;
  final int bestStaffKobo;
  final String? topItem;
  final int topItemQty;
  final List<_CashRow> cash;
  final int netVarianceKobo;
  final bool hasStockCount;
  final int productsCounted;
  final int shortageCount;
  final int shortageUnits;
  final int surplusCount;
  final int surplusUnits;
  final List<_ShortLine> shortages;
  final int totalOwedKobo;
  final int expensesKobo;
  final int expensesCount;
  final bool showCrates;
  final List<_CrateRow> crates;
}

class _CashRow {
  _CashRow({
    required this.account,
    required this.expectedKobo,
    required this.countedKobo,
    required this.varianceKobo,
  });
  final String account;
  final int expectedKobo;
  final int countedKobo;
  final int varianceKobo;
}

class _ShortLine {
  _ShortLine({
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

class _CrateRow {
  _CrateRow({required this.name, required this.count});
  final String name;
  final int count;
}
