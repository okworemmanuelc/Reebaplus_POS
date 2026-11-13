import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reebaplus_pos/shared/utils/quantity.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/date_period.dart';
import 'package:reebaplus_pos/core/utils/name_case.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/core/van_sales/driver_vans.dart';
import 'package:reebaplus_pos/features/van_sales/screens/drivers_list_screen.dart';
import 'package:reebaplus_pos/features/van_sales/screens/van_reconcile_screen.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/driver_ledger_entry_tile.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/record_driver_payment_sheet.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_driver_pickers.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_sale_receipt_sheet.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';
import 'package:reebaplus_pos/shared/widgets/app_dropdown.dart';
import 'package:reebaplus_pos/shared/widgets/glassy_card.dart';
import 'package:reebaplus_pos/shared/widgets/tabbed_sliver_scaffold.dart';

const kDriverTripRowKeyPrefix = 'driver-trip-row-';
const kDriverSaleRowKeyPrefix = 'driver-sale-row-';
const kDriverLedgerRowKeyPrefix = 'driver-ledger-row-';
const kDriverCrateRowKeyPrefix = 'driver-crate-row-';

Key driverTripRowKey(String tripId) =>
    ValueKey('$kDriverTripRowKeyPrefix$tripId');
Key driverSaleRowKey(String orderId) =>
    ValueKey('$kDriverSaleRowKeyPrefix$orderId');
Key driverLedgerRowKey(String entryId) =>
    ValueKey('$kDriverLedgerRowKeyPrefix$entryId');
Key driverCrateRowKey(String tripId) =>
    ValueKey('$kDriverCrateRowKeyPrefix$tripId');

/// One driver's whole money story (#146, reworked by #748; PRD #139 / ADR 0019,
/// van-sales spec §9.5 / §11).
///
/// The supplier/customer detail screen, keyed on a **van driver** (a plain
/// `van_drivers` row: a name and an optional phone, no sign-in). With
/// [noDriverVanStoreId] set instead it is the "No driver assigned" account of one
/// van: the trips loaded with nobody named, and what they owe. Setting a driver
/// on one of those trips moves its debt to that driver.
///
/// ## The one decision worth stating: the period selector does NOT move the
/// balance.
///
/// A driver's balance is `Σ signed_amount_kobo` over **every** entry, ever,
/// across every trip and van. It is a *current position*, not a period figure:
/// "what does Dan owe me right now". The balance card is always current, and says
/// so. The **period selector scopes the history below it**: trips by their
/// opening date, sales by when they were rung, ledger rows by their activity
/// date.
class DriverProfileScreen extends ConsumerStatefulWidget {
  /// The driver, or null for a van's "No driver assigned" account.
  final String? vanDriverId;

  /// The van whose driverless trips this screen shows (when [vanDriverId] is
  /// null).
  final String? noDriverVanStoreId;
  final String initialTab;

  const DriverProfileScreen({
    super.key,
    this.vanDriverId,
    this.noDriverVanStoreId,
    this.initialTab = 'trips',
  }) : assert(
         (vanDriverId == null) != (noDriverVanStoreId == null),
         'Pass a driver or a van, not both',
       );

  @override
  ConsumerState<DriverProfileScreen> createState() =>
      _DriverProfileScreenState();
}

