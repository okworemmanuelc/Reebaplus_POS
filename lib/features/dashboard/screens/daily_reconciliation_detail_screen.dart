import 'package:flutter/material.dart';
import 'package:reebaplus_pos/core/utils/perf_log.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:reebaplus_pos/core/permissions/permissions.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_theme.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_parts.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/report_summary_parts.dart';
import 'package:reebaplus_pos/shared/widgets/redesign/redesign.dart';
import 'package:reebaplus_pos/core/utils/csv_export.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/dashboard/reconciliation/recon_data.dart';
import 'package:reebaplus_pos/features/dashboard/widgets/changed_since_review_badge.dart';
import 'package:reebaplus_pos/shared/widgets/crate_shortage_write_off_sheet.dart';
import 'package:reebaplus_pos/shared/widgets/shared_scaffold.dart';
import 'package:reebaplus_pos/shared/widgets/slide_route.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';

/// One reconciliation bucket's detail (§25.9) — a Day / Week / Month / Year span
/// in the active store scope. Rolls up sales, stock audit, valued shrinkage,
/// debts, expenses and crates; for the **CEO** it also shows a cost-based P&L and
/// a recorded statement of account. A **Manager** never sees cost / COGS / margin
/// / profit / goods-received (cost wall, §25.3); their shrinkage is valued at
/// selling price (an accountability figure). A non-Day bucket lists the
/// next-finer buckets inside it as a drill-down breakdown.
/// The detail screen's raw content width (batch rule: details 960).
const double kReconDetailMaxWidth = 1080;

AppFixedColors _fx(ThemeData t) =>
    t.extension<AppFixedColors>() ?? AppFixedColors.light;

/// Daily Reconciliation's "Write off missing crates" button (#296).
const String kReconCrateWriteOffButtonKey = 'recon_crate_write_off_button';

