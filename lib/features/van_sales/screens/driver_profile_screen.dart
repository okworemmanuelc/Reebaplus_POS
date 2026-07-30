import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/van_sales/driver_directory.dart';
import 'package:reebaplus_pos/core/van_sales/driver_vans.dart';
import 'package:reebaplus_pos/features/van_sales/screens/drivers_list_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_reconcile_screen.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/driver_ledger_entry_tile.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_sale_receipt_sheet.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/optimized_backdrop_filter.dart';

/// One driver's whole money story (#146, PRD #139 / ADR 0019, van-sales spec
/// §9.5 / §11).
///
/// The supplier/customer detail screen, keyed on a **staff user id** — because
/// that is what a van-sales driver is (spec §3 / §14: a `users` row with the
/// seeded Driver role, never a row in the dormant legacy `drivers` table).
///
/// ## The one decision worth stating: the period selector does NOT move the
/// balance.
///
/// A driver's balance is `Σ signed_amount_kobo` over **every** entry, ever
/// (spec §4.4 — the ledger's axis is the person, cross-trip). It is a *current
/// position*, not a period figure: "what does Dan owe me right now". Filtering
/// it to "This Month" would produce a number that answers no question anybody
/// asks — a partial sum whose complement is invisible — and would quietly
/// contradict the same driver's figure on the Van Sales hub, the reconcile
/// screen and the Drivers list, all of which show the cross-trip balance.
///
/// So the balance card is always current, and says so. The **period selector
/// scopes the history below it**: trips by their opening date, sales by when
/// they were rung, ledger rows by their activity date. The Ledger tab's In/Out
/// summary is the period-scoped money figure — money that moved in the window,
/// sitting next to a balance that is a position rather than a flow.
class DriverProfileScreen extends ConsumerStatefulWidget {
  final String driverUserId;

  const DriverProfileScreen({super.key, required this.driverUserId});

  @override
  ConsumerState<DriverProfileScreen> createState() =>
      _DriverProfileScreenState();
}

class _DriverProfileScreenState extends ConsumerState<DriverProfileScreen> {
  String _timeFilter = 'This Month';
  DateTimeRange? _customRange;

  List<String> get _periodOptions =>
      datePeriodLabelsForRole(managerUp: Gates.seeExtendedDateRanges.allows(ref));

  String get _effectivePeriod {
    final isCustom = _timeFilter.startsWith('Custom:');
    final value = isCustom ? 'Custom' : _timeFilter;
    return _periodOptions.contains(value) ? value : _periodOptions.first;
  }

  @override
  Widget build(BuildContext context) {
    return Guarded.screen(
      gate: Gates.vanManage,
      builder: (context) => _build(context),
      denied: _shell(
        context,
        const Center(child: Text('You no longer have access to Van Sales.')),
      ),
    );
  }