class _DriverProfileScreenState extends ConsumerState<DriverProfileScreen>
    with TickerProviderStateMixin<DriverProfileScreen> {
  String _timeFilter = 'This Month';
  DateTimeRange? _customRange;

  TabController? _tabController;
  List<String> _tabKeys = const [];

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  List<String> _resolveTabKeys({required bool tracksCrates}) => [
    'trips',
    'sales',
    'ledger',
    if (tracksCrates) 'crates',
  ];

  void _syncTabController(List<String> tabKeys) {
    if (_tabController != null && _listEquals(_tabKeys, tabKeys)) return;
    final int newIndex;
    if (_tabController == null) {
      newIndex = tabKeys.contains(widget.initialTab)
          ? tabKeys.indexOf(widget.initialTab)
          : 0;
    } else {
      final previousIndex = _tabController!.index;
      final previousKey = previousIndex < _tabKeys.length
          ? _tabKeys[previousIndex]
          : null;
      if (previousKey != null && tabKeys.contains(previousKey)) {
        newIndex = tabKeys.indexOf(previousKey);
      } else {
        newIndex = previousIndex.clamp(0, math.max(0, tabKeys.length - 1));
      }
    }
    _tabController?.dispose();
    _tabKeys = tabKeys;
    _tabController = TabController(
      length: tabKeys.length,
      vsync: this,
      initialIndex: newIndex,
    );
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<String> get _periodOptions => datePeriodLabelsForRole(
    managerUp: Gates.seeExtendedDateRanges.allows(ref),
  );

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
        decoration: AppDecorations.pageBackground(context),
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
    final driverId = widget.vanDriverId;
    final vanId = widget.noDriverVanStoreId;
    final driverRows =
        ref.watch(vanDriverRowsProvider).valueOrNull ?? const <VanDriverData>[];
    final driver = driverId == null
        ? null
        : driverRows.where((d) => d.id == driverId).firstOrNull;

    if (driverId != null && driver == null) {
      return _shell(
        context,
        const Center(child: Text('That driver is no longer on this device.')),
      );
    }

    final vanNameById = {for (final v in ref.watch(vansProvider)) v.id: v.name};
    final name = driver?.name ?? 'No driver assigned';
    final isRemoved = driver?.isDeleted ?? false;

    final balanceKobo = driverId != null
        ? ref.watch(driverBalanceProvider(driverId)).valueOrNull ?? 0
        : ref.watch(vanNoDriverBalanceProvider(vanId!)).valueOrNull ?? 0;
    final trips = driverId != null
        ? ref.watch(driverTripsProvider(driverId)).valueOrNull ??
              const <VanTripData>[]
        : [
            for (final t
                in ref.watch(vanTripsForVanProvider(vanId!)).valueOrNull ??
                    const <VanTripData>[])
              if (t.vanDriverId == null) t,
          ];
    final sales = driverId != null
        ? ref.watch(driverVanSalesProvider(driverId)).valueOrNull ??
              const <OrderWithItems>[]
        : const <OrderWithItems>[];
    // #783: the old customer account's history, read-only. Empty unless linked.
    final oldCustomerId = driver?.customerId;
    final oldSales = oldCustomerId == null
        ? const <OrderWithItems>[]
        : ref.watch(oldAccountSalesProvider(oldCustomerId)).valueOrNull ??
              const <OrderWithItems>[];
    final oldPayments = oldCustomerId == null
        ? const <WalletTransactionData>[]
        : ref.watch(oldAccountPaymentsProvider(oldCustomerId)).valueOrNull ??
              const <WalletTransactionData>[];
    final oldCustomerName = oldCustomerId == null
        ? null
        : ref
              .watch(customerServiceProvider)
              .value
              .where((c) => c.id == oldCustomerId)
              .firstOrNull
              ?.name;
    final ledger = driverId != null
        ? ref.watch(driverLedgerHistoryProvider(driverId)).valueOrNull ??
              const <DriverLedgerEntryData>[]
        : ref.watch(vanNoDriverHistoryProvider(vanId!)).valueOrNull ??
              const <DriverLedgerEntryData>[];

    // The header's fallback source (#208 item 3): the vans this driver is the
    // default driver of. Filtered through [vanNameById], which holds vans only.
    final assignedVanStoreIds = [
      for (final v in ref.watch(vansProvider))
        if (v.vanDriverId == driverId && driverId != null) v.id,
    ];

    // Everything below the balance card is period-scoped; the balance is not.
    // See the class doc comment.
    final periodTrips = [
      for (final t in trips)
        if (isDateInPeriod(t.openedAt, _timeFilter)) t,
    ];
    final periodSales = [
      for (final s in [...sales, ...oldSales])
        if (isDateInPeriod(s.order.createdAt, _timeFilter)) s,
    ]..sort((a, b) => b.order.createdAt.compareTo(a.order.createdAt));
    final oldSaleIds = {for (final s in oldSales) s.order.id};
    final periodOldPayments = [
      for (final p in oldPayments)
        if (isDateInPeriod(p.createdAt, _timeFilter)) p,
    ];
    final periodLedger = [
      for (final e in ledger)
        if (isDateInPeriod(e.activityDate, _timeFilter)) e,
    ];

    // The crate tab is a Bar/Beverage surface (spec §11). Dropping it entirely
    // — rather than showing an always-zero tab — is what keeps the profile
    // honest for a trade with no empties, and the tab COUNT has to follow or
    // DefaultTabController and TabBarView disagree.
    final tracksCrates = businessTracksCrates(
      ref.watch(currentBusinessProvider),
    );

    final tabKeys = _resolveTabKeys(tracksCrates: tracksCrates);
    _syncTabController(tabKeys);

    return _shell(
      context,
      TabbedSliverScaffold(
        controller: _tabController!,
        tabBarExtent: context.getRSize(60),
        tabBarChromeExtent: _tabBarBottomMargin,
        tabBar: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.getRSize(16)),
          child: _tabBar(context, showCrates: tracksCrates),
        ),
        headerSlivers: [
          SliverToBoxAdapter(
            child: _Header(
              name: name,
              phone: driver?.phone,
              isRemoved: isRemoved,
              onAssignVan: driverId == null || isRemoved
                  ? null
                  : () => _assignVan(driverId),
              // #787: a payment is taken from the driver, with or without a
              // trip. A removed driver who still owes can pay too.
              onRecordPayment: driver == null
                  ? null
                  : () => RecordDriverPaymentSheet.showForDriver(
                      context,
                      vanDriverId: driver.id,
                      driverName: driver.name,
                    ),
              oldAccountName: oldCustomerId == null
                  ? null
                  : toNameCase(oldCustomerName ?? 'Old customer account'),
              trips: trips,
              vanNameById: vanNameById,
              assignedVanStoreIds: assignedVanStoreIds,
              joinedAt: _driverSince(trips),
            ),
          ),
          SliverToBoxAdapter(child: _balanceCard(context, balanceKobo)),
        ],
        tabViews: [
          TabSliverView(
            storageKey: 'driver-profile-trips',
            slivers: _tripsTabSlivers(
              trips: periodTrips,
              vanNameById: vanNameById,
              driverName: name,
            ),
          ),
          TabSliverView(
            storageKey: 'driver-profile-sales',
            slivers: _salesTabSlivers(
              sales: periodSales,
              oldSaleIds: oldSaleIds,
            ),
          ),
          TabSliverView(
            storageKey: 'driver-profile-ledger',
            slivers: _ledgerTabSlivers(
              entries: periodLedger,
              oldPayments: periodOldPayments,
              vanNameByTripId: {
                for (final t in trips) t.id: vanNameById[t.vanStoreId] ?? '',
              },
            ),
          ),
          if (tracksCrates)
            TabSliverView(
              storageKey: 'driver-profile-crates',
              slivers: _cratesTabSlivers(
                trips: periodTrips,
                vanNameById: vanNameById,
              ),
            ),
        ],
      ),
      subtitle: name,
    );
  }

  /// Make this driver the usual driver of a van (pre-fills its next load).
  Future<void> _assignVan(String driverId) async {
    final vans = ref.read(vansProvider);
    if (vans.isEmpty) {
      AppNotification.showError(context, 'There are no vans set up yet.');
      return;
    }
    final van = await showModalBottomSheet<StoreData>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Which van does this driver usually take?',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final v in vans)
              ListTile(
                title: Text(v.name),
                trailing: v.vanDriverId == driverId
                    ? const Icon(AppIcons.check)
                    : null,
                onTap: () => Navigator.pop(ctx, v),
              ),
          ],
        ),
      ),
    );
    if (van == null) return;
    await ref
        .read(databaseProvider)
        .vanDriversDao
        .assignToVan(van.id, driverId);
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
                      AppIcons.balance,
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
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    formatCurrency(balanceKobo.abs() / 100),
                    style: TextStyle(
                      fontSize: context.getRFontSize(28),
                      fontWeight: FontWeight.w900,
                      color: color,
                      letterSpacing: -1,
                    ),
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

  /// Height the pinned tab bar gives up to its bottom margin. Read by the
  /// header delegate so the TabBar keeps its full interactive height.
  double get _tabBarBottomMargin => context.getRSize(8);

  Widget _tabBar(BuildContext context, {required bool showCrates}) {
    final t = Theme.of(context);
    return Container(
      margin: EdgeInsets.only(bottom: _tabBarBottomMargin),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.colorScheme.primary.withValues(alpha: 0.1)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: TabBar(
          controller: _tabController,
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
    );
  }

  List<Widget> _tripsTabSlivers({
    required List<VanTripData> trips,
    required Map<String, String> vanNameById,
    required String driverName,
  }) {
    if (trips.isEmpty) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyTab(
            icon: AppIcons.supplier,
            message: 'No trips in this period',
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: _tabPadding(context),
        sliver: SliverList.builder(
          itemCount: trips.length,
          itemBuilder: (_, i) => _TripRow(
            key: driverTripRowKey(trips[i].id),
            trip: trips[i],
            vanName: vanNameById[trips[i].vanStoreId] ?? 'Van',
            driverName: driverName,
          ),
        ),
      ),
    ];
  }

  List<Widget> _salesTabSlivers({
    required List<OrderWithItems> sales,
    Set<String> oldSaleIds = const {},
  }) {
    if (sales.isEmpty) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyTab(
            icon: AppIcons.receipt,
            message: 'No road sales in this period',
          ),
        ),
      ];
    }
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    // The old customer account's sales are history, not road sales: they stay
    // out of the "taken on the road" figure.
    final recognised = sales
        .where(
          (s) =>
              !oldSaleIds.contains(s.order.id) &&
              orderCountsAsSale(s.order.status),
        )
        .fold<int>(0, (sum, s) => sum + s.order.netAmountKobo);

    return [
      SliverPadding(
        padding: _tabPadding(context),
        sliver: SliverList.builder(
          itemCount: sales.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) {
              return Padding(
                padding: EdgeInsets.only(bottom: context.getRSize(12)),
                child: Text(
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
            return _SaleRow(
              key: driverSaleRowKey(sale.order.id),
              sale: sale,
              fromOldAccount: oldSaleIds.contains(sale.order.id),
            );
          },
        ),
      ),
    ];
  }

  List<Widget> _ledgerTabSlivers({
    required List<DriverLedgerEntryData> entries,
    List<WalletTransactionData> oldPayments = const [],
    required Map<String, String> vanNameByTripId,
  }) {
    if (entries.isEmpty && oldPayments.isEmpty) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyTab(
            icon: AppIcons.bill,
            message: 'No account activity in this period',
          ),
        ),
      ];
    }
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;

    var inKobo = 0;
    var outKobo = 0;
    for (final e in entries) {
      if (e.signedAmountKobo >= 0) {
        inKobo += e.signedAmountKobo;
      } else {
        outKobo += -e.signedAmountKobo;
      }
    }

    // #783: interleave the old account's payments by date. They are history
    // only: the summary tiles and the balance count the driver's own rows.
    final lines =
        <
            ({
              DateTime at,
              DriverLedgerEntryData? entry,
              WalletTransactionData? old,
            })
          >[
            for (final e in entries) (at: e.createdAt, entry: e, old: null),
            for (final p in oldPayments) (at: p.createdAt, entry: null, old: p),
          ]
          ..sort((a, b) => b.at.compareTo(a.at));

    return [
      SliverPadding(
        padding: _tabPadding(context),
        sliver: SliverList.builder(
          itemCount: lines.length + 1,
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
            final line = lines[i - 1];
            final old = line.old;
            if (old != null) {
              return _OldPaymentTile(
                key: Key('driver-old-payment-${old.id}'),
                payment: old,
              );
            }
            final entry = line.entry!;
            return DriverLedgerEntryTile(
              key: driverLedgerRowKey(entry.id),
              entry: entry,
              vanName: entry.tripId == null
                  ? null
                  : vanNameByTripId[entry.tripId!],
            );
          },
        ),
      ),
    ];
  }

  List<Widget> _cratesTabSlivers({
    required List<VanTripData> trips,
    required Map<String, String> vanNameById,
  }) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;

    final withShells = [
      for (final trip in trips)
        if (trip.shellsOut != 0 || trip.shellsBack != 0) trip,
    ];
    final totalOut = withShells.fold<int>(0, (s, t) => s + t.shellsOut);
    final totalBack = withShells.fold<int>(0, (s, t) => s + t.shellsBack);

    return [
      SliverPadding(
        padding: _tabPadding(context),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
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
                  SizedBox(height: context.getRSize(12)),
                  _LostCratesLine(
                    tripIds: [for (final trip in withShells) trip.id],
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
                  key: driverCrateRowKey(trip.id),
                  margin: EdgeInsets.only(bottom: context.getRSize(12)),
                  padding: EdgeInsets.all(context.getRSize(16)),
                  radius: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
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
                      SizedBox(height: context.getRSize(8)),
                      _LostCratesLine(tripIds: [trip.id]),
                    ],
                  ),
                ),
              ),
          ]),
        ),
      ),
    ];
  }
}