/// #432 — the report-only "Pay on delivery not yet collected" line.
const String kReconPayOnDeliveryLineKey = 'recon_pay_on_delivery_line';

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
  ///
  /// **The gate must mirror the gather's watch set exactly (#192).** It used to
  /// list eight streams while the frozen `netProfitKobo` also nets out three crate
  /// terms — the per-manufacturer deposit rates, the damaged-empties ledger and
  /// the kept-deposit forfeit rows. On a Bar / Beer Distributor a cold open could
  /// therefore win the first-writer race with a net profit missing those terms and
  /// freeze it permanently. A missing figure is worse than a late snapshot: the
  /// write can always retry, but first-writer-wins never lets it be corrected.
  ///
  /// [showCrates] keeps the gate honest in the other direction. `crate_deposit`
  /// forfeit rows are read ONLY behind the opt-in (`computeReconData`'s
  /// conditional watch), so a business that tracks no crates must not be made to
  /// open — or wait on — that stream. The manufacturer and crate-damage streams
  /// are watched unconditionally by the gather, so naming them here opens nothing
  /// new for anyone.
  ///
  /// #683 — the eight period lists, the damaged-empties rows and the kept
  /// deposit (forfeit) rows all arrive in ONE feed, [reconPeriodRowsProvider],
  /// so one readiness check covers them; for a non-crate business the forfeit
  /// rows it carries are simply never read.
  bool _frozenFiguresReady(String? activeStoreId, {required bool showCrates}) {
    bool ready<T>(ProviderListenable<AsyncValue<T>> p) => ref.watch(p).hasValue;
    return ready(reconPeriodRowsProvider(_period)) &&
        // #669 — Daily allowances are in the frozen net profit and cash out.
        ready(allStaffPayTotalsProvider) &&
        ready(productsWithStockProvider(activeStoreId)) &&
        // Crate-deposit forfeiture on a damaged bottle / stored empty — the
        // per-manufacturer rates are subtracted from the frozen net profit.
        ready(allManufacturersProvider);
  }

  bool get _isDay => widget.grouping == ReconGrouping.day;

  /// This screen's period — the [reconPeriodRowsProvider] key (#683).
  ReconPeriod get _period =>
      (start: widget.start, endExclusive: widget.endExclusive);

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
    // #683 — only this period's rows (plus the rows whose effect lands in it),
    // never the whole history. Empty until the first load lands, exactly like
    // the streams it replaces; the snapshot gate below waits for it.
    final rows =
        ref.watch(reconPeriodRowsProvider(_period)).valueOrNull ??
        ReconPeriodRows.empty;
    final d = perfLog(
      'recon ${grouping.name} build',
      () => computeReconData(
        ref,
        start: start,
        endExclusive: endExclusive,
        isCeo: isCeo,
        rows: rows,
      ),
    );

    // The day close's basis (#191, ADR 0022): the BUSINESS-WIDE figures, so one
    // durable record says what the whole business's day looked like whatever
    // store the opener was locked to — and the same record is comparable from
    // every scope. Deliberately computed ONLY for a FINISHED Day — a
    // week/month/year bucket must not pay for a second full aggregate pass it
    // has no snapshot for — so this and the snapshot read below register their
    // watches conditionally; Riverpod re-resolves the dependency set on every
    // build, so a bucket that becomes a finished day simply picks them up.
    //
    // `isCeo: true` is deliberate and is NOT the viewer's role (#192, closing
    // ADR 0022's flagged cousin). The frozen record must be opener-independent
    // in role terms exactly as it is in scope terms — a Manager and a CEO opening
    // the same finished day must freeze the same numbers, because
    // first-writer-wins means whoever gets there first decides the baseline
    // forever. The flag gates only the supplier-ledger flows, none of which reach
    // the frozen figure set, so this changes no number today; it removes the way
    // one could start to.
    final dayCloseBasis = _isFinishedDay
        ? perfLog(
            'recon ${grouping.name} day-close basis',
            () => computeReconData(
              ref,
              start: start,
              endExclusive: endExclusive,
              isCeo: true,
              businessWide: true,
              rows: rows,
            ),
          )
        : null;
    if (dayCloseBasis != null) {
      // null = All Stores: the frozen figures read the UNSCOPED stock totals, so
      // that is the stream whose warmth the readiness gate must check.
      _maybeWriteSnapshot(
        dayCloseBasis,
        dataReady: _frozenFiguresReady(null, showCrates: d.showCrates),
      );
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
            rows: rows,
          );

    // ── Which frozen figures each card actually FLAGS (#192) ────────────────
    // Built before the cards, not inside them, for one reason: the banner's
    // wording promises "the flagged cards show what moved", and the only way that
    // promise cannot lie is for the banner to be told what was actually flagged.
    // Before #192 `anyChanged` covered figures that live on CEO-only cards, so a
    // Manager could read that sentence with no flagged card anywhere on screen.
    //
    // Role visibility follows the §25.3 cost wall, per card: a Manager is shown
    // money deltas only where the same money is already on their card (sales,
    // refunds, expenses) and unit deltas anywhere; the cost-basis stock figures
    // are flagged for them WITHOUT a naira amount rather than not at all.
    final salesBadges = _deltaChips([
      _CardFigure(label: 'Total sold', delta: comparison?.totalSales),
      _CardFigure(label: 'Refunds', delta: comparison?.refunds),
      _CardFigure(
        label: 'Items sold',
        delta: comparison?.itemsSold,
        isUnits: true,
      ),
    ]);
    final plBadges = !isCeo
        ? const <Widget>[]
        : _deltaChips([
            _CardFigure(label: 'Profit', delta: comparison?.netProfit),
            _CardFigure(
              label: 'Profit before expenses',
              delta: comparison?.grossProfit,
            ),
            _CardFigure(label: 'Discounts given', delta: comparison?.discounts),
            _CardFigure(
              label: 'What those goods cost you',
              delta: comparison?.cogs,
            ),
            _CardFigure(label: 'Expenses', delta: comparison?.expenses),
            _CardFigure(
              label: 'Broken or spoilt goods',
              delta: comparison?.damagesCost,
            ),
          ]);
    final cashBadges = !isCeo
        ? const <Widget>[]
        : _deltaChips([
            _CardFigure(
              label: 'Cash you should have',
              delta: comparison?.netCashMovement,
            ),
            _CardFigure(label: 'Cash from sales', delta: comparison?.cashSales),
            _CardFigure(label: 'Cash in', delta: comparison?.cashIn),
            _CardFigure(label: 'Money paid out', delta: comparison?.cashOut),
          ]);
    final stockBadges = isCeo
        ? _deltaChips([
            _CardFigure(
              label: 'Stock now',
              delta: comparison?.stockExpectedClosing,
            ),
            _CardFigure(label: 'Goods sold', delta: comparison?.stockCogs),
            _CardFigure(
              label: 'Products short',
              delta: comparison?.shortageUnits,
              isUnits: true,
            ),
          ])
        : [
            ..._deltaChips([
              _CardFigure(
                label: 'Products short',
                delta: comparison?.shortageUnits,
                isUnits: true,
              ),
            ]),
            // Cost wall: the amounts belong to the CEO's card, so a Manager gets
            // the fact that stock value moved without the figure itself.
            if (comparison != null &&
                (comparison.stockExpectedClosing.changed ||
                    comparison.stockCogs.changed ||
                    comparison.damagesCost.changed))
              _changedChip('Stock value'),
          ];
    // The Manager's own money card — the one that rendered the frozen
    // `expensesKobo` with no delta at all before #192.
    final debtsBadges = isCeo
        ? const <Widget>[]
        : _deltaChips([
            _CardFigure(label: 'Expenses', delta: comparison?.expenses),
          ]);
    final hasFlaggedCard = [
      salesBadges,
      plBadges,
      cashBadges,
      stockBadges,
      debtsBadges,
    ].any((b) => b.isNotEmpty);

    // Each card is built once and placed by the layout below: phone and
    // tablet stack them in one column; wide screens split them in two.
    final salesCard = _salesCard(
      context,
      theme,
      d,
      badges: salesBadges,
      // Keep the line whose badge is on this card (#192): a refund VOIDED
      // after the review takes `refundsKobo` to 0, which would otherwise
      // badge a line the card no longer renders.
      showRefunds: d.refundsKobo > 0 || (comparison?.refunds.changed ?? false),
    );
    final bestSellersCard = _bestSellersCard(context, theme, d);
    final plCard = isCeo ? _plCard(context, theme, d, badges: plBadges) : null;
    final cashCard = isCeo
        ? _cashFlowCard(context, theme, d, badges: cashBadges)
        : null;
    // #147 - the van channel, only when the period saw van activity.
    final vanCard = d.van.hasActivity
        ? _vanSalesCard(context, theme, d, isCeo: isCeo)
        : null;
    final stockCard = _stockReconciliationCard(
      context,
      theme,
      d,
      isCeo: isCeo,
      badges: stockBadges,
    );
    final debtsCard = isCeo
        ? null
        : _debtsExpensesCard(context, theme, d, badges: debtsBadges);
    // The crate cards (#296, #215 / ADR 0023) appear only when they did
    // before: crates tracked, and the money card only when a brand moves
    // crate money.
    final cratesCard = d.showCrates ? _cratesCard(context, theme, d) : null;
    final crateMoneyCard = d.showCrates && d.crateDeposits.hasMoney
        ? _crateMoneyCard(context, theme, d)
        : null;

    // Header figures (CEO sees profit and cash; a Manager only total sold).
    final returnsNote = d.returnsKobo != 0
        ? 'After ${formatCurrency(-d.returnsKobo / 100.0)} in returns'
        : 'No returns';
    final profitKobo = d.netProfitKobo;
    final keptPer100 = d.totalSalesKobo > 0
        ? (profitKobo * 100 / d.totalSalesKobo).round()
        : null;
    final summary = <ReportSummaryItem>[
      ReportSummaryItem(
        label: _isDay ? 'Total sold today' : 'Total sold',
        value: formatCurrency(d.totalSalesKobo / 100.0),
        note: returnsNote,
      ),
      if (isCeo) ...[
        ReportSummaryItem(
          label: 'Profit',
          value: formatCurrency(profitKobo / 100.0),
          valueColor: profitKobo >= 0 ? _fx(theme).green : _fx(theme).danger,
          note: keptPer100 == null
              ? null
              : (keptPer100 >= 0
                    ? 'You kept about ${formatCurrency(keptPer100)} from every ${formatCurrency(100)} sold'
                    : 'You lost about ${formatCurrency(-keptPer100)} on every ${formatCurrency(100)} sold'),
        ),
        ReportSummaryItem(
          label: 'Cash received',
          value: formatCurrency(d.cashInKobo / 100.0),
          note: 'From sales and old debts paid',
        ),
      ],
    ];
    // Most sales on credit: a warning bar (phone words are shorter).
    final creditShare = d.totalSalesKobo > 0
        ? (d.salesOnCreditKobo * 100 / d.totalSalesKobo).round()
        : 0;
    final mostlyCredit =
        d.totalSalesKobo > 0 && d.salesOnCreditKobo * 2 > d.totalSalesKobo;

    final dateText = _isDay
        ? DateFormat('EEEE, d MMM yyyy').format(start)
        : null;
    final shortDateText = _isDay
        ? DateFormat('EEE, d MMM yyyy').format(start)
        : null;
    final today = DateTime.now();
    final isToday =
        _isDay &&
        start.year == today.year &&
        start.month == today.month &&
        start.day == today.day;
    final headerTitle = _isDay
        ? (isToday ? "Today's report" : 'Daily report')
        : title;

    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: LayoutBuilder(
        builder: (context, outer) {
          final roomy = outer.maxWidth >= 600;
          final subtitleParts = [
            if (scopeLabel.isNotEmpty) scopeLabel,
            if (dateText != null) roomy ? dateText : shortDateText!,
          ];
          return SharedScaffold(
            activeRoute: 'dashboard',
            backgroundColor: Colors.transparent,
            appBar: ReportTopBar(
              key: ReportKeys.topBar,
              height: reportTopBarHeight(context),
              header: ScreenHeader(
                leading: const ReportBackButton(),
                icon: AppIcons.auditCheck,
                title: headerTitle,
                subtitle: subtitleParts.isEmpty
                    ? null
                    : subtitleParts.join(' · '),
                actions: [
                  if (roomy)
                    OutlinedButton.icon(
                      key: ReportKeys.export,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(
                          kMinInteractiveDimension,
                          kMinInteractiveDimension,
                        ),
                      ),
                      icon: AppIcon(
                        AppIcons.fileCsv,
                        color: theme.colorScheme.onSurface,
                      ),
                      label: Text(
                        'Download',
                        style: TextStyle(color: theme.colorScheme.onSurface),
                      ),
                      onPressed: () =>
                          _exportCsv(context, d, isCeo, scopeLabel),
                    )
                  else
                    ReportBarAction(
                      key: ReportKeys.export,
                      icon: AppIcons.fileCsv,
                      tooltip: 'Download',
                      onPressed: () =>
                          _exportCsv(context, d, isCeo, scopeLabel),
                    ),
                ],
              ),
            ),
            body: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                // Measured width decides: under 600 a phone hero card; 600-899
                // three tiles over one 720 column; 900+ three tiles over two
                // card columns, capped at 1080 (#831, screen-size rule #820).
                final wide = width >= 900;
                final tablet = width >= 600 && !wide;
                final gutter = reportGutter(
                  context,
                  width,
                  maxWidth: wide ? kReconDetailMaxWidth : kContentMaxWidth,
                );
                final gap = context.getRSize(12);
                final creditBar = mostlyCredit
                    ? ReportCreditWarning(
                        lead: wide
                            ? "Most of today's sales were on credit."
                            : 'Most sales were on credit.',
                        rest: wide
                            ? 'Customers took '
                                  '${formatCurrency(d.salesOnCreditKobo / 100.0)} '
                                  'worth of goods without paying yet \u2014 that '
                                  'is $creditShare out of every 100 naira sold.'
                            : '${formatCurrency(d.salesOnCreditKobo / 100.0)} '
                                  'is still owed by customers \u2014 $creditShare '
                                  'of every 100 naira sold.',
                      )
                    : null;
                final worthCard = isCeo
                    ? _businessWorthCard(context, theme, d, wide: wide)
                    : null;
                List<Widget> nonNull(List<Widget?> l) => [
                  for (final w in l)
                    if (w != null) w,
                ];
                Widget column(List<Widget> items) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) SizedBox(height: gap),
                      items[i],
                    ],
                  ],
                );
                final List<Widget> body;
                if (wide) {
                  body = [
                    ReportSummaryTiles(items: summary),
                    if (creditBar != null) creditBar,
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: column(
                            nonNull([salesCard, bestSellersCard, plCard]),
                          ),
                        ),
                        SizedBox(width: gap),
                        Expanded(
                          child: column(
                            nonNull([
                              cashCard,
                              vanCard,
                              debtsCard,
                              stockCard,
                              cratesCard,
                              crateMoneyCard,
                            ]),
                          ),
                        ),
                      ],
                    ),
                    if (worthCard != null) worthCard,
                  ];
                } else {
                  body = [
                    tablet
                        ? ReportSummaryTiles(items: summary)
                        : ReportHeroCard(items: summary),
                    if (creditBar != null) creditBar,
                    ...nonNull([
                      salesCard,
                      bestSellersCard,
                      plCard,
                      cashCard,
                      vanCard,
                      stockCard,
                      worthCard,
                      debtsCard,
                      cratesCard,
                      crateMoneyCard,
                    ]),
                  ];
                }
                return ListView(
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    context.getRSize(12),
                    gutter,
                    context.getRSize(16) + context.deviceBottomPadding,
                  ),
                  children: [
                    if (comparison != null) ...[
                      _reviewedBanner(
                        context,
                        theme,
                        comparison,
                        reviewerName,
                        hasFlaggedCard: hasFlaggedCard,
                        isCeo: isCeo,
                      ),
                      SizedBox(height: gap),
                    ],
                    for (var i = 0; i < body.length; i++) ...[
                      if (i > 0) SizedBox(height: gap),
                      body[i],
                    ],
                    if (children.isNotEmpty) ...[
                      SizedBox(height: gap),
                      _breakdown(context, theme, children),
                    ],
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  // ── Cards ───────────────────────────────────────────────────────────────

  Widget _salesCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    List<Widget> badges = const [],
    bool showRefunds = false,
  }) {
    final itemsLabel = d.itemsSold == 1 ? 'item' : 'items';
    final productsLabel = d.skus == 1 ? 'product' : 'different products';
    return _card(
      context,
      theme,
      'Sales',
      AppIcons.analytics,
      context.primaryColor,
      subtitle:
          '${formatQtyGrouped(d.itemsSold)} $itemsLabel sold across '
          '${fmtNumber(d.skus)} $productsLabel',
      [
        // #176 — paid-now vs on-credit split. Shown only when some sale was on
        // credit, as before.
        if (d.salesOnCreditKobo != 0) ...[
          SizedBox(height: context.getRSize(4)),
          ReportPaidBar(
            paidNowKobo: d.salesPaidNowKobo,
            onCreditKobo: d.salesOnCreditKobo,
            paidNowText: formatCurrency(d.salesPaidNowKobo / 100.0),
            onCreditText: formatCurrency(d.salesOnCreditKobo / 100.0),
          ),
          SizedBox(height: context.getRSize(10)),
        ],
        // #708 — returns on their own line when the day has cancel entries.
        if (d.returnsKobo != 0) ...[
          _line(
            context,
            theme,
            'Sold before returns',
            formatCurrency((d.totalSalesKobo - d.returnsKobo) / 100.0),
          ),
          _line(
            context,
            theme,
            'Goods brought back',
            '− ${formatCurrency(-d.returnsKobo / 100.0)}',
          ),
          _divider(theme),
        ],
        _line(
          context,
          theme,
          'Total sold',
          formatCurrency(d.totalSalesKobo / 100.0),
          strong: true,
        ),
        if (showRefunds)
          _line(
            context,
            theme,
            'Refunds paid to customers',
            '− ${formatCurrency(d.refundsKobo / 100.0)}',
          ),
        if (d.vatEnabled)
          _line(
            context,
            theme,
            'VAT to pay (${d.vatRateLabel}%, ${d.vatBasisLabel})',
            formatCurrency(d.vatKobo / 100.0),
          ),
      ],
      badges: badges,
    );
  }

  /// Best sellers and top staff (look-only split of the old Sales summary).
  Widget _bestSellersCard(BuildContext context, ThemeData theme, ReconData d) {
    final fx = _fx(theme);
    return _card(
      context,
      theme,
      'Best sellers',
      AppIcons.analytics,
      context.primaryColor,
      [
        SizedBox(height: context.getRSize(4)),
        if (d.topItems.isEmpty)
          _line(context, theme, 'Nothing sold yet', '—')
        else
          for (var i = 0; i < d.topItems.length; i++)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.getRSize(4)),
              child: Row(
                children: [
                  Container(
                    width: context.getRSize(26),
                    height: context.getRSize(26),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: fx.infoTint,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: context.boldStyle(12).copyWith(color: fx.info),
                    ),
                  ),
                  SizedBox(width: context.getRSize(10)),
                  Expanded(
                    child: Text(
                      d.topItems[i].name,
                      style: context.mediumStyle(13),
                    ),
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Text(
                    '${formatQty(d.topItems[i].qty)} sold',
                    style: context.boldStyle(13),
                  ),
                ],
              ),
            ),
        SizedBox(height: context.getRSize(8)),
        DecoratedBox(
          decoration: BoxDecoration(
            color: fx.neutralTile,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(12)),
            child: _line(
              context,
              theme,
              _isDay ? 'Top staff today' : 'Top staff',
              d.bestStaff == null
                  ? '—'
                  : '${d.bestStaff} · sold ${formatCurrency(d.bestStaffKobo / 100.0)}',
            ),
          ),
        ),
      ],
    );
  }

  Widget _plCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    List<Widget> badges = const [],
  }) {
    final net = d.netProfitKobo;
    final netColor = net >= 0 ? _fx(theme).green : _fx(theme).danger;
    // #198 — only disclose the two expense date bases when there is expense
    // money in the period on either basis; an expense-free day needs no note.
    final hasExpenseFigures = d.expensesKobo != 0 || d.cashExpensesKobo != 0;
    return _card(
      context,
      theme,
      'How we got your profit',
      AppIcons.chartPie,
      netColor,
      subtitle: 'What you sold for, minus what those goods cost you',
      [
        _line(
          context,
          theme,
          d.uncostedTakingsKobo != 0
              ? 'Sales with a buying price'
              : 'Total sold',
          formatCurrency(d.costedRevenueKobo / 100.0),
        ),
        if (d.discountsKobo > 0) ...[
          _line(
            context,
            theme,
            'Discounts given',
            '− ${formatCurrency(d.discountsKobo / 100.0)}',
          ),
          _line(
            context,
            theme,
            'Sold after discounts',
            formatCurrency(d.netRevenueKobo / 100.0),
          ),
        ],
        _line(
          context,
          theme,
          'What those goods cost you',
          '− ${formatCurrency(d.cogsKobo / 100.0)}',
        ),
        _divider(theme),
        _line(
          context,
          theme,
          'Profit before expenses',
          formatCurrency(d.grossProfitKobo / 100.0),
          strong: true,
        ),
        // #176 — earnings the P&L used to hide: quick-sale takings (no recorded
        // cost, so pure margin — see the footnote) and kept crate deposits.
        if (d.uncostedTakingsKobo != 0)
          _line(
            context,
            theme,
            'Sold without a buying price',
            '+ ${formatCurrency(d.uncostedTakingsKobo / 100.0)}',
          ),
        if (d.forfeitIncomeKobo != 0)
          _line(
            context,
            theme,
            'Crate deposits you kept',
            '+ ${formatCurrency(d.forfeitIncomeKobo / 100.0)}',
          ),
        // #217 — and, right underneath it, the crate that money paid for.
        //
        // This line exists so the owner is never shown a gain with an invisible
        // offset. Without it the deposit reads as +₦3,500 of pure profit while
        // net profit quietly fails to rise, which is how a correct figure gets
        // reported as a bug.
        if (d.crateForfeitNettedKobo != 0)
          _line(
            context,
            theme,
            'Crates those customers kept (you owe the depot)',
            '− ${formatCurrency(d.crateForfeitNettedKobo / 100.0)}',
          ),
        _line(
          context,
          theme,
          'Expenses',
          '− ${formatCurrency(d.expensesKobo / 100.0)}',
        ),
        // #669 — one combined line, no worker named (ADR 0034).
        if (d.dailyAllowancesKobo != 0)
          _line(
            context,
            theme,
            'Daily staff allowances',
            '− ${formatCurrency(d.dailyAllowancesKobo / 100.0)}',
          ),
        // #671 — one combined line per payday, no worker named (ADR 0034).
        if (d.salariesKobo != 0)
          _line(
            context,
            theme,
            'Staff salaries',
            '− ${formatCurrency(d.salariesKobo / 100.0)}',
          ),
        // #696 — approved bonuses are a cost (advances and loans are not).
        if (d.bonusesKobo != 0)
          _line(
            context,
            theme,
            'Staff bonuses',
            '− ${formatCurrency(d.bonusesKobo / 100.0)}',
          ),
        _line(
          context,
          theme,
          'Broken or spoilt goods',
          '− ${formatCurrency(d.damageCostKobo / 100.0)}',
        ),
        if (d.crateDamageDepositKobo > 0)
          _line(
            context,
            theme,
            'Crate deposits lost on broken crates',
            '− ${formatCurrency(d.crateDamageDepositKobo / 100.0)}',
          ),
        // #193 — stock written off because its product was deleted. One family
        // with Damages: value the business paid for and no longer has, so it is
        // netted out of the result rather than only noted on the stock card.
        if (d.deletionCostKobo > 0)
          _line(
            context,
            theme,
            'Goods lost when products were deleted',
            '− ${formatCurrency(d.deletionCostKobo / 100.0)}',
          ),
        _divider(theme),
        _line(
          context,
          theme,
          'Profit',
          formatCurrency(net / 100.0),
          strong: true,
          color: netColor,
        ),
        // #217 — the sentence that stops this reading as a bug. Shop-owner
        // words, no accounting terms: you kept their money, but the crate they
        // kept is one you still owe the depot, and it costs the same.
        if (d.crateForfeitNettedKobo != 0) ...[
          const SizedBox(height: 6),
          Text(
            'You kept ${formatCurrency(d.forfeitIncomeKobo / 100.0)} of crate '
            'deposits from customers who never brought the crates back. Those '
            'crates are not yours — you paid your depot a deposit for them, at '
            'the same price you charged the customer — so they cost you '
            '${formatCurrency(d.crateForfeitNettedKobo / 100.0)} and the two '
            'cancel out. You are not worse off, and you did not really gain: '
            'this is why kept deposits no longer add to your profit on brands '
            'where you pay your depot a crate deposit. On brands where you do '
            'not, they still do.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
        if (d.uncostedItems > 0) ...[
          const SizedBox(height: 6),
          Text(
            '${formatQtyGrouped(d.uncostedItems)} item(s) were sold without a '
            'buying price, so their full '
            '${formatCurrency(d.uncostedTakingsKobo / 100.0)} is counted as '
            'profit.',
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
            '${fmtNumber(d.legacyValuedDamageRows)} older broken-goods '
            'record(s) are counted at today\'s buying price, because the price '
            'was not saved when they happened. Changing a buying price changes '
            'this figure.',
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
            'Expenses count on the date you picked when you recorded them. The '
            'Cash card counts the same money on the day it left the drawer, so '
            'the two can differ.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
      ],
      badges: badges,
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
    final semantic = _fx(theme);
    return _card(
      context,
      theme,
      'Van sales',
      AppIcons.supplier,
      semantic.info,
      subtitle: 'Sales made from vans',
      [
        _line(
          context,
          theme,
          'Sold from vans',
          formatCurrency(van.salesKobo / 100.0),
          strong: true,
        ),
        _line(
          context,
          theme,
          'Cash handed in by drivers',
          formatCurrency(van.remittedKobo / 100.0),
        ),
        if (isCeo) ...[
          _divider(theme),
          _line(
            context,
            theme,
            'What those goods cost you (closed trips)',
            formatCurrency(van.cogsKobo / 100.0),
          ),
          _line(
            context,
            theme,
            'Van profit (closed trips)',
            formatCurrency(van.profitKobo / 100.0),
            strong: true,
            color: van.profitKobo >= 0 ? semantic.green : _fx(theme).danger,
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
          'Van sales are counted under the warehouse each van loaded from, not '
          'under a shop. Van profit shows up once a trip is checked and '
          'closed.',
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }

  Widget _cashFlowCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    List<Widget> badges = const [],
  }) {
    final successColor = _fx(theme).green;
    final dangerColor = _fx(theme).danger;
    final netColor = d.netCashMovementKobo >= 0 ? successColor : dangerColor;
    // #198 — mirrors the Profit & Loss card: name the basis wherever an expense
    // figure is shown, so the CEO can see why the two differ.
    final hasExpenseFigures = d.expensesKobo != 0 || d.cashExpensesKobo != 0;
    return _card(
      context,
      theme,
      'Cash',
      AppIcons.payments,
      netColor,
      subtitle: _isDay
          ? 'Money recorded as coming in and going out today'
          : 'Money recorded as coming in and going out',
      [
        _line(
          context,
          theme,
          'Cash from sales',
          '+ ${formatCurrency(d.cashSalesKobo / 100.0)}',
        ),
        _line(
          context,
          theme,
          'Old debts paid by customers',
          '+ ${formatCurrency(d.cashDebtsCollectedKobo / 100.0)}',
        ),
        // #147 — "Cash from drivers": remittances, on the day the money
        // arrived. Beside Cash sales, never inside it: a road sale wrote no
        // payment row at all (ADR 0019 decision 2), so this is the one moment
        // van money enters the cash books, and folding it into Cash sales would
        // double-count revenue the driver already rang.
        if (d.cashFromDriversKobo != 0)
          _line(
            context,
            theme,
            'Cash handed in by drivers',
            '+ ${formatCurrency(d.cashFromDriversKobo / 100.0)}',
          ),
        // #696 — staff loans repaid in cash at the till (outside payday).
        if (d.cashLoansRepaidKobo != 0)
          _line(
            context,
            theme,
            'Staff loans repaid in cash',
            '+ ${formatCurrency(d.cashLoansRepaidKobo / 100.0)}',
          ),
        _line(
          context,
          theme,
          'Total cash in',
          formatCurrency(d.cashInKobo / 100.0),
          strong: true,
        ),
        _divider(theme),
        _line(
          context,
          theme,
          'Refunds paid to customers',
          '− ${formatCurrency(d.cashRefundsKobo / 100.0)}',
        ),
        _line(
          context,
          theme,
          'Expenses paid',
          '− ${formatCurrency(d.cashExpensesKobo / 100.0)}',
        ),
        // #669 — Daily allowances are till cash, inside Cash out below.
        if (d.dailyAllowancesKobo != 0)
          _line(
            context,
            theme,
            'Daily allowances paid',
            '− ${formatCurrency(d.dailyAllowancesKobo / 100.0)}',
          ),
        // #671 — only the till-cash part of the salaries paid.
        if (d.cashSalariesKobo != 0)
          _line(
            context,
            theme,
            'Salaries paid',
            '− ${formatCurrency(d.cashSalariesKobo / 100.0)}',
          ),
        // #696 — bonuses, advances and staff loans handed over in till cash.
        if (d.cashBonusesKobo != 0)
          _line(
            context,
            theme,
            'Bonuses paid',
            '− ${formatCurrency(d.cashBonusesKobo / 100.0)}',
          ),
        if (d.cashAdvancesKobo != 0)
          _line(
            context,
            theme,
            'Salary advances paid',
            '− ${formatCurrency(d.cashAdvancesKobo / 100.0)}',
          ),
        if (d.cashLoansGivenKobo != 0)
          _line(
            context,
            theme,
            'Staff loans given',
            '− ${formatCurrency(d.cashLoansGivenKobo / 100.0)}',
          ),
        _line(
          context,
          theme,
          'Paid to suppliers',
          '− ${formatCurrency(d.cashSupplierPaidKobo / 100.0)}',
        ),
        _line(
          context,
          theme,
          'Total money paid out',
          formatCurrency(d.cashOutKobo / 100.0),
          strong: true,
        ),
        _divider(theme),
        _line(
          context,
          theme,
          'Cash you should have',
          formatCurrency(d.netCashMovementKobo / 100.0),
          strong: true,
          color: netColor,
        ),
        // #175 — refundable crate deposits collected in cash this period, HELD
        // (net of any cancelled deposit sale). Shown below the net, OUTSIDE it:
        // it is customers' money in the drawer, never earnings.
        if (d.cashCrateDepositsKobo != 0) ...[
          const SizedBox(height: 6),
          _line(
            context,
            theme,
            'Crate deposits taken from customers (not yours)',
            formatCurrency(d.cashCrateDepositsKobo / 100.0),
          ),
        ],
        // #215 — the SUPPLIER leg, on its own line beside the customer leg and
        // outside the net for the identical reason: refundable money passing
        // through the drawer, never operating cash. Paying it is not an
        // expense, so it must not sit above with "Expenses paid (cash)", and it
        // never reduces profit.
        if (d.cashCrateDepositsPlacedKobo != 0) ...[
          const SizedBox(height: 6),
          _line(
            context,
            theme,
            'Crate deposits paid to suppliers (still yours)',
            formatCurrency(d.cashCrateDepositsPlacedKobo / 100.0),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          'Count the cash drawer to confirm this. Covers all branches. Crate '
          'deposits are refundable money, so they are kept out of the total.',
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
        if (hasExpenseFigures) ...[
          const SizedBox(height: 6),
          Text(
            'Expenses here count on the day the money left the drawer, so they '
            'can differ from the Expenses in "How we got your profit". Both are '
            'right: this card follows the cash.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
      ],
      badges: badges,
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
    List<Widget> badges = const [],
  }) {
    final successColor = _fx(theme).green;
    final dangerColor = _fx(theme).danger;
    final hasShortage = d.shortageUnits > 0;

    // Physical-count detail, shared by both roles.
    List<Widget> countSection() => [
      _line(context, theme, 'Products counted', fmtNumber(d.productsCounted)),
      _line(
        context,
        theme,
        'Products short',
        '${fmtNumber(d.shortageCount)} products · ${formatQty(d.shortageUnits)} units',
        danger: hasShortage,
      ),
      _line(
        context,
        theme,
        'Products extra',
        '${fmtNumber(d.surplusCount)} products · ${formatQty(d.surplusUnits)} units',
      ),
      if (d.shortages.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(
          'Products that came up short',
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
        'Stock',
        AppIcons.inventory,
        _fx(theme).info,
        subtitle: 'Valued at selling price',
        [
          _line(
            context,
            theme,
            'Missing stock',
            '${formatQty(d.shortageUnits)} unit(s) · ${formatCurrency(d.shortageRetailKobo / 100.0)}',
            danger: hasShortage,
          ),
          _line(
            context,
            theme,
            'Broken or spoilt goods',
            '${formatQtyGrouped(d.damageUnits)} unit(s) · ${formatCurrency(d.damageRetailKobo / 100.0)}',
          ),
          _divider(theme),
          _line(
            context,
            theme,
            'Selling value of what is missing',
            formatCurrency(shrinkVal / 100.0),
            strong: true,
          ),
          const SizedBox(height: 6),
          Text(
            'Valued at selling price, so this shows what is missing, not what '
            'the loss cost you.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
          if (d.hasStockCount) ...[_divider(theme), ...countSection()],
        ],
        danger: hasShortage,
        badges: badges,
      );
    }

    // CEO: cost-valued flow equation reconciled to the count.
    final variance = d.stockVarianceKobo;
    final hasVariance = d.hasStockCount && variance != 0;
    return _card(
      context,
      theme,
      'Stock',
      AppIcons.balance,
      _fx(theme).info,
      subtitle: 'Valued at what you paid for it',
      [
        if (d.hasStockFlow) ...[
          _line(
            context,
            theme,
            _isDay ? 'Stock this morning' : 'Stock at the start',
            formatCurrency(d.stockOpeningKobo / 100.0),
          ),
          _line(
            context,
            theme,
            'New goods received',
            '+ ${formatCurrency(d.stockReceivedKobo / 100.0)}',
          ),
          _line(
            context,
            theme,
            'Goods sold',
            '− ${formatCurrency(d.stockCogsKobo / 100.0)}',
          ),
          _line(
            context,
            theme,
            'Broken goods',
            '− ${formatCurrency(d.stockDamagesKobo / 100.0)}',
          ),
          _line(
            context,
            theme,
            'Expired goods',
            '− ${formatCurrency(d.stockExpiredKobo / 100.0)}',
          ),
          // #176 — the former single "Other movements" residual, broken out by
          // cause so a delete / transfer / count-fix can't hide unlabeled.
          if (d.stockTransfersKobo != 0)
            _signedLine(
              context,
              theme,
              'Moved between stores',
              d.stockTransfersKobo,
            ),
          if (d.stockCountAdjustmentsKobo != 0)
            _signedLine(
              context,
              theme,
              'Stock count corrections',
              d.stockCountAdjustmentsKobo,
            ),
          if (d.stockDeletionsKobo != 0)
            _signedLine(
              context,
              theme,
              'Goods lost when products were deleted',
              d.stockDeletionsKobo,
            ),
          if (d.stockOtherMovementsKobo != 0)
            _signedLine(
              context,
              theme,
              'Other stock changes',
              d.stockOtherMovementsKobo,
            ),
          _divider(theme),
          _line(
            context,
            theme,
            'Stock now',
            formatCurrency(d.stockExpectedClosingKobo / 100.0),
            strong: true,
          ),
          if (d.hasStockCount)
            _line(
              context,
              theme,
              'Difference found when counted',
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
            'Profit after the stock count',
            formatCurrency(d.integrityAdjustedProfitKobo / 100.0),
            strong: true,
            color: hasVariance ? dangerColor : successColor,
          ),
          const SizedBox(height: 6),
          Text(
            hasVariance
                ? 'The stock count is off by '
                      '${formatCurrency(variance.abs() / 100.0)} compared with '
                      'what your records say. This is either goods that went '
                      'missing or a miscount, and it is not in your profit.'
                : 'The stock count matches your sales, goods received, broken '
                      'and expired goods, so your profit adds up.',
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
              ? 'The lines above use today\'s buying prices so they add up to '
                    'Stock now. What those losses really cost you is in "How we '
                    'got your profit".'
              : (_isDay
                    ? 'No stock count was done today, so there is nothing to '
                          'compare against.'
                    : 'No stock count was done in this period, so there is '
                          'nothing to compare against.'),
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
        // #186 — the count figures' own basis, said in the owner's words. Count
        // a day twice and only the last count is reported, in units AND in
        // money: this line is what stops "but I recounted and it matched" from
        // reading as a hidden loss. "Count corrections" above is the other
        // reading (every count of every day) and stays deliberately different.
        if (d.hasStockCount) ...[
          const SizedBox(height: 6),
          Text(
            'If a day was counted twice, only the latest count is used.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
        // #200 / US 20 — the shortage/variance figure's own current-cost
        // fallback, labelled where that figure is shown.
        if (d.legacyValuedShortageRows > 0) ...[
          const SizedBox(height: 6),
          Text(
            '${fmtNumber(d.legacyValuedShortageRows)} older shortage '
            'record(s) are counted at today\'s buying price, because the price '
            'was not saved when they happened. Changing a buying price changes '
            'the difference above.',
            style: context.bodySmall.copyWith(color: theme.hintColor),
          ),
        ],
      ],
      danger: hasVariance,
      badges: badges,
    );
  }

  /// Point-in-time net worth: the inventory-on-hand asset, held empty-crate
  /// deposits, money owed to us and the supplier-account position.
  Widget _businessWorthCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    required bool wide,
  }) {
    final fx = _fx(theme);
    final successColor = fx.green;
    final dangerColor = fx.danger;
    final positionColor = d.businessNetPositionKobo >= 0
        ? successColor
        : dangerColor;

    final have = ReportWorthBox(
      title: 'What you have',
      tint: fx.greenTint,
      titleColor: successColor,
      children: [
        _line(
          context,
          theme,
          'Stock',
          formatCurrency(d.inventoryOnHandKobo / 100.0),
        ),
        // #176 / #170 #7b - stock dispatched between stores but not yet received.
        if (d.inTransitValueKobo != 0)
          _line(
            context,
            theme,
            'Stock on the way between stores',
            formatCurrency(d.inTransitValueKobo / 100.0),
          ),
        if (d.showCrates)
          _line(
            context,
            theme,
            'Empty crates',
            formatCurrency(d.crateDepositKobo / 100.0),
          ),
        // #215 / ADR 0023 rule 1 - deposits paid to suppliers are still ours.
        if (d.showCrates && d.placedCrateDepositsKobo != 0)
          _line(
            context,
            theme,
            'Crate deposits held by your suppliers',
            formatCurrency(d.placedCrateDepositsKobo / 100.0),
          ),
        _line(
          context,
          theme,
          'Money customers owe you',
          formatCurrency(d.totalOwedKobo / 100.0),
          color: d.totalOwedKobo > 0 ? dangerColor : null,
        ),
        if (d.payOnDeliveryUncollectedKobo != 0)
          _payOnDeliveryLine(context, theme, d),
        // Money paid to suppliers ahead of goods (an asset).
        if (d.supplierAccountBalanceKobo > 0)
          _line(
            context,
            theme,
            'Paid to suppliers in advance',
            formatCurrency(d.supplierAccountBalanceKobo / 100.0),
            color: successColor,
          ),
      ],
    );
    final owe = ReportWorthBox(
      title: 'What you owe',
      tint: fx.dangerTint,
      titleColor: dangerColor,
      children: [
        _line(
          context,
          theme,
          'Suppliers',
          formatCurrency(
            (d.supplierAccountBalanceKobo < 0
                    ? d.supplierAccountBalanceKobo.abs()
                    : 0) /
                100.0,
          ),
        ),
        if (d.showCrates && d.heldCrateDepositsKobo != 0)
          _line(
            context,
            theme,
            'Crate deposits to return to customers',
            formatCurrency(d.heldCrateDepositsKobo / 100.0),
          ),
        if (d.showCrates && d.supplierCrateDebtKobo != 0)
          _line(
            context,
            theme,
            'Crates you owe suppliers',
            formatCurrency(d.supplierCrateDebtKobo / 100.0),
          ),
      ],
    );

    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What your business is worth right now',
          style: context
              .boldStyle(17)
              .copyWith(color: theme.colorScheme.onSurface),
        ),
        Text(
          'What you have, minus what you owe. This is not cash in hand.',
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
      ],
    );
    final total = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: wide ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        formatCurrency(d.businessNetPositionKobo / 100.0),
        style: context.extraBoldStyle(28).copyWith(color: positionColor),
      ),
    );
    final gap = context.getRSize(12);
    return DecoratedBox(
      decoration: AppDecorations.card(context),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: title),
                  SizedBox(width: gap),
                  Flexible(child: total),
                ],
              )
            else ...[
              title,
              SizedBox(height: context.getRSize(8)),
              total,
            ],
            SizedBox(height: gap),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: have),
                  SizedBox(width: gap),
                  Expanded(child: owe),
                ],
              )
            else ...[
              have,
              SizedBox(height: gap),
              owe,
            ],
            if (d.uncostedInventoryItems > 0) ...[
              SizedBox(height: gap),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: fx.warningTint,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: fx.warningOutline),
                ),
                child: Padding(
                  padding: EdgeInsets.all(context.getRSize(12)),
                  child: Text(
                    '${formatQtyGrouped(d.uncostedInventoryItems)} item(s) '
                    'have no buying price, so they are left out of this '
                    'total.',
                    style: context.mediumStyle(13).copyWith(color: fx.warning),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _debtsExpensesCard(
    BuildContext context,
    ThemeData theme,
    ReconData d, {
    List<Widget> badges = const [],
  }) {
    return _card(
      context,
      theme,
      'Debts and expenses',
      AppIcons.payments,
      _fx(theme).danger,
      [
        _line(
          context,
          theme,
          'Money customers owe you (all branches)',
          formatCurrency(d.totalOwedKobo / 100.0),
          danger: d.totalOwedKobo > 0,
        ),
        if (d.payOnDeliveryUncollectedKobo != 0)
          _payOnDeliveryLine(context, theme, d),
        _line(
          context,
          theme,
          'Expenses',
          formatCurrency(d.expensesKobo / 100.0),
        ),
        if (d.dailyAllowancesKobo != 0)
          _line(
            context,
            theme,
            'Daily staff allowances',
            formatCurrency(d.dailyAllowancesKobo / 100.0),
          ),
        if (d.salariesKobo != 0)
          _line(
            context,
            theme,
            'Staff salaries',
            formatCurrency(d.salariesKobo / 100.0),
          ),
        if (d.bonusesKobo != 0)
          _line(
            context,
            theme,
            'Staff bonuses',
            formatCurrency(d.bonusesKobo / 100.0),
          ),
      ],
      badges: badges,
    );
  }

  /// #432 — "Pay on delivery not yet collected": REPORT-ONLY. It is part of
  /// the customer debt line above it, so it carries no sign and adds to
  /// nothing; and it is never a cash figure (no cash balance, Hard Rule #8).
  Widget _payOnDeliveryLine(
    BuildContext context,
    ThemeData theme,
    ReconData d,
  ) => KeyedSubtree(
    key: const ValueKey(kReconPayOnDeliveryLineKey),
    child: _line(
      context,
      theme,
      'Pay on delivery not yet collected',
      formatCurrency(d.payOnDeliveryUncollectedKobo / 100.0),
    ),
  );

  Widget _cratesCard(BuildContext context, ThemeData theme, ReconData d) {
    return _card(
      context,
      theme,
      'Empty crates you hold',
      AppIcons.box,
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
              '${formatQtyGrouped(m.count)} crate(s) · ${formatCurrency(m.valueKobo / 100.0)}',
            ),
          _divider(theme),
          _line(
            context,
            theme,
            'Value of empty crates',
            formatCurrency(d.crateDepositKobo / 100.0),
            strong: true,
          ),
        ],
        // ── #296 — the warning, and the loss somebody took ──────────────────
        ...(_crateShortageSection(context, theme, d)),
      ],
    );
  }

  /// **Crate money with suppliers (business-wide)** — the sixth reconciliation
  /// card (#215, PRD #203, ADR 0023).
  ///
  /// ADR 0014 cut this report from nine cards to five on purpose, and this is a
  /// deliberate, owner-chosen exception to that count, recorded in ADR 0023's
  /// Consequences and in an amendment note on ADR 0014 itself. The reason it
  /// earns a card of its own rather than a line on another: before PRD #203 a
  /// business could hand a depot ₦180,000 and every money figure in the app
  /// read exactly the same afterwards. A line inside Business worth would show
  /// the total; only a card can name WHICH supplier is holding it, which is the
  /// question an owner actually rings someone about.
  ///
  /// **"(business-wide)" is on the title for a reason, and it stays there under
  /// a locked store.** Supplier crate money is a company obligation — the depot
  /// invoices the business, not the branch. Splitting it per store would repeat
  /// the defect `CRATE_TRACKING_AUDIT` C4 already names (point-in-time
  /// business-wide crate figures presented inside a store-scoped report) and
  /// would let two branches each believe the same money is theirs. The figures
  /// come from a business-scoped provider that never reads the active store, so
  /// the label is a description of the data, not a promise the screen keeps.
  ///
  /// Not behind the §25.3 cost wall: this is a receivable, not cost, margin or
  /// profit — the same category as the customer debt a Manager already sees.
  Widget _crateMoneyCard(BuildContext context, ThemeData theme, ReconData d) {
    final successColor = _fx(theme).green;
    final rollup = d.crateDeposits;
    return _card(
      context,
      theme,
      'Crate money with suppliers (business-wide)',
      AppIcons.settlement,
      successColor,
      [
        if (rollup.bySupplier.isEmpty)
          _line(context, theme, 'Held by suppliers', formatCurrency(0))
        else ...[
          for (final s in rollup.bySupplier)
            _line(
              context,
              theme,
              s.supplierName,
              formatCurrency(s.placedDepositKobo / 100.0),
            ),
          _divider(theme),
        ],
        _line(
          context,
          theme,
          'Total held by suppliers (now)',
          formatCurrency(rollup.placedDepositKobo / 100.0),
          strong: true,
          color: successColor,
        ),
        // Raised but not yet decided (ADR 0023 rule 6). Deliberately BELOW the
        // total and outside it: nothing has moved, and a book entry appears
        // only when money genuinely moved.
        if (rollup.hasPending) ...[
          const SizedBox(height: 6),
          _line(
            context,
            theme,
            'Awaiting your confirmation',
            formatCurrency(rollup.pendingDepositKobo / 100.0),
          ),
        ],
        // ADR 0023 finding #3 — "two numbers that never meet", shown side by
        // side instead of one being quietly reported as the other. Large and
        // CORRECT on a brand switched on today: every crate received before the
        // switch was received under `none`, and ADR 0021 forbids restating it.
        if (rollup.unbackedValueKobo != 0) ...[
          const SizedBox(height: 6),
          _line(
            context,
            theme,
            'Crates owed with no deposit behind them',
            formatCurrency(rollup.unbackedValueKobo / 100.0),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          'Your money, held by your suppliers — refundable when you settle, so '
          'it counts in Business worth and never as a cost. Business-wide: a '
          'depot invoices the business, not a branch, so this is the same '
          'figure in every store.',
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
      ],
    );
  }

  /// **Crates missing** — the count-based Crate Shortage, and the write-offs
  /// taken against it (#296, PRD #284 decision 7).
  ///
  /// The same per-brand read the manufacturer screen shows, in the same store
  /// scope, so the two can't disagree. It is a warning, not a loss: it sits in
  /// no total. Only the write-off — the owner's decision, never a timer — puts
  /// it into profit, on the day it is taken. Crates owed to depots are not a
  /// shortage here.
  List<Widget> _crateShortageSection(
    BuildContext context,
    ThemeData theme,
    ReconData d,
  ) {
    final shortages = d.crateShortages;
    final writtenOff = d.crateShortfallWrittenOffKobo;
    // #217 — the slice of [writtenOff] that a customer forfeit raised. Already
    // inside it; shown as a breakdown, never added again.
    final netted = d.crateForfeitNettedKobo;
    if (!shortages.hasShortage && writtenOff == 0) return const [];

    final warnColor = _fx(theme).warning;
    final dangerColor = _fx(theme).danger;
    // Only a money-permitted role may accept a loss — the same gate that
    // confirms a crate deposit. Hidden, not disabled, for everyone else.
    final mayWriteOff = Gates.confirmCrateDeposit.allows(ref);

    return [
      SizedBox(height: context.spacingM),
      _divider(theme),
      if (shortages.hasShortage) ...[
        for (final s in shortages.openBrands)
          _line(
            context,
            theme,
            '${s.manufacturerName} — '
            '${formatQty(s.openCrates)} crate'
            '${s.openCrates == 1 ? '' : 's'} missing',
            formatCurrency(s.openValueKobo / 100.0),
            danger: true,
          ),
        _line(
          context,
          theme,
          'Crates missing (now)',
          formatCurrency(shortages.openValueKobo / 100.0),
          strong: true,
          color: warnColor,
        ),
        SizedBox(height: context.spacingXs),
        Text(
          'Crates a count found missing. This is a warning, not a loss — it '
          'has not touched your profit, and a later count that finds them '
          'clears it. It stays here until you decide to write it off.',
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
      ],
      // The accepted loss, in the period it was accepted. Shown even once the
      // shortage has closed: the money left the profit on that day and the
      // report for that day must keep saying so (ADR 0021).
      if (writtenOff != 0) ...[
        SizedBox(height: context.spacingXs),
        _line(
          context,
          theme,
          writtenOff > 0
              ? 'Crate losses written off this period'
              : 'Crate write-offs reversed this period',
          writtenOff > 0
              ? '− ${formatCurrency(writtenOff / 100.0)}'
              : '+ ${formatCurrency(-writtenOff / 100.0)}',
          color: writtenOff > 0 ? dangerColor : null,
        ),
        // #217 — split out the half nobody chose.
        if (netted != 0)
          _line(
            context,
            theme,
            '…of which crates customers kept',
            '− ${formatCurrency(netted / 100.0)}',
          ),
        for (final s in shortages.brands)
          if (s.lastWrittenOffAt != null)
            Text(
              'Last written off on ${_dayLabel(s.lastWrittenOffAt!)}'
              '${_staffLabel(s.lastWrittenOffBy)} — ${s.manufacturerName}',
              style: context.bodySmall.copyWith(color: theme.hintColor),
            ),
        SizedBox(height: context.spacingXs),
        Text(
          netted == writtenOff
              ? 'Crates customers never brought back. Their deposit stays with '
                    'you, but the crate is one you owe your depot at the same '
                    'price — so it comes out of your profit on the day the '
                    'order was settled, and the deposit you kept covers it '
                    'exactly.'
              : 'Crates you accepted as lost come out of your profit on the '
                    'day you accepted them. A reversal puts them back on the '
                    'day you reverse it.',
          style: context.bodySmall.copyWith(color: theme.hintColor),
        ),
      ],
      if (shortages.hasShortage && mayWriteOff) ...[
        SizedBox(height: context.spacingS),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey(kReconCrateWriteOffButtonKey),
            onPressed: () => CrateShortageWriteOffSheet.show(context),
            icon: Icon(AppIcons.removeCircle, size: context.getRSize(14)),
            label: const Text('Write off missing crates'),
          ),
        ),
      ],
    ];
  }

  /// The day a write-off was taken, in the owner's own date format.
  String _dayLabel(DateTime at) => DateFormat('d MMM yyyy').format(at);

  /// " by Ada" when the actor is known and named, "" otherwise. Never "by
  /// unknown" — an unnamed actor is better left unsaid than asserted.
  String _staffLabel(String? userId) {
    if (userId == null) return '';
    final name = ref.read(usersByBusinessProvider).valueOrNull?[userId]?.name;
    return name == null ? '' : ' by $name';
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
            style: context
                .boldStyle(15)
                .copyWith(color: theme.colorScheme.onSurface),
          ),
        ),
        for (final b in children) ...[
          _bucketCard(context, theme, b),
          SizedBox(height: context.getRSize(8)),
        ],
      ],
    );
  }

  Widget _bucketCard(BuildContext context, ThemeData theme, ReconBucket b) {
    final mismatch = b.hasShortage;
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    final radius = BorderRadius.circular(AppSpacing.borderRadiusXL);
    return DecoratedBox(
      decoration: AppDecorations.card(context).copyWith(
        border: mismatch ? Border.all(color: _fx(theme).dangerOutline) : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
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
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsets.all(context.getRSize(14)),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context
                              .boldStyle(16)
                              .copyWith(color: theme.colorScheme.onSurface),
                        ),
                        SizedBox(height: context.getRSize(4)),
                        Text(
                          '${formatQtyGrouped(b.itemsSold)} items sold',
                          style: context
                              .regularStyle(13)
                              .copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  if (mismatch) ...[
                    SizedBox(width: context.getRSize(8)),
                    const StatusPill(
                      label: 'Mismatch',
                      tone: TagPillTone.danger,
                    ),
                  ],
                  SizedBox(width: context.getRSize(8)),
                  AppIcon(
                    AppIcons.chevronRight,
                    color: muted,
                    size: context.getRSize(22),
                  ),
                ],
              ),
            ),
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
    String? subtitle,
    List<Widget> badges = const [],
  }) {
    return DecoratedBox(
      decoration: AppDecorations.card(context).copyWith(
        border: danger ? Border.all(color: _fx(theme).dangerOutline) : null,
      ),
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: context
                  .boldStyle(17)
                  .copyWith(color: theme.colorScheme.onSurface),
            ),
            if (subtitle != null)
              Padding(
                padding: EdgeInsets.only(top: context.getRSize(2)),
                child: Text(
                  subtitle,
                  style: context.bodySmall.copyWith(color: theme.hintColor),
                ),
              ),
            // #192 — a card can now flag SEVERAL frozen figures (expenses and
            // damages move independently of net profit), so the badges wrap onto
            // their own line under the title instead of competing with it for the
            // header row's width.
            if (badges.isNotEmpty) ...[
              SizedBox(height: context.getRSize(8)),
              Wrap(
                spacing: context.getRSize(6),
                runSpacing: context.getRSize(6),
                children: badges,
              ),
            ],
            SizedBox(height: context.getRSize(8)),
            ...children,
          ],
        ),
      ),
    );
  }

  // ── Persisted day close (#174) — delta badge + reviewed banner ─────────────

  /// The card's "changed since review" badges — one per figure in [figures] that
  /// actually moved, and none at all for an unreviewed or unchanged day.
  ///
  /// Callers pass only what THIS card renders for THIS role, so the list doubles
  /// as the answer to "did anything visible get flagged?" that the reviewed
  /// banner is worded from.
  List<Widget> _deltaChips(List<_CardFigure> figures) => [
    for (final f in figures)
      if (f.delta != null && f.delta!.changed)
        ChangedSinceReviewBadge(
          label:
              '${f.label} ${f.delta!.delta > 0 ? '+' : '−'} '
              '${f.isUnits ? formatQtyGrouped(f.delta!.delta.abs()) : formatCurrency(f.delta!.delta.abs() / 100.0)}',
        ),
  ];

  /// A "changed since review" badge with NO figure on it — the form used where
  /// the money behind the change is on the far side of the §25.3 cost wall
  /// (#192). A Manager is told their stock value moved after the review without
  /// being shown the cost it moved by.
  Widget _changedChip(String label) =>
      ChangedSinceReviewBadge(label: '$label changed');

  /// The screen-level banner shown once, above the cards, when the finished day
  /// has a persisted review snapshot (#174). States when (and by whom) the day
  /// was reviewed, and whether any figure has changed since — turning silent
  /// history mutation into a visible statement.
  ///
  /// [hasFlaggedCard] is what the changed wording is allowed to promise (#192).
  /// The banner used to say "the flagged cards show what moved" off `anyChanged`
  /// alone, which includes figures that live on CEO-only cards — so a Manager
  /// could be told to look at flagged cards when the screen had none. It is now
  /// told what was actually flagged, and when the answer is "nothing you can
  /// see", it says that instead of pointing at cards that do not exist.
  Widget _reviewedBanner(
    BuildContext context,
    ThemeData theme,
    ReconClosingComparison c,
    String? reviewerName, {
    required bool hasFlaggedCard,
    required bool isCeo,
  }) {
    final changed = c.anyChanged;
    final accent = changed ? _fx(theme).warning : _fx(theme).green;
    final reviewedOn = DateFormat('d MMM yyyy').format(c.reviewedAt.toLocal());
    final by = reviewerName == null ? '' : ' by $reviewerName';
    return Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: changed ? _fx(theme).warningTint : _fx(theme).greenTint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
        border: Border.all(
          color: changed
              ? _fx(theme).warningOutline
              : _fx(theme).green.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Icon(
            changed ? AppIcons.history : AppIcons.checkCircle,
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
                  style: context
                      .boldStyle(13)
                      .copyWith(color: theme.colorScheme.onSurface),
                ),
                const SizedBox(height: 2),
                Text(
                  !changed
                      ? 'The figures still match what was reviewed.'
                      : hasFlaggedCard
                      ? 'Some figures changed after this day was reviewed — the '
                            'flagged cards show what moved since.'
                      : isCeo
                      ? 'Some figures changed after this day was reviewed, but '
                            'not on any card shown here — the CSV export lists '
                            'every figure.'
                      : 'Some figures changed after this day was reviewed, but '
                            'not on any card you can see here — ask the owner to '
                            'open this day.',
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
    final c = color ?? (danger ? _fx(theme).danger : null);
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(3)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: context.mediumStyle(13).copyWith(color: muted),
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            value,
            textAlign: TextAlign.end,
            style: (strong ? context.extraBoldStyle(14) : context.boldStyle(13))
                .copyWith(color: c ?? theme.colorScheme.onSurface),
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
  ) => _line(
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
      ['Items sold', formatQty(d.itemsSold)],
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
        if (d.dailyAllowancesKobo != 0)
          ['Daily allowances', money(d.dailyAllowancesKobo)],
        if (d.salariesKobo != 0) ['Salaries', money(d.salariesKobo)],
        if (d.bonusesKobo != 0) ['Bonuses', money(d.bonusesKobo)],
        ['Damages (at cost)', money(d.damageCostKobo)],
        if (d.crateDamageDepositKobo > 0)
          ['Crate deposit loss (at deposit)', money(d.crateDamageDepositKobo)],
        // #193 — the deleted-product write-off as a loss, beside Damages, at the
        // write-time snapshot. The stock-card row further down is the SAME event
        // on that card's current-cost basis (ADR 0014), so it is disambiguated as
        // "(stock, at cost)" exactly as Damages already is. Conditional like the
        // crate row above, so an export from a business that deleted nothing is
        // byte-identical to before.
        if (d.deletionCostKobo > 0)
          ['Product deletions (at cost)', money(d.deletionCostKobo)],
        // #186 — the label names the basis, because the export sits beside a
        // "Count corrections" row further down that reads every count of the
        // day. Same event, two honest figures, exactly like Damages already is.
        [
          'Stock shortages (at cost, latest count per day)',
          money(d.shortageCostKobo),
        ],
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
          [
            'Quick-sale takings (no recorded cost)',
            money(d.uncostedTakingsKobo),
          ],
        if (d.forfeitIncomeKobo != 0)
          ['Forfeit income (kept crate deposits)', money(d.forfeitIncomeKobo)],
        // #216 — the one crate figure that reaches profit: crates the owner
        // deliberately accepted as lost, on the day they accepted them.
        if (d.showCrates && d.crateShortfallWrittenOffKobo != 0)
          [
            'Crate losses written off, net of reversals (this period)',
            money(-d.crateShortfallWrittenOffKobo),
          ],
        // #217 — a BREAKDOWN of the line above, not a further deduction: how
        // much of it was crates customers kept, cancelling the deposit income
        // two lines up.
        if (d.showCrates && d.crateForfeitNettedKobo != 0)
          [
            '…of which crates customers kept (cancels the forfeit income)',
            money(-d.crateForfeitNettedKobo),
          ],
        ['Net profit', money(d.netProfitKobo)],
        // Business worth right now (point-in-time) — mirrors _businessWorthCard.
        // Supplier account position: negative = a debt we owe for unpaid goods,
        // positive = money we paid the supplier in advance (a prepayment).
        if (d.inTransitValueKobo != 0)
          [
            'In-transit stock (dispatched, not received)',
            money(d.inTransitValueKobo),
          ],
        ['Supplier account balance (now)', money(d.supplierAccountBalanceKobo)],
        // #163 — crate liabilities netted into the position below.
        if (d.showCrates)
          [
            'Crate deposits held for customers (now)',
            money(d.heldCrateDepositsKobo),
          ],
        if (d.showCrates)
          [
            'Crate debt owed to suppliers (now)',
            money(d.supplierCrateDebtKobo),
          ],
        // #215 — the Placed Deposit ASSET added into the position below, and
        // its per-supplier breakdown. Business-wide even when a store is
        // locked; the label says so, like it does on the card.
        if (d.showCrates && d.placedCrateDepositsKobo != 0)
          [
            'Crate deposits held by suppliers (now, business-wide)',
            money(d.placedCrateDepositsKobo),
          ],
        ['Business net position (now)', money(d.businessNetPositionKobo)],
        // Crate money with suppliers (business-wide) — mirrors _crateMoneyCard.
        if (d.showCrates)
          for (final s in d.crateDeposits.bySupplier)
            [
              'Crate money held by ${s.supplierName} (now)',
              money(s.placedDepositKobo),
            ],
        // #296 — the WARNING, deliberately outside every total above: it has
        // not touched profit and a later count that finds the crates clears it.
        if (d.showCrates && d.crateShortages.hasShortage) ...[
          for (final s in d.crateShortages.openBrands)
            [
              '${s.manufacturerName} crates missing (now)',
              money(s.openValueKobo),
            ],
          [
            'Crates missing, not yet written off (now)',
            money(d.crateShortages.openValueKobo),
          ],
        ],
        if (d.showCrates && d.crateDeposits.hasPending)
          [
            'Crate money awaiting confirmation (now)',
            money(d.crateDeposits.pendingDepositKobo),
          ],
        // Cash flow (business-wide) — mirrors _cashFlowCard.
        ['Cash sales', money(d.cashSalesKobo)],
        ['Debts collected (cash)', money(d.cashDebtsCollectedKobo)],
        if (d.cashFromDriversKobo != 0)
          ['Cash from drivers', money(d.cashFromDriversKobo)],
        if (d.cashLoansRepaidKobo != 0)
          ['Staff loans repaid (cash)', money(d.cashLoansRepaidKobo)],
        ['Refunds paid (cash)', money(d.cashRefundsKobo)],
        ['Expenses paid (cash)', money(d.cashExpensesKobo)],
        if (d.dailyAllowancesKobo != 0)
          ['Daily allowances (cash)', money(d.dailyAllowancesKobo)],
        if (d.cashSalariesKobo != 0)
          ['Salaries (cash)', money(d.cashSalariesKobo)],
        if (d.cashBonusesKobo != 0)
          ['Bonuses (cash)', money(d.cashBonusesKobo)],
        if (d.cashAdvancesKobo != 0)
          ['Salary advances (cash)', money(d.cashAdvancesKobo)],
        if (d.cashLoansGivenKobo != 0)
          ['Staff loans given (cash)', money(d.cashLoansGivenKobo)],
        ['Paid to suppliers (cash)', money(d.cashSupplierPaidKobo)],
        ['Net cash movement', money(d.netCashMovementKobo)],
        ['Crate deposits held (cash)', money(d.cashCrateDepositsKobo)],
        // #215 — outside Net cash movement above, exactly like the line before
        // it. Refundable money through the drawer, not operating cash.
        if (d.cashCrateDepositsPlacedKobo != 0)
          [
            'Crate deposits placed with suppliers (cash)',
            money(d.cashCrateDepositsPlacedKobo),
          ],
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
        // #186 — "every count" is the point of difference from the shortage row
        // above, which reports only the count each day ended on.
        [
          'Count corrections (every count, units at today\'s cost)',
          money(d.stockCountAdjustmentsKobo),
        ],
        // #193 renamed this one to disambiguate it from the P&L's own
        // "Product deletions (at cost)", which carries the snapshot value.
        ['Product deletions (stock, at cost)', money(d.stockDeletionsKobo)],
        ['Other stock movements (at cost)', money(d.stockOtherMovementsKobo)],
        ['Expected closing (at cost)', money(d.stockExpectedClosingKobo)],
        ['Stock variance (counted − expected)', money(d.stockVarianceKobo)],
        // Integrity check — mirrors _integrityCard.
        ['Count-reconciled profit', money(d.integrityAdjustedProfitKobo)],
        ['Stock shortages (units)', formatQty(d.shortageUnits)],
      ] else ...[
        ['Stock shortages (units)', formatQty(d.shortageUnits)],
        [
          'Sellable value unaccounted',
          money(d.shortageRetailKobo + d.damageRetailKobo),
        ],
      ],
      ['Expenses recorded', money(d.expensesKobo)],
      ['Outstanding customer debt', money(d.totalOwedKobo)],
      if (d.payOnDeliveryUncollectedKobo != 0)
        [
          'Pay on delivery not yet collected',
          money(d.payOnDeliveryUncollectedKobo),
        ],
      if (d.showCrates) ['Empty crates held (units)', formatQty(d.crateUnits)],
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
      debugPrint('[ReconciliationDetail] export failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't export the report. Please try again."),
          ),
        );
      }
    }
  }
}

/// One frozen figure a card can flag (#192): the label the badge names it by,
/// the figure's as-reviewed-vs-current delta (null when the day was never
/// reviewed), and whether that delta reads as a unit COUNT rather than money.
///
/// Naming the figure is what makes several badges on one card readable, and what
/// lets a Manager tell an "Expenses" badge from a "Total sales" one without
/// inferring it from position. The unit flag is not cosmetic: `itemsSold` and
/// `shortageUnits` are frozen as counts, and formatting a count as naira would
/// state a number that never existed.
class _CardFigure {
  const _CardFigure({
    required this.label,
    required this.delta,
    this.isUnits = false,
  });
  final String label;
  final ReconFigureDelta? delta;
  final bool isUnits;
}