  /// The page chrome, shared by the guarded body and its denied state so a
  /// revocation mid-session empties the screen rather than replacing it with a
  /// different-looking one.
  Widget _shell(BuildContext context, Widget body, {String? subtitle}) {
    final t = Theme.of(context);
    return ColoredBox(
      color: t.scaffoldBackgroundColor,
      child: Container(
        decoration: AppDecorations.glassyBackground(context),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: Column(
              children: [
                const Text(
                  'Driver',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                if (subtitle != null)
                  Text(subtitle, style: t.textTheme.labelSmall),
              ],
            ),
            centerTitle: true,
          ),
          body: body,
        ),
      ),
    );
  }

  Widget _build(BuildContext context) {
    final entries = ref.watch(vanDriverEntriesProvider);
    final users =
        ref.watch(usersByBusinessProvider).valueOrNull ??
        const <String, UserData>{};
    final user = users[widget.driverUserId];

    if (user == null) {
      return _shell(
        context,
        const Center(child: Text('That driver is no longer on this device.')),
      );
    }

    final standing = entries
        .where((e) => e.userId == widget.driverUserId)
        .map((e) => e.standing)
        .firstOrNull;
    final balanceKobo =
        ref.watch(driverBalanceProvider(widget.driverUserId)).valueOrNull ?? 0;
    final trips =
        ref.watch(driverTripsProvider(widget.driverUserId)).valueOrNull ??
        const <VanTripData>[];
    final sales =
        ref.watch(driverVanSalesProvider(widget.driverUserId)).valueOrNull ??
        const <OrderWithItems>[];
    final ledger =
        ref
            .watch(driverLedgerHistoryProvider(widget.driverUserId))
            .valueOrNull ??
        const <DriverLedgerEntryData>[];

    final vanNameById = {
      for (final v in ref.watch(vansProvider)) v.id: v.name,
    };

    // The header's fallback source (#208 item 3). Filtered through
    // [vanNameById] — which holds vans and nothing else — so a warehouse
    // assignment can never be read as a van. It is only consulted when the
    // trips name nothing, which is the long-dormant-driver case: every trip
    // they ever ran fell out of the local pull window.
    final assignedVanStoreIds = [
      for (final s
          in ref.watch(myUserStoresProvider(widget.driverUserId)).valueOrNull ??
              const <UserStoreData>[])
        if (vanNameById.containsKey(s.storeId)) s.storeId,
    ];

    // Everything below the balance card is period-scoped; the balance is not.
    // See the class doc comment.
    final periodTrips = [
      for (final t in trips)
        if (isDateInPeriod(t.openedAt, _timeFilter)) t,
    ];
    final periodSales = [
      for (final s in sales)
        if (isDateInPeriod(s.order.createdAt, _timeFilter)) s,
    ];
    final periodLedger = [
      for (final e in ledger)
        if (isDateInPeriod(e.activityDate, _timeFilter)) e,
    ];

    // The crate tab is a Bar/Beverage surface (spec §11). Dropping it entirely
    // — rather than showing an always-zero tab — is what keeps the profile
    // honest for a trade with no empties, and the tab COUNT has to follow or
    // DefaultTabController and TabBarView disagree.
    final tracksCrates = businessTracksCrates(ref.watch(currentBusinessProvider));

    return DefaultTabController(
      length: tracksCrates ? 4 : 3,
      child: _shell(
        context,
        NestedScrollView(
          headerSliverBuilder: (context, _) => [
            SliverToBoxAdapter(
              child: _Header(
                user: user,
                standing: standing,
                trips: trips,
                vanNameById: vanNameById,
                assignedVanStoreIds: assignedVanStoreIds,
                joinedAt: _driverSince(trips),
              ),
            ),
            SliverToBoxAdapter(child: _balanceCard(context, balanceKobo)),
            SliverPersistentHeader(
              pinned: true,
              delegate: _SliverTabBarDelegate(
                extent: context.getRSize(60),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(16),
                  ),
                  child: _tabBar(context, showCrates: tracksCrates),
                ),
              ),
            ),
          ],
          body: TabBarView(
            children: [
              _TripsTab(
                trips: periodTrips,
                vanNameById: vanNameById,
                driverName: user.name,
              ),
              _SalesTab(sales: periodSales),
              _LedgerTab(entries: periodLedger, vanNameByTripId: {
                for (final t in trips) t.id: vanNameById[t.vanStoreId] ?? '',
              }),
              if (tracksCrates)
                _CratesTab(trips: periodTrips, vanNameById: vanNameById),
            ],
          ),
        ),
        subtitle: user.name,
      ),
    );
  }

  /// "Driver since" — the first trip they ever ran.
  ///
  /// Deliberately the first TRIP and not the membership's created date: a
  /// removed driver has no membership row left on the device (#107 keeps the
  /// `users` stub and nothing else), and the profile of a former driver who
  /// still owes money must not lose its dates. The trips are the durable record.
  DateTime? _driverSince(List<VanTripData> trips) {
    if (trips.isEmpty) return null;
    // `driverTripsProvider` is newest-first.
    return trips.last.openedAt;
  }

  Widget _balanceCard(BuildContext context, int balanceKobo) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final owes = balanceKobo < 0;
    final color = owes
        ? t.colorScheme.error
        : (balanceKobo > 0 ? semantic.success : t.colorScheme.onSurface);
    final label = owes
        ? 'Owed by this driver'
        : (balanceKobo > 0 ? 'Owed to this driver' : 'Settled');

    return GlassyCard(
      margin: EdgeInsets.fromLTRB(
        context.getRSize(16),
        0,
        context.getRSize(16),
        context.getRSize(12),
      ),
      padding: EdgeInsets.all(context.getRSize(18)),
      radius: 20,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      FontAwesomeIcons.scaleBalanced.data,
                      size: context.getRSize(14),
                      color: t.colorScheme.primary,
                    ),
                    SizedBox(width: context.getRSize(8)),
                    Flexible(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: context.getRFontSize(12),
                          fontWeight: FontWeight.w600,
                          color: t.colorScheme.onSurface.withAlpha(128),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: context.getRSize(6)),
                Text(
                  formatCurrency(balanceKobo.abs() / 100),
                  style: TextStyle(
                    fontSize: context.getRFontSize(28),
                    fontWeight: FontWeight.w900,
                    color: color,
                    letterSpacing: -1,
                  ),
                ),
                SizedBox(height: context.getRSize(4)),
                // The one sentence that stops the period dropdown next to it
                // from being read as scoping this figure.
                Text(
                  'Right now, across every trip',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: t.textTheme.bodySmall?.color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'History:',
                style: TextStyle(
                  fontSize: context.getRFontSize(10),
                  fontWeight: FontWeight.w600,
                  color: t.colorScheme.onSurface.withAlpha(128),
                ),
              ),
              SizedBox(height: context.getRSize(4)),
              SizedBox(
                width: context.getRSize(118),
                child: AppDropdown<String>(
                  value: _effectivePeriod,
                  isExpanded: false,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: context.getRSize(8),
                    vertical: context.getRSize(6),
                  ),
                  items: _periodOptions
                      .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                      .toList(),
                  onChanged: _onPeriodChanged,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _onPeriodChanged(String? v) async {
    if (v == 'Custom') {
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        initialDateRange: _customRange,
      );
      if (range == null || !mounted) return;
      setState(() {
        _customRange = range;
        _timeFilter =
            'Custom:${range.start.toIso8601String()}:'
            '${range.end.toIso8601String()}';
      });
      return;
    }
    if (v == null) return;
    setState(() {
      _timeFilter = v;
      _customRange = null;
    });
  }

  Widget _tabBar(BuildContext context, {required bool showCrates}) {
    final t = Theme.of(context);
    return Container(
      margin: EdgeInsets.only(bottom: context.getRSize(8)),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: t.colorScheme.primary.withValues(alpha: 0.1),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: OptimizedBackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          fallbackBuilder: (context, child) => child,
          child: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorPadding: EdgeInsets.all(context.getRSize(4)),
            indicator: BoxDecoration(
              color: t.colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: t.colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
            labelColor: t.colorScheme.primary,
            unselectedLabelColor: t.colorScheme.onSurface.withAlpha(150),
            labelStyle: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: context.getRFontSize(13),
            ),
            unselectedLabelStyle: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: context.getRFontSize(13),
            ),
            dividerColor: Colors.transparent,
            tabs: [
              const Tab(text: 'Trips'),
              const Tab(text: 'Sales'),
              const Tab(text: 'Ledger'),
              // Must stay in lockstep with the TabBarView children and the
              // controller length above.
              if (showCrates) const Tab(text: 'Crates'),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Header ──────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final UserData user;
  final DriverStanding? standing;
  final List<VanTripData> trips;
  final Map<String, String> vanNameById;

  /// The driver's current van assignments — the fallback the header falls back
  /// to when the trips name nothing. See [resolveDriverVanNames].
  final List<String> assignedVanStoreIds;

  final DateTime? joinedAt;

  const _Header({
    required this.user,
    required this.standing,
    required this.trips,
    required this.vanNameById,
    required this.assignedVanStoreIds,
    required this.joinedAt,
  });

  static String _initials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  /// The vans this driver has actually run, most recent first, falling back to
  /// their current assignment only when the trips name nothing (#208 item 3).
  /// The rule and its ordering live in [resolveDriverVanNames].
  String get _vans => driverVanSummary(
    resolveDriverVanNames(
      trips: trips,
      vanNameById: vanNameById,
      assignedVanStoreIds: assignedVanStoreIds,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    return GlassyCard(
      margin: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(16),
        context.getRSize(12),
      ),
      padding: EdgeInsets.all(context.getRSize(16)),
      radius: 20,
      child: Row(
        children: [
          Container(
            width: context.getRSize(60),
            height: context.getRSize(60),
            decoration: BoxDecoration(
              color: t.colorScheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                _initials(user.name),
                style: TextStyle(
                  fontSize: context.getRFontSize(22),
                  fontWeight: FontWeight.w900,
                  color: t.colorScheme.primary,
                ),
              ),
            ),
          ),
          SizedBox(width: context.getRSize(16)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        user.name,
                        style: TextStyle(
                          fontSize: context.getRFontSize(18),
                          fontWeight: FontWeight.w800,
                          color: t.colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(width: context.getRSize(8)),
                    DriverStandingBadge(
                      standing: standing ?? DriverStanding.removed,
                    ),
                  ],
                ),
                if ((user.phone ?? '').isNotEmpty) ...[
                  SizedBox(height: context.getRSize(6)),
                  _InfoRow(
                    icon: FontAwesomeIcons.phone.data,
                    text: user.phone!,
                  ),
                ],
                SizedBox(height: context.getRSize(4)),
                _InfoRow(icon: FontAwesomeIcons.truck.data, text: _vans),
                SizedBox(height: context.getRSize(4)),
                _InfoRow(
                  icon: FontAwesomeIcons.calendarDay.data,
                  text: joinedAt == null
                      ? 'No trips yet'
                      : 'Driving since ${DateFormat('d MMM y').format(joinedAt!)}',
                ),
                if (standing == DriverStanding.removed) ...[
                  SizedBox(height: context.getRSize(8)),
                  Text(
                    'No longer with the business. They stay on the Drivers '
                    'list until this account is settled or written off.',
                    style: t.textTheme.bodySmall?.copyWith(color: subtext),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Trips ───────────────────────────────────────────────────────────────────

class _TripsTab extends StatelessWidget {
  final List<VanTripData> trips;
  final Map<String, String> vanNameById;
  final String driverName;

  const _TripsTab({
    required this.trips,
    required this.vanNameById,
    required this.driverName,
  });

  @override
  Widget build(BuildContext context) {
    if (trips.isEmpty) {
      return _EmptyTab(
        icon: FontAwesomeIcons.truck.data,
        message: 'No trips in this period',
      );
    }
    return ListView.builder(
      padding: _tabPadding(context),
      itemCount: trips.length,
      itemBuilder: (_, i) => _TripRow(
        trip: trips[i],
        vanName: vanNameById[trips[i].vanStoreId] ?? 'Van',
        driverName: driverName,
      ),
    );
  }
}

/// One trip row: which van, when it went out, how it ended, and the net.
///
/// The status is deliberately three facts and not one: **closed with a balance**
/// and **restated** are the two states a trip can end in that a manager must not
/// have to open the trip to discover (spec §9.4 #14 / #15) — the first means a
/// residual followed the driver onto their next run, the second means the trip's
/// artifact was corrected after it was frozen.
class _TripRow extends ConsumerWidget {
  final VanTripData trip;
  final String vanName;
  final String driverName;

  const _TripRow({
    required this.trip,
    required this.vanName,
    required this.driverName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final isOpen = trip.status == kVanTripStatusOpen;

    // An OPEN trip has no artifact yet, so its net is the live position (a
    // driver holds at most one open trip, so this watches at most one family).
    final position = isOpen
        ? ref.watch(vanTripPositionProvider(trip.id)).valueOrNull
        : null;

    final (netLabel, netValue, netColor) = isOpen
        ? position == null
              ? ('On the road', '—', subtext)
              : position.outstandingKobo > 0
              ? (
                  'Owed so far',
                  formatCurrency(position.outstandingKobo / 100),
                  t.colorScheme.error,
                )
              : ('Settled so far', formatCurrency(0), semantic.success)
        : (
            'Profit booked',
            formatCurrency(trip.profitKobo / 100),
            trip.profitKobo < 0 ? t.colorScheme.error : semantic.success,
          );

    return GlassyCard(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      radius: 16,
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VanReconcileScreen(
              tripId: trip.id,
              driverName: driverName,
              vanName: vanName,
            ),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    FontAwesomeIcons.truck.data,
                    size: context.getRSize(14),
                    color: isOpen ? semantic.warning : subtext,
                  ),
                  SizedBox(width: context.getRSize(10)),
                  Expanded(
                    child: Text(
                      vanName,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: context.getRFontSize(15),
                        color: t.colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: context.getRSize(18),
                    color: subtext,
                  ),
                ],
              ),
              SizedBox(height: context.getRSize(8)),
              Text(
                'Out on ${DateFormat('d MMM y').format(trip.openedAt)}'
                '${trip.closedAt == null ? '' : ' • closed '
                      '${DateFormat('d MMM y').format(trip.closedAt!)}'}',
                style: TextStyle(
                  fontSize: context.getRFontSize(12),
                  color: subtext,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: context.getRSize(10)),
              Wrap(
                spacing: context.getRSize(6),
                runSpacing: context.getRSize(6),
                children: [
                  _Chip(
                    label: isOpen ? 'On the road' : 'Closed',
                    color: isOpen ? semantic.warning : semantic.success,
                  ),
                  if (trip.closedWithBalance)
                    _Chip(
                      label: 'Closed with a balance',
                      color: t.colorScheme.error,
                    ),
                  if (trip.restatedAt != null)
                    _Chip(label: 'Corrected later', color: semantic.info),
                ],
              ),
              SizedBox(height: context.getRSize(10)),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      netLabel,
                      style: TextStyle(
                        fontSize: context.getRFontSize(12),
                        color: subtext,
                      ),
                    ),
                  ),
                  Text(
                    netValue,
                    style: TextStyle(
                      fontSize: context.getRFontSize(15),
                      fontWeight: FontWeight.w800,
                      color: netColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Sales ───────────────────────────────────────────────────────────────────

class _SalesTab extends StatelessWidget {
  final List<OrderWithItems> sales;

  const _SalesTab({required this.sales});

  @override
  Widget build(BuildContext context) {
    if (sales.isEmpty) {
      return _EmptyTab(
        icon: FontAwesomeIcons.receipt.data,
        message: 'No road sales in this period',
      );
    }
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final recognised = sales
        .where((s) => orderCountsAsSale(s.order.status))
        .fold<int>(0, (sum, s) => sum + s.order.netAmountKobo);

    return ListView.builder(
      padding: _tabPadding(context),
      itemCount: sales.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(
            padding: EdgeInsets.only(bottom: context.getRSize(12)),
            child: Text(
              // Road takings, NOT cash the business holds — a road sale writes
              // no payment row (ADR 0019 decision 2). Named so on purpose.
              'Taken on the road in this period: '
              '${formatCurrency(recognised / 100)}',
              style: TextStyle(
                fontSize: context.getRFontSize(12),
                color: subtext,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
        }
        final sale = sales[i - 1];
        return _SaleRow(sale: sale);
      },
    );
  }
}

class _SaleRow extends StatelessWidget {
  final OrderWithItems sale;

  const _SaleRow({required this.sale});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final order = sale.order;
    final counted = orderCountsAsSale(order.status);
    final units = sale.items.fold<int>(0, (sum, l) => sum + l.item.quantity);

    return GlassyCard(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      radius: 16,
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => VanSaleReceiptSheet.show(context, sale),
        child: Padding(
          padding: EdgeInsets.all(context.getRSize(16)),
          child: Row(
            children: [
              Container(
                width: context.getRSize(40),
                height: context.getRSize(40),
                decoration: BoxDecoration(
                  color: (counted ? semantic.success : subtext).withValues(
                    alpha: 0.12,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  FontAwesomeIcons.receipt.data,
                  size: context.getRSize(16),
                  color: counted ? semantic.success : subtext,
                ),
              ),
              SizedBox(width: context.getRSize(14)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      order.orderNumber,
                      style: TextStyle(
                        fontSize: context.getRFontSize(14),
                        fontWeight: FontWeight.bold,
                        color: t.colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: context.getRSize(4)),
                    Text(
                      '${DateFormat('d MMM y, HH:mm').format(order.createdAt)}'
                      ' • $units ${units == 1 ? 'item' : 'items'}'
                      '${counted ? '' : ' • ${order.status}'}',
                      style: TextStyle(
                        fontSize: context.getRFontSize(12),
                        color: subtext,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              SizedBox(width: context.getRSize(8)),
              Text(
                formatCurrency(order.netAmountKobo / 100),
                style: TextStyle(
                  fontSize: context.getRFontSize(15),
                  fontWeight: FontWeight.w800,
                  color: counted ? t.colorScheme.onSurface : subtext,
                  decoration: counted ? null : TextDecoration.lineThrough,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Ledger ──────────────────────────────────────────────────────────────────

class _LedgerTab extends StatelessWidget {
  final List<DriverLedgerEntryData> entries;
  final Map<String, String> vanNameByTripId;

  const _LedgerTab({required this.entries, required this.vanNameByTripId});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return _EmptyTab(
        icon: FontAwesomeIcons.fileInvoiceDollar.data,
        message: 'No account activity in this period',
      );
    }
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;

    // The period-scoped money figure. A void's compensating row is a real
    // signed entry and belongs in these totals; the row it reversed is left in
    // too, and the pair nets to zero, exactly as it does in the balance.
    var inKobo = 0;
    var outKobo = 0;
    for (final e in entries) {
      if (e.signedAmountKobo >= 0) {
        inKobo += e.signedAmountKobo;
      } else {
        outKobo += -e.signedAmountKobo;
      }
    }

    return ListView.builder(
      padding: _tabPadding(context),
      itemCount: entries.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(
            padding: EdgeInsets.only(bottom: context.getRSize(12)),
            child: Row(
              children: [
                Expanded(
                  child: _SummaryTile(
                    label: 'Credited this period',
                    value: inKobo,
                    color: semantic.success,
                  ),
                ),
                SizedBox(width: context.getRSize(10)),
                Expanded(
                  child: _SummaryTile(
                    label: 'Signed for this period',
                    value: outKobo,
                    color: t.colorScheme.error,
                  ),
                ),
              ],
            ),
          );
        }
        final entry = entries[i - 1];
        return DriverLedgerEntryTile(
          entry: entry,
          vanName: entry.tripId == null ? null : vanNameByTripId[entry.tripId!],
        );
      },
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _SummaryTile({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return GlassyCard(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(14),
        vertical: context.getRSize(10),
      ),
      radius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: context.getRFontSize(11),
              fontWeight: FontWeight.w600,
              color: t.colorScheme.onSurface.withAlpha(128),
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            formatCurrency(value / 100),
            style: TextStyle(
              fontSize: context.getRFontSize(15),
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Crates ──────────────────────────────────────────────────────────────────

/// The crate seam (#146, van-sales spec §11).
///
/// **Counts, never money.** v1 tracks empty shells on a van as a write-only
/// memo: `shells_out` accumulates onto the trip at every load and restock,
/// `shells_back` at every return. Nothing here reads the crate pool, moves a
/// deposit, or values a missing shell — the deposit pass is Van Sales v2.
///
/// It exists anyway because of what it prevents: a 100-crate load carries
/// roughly ₦180,000 of deposit-value shells, and without the memo a trip closes
/// at "balance 0 = settled" having lost every one of them, with no data left to
/// reconstruct it. These are the same two columns `VanTripPosition.shellsOut` /
/// `shellsBack` report on the reconcile screen, read straight off the trip, so
/// the two surfaces cannot disagree.
class _CratesTab extends StatelessWidget {
  final List<VanTripData> trips;
  final Map<String, String> vanNameById;

  const _CratesTab({required this.trips, required this.vanNameById});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    final withShells = [
      for (final trip in trips)
        if (trip.shellsOut != 0 || trip.shellsBack != 0) trip,
    ];
    final totalOut = withShells.fold<int>(0, (s, t) => s + t.shellsOut);
    final totalBack = withShells.fold<int>(0, (s, t) => s + t.shellsBack);

    return ListView(
      padding: _tabPadding(context),
      children: [
        GlassyCard(
          padding: EdgeInsets.all(context.getRSize(16)),
          radius: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Empty crates on the road',
                style: TextStyle(
                  fontSize: context.getRFontSize(14),
                  fontWeight: FontWeight.w800,
                  color: t.colorScheme.onSurface,
                ),
              ),
              SizedBox(height: context.getRSize(4)),
              Text(
                'Swap only — no crate deposits are taken or refunded on the '
                'road. These are counts, not money.',
                style: TextStyle(
                  fontSize: context.getRFontSize(12),
                  color: subtext,
                ),
              ),
              SizedBox(height: context.getRSize(14)),
              Row(
                children: [
                  Expanded(
                    child: _CrateStat(label: 'Went out', value: totalOut),
                  ),
                  Expanded(
                    child: _CrateStat(label: 'Came back', value: totalBack),
                  ),
                  Expanded(
                    child: _CrateStat(
                      label: 'Unaccounted',
                      value: totalOut - totalBack,
                      color: totalOut - totalBack > 0
                          ? semantic.warning
                          : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: context.getRSize(16)),
        if (withShells.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.getRSize(20)),
            child: Text(
              'No crates counted on any trip in this period',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.getRFontSize(13),
                color: subtext,
              ),
            ),
          )
        else
          ...withShells.map(
            (trip) => GlassyCard(
              margin: EdgeInsets.only(bottom: context.getRSize(12)),
              padding: EdgeInsets.all(context.getRSize(16)),
              radius: 16,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          vanNameById[trip.vanStoreId] ?? 'Van',
                          style: TextStyle(
                            fontSize: context.getRFontSize(14),
                            fontWeight: FontWeight.w700,
                            color: t.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: context.getRSize(4)),
                        Text(
                          '${DateFormat('d MMM y').format(trip.openedAt)}'
                          '${trip.status == kVanTripStatusOpen ? ' • on the road' : ''}',
                          style: TextStyle(
                            fontSize: context.getRFontSize(12),
                            color: subtext,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _CrateStat(label: 'Out', value: trip.shellsOut),
                  SizedBox(width: context.getRSize(14)),
                  _CrateStat(label: 'Back', value: trip.shellsBack),
                  SizedBox(width: context.getRSize(14)),
                  _CrateStat(
                    label: 'Short',
                    value: trip.shellsOut - trip.shellsBack,
                    color: trip.shellsOut - trip.shellsBack > 0
                        ? semantic.warning
                        : null,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _CrateStat extends StatelessWidget {
  final String label;
  final int value;
  final Color? color;

  const _CrateStat({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: context.getRFontSize(11),
            color: subtext,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: context.getRSize(2)),
        Text(
          '$value',
          style: TextStyle(
            fontSize: context.getRFontSize(16),
            fontWeight: FontWeight.w800,
            color: color ?? t.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}

// ── Shared bits ─────────────────────────────────────────────────────────────

EdgeInsets _tabPadding(BuildContext context) => EdgeInsets.fromLTRB(
  context.getRSize(16),
  context.getRSize(12),
  context.getRSize(16),
  context.getRSize(32) + context.deviceBottomPadding,
);

class _Chip extends StatelessWidget {
  final String label;
  final Color color;

  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(10),
        vertical: context.getRSize(4),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: t.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData? icon;
  final String text;

  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: context.getRSize(2)),
          child: Icon(
            icon,
            size: context.getRSize(11),
            color: t.colorScheme.onSurface.withAlpha(128),
          ),
        ),
        SizedBox(width: context.getRSize(8)),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: context.getRFontSize(13),
              fontWeight: FontWeight.w500,
              color: t.colorScheme.onSurface.withAlpha(178),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyTab extends StatelessWidget {
  final IconData? icon;
  final String message;

  const _EmptyTab({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(40)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: context.getRSize(40), color: subtext),
            SizedBox(height: context.getRSize(14)),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: subtext,
                fontSize: context.getRFontSize(14),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double extent;

  _SliverTabBarDelegate({required this.child, required this.extent});

  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    // Force the height: under a NestedScrollView a pinned header reports
    // paintExtent from the child's rendered height but layoutExtent from
    // maxExtent, and a fractionally shorter child trips the framework's
    // "layoutExtent exceeds paintExtent" assert.
    return SizedBox(height: extent, child: child);
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate old) => old.extent != extent;
}
