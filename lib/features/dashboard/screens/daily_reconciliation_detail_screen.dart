import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';

/// One reconciliation bucket's detail (§25.9) — a Day / Week / Month / Year span
/// in the active store scope. Rolls up sales, stock audit, valued shrinkage,
/// debts, expenses and crates; for the **CEO** it also shows a cost-based P&L and
/// a recorded statement of account. A **Manager** never sees cost / COGS / margin
/// / profit / goods-received (cost wall, §25.3); their shrinkage is valued at
/// selling price (an accountability figure). A non-Day bucket lists the
/// next-finer buckets inside it as a drill-down breakdown.
class DailyReconciliationDetailScreen extends ConsumerStatefulWidget {
  const DailyReconciliationDetailScreen({
    super.key,
    required this.start,
    required this.endExclusive,
    required this.grouping,
    required this.title,
  });

  final DateTime start;
  final DateTime endExclusive;
  final ReconGrouping grouping;
  final String title;

  @override
  ConsumerState<DailyReconciliationDetailScreen> createState() =>
      _DailyReconciliationDetailScreenState();
}

class _DailyReconciliationDetailScreenState
    extends ConsumerState<DailyReconciliationDetailScreen> {
  // One-shot guard so the day-close snapshot is attempted once per screen mount
  // (build can run many times). First-writer-wins in the DAO makes a repeat a
  // no-op regardless, but this avoids re-scheduling the write on every rebuild.
  bool _snapshotAttempted = false;

  /// `YYYY-MM-DD` for the Day bucket [DailyReconciliationDetailScreen.start] —
  /// the natural-key day (matches `DailyClosings.businessDate`).
  String get _businessDate =>
      '${widget.start.year.toString().padLeft(4, '0')}-'
      '${widget.start.month.toString().padLeft(2, '0')}-'
      '${widget.start.day.toString().padLeft(2, '0')}';

  /// A Day bucket whose whole calendar day has elapsed — the only bucket a day
  /// close snapshot is written for (#174). Weeks / months / years and the
  /// current or future day never freeze.
  bool get _isFinishedDay =>
      widget.grouping == ReconGrouping.day &&
      !widget.endExclusive.isAfter(DateTime.now());

  /// True once every stream that feeds a FROZEN figure has emitted its first
  /// value, so a snapshot never freezes zeros captured mid-load:
  /// [computeReconData] treats a still-loading stream as empty
  /// (`valueOrNull ?? const []`), and a zeroed snapshot would lock in
  /// permanently under first-writer-wins. Until every source is loaded the write
  /// is deferred — a genuinely empty day still has real (loaded, all-zero)
  /// streams, so it snapshots correctly. Called during build so the watches
  /// register and the write retries the instant the last stream warms.
  bool _frozenFiguresReady(String? activeStoreId) {
    bool ready<T>(ProviderListenable<AsyncValue<T>> p) => ref.watch(p).hasValue;
    return ready(allOrdersProvider) &&
        ready(allPaymentTransactionsProvider) &&
        ready(allExpensesProvider) &&
        ready(allStockAdjustmentsProvider) &&
        ready(allStockTransactionsProvider) &&
        ready(allStockCountsProvider) &&
        ready(allSupplierLedgerEntriesProvider) &&
        ready(productsWithStockProvider(activeStoreId));
  }

  /// Freezes the day's computed figures as a `daily_closings` snapshot the FIRST
  /// time a permitted user (Manager+ via [Gates.dailyReconciliation]) opens a
  /// finished day — natural-key first-writer-wins; re-opening is a no-op.
  /// PURELY OBSERVATIONAL: no money flow or existing figure changes. [dataReady]
  /// gates on every source stream having loaded (see [_frozenFiguresReady]) so a
  /// zeroed mid-load snapshot can't freeze permanently. Deferred past the current
  /// build so it never mutates a provider mid-build.
  ///
  /// [businessWideFigures] — NOT the viewer's scoped figures (#191, ADR 0022).
  /// The natural key is (business, day) with first-writer-wins, so freezing
  /// whatever store the opener happened to be locked to let that accident decide
  /// the day's baseline forever, and left every other scope with none.
  void _maybeWriteSnapshot(
    ReconData businessWideFigures, {
    required bool dataReady,
  }) {
    if (_snapshotAttempted || !_isFinishedDay || !dataReady) return;
    if (!Gates.dailyReconciliation.allows(ref)) return;
    _snapshotAttempted = true;
    final reviewedBy = ref.read(currentUserIdProvider);
    final db = ref.read(databaseProvider);
    Future.microtask(() async {
      try {
        await db.dailyClosingsDao.snapshotIfAbsent(
          businessDate: _businessDate,
          figures: dailyClosingFiguresFrom(businessWideFigures),
          reviewedBy: reviewedBy,
        );
      } on Exception catch (e) {
        // Observational-only: a snapshot write must never surface an error into
        // the reconciliation view. Log (never swallow silently) and allow a
        // retry on the next open. Programmer errors (e.g. a missing session)
        // stay uncaught and reach the global handler.
        debugPrint('[DailyClose] snapshot write failed for $_businessDate: $e');
        _snapshotAttempted = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currencySymbolProvider); // rebuild money on currency change
    final theme = Theme.of(context);
    final isCeo = ref.watch(currentUserRoleProvider)?.slug == 'ceo';
    final scopeLabel = ref.watch(activeStoreLabelProvider);
    final grouping = widget.grouping;
    final start = widget.start;
    final endExclusive = widget.endExclusive;
    final title = widget.title;
    final d = computeReconData(
      ref,
      start: start,
      endExclusive: endExclusive,
      isCeo: isCeo,
    );

    // The day close's basis (#191, ADR 0022): the BUSINESS-WIDE figures, so one
    // durable record says what the whole business's day looked like whatever
    // store the opener was locked to — and the same record is comparable from
    // every scope. Deliberately computed ONLY for a FINISHED Day — a
    // week/month/year bucket must not pay for a second full aggregate pass it
    // has no snapshot for — so this and the snapshot read below register their
    // watches conditionally; Riverpod re-resolves the dependency set on every
    // build, so a bucket that becomes a finished day simply picks them up.
    final dayCloseBasis = _isFinishedDay
        ? computeReconData(
            ref,
            start: start,
            endExclusive: endExclusive,
            isCeo: isCeo,
            businessWide: true,
          )
        : null;
    if (dayCloseBasis != null) {
      // null = All Stores: the frozen figures read the UNSCOPED stock totals, so
      // that is the stream whose warmth the readiness gate must check.
      _maybeWriteSnapshot(dayCloseBasis, dataReady: _frozenFiguresReady(null));
    }

    // As-reviewed-vs-current delta (#174): for a FINISHED Day that HAS a
    // snapshot, at EVERY viewing scope (#191 — a snapshot is business-wide, so
    // the badges are no longer gated on the scope that happened to capture it).
    // Null for a week/month/year or an unreviewed day, which render exactly as
    // before — no banner, no badges.
    final snapshot = _isFinishedDay
        ? ref.watch(dailyClosingForDayProvider(_businessDate)).valueOrNull
        : null;
    final comparison = dayCloseBasis == null
        ? null
        : reconClosingComparisonOrNull(snapshot, dayCloseBasis);
    final reviewerName = comparison?.reviewedBy == null
        ? null
        : (ref.watch(usersByBusinessProvider).valueOrNull ??
                const {})[comparison!.reviewedBy]
            ?.name;

    final children = grouping.finer == null
        ? const <ReconBucket>[]
        : buildReconBuckets(
            ref,
            start: start,
            endExclusive: endExclusive,
            grouping: grouping.finer!,
          );

    return SharedScaffold(
      activeRoute: 'dashboard',
      appBar: AppBar(
        elevation: 0,
        backgroundColor: context.backgroundColor,
        leading: BackButton(color: context.primaryColor),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: context.h3.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              scopeLabel,
              style: context.bodySmall.copyWith(color: theme.hintColor),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: Icon(
              FontAwesomeIcons.fileCsv.data,
              size: 18,
              color: context.primaryColor,
            ),
            onPressed: () => _exportCsv(context, d, isCeo, scopeLabel),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(
          context.spacingM,
        ).copyWith(bottom: context.spacingM + context.deviceBottomPadding),
        children: [
          if (comparison != null) ...[
            _reviewedBanner(context, theme, comparison, reviewerName),
            SizedBox(height: context.spacingM),
          ],
          _salesCard(context, theme, d, delta: comparison?.totalSales),
          // #147 — the van channel, as one aggregated block. Rendered only when
          // the period actually saw van activity, so a business with no vans
          // reads exactly as it did before.
          if (d.van.hasActivity) ...[
            SizedBox(height: context.spacingM),
            _vanSalesCard(context, theme, d, isCeo: isCeo),
          ],
          if (isCeo) ...[
            SizedBox(height: context.spacingM),
            _plCard(context, theme, d, delta: comparison?.netProfit),
            SizedBox(height: context.spacingM),
            _cashFlowCard(context, theme, d, delta: comparison?.netCashMovement),
          ],
          SizedBox(height: context.spacingM),
          _stockReconciliationCard(
            context,
            theme,
            d,
            isCeo: isCeo,
            delta: comparison?.stockExpectedClosing,
          ),
          if (isCeo) ...[
            SizedBox(height: context.spacingM),
            _businessWorthCard(context, theme, d),
          ],
          if (!isCeo) ...[
            SizedBox(height: context.spacingM),
            _debtsExpensesCard(context, theme, d),
          ],
          if (d.showCrates) ...[
            SizedBox(height: context.spacingM),
            _cratesCard(context, theme, d),
          ],
          if (children.isNotEmpty) ...[
            SizedBox(height: context.spacingM),
            _breakdown(context, theme, children),
          ],
        ],
      ),
    );
  }

  // ── Cards ───────────────────────────────────────────────────────────────

  Widget _salesCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    ReconFigureDelta? delta,
  }) {
    return _card(
      context,
      theme,
      'Sales summary',
      FontAwesomeIcons.chartLine.data,
      context.primaryColor,
      [
        _line(context, theme, 'Items sold', fmtNumber(d.itemsSold)),
        _line(context, theme, 'Products (SKUs) sold', fmtNumber(d.skus)),
        _line(
          context,
          theme,
          'Total sales',
          formatCurrency(d.totalSalesKobo / 100.0),
          strong: true,
        ),
        // #176 — paid-now vs on-credit split so the drawer isn't over-expected
        // by the credit amount. Shown only when some sale was on credit.
        if (d.salesOnCreditKobo != 0) ...[
          _line(
            context,
            theme,
            'Paid now',
            formatCurrency(d.salesPaidNowKobo / 100.0),
          ),
          _line(
            context,
            theme,
            'On credit',
            formatCurrency(d.salesOnCreditKobo / 100.0),
          ),
        ],
        if (d.refundsKobo > 0)
          _line(
            context,
            theme,
            'Refunds',
            '− ${formatCurrency(d.refundsKobo / 100.0)}',
          ),
        if (d.vatEnabled)
          _line(
            context,
            theme,
            'VAT due (${d.vatRateLabel}%, ${d.vatBasisLabel})',
            formatCurrency(d.vatKobo / 100.0),
          ),
        _line(
          context,
          theme,
          'Best staff',
          d.bestStaff == null
              ? '—'
              : '${d.bestStaff} (${formatCurrency(d.bestStaffKobo / 100.0)})',
        ),
        _line(
          context,
          theme,
          'Top items',
          d.topItems.isEmpty
              ? '—'
              : d.topItems.map((e) => '${e.name} (×${e.qty})').join('\n'),
        ),
      ],
      badge: _deltaBadge(context, theme, delta),
    );
  }

  Widget _plCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    ReconFigureDelta? delta,
  }) {
    final net = d.netProfitKobo;
    final netColor = net >= 0
        ? theme.extension<AppSemanticColors>()!.success
        : theme.colorScheme.error;
    // #198 — only disclose the two expense date bases when there is expense
    // money in the period on either basis; an expense-free day needs no note.
    final hasExpenseFigures = d.expensesKobo != 0 || d.cashExpensesKobo != 0;
    return _card(
      context,
      theme,
      'Profit & Loss',
      FontAwesomeIcons.chartPie.data,
      netColor,
      [
        _line(
          context,
          theme,
          'Revenue',
          formatCurrency(d.costedRevenueKobo / 100.0),
        ),
        if (d.discountsKobo > 0) ...[
          _line(
            context,
            theme,
            'Discounts',
            '− ${formatCurrency(d.discountsKobo / 100.0)}',
          ),
          _line(
            context,
            theme,
            'Net revenue',
            formatCurrency(d.netRevenueKobo / 100.0),
          ),
        ],
        _line(
          context,
          theme,
          'Cost of goods sold',
          '− ${formatCurrency(d.cogsKobo / 100.0)}',
        ),
        _divider(theme),
        _line(
          context,
          theme,
          'Gross profit',
          formatCurrency(d.grossProfitKobo / 100.0),
          strong: true,
        ),
        // #176 — earnings the P&L used to hide: quick-sale takings (no recorded
        // cost, so pure margin — see the footnote) and kept crate deposits.
        if (d.uncostedTakingsKobo != 0)
          _line(
            context,
            theme,
            'Quick-sale takings (no recorded cost)',
            '+ ${formatCurrency(d.uncostedTakingsKobo / 100.0)}',
          ),
        if (d.forfeitIncomeKobo != 0)
          _line(
            context,
            theme,
            'Forfeit income (kept crate deposits)',
            '+ ${formatCurrency(d.forfeitIncomeKobo / 100.0)}',
          ),
        _line(
          context,
          theme,
          'Expenses (${d.expensesCount})',
          '− ${formatCurrency(d.expensesKobo / 100.0)}',
        ),
        _line(
          context,
          theme,
          'Damages (at cost)',
          '− ${formatCurrency(d.damageCostKobo / 100.0)}',
        ),
        if (d.crateDamageDepositKobo > 0)
          _line(
            context,
            theme,
            'Crate deposit loss',
            '− ${formatCurrency(d.crateDamageDepositKobo / 100.0)}',
          ),
        _divider(theme),
        _line(
          context,
          theme,
          'Net profit',
          formatCurrency(net / 100.0),
          strong: true,
          color: netColor,
        ),
        if (d.uncostedItems > 0) ...[
          const SizedBox(height: 6),
          Text(
            'Includes ${fmtNumber(d.uncostedItems)} item(s) sold with no recorded '
            'buying price (e.g. quick sales) as takings — counted in full above '
            'because no cost was recorded to deduct, so they carry no COGS or '
            'gross margin.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
        // #200 / US 20 — label the current-cost fallback. Newer damages are held
        // at the cost they actually drew, so editing a buying price today cannot
        // move them; older records kept only a quantity, so they DO move. Saying
        // so is the difference between a frozen figure and one that looks frozen.
        if (d.legacyValuedDamageRows > 0) ...[
          const SizedBox(height: 6),
          Text(
            '${fmtNumber(d.legacyValuedDamageRows)} older damage record(s) are '
            'valued at today\'s cost — they were saved before the cost of each '
            'loss was recorded, so changing a buying price also changes this '
            'figure.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
        // #198 (#155 US 34) — the two expense date bases, said out loud. Profit
        // uses the date the owner picked; the cash card uses the day the drawer
        // actually moved. Without this note a CEO reads two different expense
        // figures on one screen and assumes one of them is broken.
        if (hasExpenseFigures) ...[
          const SizedBox(height: 6),
          Text(
            'Expenses are counted on the date you picked when you recorded them, '
            'so a bill entered late still lands in the period it was spent. Cash '
            'flow counts that same money on the day it left the drawer, so the '
            'two expense figures can differ.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
      ],
      badge: _deltaBadge(context, theme, delta),
    );
  }

  /// Derived cash-flow summary (ADR 0014): the period's expected cash MOVEMENT
  /// from recorded cash tenders — cash sales + debts collected in, refunds +
  /// cash expenses + cash supplier payments out. **Business-wide** (the
  /// payment_transactions ledger has no store) and **not a counted drawer**:
  /// there is no opening float to add this to (Hard Rule #8). CEO-only.
  /// Van Sales — the road channel's whole contribution to the period (#147,
  /// van-sales spec §8.2, ADR 0019 decision 3).
  ///
  /// One aggregated revenue line and no detail: the per-order story lives on
  /// the driver profile, and a closing report that listed every road sale would
  /// bury the shop's own day. Profit is **read from each closed trip's
  /// persisted artifact**, never re-derived — and when a trip is still out, the
  /// card prints the caveat instead of a figure, because revenue was recognised
  /// at the sale and profit is only decided at the close.
  Widget _vanSalesCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    required bool isCeo,
  }) {
    final van = d.van;
    final semantic = theme.extension<AppSemanticColors>()!;
    return _card(
      context,
      theme,
      'Van sales',
      FontAwesomeIcons.truck.data,
      semantic.info,
      [
        _line(
          context,
          theme,
          'Van sales (all trips)',
          formatCurrency(van.salesKobo / 100.0),
          strong: true,
        ),
        _line(context, theme, 'Cash from drivers',
            formatCurrency(van.remittedKobo / 100.0)),
        if (isCeo) ...[
          _divider(theme),
          _line(context, theme, 'Cost of goods gone (closed trips)',
              formatCurrency(van.cogsKobo / 100.0)),
          _line(
            context,
            theme,
            'Van profit (closed trips)',
            formatCurrency(van.profitKobo / 100.0),
            strong: true,
            color: van.profitKobo >= 0 ? semantic.success : theme.colorScheme.error,
          ),
        ],
        if (van.hasOpenTripCaveat) ...[
          const SizedBox(height: 6),
          Text(
            van.caveatLine((v) => formatCurrency(v)),
            style: context.bodySmall.copyWith(color: semantic.warning),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          'Road sales are counted through the warehouse each van loaded from, '
          'and are kept out of every per-store figure. Profit is booked when '
          'the trip is reconciled and closed.',
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }

  Widget _cashFlowCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    ReconFigureDelta? delta,
  }) {
    final successColor = theme.extension<AppSemanticColors>()!.success;
    final dangerColor = theme.colorScheme.error;
    final netColor = d.netCashMovementKobo >= 0 ? successColor : dangerColor;
    // #198 — mirrors the Profit & Loss card: name the basis wherever an expense
    // figure is shown, so the CEO can see why the two differ.
    final hasExpenseFigures = d.expensesKobo != 0 || d.cashExpensesKobo != 0;
    return _card(
      context,
      theme,
      'Cash flow (business-wide)',
      FontAwesomeIcons.moneyBillWave.data,
      netColor,
      [
        _line(context, theme, 'Cash sales',
            '+ ${formatCurrency(d.cashSalesKobo / 100.0)}'),
        _line(context, theme, 'Debts collected (cash)',
            '+ ${formatCurrency(d.cashDebtsCollectedKobo / 100.0)}'),
        // #147 — "Cash from drivers": remittances, on the day the money
        // arrived. Beside Cash sales, never inside it: a road sale wrote no
        // payment row at all (ADR 0019 decision 2), so this is the one moment
        // van money enters the cash books, and folding it into Cash sales would
        // double-count revenue the driver already rang.
        if (d.cashFromDriversKobo != 0)
          _line(context, theme, 'Cash from drivers',
              '+ ${formatCurrency(d.cashFromDriversKobo / 100.0)}'),
        _line(context, theme, 'Cash in',
            formatCurrency(d.cashInKobo / 100.0), strong: true),
        _divider(theme),
        _line(context, theme, 'Refunds paid (cash)',
            '− ${formatCurrency(d.cashRefundsKobo / 100.0)}'),
        _line(context, theme, 'Expenses paid (cash)',
            '− ${formatCurrency(d.cashExpensesKobo / 100.0)}'),
        _line(context, theme, 'Paid to suppliers (cash)',
            '− ${formatCurrency(d.cashSupplierPaidKobo / 100.0)}'),
        _line(context, theme, 'Cash out',
            formatCurrency(d.cashOutKobo / 100.0), strong: true),
        _divider(theme),
        _line(context, theme, 'Net cash movement',
            formatCurrency(d.netCashMovementKobo / 100.0),
            strong: true, color: netColor),
        // #175 — refundable crate deposits collected in cash this period, HELD
        // (net of any cancelled deposit sale). Shown below the net, OUTSIDE it:
        // it is customers' money in the drawer, never earnings.
        if (d.cashCrateDepositsKobo != 0) ...[
          const SizedBox(height: 6),
          _line(context, theme, 'Crate deposits held (cash)',
              formatCurrency(d.cashCrateDepositsKobo / 100.0)),
        ],
        const SizedBox(height: 6),
        Text(
          'Expected cash movement from recorded cash tenders — business-wide, '
          'not a counted drawer. Crate deposits are refundable customer money '
          'held in the drawer, kept out of the net.',
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
        if (hasExpenseFigures) ...[
          const SizedBox(height: 6),
          Text(
            'Expenses here are counted on the day the money left the drawer, not '
            'the date picked on the expense — so this can differ from Expenses '
            'in Profit & Loss. Both are right: this card follows the cash.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
      ],
      badge: _deltaBadge(context, theme, delta),
    );
  }

  /// The single stock section of the closing — replaces the former separate
  /// Shrinkage, Stock audit, Stock reconciliation and Integrity cards, which
  /// each re-showed the same shortage / damage / COGS figures. For the CEO it is
  /// a cost-valued flow equation (Opening + Goods received − COGS − Damages −
  /// Expired ± Other = Expected closing) reconciled to the physical count, then
  /// the count-reconciled profit. For a Manager (cost wall §25.3) it is a
  /// retail-valued shrinkage + count view with no cost/COGS/flow.
  Widget _stockReconciliationCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    required bool isCeo,
    ReconFigureDelta? delta,
  }) {
    final successColor = theme.extension<AppSemanticColors>()!.success;
    final dangerColor = theme.colorScheme.error;
    final hasShortage = d.shortageUnits > 0;

    // Physical-count detail, shared by both roles.
    List<Widget> countSection() => [
      _line(context, theme, 'Products counted', fmtNumber(d.productsCounted)),
      _line(
        context,
        theme,
        'Short',
        '${fmtNumber(d.shortageCount)} products · ${fmtNumber(d.shortageUnits)} units',
        danger: hasShortage,
      ),
      _line(
        context,
        theme,
        'Surplus',
        '${fmtNumber(d.surplusCount)} products · ${fmtNumber(d.surplusUnits)} units',
      ),
      if (d.shortages.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(
          'Shortages',
          style: context.bodySmall.copyWith(fontWeight: FontWeight.w700),
        ),
        for (final s in d.shortages)
          _line(
            context,
            theme,
            s.name,
            '${s.diff} (had ${s.system}, counted ${s.actual})',
            danger: true,
          ),
      ],
    ];

    if (!isCeo) {
      // Manager: retail-valued shrinkage + count. No cost, COGS or flow.
      final shrinkVal = d.shortageRetailKobo + d.damageRetailKobo;
      return _card(
        context,
        theme,
        'Stock & shrinkage',
        FontAwesomeIcons.boxesStacked.data,
        Colors.blueAccent,
        [
          _line(
            context,
            theme,
            'Stock shortages',
            '${fmtNumber(d.shortageUnits)} unit(s) · ${formatCurrency(d.shortageRetailKobo / 100.0)}',
            danger: hasShortage,
          ),
          _line(
            context,
            theme,
            'Damages recorded',
            '${fmtNumber(d.damageUnits)} unit(s) · ${formatCurrency(d.damageRetailKobo / 100.0)}',
          ),
          _divider(theme),
          _line(
            context,
            theme,
            'Sellable value unaccounted',
            formatCurrency(shrinkVal / 100.0),
            strong: true,
          ),
          const SizedBox(height: 6),
          Text(
            'Valued at selling price — an accountability figure, not the '
            'company\'s cost of the loss.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
          if (d.hasStockCount) ...[_divider(theme), ...countSection()],
        ],
        danger: hasShortage,
        badge: _deltaBadge(context, theme, delta),
      );
    }

    // CEO: cost-valued flow equation reconciled to the count.
    final variance = d.stockVarianceKobo;
    final hasVariance = d.hasStockCount && variance != 0;
    return _card(
      context,
      theme,
      'Stock reconciliation (at cost)',
      FontAwesomeIcons.scaleBalanced.data,
      Colors.blueAccent,
      [
        if (d.hasStockFlow) ...[
          _line(context, theme, 'Opening stock',
              formatCurrency(d.stockOpeningKobo / 100.0)),
          _line(context, theme, 'Goods received',
              '+ ${formatCurrency(d.stockReceivedKobo / 100.0)}'),
          _line(context, theme, 'Cost of goods sold',
              '− ${formatCurrency(d.stockCogsKobo / 100.0)}'),
          _line(context, theme, 'Damages',
              '− ${formatCurrency(d.stockDamagesKobo / 100.0)}'),
          _line(context, theme, 'Expired',
              '− ${formatCurrency(d.stockExpiredKobo / 100.0)}'),
          // #176 — the former single "Other movements" residual, broken out by
          // cause so a delete / transfer / count-fix can't hide unlabeled.
          if (d.stockTransfersKobo != 0)
            _signedLine(context, theme, 'Store transfers', d.stockTransfersKobo),
          if (d.stockCountAdjustmentsKobo != 0)
            _signedLine(context, theme, 'Count corrections',
                d.stockCountAdjustmentsKobo),
          if (d.stockDeletionsKobo != 0)
            _signedLine(context, theme, 'Product deletions',
                d.stockDeletionsKobo),
          if (d.stockOtherMovementsKobo != 0)
            _signedLine(context, theme, 'Other movements',
                d.stockOtherMovementsKobo),
          _divider(theme),
          _line(context, theme, 'Expected closing',
              formatCurrency(d.stockExpectedClosingKobo / 100.0),
              strong: true),
          if (d.hasStockCount)
            _line(
              context,
              theme,
              'Variance (counted − expected)',
              '${variance >= 0 ? '+ ' : '− '}'
                  '${formatCurrency(variance.abs() / 100.0)}',
              strong: true,
              color: hasVariance ? dangerColor : null,
            ),
        ],
        if (d.hasStockCount) ...[
          _divider(theme),
          ...countSection(),
          _divider(theme),
          _line(
            context,
            theme,
            'Count-reconciled profit',
            formatCurrency(d.integrityAdjustedProfitKobo / 100.0),
            strong: true,
            color: hasVariance ? dangerColor : successColor,
          ),
          const SizedBox(height: 6),
          Text(
            hasVariance
                ? 'The physical count is off the recorded flows by '
                      '${formatCurrency(variance.abs() / 100.0)} — an unbooked '
                      'shrinkage or miscount, not reflected in reported profit.'
                : 'The physical count matches recorded sales, receipts, damages '
                      'and expiries — reported profit reconciles.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
        // #200 — the card's valuation basis, stated on EVERY view rather than
        // only when no count exists (the old `else` branch). The flow lines above
        // price the units that MOVED at today's cost, which is what lets the
        // column add up to Expected closing; the Profit & Loss card values the
        // same losses at what they actually cost when they happened. One event,
        // two figures, each labelled — see the report note on #186.
        const SizedBox(height: 6),
        Text(
          d.hasStockCount
              ? 'The lines above value the units that moved at today\'s cost, so '
                    'the column adds up to Expected closing. What those losses '
                    'actually cost you is on the Profit & Loss card.'
              : 'The lines above value the units that moved at today\'s cost. No '
                    'stock count in this period, so there is no variance to '
                    'reconcile against.',
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
        // #200 / US 20 — the shortage/variance figure's own current-cost
        // fallback, labelled where that figure is shown.
        if (d.legacyValuedShortageRows > 0) ...[
          const SizedBox(height: 6),
          Text(
            '${fmtNumber(d.legacyValuedShortageRows)} older shortage record(s) '
            'are valued at today\'s cost — they were saved before the cost of '
            'each shortage was recorded, so changing a buying price also changes '
            'the variance.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
      ],
      danger: hasVariance,
      badge: _deltaBadge(context, theme, delta),
    );
  }

  /// Point-in-time net worth: the inventory-on-hand asset, held empty-crate
  /// deposits, money owed to us and the supplier-account position.
  Widget _businessWorthCard(BuildContext context, ThemeData theme, ReconData d) {
    final successColor = theme.extension<AppSemanticColors>()!.success;
    final dangerColor = theme.colorScheme.error;
    final positionColor = d.businessNetPositionKobo >= 0 ? successColor : dangerColor;

    return _card(
      context,
      theme,
      'Business worth right now (point-in-time)',
      FontAwesomeIcons.vault.data,
      positionColor,
      [
        _line(context, theme, 'Inventory on hand (at cost)', '+ ${formatCurrency(d.inventoryOnHandKobo / 100.0)}'),
        // #176 / #170 #7b — stock dispatched between stores but not yet received.
        // Value that used to vanish between dispatch and receipt; now its own
        // line in worth. Shown only when something is in transit.
        if (d.inTransitValueKobo != 0)
          _line(context, theme, 'In-transit stock (dispatched, not received)', '+ ${formatCurrency(d.inTransitValueKobo / 100.0)}'),
        if (d.showCrates)
          _line(context, theme, 'Empty crates held (now)', '+ ${formatCurrency(d.crateDepositKobo / 100.0)}'),
        _line(context, theme, 'Outstanding customer debt (at risk)', '+ ${formatCurrency(d.totalOwedKobo / 100.0)}', color: d.totalOwedKobo > 0 ? dangerColor : null),
        // #163 — crate liabilities netted against the empties asset above: the
        // deposits we still hold for customers (owed back on return) and the
        // crate debt we owe suppliers for full crates delivered. Only shown when
        // there is something to owe, so the card stays clean for a settled shop.
        if (d.showCrates && d.heldCrateDepositsKobo != 0)
          _line(context, theme, 'Crate deposits held for customers (now)', '− ${formatCurrency(d.heldCrateDepositsKobo / 100.0)}', color: dangerColor),
        if (d.showCrates && d.supplierCrateDebtKobo != 0)
          _line(context, theme, 'Crate debt owed to suppliers (now)', '− ${formatCurrency(d.supplierCrateDebtKobo / 100.0)}', color: dangerColor),
        // Supplier account position — tracks payments made to suppliers vs
        // goods received. Negative (red) = a debt we owe them for unpaid goods;
        // positive (green) = money we paid them in advance (a prepayment), not
        // money we hold on their behalf.
        if (d.supplierAccountBalanceKobo < 0)
          _line(context, theme, 'Owed to suppliers (now)', '− ${formatCurrency(d.supplierAccountBalanceKobo.abs() / 100.0)}', color: dangerColor)
        else
          _line(context, theme, 'Paid in advance to suppliers (now)', '+ ${formatCurrency(d.supplierAccountBalanceKobo / 100.0)}', color: d.supplierAccountBalanceKobo > 0 ? successColor : null),
        _divider(theme),
        _line(context, theme, 'Business net position (now)', formatCurrency(d.businessNetPositionKobo / 100.0), strong: true, color: positionColor),
        if (d.uncostedInventoryItems > 0) ...[
          const SizedBox(height: 6),
          Text(
            'Excludes ${fmtNumber(d.uncostedInventoryItems)} inventory item(s) with no recorded buying price.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
        const SizedBox(height: 6),
        Text('Point-in-time net position. Not a cash balance.', style: context.bodySmall.copyWith(color: theme.hintColor)),
      ],
    );
  }

  Widget _debtsExpensesCard(
    BuildContext context,
    ThemeData theme,
    ReconData d,
  ) {
    return _card(
      context,
      theme,
      'Debts & expenses',
      FontAwesomeIcons.moneyBillWave.data,
      Colors.redAccent,
      [
        _line(
          context,
          theme,
          'Outstanding customer debt (business-wide)',
          formatCurrency(d.totalOwedKobo / 100.0),
          danger: d.totalOwedKobo > 0,
        ),
        _line(
          context,
          theme,
          'Expenses recorded (${d.expensesCount})',
          formatCurrency(d.expensesKobo / 100.0),
        ),
      ],
    );
  }

  Widget _cratesCard(BuildContext context, ThemeData theme, ReconData d) {
    return _card(
      context,
      theme,
      'Empty crates (held now)',
      FontAwesomeIcons.boxOpen.data,
      theme.colorScheme.primary,
      [
        if (d.manufacturerEmpties.isEmpty)
          _line(context, theme, 'Crates held', '0 crates')
        else ...[
          for (final m in d.manufacturerEmpties)
            _line(
              context,
              theme,
              m.manufacturerName,
              '${fmtNumber(m.count)} crate(s) · ${formatCurrency(m.valueKobo / 100.0)}',
            ),
          _divider(theme),
          _line(
            context,
            theme,
            'Total empty-crate value (now)',
            formatCurrency(d.crateDepositKobo / 100.0),
            strong: true,
          ),
        ],
      ],
    );
  }

  Widget _breakdown(
    BuildContext context,
    ThemeData theme,
    List<ReconBucket> children,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: context.spacingS,
            bottom: context.spacingS,
          ),
          child: Text(
            'Breakdown by ${children.first.grouping.label.toLowerCase()}',
            style: context.bodyMedium.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        for (final b in children) ...[
          _bucketCard(context, theme, b),
          SizedBox(height: context.spacingS),
        ],
      ],
    );
  }

  Widget _bucketCard(BuildContext context, ThemeData theme, ReconBucket b) {
    final mismatch = b.hasShortage;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(context.radiusL),
        onTap: () => Navigator.push(
          context,
          slideDownRoute(
            DailyReconciliationDetailScreen(
              start: b.start,
              endExclusive: b.endExclusive,
              grouping: b.grouping,
              title: b.label,
            ),
          ),
        ),
        child: Container(
          padding: EdgeInsets.all(context.spacingM),
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(context.radiusL),
            border: Border.all(
              color: mismatch
                  ? theme.colorScheme.error.withValues(alpha: 0.3)
                  : theme.dividerColor.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.label,
                      style: context.bodyMedium.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${fmtNumber(b.itemsSold)} items sold',
                      style: context.bodySmall.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              if (mismatch)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Mismatch',
                    style: context.bodySmall.copyWith(
                      color: theme.colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: theme.hintColor),
            ],
          ),
        ),
      ),
    );
  }

  // ── Shared widgets ────────────────────────────────────────────────────────

  Widget _card(
    BuildContext context,
    ThemeData theme,
    String title,
    IconData icon,
    Color color,
    List<Widget> children, {
    bool danger = false,
    Widget? badge,
  }) {
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
              Expanded(
                child: Text(
                  title,
                  style:
                      context.bodyMedium.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (badge != null) ...[const SizedBox(width: 8), badge],
            ],
          ),
          SizedBox(height: context.spacingS),
          ...children,
        ],
      ),
    );
  }

  // ── Persisted day close (#174) — delta badge + reviewed banner ─────────────

  /// The per-card "changed since review" badge, or null when the day was not
  /// reviewed or this card's figure has not moved (an unchanged card shows no
  /// badge). Neutral WARNING treatment: it flags that history mutated after the
  /// review, not that the change is good or bad.
  Widget? _deltaBadge(
    BuildContext context,
    ThemeData theme,
    ReconFigureDelta? delta,
  ) {
    if (delta == null || !delta.changed) return null;
    final warn = theme.extension<AppSemanticColors>()!.warning;
    final up = delta.delta > 0;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(8),
        vertical: context.getRSize(3),
      ),
      decoration: BoxDecoration(
        color: warn.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: warn.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FontAwesomeIcons.arrowsRotate.data, size: 10, color: warn),
          const SizedBox(width: 5),
          Text(
            '${up ? '+' : '−'} ${formatCurrency(delta.delta.abs() / 100.0)} '
            'since review',
            style: context.bodySmall.copyWith(
              color: warn,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  /// The screen-level banner shown once, above the cards, when the finished day
  /// has a persisted review snapshot (#174). States when (and by whom) the day
  /// was reviewed, and whether any figure has changed since — turning silent
  /// history mutation into a visible statement.
  Widget _reviewedBanner(
    BuildContext context,
    ThemeData theme,
    ReconClosingComparison c,
    String? reviewerName,
  ) {
    final changed = c.anyChanged;
    final accent = changed
        ? theme.extension<AppSemanticColors>()!.warning
        : theme.extension<AppSemanticColors>()!.success;
    final reviewedOn = DateFormat('d MMM yyyy').format(c.reviewedAt.toLocal());
    final by = reviewerName == null ? '' : ' by $reviewerName';
    return Container(
      padding: EdgeInsets.all(context.spacingM),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(context.radiusL),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            changed
                ? FontAwesomeIcons.clockRotateLeft.data
                : FontAwesomeIcons.circleCheck.data,
            size: 15,
            color: accent,
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Reviewed $reviewedOn$by',
                  style:
                      context.bodySmall.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  changed
                      ? 'Some figures changed after this day was reviewed — the '
                          'flagged cards show what moved since.'
                      : 'The figures still match what was reviewed.',
                  style: context.bodySmall.copyWith(color: theme.hintColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _line(
    BuildContext context,
    ThemeData theme,
    String label,
    String value, {
    bool strong = false,
    bool danger = false,
    Color? color,
  }) {
    final c = color ?? (danger ? theme.colorScheme.error : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: context.bodySmall.copyWith(color: theme.hintColor),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: context.bodySmall.copyWith(
              fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
              color: c,
            ),
          ),
        ],
      ),
    );
  }

  /// A stock-flow line whose value is signed: a positive delta reads `+ ₦x`, a
  /// negative one `− ₦x`. Keeps the broken-out movement classes (#176) readable
  /// without repeating the sign ternary at every call site.
  Widget _signedLine(
    BuildContext context,
    ThemeData theme,
    String label,
    int kobo,
  ) =>
      _line(
        context,
        theme,
        label,
        '${kobo >= 0 ? '+ ' : '− '}${formatCurrency(kobo.abs() / 100.0)}',
      );

  Widget _divider(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Divider(
      height: 1,
      color: theme.dividerColor.withValues(alpha: 0.25),
    ),
  );

  Future<void> _exportCsv(
    BuildContext context,
    ReconData d,
    bool isCeo,
    String scope,
  ) async {
    String money(int kobo) => (kobo / 100.0).toStringAsFixed(2);
    final rows = <List<String>>[
      ['Items sold', '${d.itemsSold}'],
      ['Products (SKUs) sold', '${d.skus}'],
      ['Total sales', money(d.totalSalesKobo)],
      if (d.salesOnCreditKobo != 0) ...[
        ['Total sales — paid now', money(d.salesPaidNowKobo)],
        ['Total sales — on credit', money(d.salesOnCreditKobo)],
      ],
      if (d.vatEnabled)
        ['VAT due (${d.vatRateLabel}%, ${d.vatBasisLabel})', money(d.vatKobo)],
      // #147 — the van card's lines, in the same order the card renders them.
      // Emitted only when the period saw van activity, so an export from a
      // business with no vans is byte-identical to before.
      if (d.van.hasActivity) ...[
        ['Van sales (all trips)', money(d.van.salesKobo)],
        ['Cash from drivers', money(d.van.remittedKobo)],
        if (isCeo) ...[
          ['Van cost of goods gone (closed trips)', money(d.van.cogsKobo)],
          ['Van profit (closed trips)', money(d.van.profitKobo)],
        ],
        if (d.van.hasOpenTripCaveat)
          ['Van revenue awaiting trip close', money(d.van.openRevenueKobo)],
      ],
      if (isCeo) ...[
        // Net result for this period (flow) — mirrors _netResultCard.
        ['Inventory on hand (at cost)', money(d.inventoryOnHandKobo)],
        ['Goods received', money(d.goodsReceivedKobo)],
        ['Paid to suppliers', money(d.supplierPaidKobo)],
        ['Refunds', money(d.refundsKobo)],
        ['Expenses', money(d.expensesKobo)],
        ['Damages (at cost)', money(d.damageCostKobo)],
        if (d.crateDamageDepositKobo > 0)
          ['Crate deposit loss (at deposit)', money(d.crateDamageDepositKobo)],
        ['Stock shortages (at cost)', money(d.shortageCostKobo)],
        // #200 / US 20 — the export carries the same disclosure the screen shows:
        // which of the two loss figures above lean on today's cost because the
        // record predates loss-cost snapshotting. Omitted when nothing does.
        if (d.legacyValuedDamageRows > 0)
          [
            'Damages — older records valued at today\'s cost',
            '${d.legacyValuedDamageRows}',
          ],
        if (d.legacyValuedShortageRows > 0)
          [
            'Stock shortages — older records valued at today\'s cost',
            '${d.legacyValuedShortageRows}',
          ],
        ['Net result for period', money(d.periodNetResultKobo)],
        // Profit & Loss — mirrors _plCard.
        ['Revenue (costed, gross)', money(d.costedRevenueKobo)],
        ['Discounts', money(d.discountsKobo)],
        ['Net revenue (costed)', money(d.netRevenueKobo)],
        ['Cost of goods sold', money(d.cogsKobo)],
        ['Gross profit', money(d.grossProfitKobo)],
        ['Gross margin %', d.grossMarginPct],
        if (d.uncostedTakingsKobo != 0)
          ['Quick-sale takings (no recorded cost)',
            money(d.uncostedTakingsKobo)],
        if (d.forfeitIncomeKobo != 0)
          ['Forfeit income (kept crate deposits)', money(d.forfeitIncomeKobo)],
        ['Net profit', money(d.netProfitKobo)],
        // Business worth right now (point-in-time) — mirrors _businessWorthCard.
        // Supplier account position: negative = a debt we owe for unpaid goods,
        // positive = money we paid the supplier in advance (a prepayment).
        if (d.inTransitValueKobo != 0)
          ['In-transit stock (dispatched, not received)',
            money(d.inTransitValueKobo)],
        ['Supplier account balance (now)', money(d.supplierAccountBalanceKobo)],
        // #163 — crate liabilities netted into the position below.
        if (d.showCrates)
          ['Crate deposits held for customers (now)',
            money(d.heldCrateDepositsKobo)],
        if (d.showCrates)
          ['Crate debt owed to suppliers (now)',
            money(d.supplierCrateDebtKobo)],
        ['Business net position (now)', money(d.businessNetPositionKobo)],
        // Cash flow (business-wide) — mirrors _cashFlowCard.
        ['Cash sales', money(d.cashSalesKobo)],
        ['Debts collected (cash)', money(d.cashDebtsCollectedKobo)],
        if (d.cashFromDriversKobo != 0)
          ['Cash from drivers', money(d.cashFromDriversKobo)],
        ['Refunds paid (cash)', money(d.cashRefundsKobo)],
        ['Expenses paid (cash)', money(d.cashExpensesKobo)],
        ['Paid to suppliers (cash)', money(d.cashSupplierPaidKobo)],
        ['Net cash movement', money(d.netCashMovementKobo)],
        ['Crate deposits held (cash)', money(d.cashCrateDepositsKobo)],
        // Stock reconciliation (at cost) — mirrors _stockFlowCard.
        ['Opening stock (at cost)', money(d.stockOpeningKobo)],
        ['Goods received (at cost)', money(d.stockReceivedKobo)],
        ['COGS (at current cost)', money(d.stockCogsKobo)],
        // #200 — this block is the stock FLOW: every line prices the units that
        // moved at TODAY's cost, which is what makes it add up to Expected
        // closing. Spelled out here because the same export also carries the
        // Profit & Loss "Damages (at cost)" row above, which is the write-time
        // cost of the very same damages — one event, two labelled figures.
        ['Damages (stock, units at today\'s cost)', money(d.stockDamagesKobo)],
        ['Expired (at cost)', money(d.stockExpiredKobo)],
        ['Store transfers (at cost)', money(d.stockTransfersKobo)],
        [
          'Count corrections (units at today\'s cost)',
          money(d.stockCountAdjustmentsKobo),
        ],
        ['Product deletions (at cost)', money(d.stockDeletionsKobo)],
        ['Other stock movements (at cost)', money(d.stockOtherMovementsKobo)],
        ['Expected closing (at cost)', money(d.stockExpectedClosingKobo)],
        ['Stock variance (counted − expected)', money(d.stockVarianceKobo)],
        // Integrity check — mirrors _integrityCard.
        ['Count-reconciled profit', money(d.integrityAdjustedProfitKobo)],
        ['Stock shortages (units)', '${d.shortageUnits}'],
      ] else ...[
        ['Stock shortages (units)', '${d.shortageUnits}'],
        [
          'Sellable value unaccounted',
          money(d.shortageRetailKobo + d.damageRetailKobo),
        ],
      ],
      ['Expenses recorded', money(d.expensesKobo)],
      ['Outstanding customer debt', money(d.totalOwedKobo)],
      if (d.showCrates) ['Empty crates held (units)', '${d.crateUnits}'],
    ];
    final name = isCeo ? 'business_statement' : 'store_reconciliation';
    try {
      await shareCsv(
        csv: buildCsv(['Metric', 'Value'], rows),
        fileName:
            '${name}_${widget.title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}',
        subject: 'Reconciliation — $scope — ${widget.title}',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not export: $e')));
      }
    }
  }
}