/// Lost crates (#726): the count and naira value of crates that went out on
/// [tripIds] and are not accounted for, at the manufacturer deposit rate.
///
/// **Shown only.** The driver is not charged for these and they sit outside
/// every money total on this profile.
class _LostCratesLine extends ConsumerWidget {
  final List<String> tripIds;

  const _LostCratesLine({required this.tripIds});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var units = 0;
    var valueKobo = 0;
    for (final id in tripIds) {
      final p = ref.watch(vanTripPositionProvider(id)).valueOrNull;
      if (p == null) continue;
      units += p.shellsLostUnits;
      valueKobo += p.shellsLostValueKobo;
    }
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final lost = units > 0;
    return Text(
      lost
          ? 'Lost crates: $units'
                '${valueKobo > 0 ? ' (${formatCurrency(valueKobo / 100)})' : ''}'
                ' — shown only, not charged to the driver.'
          : 'No lost crates.',
      key: const ValueKey('driver-lost-crates'),
      style: TextStyle(
        fontSize: context.getRFontSize(12),
        fontWeight: FontWeight.w600,
        color: lost
            ? semantic.warning
            : (t.textTheme.bodySmall?.color ?? t.iconTheme.color),
      ),
    );
  }
}

// ── Header ──────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String name;
  final String? phone;
  final bool isRemoved;
  final VoidCallback? onAssignVan;
  final VoidCallback? onRecordPayment;

  /// #783: the brought-in old customer account's name, when linked.
  final String? oldAccountName;
  final List<VanTripData> trips;
  final Map<String, String> vanNameById;

  /// The driver's current van assignments — the fallback the header falls back
  /// to when the trips name nothing. See [resolveDriverVanNames].
  final List<String> assignedVanStoreIds;

  final DateTime? joinedAt;

  const _Header({
    required this.name,
    required this.phone,
    required this.isRemoved,
    required this.onAssignVan,
    this.onRecordPayment,
    this.oldAccountName,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                    _initials(name),
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
                            name,
                            style: TextStyle(
                              fontSize: context.getRFontSize(18),
                              fontWeight: FontWeight.w800,
                              color: t.colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isRemoved) ...[
                          SizedBox(width: context.getRSize(8)),
                          const RemovedDriverBadge(),
                        ],
                      ],
                    ),
                    if ((phone ?? '').isNotEmpty) ...[
                      SizedBox(height: context.getRSize(6)),
                      _InfoRow(icon: AppIcons.phone, text: phone!),
                    ],
                    SizedBox(height: context.getRSize(4)),
                    _InfoRow(icon: AppIcons.supplier, text: _vans),
                    SizedBox(height: context.getRSize(4)),
                    _InfoRow(
                      icon: AppIcons.calendar,
                      text: joinedAt == null
                          ? 'No trips yet'
                          : 'Driving since ${DateFormat('d MMM y').format(joinedAt!)}',
                    ),
                    if (isRemoved) ...[
                      SizedBox(height: context.getRSize(8)),
                      Text(
                        'No longer a driver here. They stay on the Drivers '
                        'list until this account is settled or written off.',
                        style: t.textTheme.bodySmall?.copyWith(color: subtext),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (onRecordPayment != null || onAssignVan != null) ...[
            SizedBox(height: context.getRSize(14)),
            Row(
              children: [
                if (onRecordPayment != null)
                  Expanded(
                    child: AppButton(
                      key: const Key('driver-record-payment'),
                      text: 'Record payment',
                      icon: AppIcons.transfer,
                      variant: AppButtonVariant.secondary,
                      size: AppButtonSize.small,
                      onPressed: onRecordPayment,
                    ),
                  ),
                if (onRecordPayment != null && onAssignVan != null)
                  SizedBox(width: context.getRSize(10)),
                if (onAssignVan != null)
                  Expanded(
                    child: AppButton(
                      text: 'Set usual van',
                      icon: AppIcons.vanDelivery,
                      variant: AppButtonVariant.outline,
                      size: AppButtonSize.small,
                      onPressed: onAssignVan,
                    ),
                  ),
              ],
            ),
          ],
          if (oldAccountName != null) ...[
            SizedBox(height: context.getRSize(10)),
            Text(
              'Old customer account: $oldAccountName',
              style: t.textTheme.bodySmall?.copyWith(color: subtext),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Trips ───────────────────────────────────────────────────────────────────

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
    super.key,
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
                    AppIcons.supplier,
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
                    AppIcons.chevronRight,
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
              SizedBox(height: context.getRSize(4)),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Driver: $driverName',
                      style: TextStyle(
                        fontSize: context.getRFontSize(12),
                        color: subtext,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        showAssignTripDriverSheet(context, ref, trip),
                    child: Text(
                      trip.vanDriverId == null ? 'Set driver' : 'Change',
                    ),
                  ),
                ],
              ),
              SizedBox(height: context.getRSize(6)),
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

class _SaleRow extends StatelessWidget {
  final OrderWithItems sale;

  /// #783: this sale is from the driver's old customer account (history).
  final bool fromOldAccount;

  const _SaleRow({super.key, required this.sale, this.fromOldAccount = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final order = sale.order;
    final counted = orderCountsAsSale(order.status);
    final units = sale.items.fold<double>(0, (sum, l) => sum + l.item.quantity);

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
                  AppIcons.receipt,
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
                      ' • ${formatQty(units)} ${units == 1 ? 'item' : 'items'}'
                      '${counted ? '' : ' • ${order.status}'}'
                      '${fromOldAccount ? ' • Old customer account' : ''}',
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

/// One payment from the driver's OLD customer account (#783): read-only, and
/// tagged so it is never mistaken for a driver ledger row.
class _OldPaymentTile extends StatelessWidget {
  final WalletTransactionData payment;
  const _OldPaymentTile({super.key, required this.payment});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    // An account adjustment (opening balance, correction, or the move to the
    // driver) is listed too, so the history adds up; it is not a payment.
    final isAdjustment = payment.referenceType == 'adjustment';
    final isCredit = payment.signedAmountKobo >= 0;
    final title = isAdjustment
        ? 'Account adjustment'
        : payment.referenceType == 'topup_transfer'
        ? 'Payment received (Transfer)'
        : 'Payment received (Cash)';
    final tone = isAdjustment ? t.colorScheme.onSurface : semantic.success;
    return GlassyCard(
      margin: EdgeInsets.only(bottom: context.getRSize(12)),
      radius: 16,
      padding: EdgeInsets.all(context.getRSize(16)),
      child: Row(
        children: [
          Container(
            width: context.getRSize(40),
            height: context.getRSize(40),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              AppIcons.transfer,
              color: tone,
              size: context.getRSize(16),
            ),
          ),
          SizedBox(width: context.getRSize(14)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: context.getRFontSize(14),
                    fontWeight: FontWeight.bold,
                    color: t.colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: context.getRSize(4)),
                Text(
                  '${DateFormat('d MMM y').format(payment.createdAt)}'
                  ' • Old customer account',
                  style: TextStyle(
                    fontSize: context.getRFontSize(12),
                    color: subtext,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            '${isCredit ? '+' : '−'}${formatCurrency(payment.amountKobo / 100)}',
            style: TextStyle(
              fontSize: context.getRFontSize(15),
              fontWeight: FontWeight.w800,
              color: tone,
            ),
          ),
        ],
      ),
    );
  }
}
