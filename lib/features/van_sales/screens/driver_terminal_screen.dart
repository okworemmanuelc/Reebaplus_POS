import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/theme/scheme_colors.dart';
import 'package:reebaplus_pos/core/utils/currency_input_formatter.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/van_sales/driver_terminal_data.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_run_screen.dart';
import 'package:reebaplus_pos/features/van_sales/widgets/van_receipt_view.dart';
import 'package:reebaplus_pos/shared/widgets/app_button.dart';
import 'package:reebaplus_pos/shared/widgets/frame/frame_nav.dart';

/// The **driver terminal** (#142, PRD #139 / ADR 0019, van-sales spec §9.2),
/// restyled to the owner's mockups (#729).
///
/// A driver's whole app: a two-tab shell, **Sell** and **My Trip** (bottom bar
/// on a phone, side rail on a tablet). Not a mode of the shop POS — there is no
/// store picker, no customer, no credit and no discount here, because none of
/// them was ever built.
///
///  * Every line is priced at the **load price** from the trip's lots
///    (`van_trip_lots.load_price_kobo`), never the catalogue tier (spec §5.1);
///    a product with no load price is not sold.
///  * A sale is an ordinary cash walk-in order on the van store, which writes no
///    payment row and books no per-sale COGS (`OrdersDao.createOrder` enforces
///    both from the store).
///  * **A sale does not touch the driver's balance** (`loaded − returned −
///    paid`); the driver cannot record payments.
///  * **No open trip ⇒ no selling** (spec §9.2 #6): the normal state at the yard.
class DriverTerminalScreen extends ConsumerStatefulWidget {
  const DriverTerminalScreen({super.key});

  @override
  ConsumerState<DriverTerminalScreen> createState() =>
      _DriverTerminalScreenState();
}

enum _Stage { sell, checkout, complete }

class _DriverTerminalScreenState extends ConsumerState<DriverTerminalScreen> {
  /// productId → units in the current sale. A plain map, deliberately: the shop
  /// `CartService` carries customers, discounts, custom prices and crate lines,
  /// every one of which is out of scope on the road.
  final Map<String, int> _units = {};

  int _tab = 0;
  _Stage _stage = _Stage.sell;
  _RoadSale? _lastSale;
  String _query = '';
  bool _ringing = false;

  final TextEditingController _cashCtrl = TextEditingController();

  /// #730 - productId -> the selling price (kobo) the driver typed; absent means
  /// "at the load price". Never read raw: [_sellFor] clamps it up to the load.
  final Map<String, int> _sellKobo = {};
  final Map<String, TextEditingController> _priceCtrls = {};

  int _sellFor(String productId, int loadPriceKobo) => driverSellPriceKobo(
    loadPriceKobo: loadPriceKobo,
    typedKobo: _sellKobo[productId],
  );

  void _resetPrices() {
    for (final c in _priceCtrls.values) {
      c.dispose();
    }
    _priceCtrls.clear();
    _sellKobo.clear();
  }

  final GlobalKey<VanReceiptViewState> _receiptKey =
      GlobalKey<VanReceiptViewState>();

  @override
  void dispose() {
    _cashCtrl.dispose();
    _resetPrices();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Guarded.screen(
      gate: Gates.vanSell,
      builder: (context) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final trip = ref.watch(currentDriverTripProvider).valueOrNull;
    final driverName = ref.watch(driverDisplayNameProvider);
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final rail = context.isRailLayout;

    if (trip == null) {
      return _NoOpenTripShell(
        tab: _tab,
        onTab: (i) => setState(() => _tab = i),
        driverName: driverName,
      );
    }

    final van = _storeById(stores, trip.vanStoreId);
    final vanLabel = _vanLabel(van);
    final openedLabel = 'Opened ${_when(trip.openedAt)}';

    if (_tab == 1) {
      return _DriverShell(
        tab: 1,
        onTab: _setTab,
        header: _DriverHeader(
          title: 'My Trip',
          subtitle: '$vanLabel · $openedLabel',
          chip: const _SyncChip(),
        ),
        body: DriverRunScreen(tripId: trip.id),
      );
    }

    if (_stage == _Stage.complete && _lastSale != null) {
      final sale = _lastSale!;
      final change = sale.cashReceivedKobo - sale.totalKobo;
      return _DriverShell(
        tab: 0,
        onTab: _setTab,
        showNav: false,
        header: _DriverHeader(
          title: 'Sale Complete',
          subtitle: rail
              ? 'Saved on this tablet · sends when online'
              : 'Saved on this phone · sends when online',
          leadingIcon: AppIcons.close,
          leadingLabel: 'Close',
          onLeading: _newSale,
          chip: rail ? const _SyncChip() : null,
        ),
        body: ListView(
          padding: _pagePadding(context),
          children: [
            _PaidBanner(totalKobo: sale.totalKobo, changeKobo: change),
            SizedBox(height: context.getRSize(14)),
            VanReceiptView(
              // Keyed on the sale so a second run gets a FRESH receipt state —
              // the auto-print fires from `initState`.
              key: _receiptKey,
              orderNumber: sale.orderNumber,
              cart: sale.cart,
              totalKobo: sale.totalKobo,
              cashReceivedKobo: sale.cashReceivedKobo,
              autoPrint: true,
              showActions: false,
            ),
          ],
        ),
        bottom: _ActionBar(
          showInset: true,
          child: Row(
            children: [
              Expanded(
                child: AppButton(
                  key: const ValueKey('van-new-sale'),
                  text: 'New Sale',
                  variant: AppButtonVariant.secondary,
                  icon: AppIcons.cartAdd,
                  onPressed: _newSale,
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: AppButton(
                  key: const ValueKey('van-print-receipt'),
                  text: 'Print Receipt',
                  icon: AppIcons.print,
                  onAsyncPressed: () async =>
                      _receiptKey.currentState?.printReceipt(),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final prices =
        ref.watch(vanTripLoadPricesProvider(trip.id)).valueOrNull ??
        const <String, int>{};
    final stock =
        ref.watch(productsWithStockProvider(trip.vanStoreId)).valueOrNull ??
        const <ProductDataWithStock>[];
    // Only what was loaded at an agreed price is on the list: a product with
    // van stock but no lot has no road price, and inventing one from the
    // catalogue is exactly what spec §5.1 rules out. Sold-out products stay,
    // greyed out.
    final sellable = [
      for (final s in stock)
        if (prices.containsKey(s.product.id)) s,
    ]..sort(
        (a, b) => a.product.name.toLowerCase().compareTo(
          b.product.name.toLowerCase(),
        ),
      );
    final tracksCrates = businessTracksCrates(
      ref.watch(currentBusinessProvider),
    );

    final totalKobo = _units.entries.fold<int>(
      0,
      (sum, e) => sum + (prices[e.key] ?? 0) * e.value,
    );
    final itemCount = _units.values.fold<int>(0, (a, b) => a + b);
    final onVanTotal = sellable.fold<int>(
      0,
      (a, s) => a + s.totalStock.floor(),
    );
    final saleLines = [
      for (final s in sellable)
        if ((_units[s.product.id] ?? 0) > 0)
          (
            row: s,
            units: _units[s.product.id]!,
            priceKobo: prices[s.product.id] ?? 0,
          ),
    ];
    final empties = driverCrateEmpties(
      businessTracksCrates: tracksCrates,
      lines: [
        for (final l in saleLines)
          (
            name: l.row.product.name,
            units: l.units,
            unit: l.row.product.unit,
            trackEmpties: l.row.product.trackEmpties,
          ),
      ],
    );

    if (_stage == _Stage.checkout && saleLines.isNotEmpty) {
      return _buildCheckout(
        context,
        trip: trip,
        saleLines: saleLines,
        totalKobo: totalKobo,
        itemCount: itemCount,
        empties: empties,
        sellable: sellable,
        prices: prices,
      );
    }

    final subtitle = rail ? '$vanLabel · $driverName' : vanLabel;
    final tripOpened = Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'Trip opened '),
          TextSpan(
            text: _when(trip.openedAt),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
    final query = _query.trim().toLowerCase();
    final shown = [
      for (final s in sellable)
        if (query.isEmpty || s.product.name.toLowerCase().contains(query)) s,
    ];

    Widget productList() {
      if (sellable.isEmpty) return const _EmptyVan();
      if (shown.isEmpty) {
        return const _CenterNote(
          title: 'No match',
          message: 'Nothing on your van matches that search.',
        );
      }
      if (rail) {
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
            context.getRSize(8),
            0,
            context.getRSize(8),
            context.getRSize(16),
          ),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: context.getRSize(340),
            mainAxisExtent: context.getRSize(214),
            mainAxisSpacing: context.getRSize(12),
            crossAxisSpacing: context.getRSize(12),
          ),
          itemCount: shown.length,
          itemBuilder: (_, i) => _productCard(shown[i], prices, tracksCrates),
        );
      }
      return ListView.separated(
        padding: EdgeInsets.fromLTRB(
          0,
          0,
          0,
          context.getRSize(16),
        ),
        itemCount: shown.length,
        separatorBuilder: (_, _) => SizedBox(height: context.getRSize(10)),
        itemBuilder: (_, i) => _productCard(shown[i], prices, tracksCrates),
      );
    }

    final searchRow = Row(
      children: [
        Expanded(
          child: _SearchBox(onChanged: (v) => setState(() => _query = v)),
        ),
        if (rail) ...[
          SizedBox(width: context.getRSize(12)),
          _OnVanPill(count: onVanTotal),
        ],
      ],
    );

    final left = Padding(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(rail ? 12 : 16),
        context.getRSize(12),
        context.getRSize(rail ? 12 : 16),
        0,
      ),
      child: Column(
        children: [
          if (!rail) ...[
            _InfoCard(
              child: Row(
                children: [
                  Icon(
                    AppIcons.vanDelivery,
                    size: context.getRSize(20),
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  SizedBox(width: context.getRSize(10)),
                  Expanded(child: tripOpened),
                  SizedBox(width: context.getRSize(8)),
                  Text(
                    '$onVanTotal on van',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.getRSize(10)),
          ],
          searchRow,
          SizedBox(height: context.getRSize(12)),
          Expanded(child: productList()),
        ],
      ),
    );

    return _DriverShell(
      tab: 0,
      onTab: _setTab,
      header: _DriverHeader(
        title: 'Sell',
        subtitle: subtitle,
        trailing: rail
            ? DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.bodySmall,
                child: tripOpened,
              )
            : null,
        chip: const _SyncChip(),
      ),
      body: rail
          ? Row(
              children: [
                Expanded(child: left),
                _SalePanel(
                  lines: saleLines,
                  itemCount: itemCount,
                  totalKobo: totalKobo,
                  empties: empties,
                  onAdd: (id, onVan) => _bump(id, 1, onVan),
                  onRemove: (id, onVan) => _bump(id, -1, onVan),
                  onClear: () => setState(_units.clear),
                  onCheckout: _goCheckout,
                ),
              ],
            )
          : left,
      bottom: rail
          ? null
          : _ActionBar(
              showInset: false,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$itemCount ${itemCount == 1 ? 'item' : 'items'}'
                          ' · at load price',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          formatCurrency(totalKobo / 100),
                          key: const ValueKey('van-sell-total'),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(12)),
                  Expanded(
                    child: AppButton(
                      key: const ValueKey('van-checkout'),
                      text: 'Checkout',
                      trailingIcon: AppIcons.chevronRight,
                      onPressed: totalKobo <= 0 ? null : _goCheckout,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _productCard(
    ProductDataWithStock row,
    Map<String, int> prices,
    bool tracksCrates,
  ) {
    final id = row.product.id;
    final onVan = row.totalStock.floor(); // the van stays whole
    return _ProductCard(
      productId: id,
      name: row.product.name,
      unitLabel: _unitLabel(row.product, tracksCrates),
      loadPriceKobo: prices[id] ?? 0,
      onVan: onVan,
      units: _units[id] ?? 0,
      wide: context.isRailLayout,
      onAdd: () => _bump(id, 1, onVan),
      onRemove: () => _bump(id, -1, onVan),
    );
  }

  Widget _buildCheckout(
    BuildContext context, {
    required VanTripData trip,
    required List<_SaleLine> saleLines,
    required int totalKobo,
    required int itemCount,
    required ({int count, String? names}) empties,
    required List<ProductDataWithStock> sellable,
    required Map<String, int> prices,
  }) {
    final rail = context.isRailLayout;
    // #730 - what the customer pays can exceed the load value; the extra is the
    // driver's. Cash and change are about what the customer pays.
    final figures = driverCheckoutFigures([
      for (final l in saleLines)
        (
          units: l.units,
          loadPriceKobo: l.priceKobo,
          sellPriceKobo: _sellFor(l.row.product.id, l.priceKobo),
        ),
    ]);
    final payKobo = figures.customerPaysKobo;
    final cashKobo = (parseCurrency(_cashCtrl.text) * 100).round();
    final changeKobo = cashKobo - payKobo;
    final enough = cashKobo >= payKobo;

    final lines = _InfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$itemCount ${itemCount == 1 ? 'item' : 'items'}',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          Divider(height: context.getRSize(20)),
          for (final l in saleLines) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: l.row.product.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            TextSpan(
                              text: ' × ${l.units}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Text(
                        'Load ${formatCurrency(l.priceKobo / 100)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      SizedBox(height: context.getRSize(6)),
                      SizedBox(
                        width: context.getRSize(170),
                        child: _sellPriceField(l.row.product.id, l.priceKobo),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: context.getRSize(8)),
                Text(
                  formatCurrency(
                    _sellFor(l.row.product.id, l.priceKobo) * l.units / 100,
                  ),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(10)),
          ],
        ],
      ),
    );

    final customerPays = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Customer pays',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: rail ? FontWeight.w500 : FontWeight.w700,
          ),
        ),
        Text(
          formatCurrency(payKobo / 100),
          key: const ValueKey('van-checkout-total'),
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        SizedBox(height: context.getRSize(8)),
        Row(
          children: [
            Expanded(
              child: Text(
                'Load value (you hand in)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Text(
              formatCurrency(figures.loadValueKobo / 100),
              key: const ValueKey('van-checkout-load-value'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        if (figures.extraKobo > 0)
          Row(
            children: [
              Expanded(
                child: Text(
                  'Your extra',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Text(
                formatCurrency(figures.extraKobo / 100),
                key: const ValueKey('van-checkout-extra'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
      ],
    );

    final cashField = TextField(
      key: const ValueKey('van-cash-received'),
      controller: _cashCtrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        CurrencyInputFormatter(),
      ],
      onChanged: (_) => setState(() {}),
      style: const TextStyle(fontWeight: FontWeight.w800),
      decoration: InputDecoration(
        prefixText: '$activeCurrencySymbol ',
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        ),
      ),
    );

    final changeTile = Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: Theme.of(context).extension<AppSchemeColors>()?.primaryTint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              rail ? 'Change to give' : '',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            key: const ValueKey('van-change'),
            enough ? formatCurrency(changeKobo / 100) : 'Not enough cash',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );

    final completeButton = AppButton(
      key: const ValueKey('van-complete-sale'),
      text: 'Complete Sale · ${formatCurrency(payKobo / 100)}',
      icon: AppIcons.checkCircle,
      // Locks on the first tap, before any await (the #659 rule).
      onAsyncPressed: enough && !_ringing
          ? () => _ring(trip, prices, sellable, cashKobo)
          : null,
    );

    final quickPicks = <int>{};
    if (rail) {
      for (final step in [100000, 500000]) {
        final up = ((payKobo + step - 1) ~/ step) * step;
        if (up > payKobo) quickPicks.add(up);
      }
    }

    final Widget body;
    if (rail) {
      body = Row(
        children: [
          Expanded(
            child: ListView(
              padding: _pagePadding(context),
              children: [
                lines,
                if (empties.count > 0) ...[
                  SizedBox(height: context.getRSize(14)),
                  _CratesNote(empties: empties),
                ],
              ],
            ),
          ),
          Container(
            width: context.getRSize(360),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            padding: EdgeInsets.all(context.getRSize(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                customerPays,
                SizedBox(height: context.getRSize(16)),
                Text(
                  'Cash received',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SizedBox(height: context.getRSize(6)),
                cashField,
                SizedBox(height: context.getRSize(10)),
                Wrap(
                  spacing: context.getRSize(8),
                  children: [
                    ActionChip(
                      label: const Text('Exact'),
                      onPressed: () => setState(
                        () => _cashCtrl.text = koboToInputText(payKobo),
                      ),
                    ),
                    for (final p in quickPicks)
                      ActionChip(
                        label: Text(formatCurrency(p / 100)),
                        onPressed: () => setState(
                          () => _cashCtrl.text = koboToInputText(p),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: context.getRSize(12)),
                changeTile,
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: completeButton,
                ),
                SizedBox(height: context.deviceBottomPadding),
              ],
            ),
          ),
        ],
      );
    } else {
      body = ListView(
        padding: _pagePadding(context),
        children: [
          lines,
          SizedBox(height: context.getRSize(12)),
          _InfoCard(child: customerPays),
          SizedBox(height: context.getRSize(12)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cash received',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: context.getRSize(6)),
                    cashField,
                  ],
                ),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Change to give',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: context.getRSize(6)),
                    changeTile,
                  ],
                ),
              ),
            ],
          ),
          if (empties.count > 0) ...[
            SizedBox(height: context.getRSize(12)),
            _CratesNote(empties: empties),
          ],
        ],
      );
    }

    return _DriverShell(
      tab: 0,
      onTab: _setTab,
      showNav: false,
      header: _DriverHeader(
        title: 'Checkout',
        subtitle: 'Cash sale · Walk-in customer',
        leadingIcon: AppIcons.arrowBack,
        leadingLabel: 'Back',
        onLeading: () => setState(() => _stage = _Stage.sell),
        chip: rail ? const _SyncChip() : null,
      ),
      body: body,
      bottom: rail
          ? null
          : _ActionBar(showInset: true, child: completeButton),
    );
  }

  // ── actions ───────────────────────────────────────────────────────────────

  void _setTab(int i) => setState(() => _tab = i);

  void _goCheckout() {
    if (_units.isEmpty) return;
    setState(() {
      _resetPrices();
      _stage = _Stage.checkout;
      // Default to exact cash; the driver types what was actually handed over.
      _cashCtrl.text = koboToInputText(_currentTotalKobo());
    });
  }

  int _currentTotalKobo() {
    final trip = ref.read(currentDriverTripProvider).valueOrNull;
    if (trip == null) return 0;
    final prices =
        ref.read(vanTripLoadPricesProvider(trip.id)).valueOrNull ??
        const <String, int>{};
    return _units.entries.fold<int>(
      0,
      (s, e) => s + (prices[e.key] ?? 0) * e.value,
    );
  }

  void _newSale() => setState(() {
    _lastSale = null;
    _stage = _Stage.sell;
  });

  void _bump(String productId, int delta, int onVan) {
    setState(() {
      final next = (_units[productId] ?? 0) + delta;
      if (next <= 0) {
        _units.remove(productId);
      } else {
        // The van is single-device, so this local cap IS the oversell guard for
        // the road (spec §9.2 #7); `createOrder`'s stock guard remains the
        // write-boundary backstop.
        _units[productId] = next > onVan ? onVan : next;
      }
    });
  }

  /// #730 - the per-line selling-price box. Starts at the load price and cannot
  /// go below it: a lower number is held at the load price and flagged.
  Widget _sellPriceField(String productId, int loadPriceKobo) {
    final ctrl = _priceCtrls.putIfAbsent(
      productId,
      () => TextEditingController(text: koboToInputText(loadPriceKobo)),
    );
    final typed = (parseCurrency(ctrl.text) * 100).round();
    final below = typed < loadPriceKobo;
    final extra = _sellFor(productId, loadPriceKobo) - loadPriceKobo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: ValueKey('van-sell-price-$productId'),
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            CurrencyInputFormatter(),
          ],
          onChanged: (_) => setState(() {
            _sellKobo[productId] = (parseCurrency(ctrl.text) * 100).round();
            _cashCtrl.text = koboToInputText(_checkoutPayKobo());
          }),
          style: const TextStyle(fontWeight: FontWeight.w800),
          decoration: InputDecoration(
            isDense: true,
            labelText: 'Selling price',
            prefixText: '$activeCurrencySymbol ',
            errorText: below ? "Can't go below the load price" : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
            ),
          ),
        ),
        if (extra > 0)
          Padding(
            padding: EdgeInsets.only(top: context.getRSize(4)),
            child: Text(
              '${formatCurrency(extra / 100)} above load on each',
              key: ValueKey('van-above-load-$productId'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  int _checkoutPayKobo() {
    final trip = ref.read(currentDriverTripProvider).valueOrNull;
    if (trip == null) return 0;
    final prices =
        ref.read(vanTripLoadPricesProvider(trip.id)).valueOrNull ??
        const <String, int>{};
    return _units.entries.fold<int>(
      0,
      (s, e) => s + _sellFor(e.key, prices[e.key] ?? 0) * e.value,
    );
  }

  Future<void> _ring(
    VanTripData trip,
    Map<String, int> prices,
    List<ProductDataWithStock> sellable,
    int cashReceivedKobo,
  ) async {
    if (_ringing) return;
    setState(() => _ringing = true);
    try {
      final byId = {for (final s in sellable) s.product.id: s.product};
      final cart = <Map<String, dynamic>>[
        for (final entry in _units.entries)
          {
            'id': entry.key,
            'name': byId[entry.key]?.name ?? 'Item',
            'qty': entry.value,
            // The LOAD price, not the catalogue tier (spec §5.1 / §9.2 #9).
            'unitPriceKobo': prices[entry.key] ?? 0,
            // #730: the driver's selling price, only when above the load
            // price. The order stays at load price; this rides on the side.
            if (_sellFor(entry.key, prices[entry.key] ?? 0) >
                (prices[entry.key] ?? 0))
              'chargedUnitPriceKobo': _sellFor(
                entry.key,
                prices[entry.key] ?? 0,
              ),
            // #146: the receipt surfaces read `price`, in NAIRA. It shows what
            // the customer paid per unit (#730).
            'price': _sellFor(entry.key, prices[entry.key] ?? 0) / 100.0,
          },
      ];
      final totalKobo = cart.fold<int>(
        0,
        (sum, l) => sum + (l['unitPriceKobo'] as int) * (l['qty'] as int),
      );
      final customerPaysKobo = cart.fold<int>(
        0,
        (sum, l) =>
            sum +
            ((l['chargedUnitPriceKobo'] as int?) ??
                    (l['unitPriceKobo'] as int)) *
                (l['qty'] as int),
      );

      final orderNumber = await ref
          .read(orderServiceProvider)
          .addOrder(
            // Walk-in ONLY on the road: no wallet, no credit, no crate balance.
            customerId: null,
            cart: cart,
            totalAmountKobo: totalKobo,
            // Cash in full. The change given is a receipt figure only.
            amountPaidKobo: totalKobo,
            paymentType: 'Cash',
            staffId: ref.read(authProvider).currentUser?.id,
            // The VAN: the single fact `createOrder` keys its van behaviour on.
            storeId: trip.vanStoreId,
            paymentSubType: 'cash',
          );

      if (!mounted) return;
      setState(() {
        _units.clear();
        _lastSale = _RoadSale(
          orderNumber: orderNumber,
          cart: cart,
          totalKobo: customerPaysKobo,
          cashReceivedKobo: cashReceivedKobo < customerPaysKobo
              ? customerPaysKobo
              : cashReceivedKobo,
        );
        _resetPrices();
        _stage = _Stage.complete;
      });
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'van.terminal.ring');
      if (mounted) {
        AppNotification.showError(context, 'Sale failed: $e');
      }
    } finally {
      if (mounted) setState(() => _ringing = false);
    }
  }
}

/// A sale line being built: the product row, units and load price.
typedef _SaleLine = ({ProductDataWithStock row, int units, int priceKobo});

/// One rung road sale, snapshotted so the receipt survives the cart clearing.
class _RoadSale {
  final String orderNumber;
  final List<Map<String, dynamic>> cart;
  final int totalKobo;
  final int cashReceivedKobo;

  const _RoadSale({
    required this.orderNumber,
    required this.cart,
    required this.totalKobo,
    required this.cashReceivedKobo,
  });
}

// ── helpers ─────────────────────────────────────────────────────────────────

StoreData? _storeById(List<StoreData> stores, String? id) {
  for (final s in stores) {
    if (s.id == id) return s;
  }
  return null;
}

String _vanLabel(StoreData? van) {
  if (van == null) return 'Your van';
  final plate = (van.location ?? '').trim();
  return plate.isEmpty ? van.name : '${van.name} · $plate';
}

String _unitLabel(ProductData p, bool tracksCrates) {
  final unit = (p.unit ?? '').trim();
  if (tracksCrates && unit.toLowerCase() == 'bottle' && p.trackEmpties) {
    return 'Crate';
  }
  if (unit.isEmpty) return 'Unit';
  return unit[0].toUpperCase() + unit.substring(1);
}

String _clock(DateTime d) => DateFormat('h:mm a').format(d).toLowerCase();

/// "today, 7:42 am" / "yesterday, 6:15 pm" / "3 Nov, 7:42 am".
String _when(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(n.year, n.month, n.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'today, ${_clock(d)}';
  if (diff == 1) return 'yesterday, ${_clock(d)}';
  return '${DateFormat('d MMM').format(d)}, ${_clock(d)}';
}

EdgeInsets _pagePadding(BuildContext context) => EdgeInsets.fromLTRB(
  context.getRSize(16),
  context.getRSize(12),
  context.getRSize(16),
  context.getRSize(16),
);

// ── shell ───────────────────────────────────────────────────────────────────

/// The two-tab driver shell: a bottom bar on a phone, a side rail on a tablet.
/// [showNav] hides only the PHONE bottom bar (Checkout and Sale complete are
/// full-height steps); the rail stays, as in the tablet mockups.
class _DriverShell extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  final bool showNav;
  final Widget header;
  final Widget body;
  final Widget? bottom;

  const _DriverShell({
    required this.tab,
    required this.onTab,
    required this.header,
    required this.body,
    this.showNav = true,
    this.bottom,
  });

  static const _items = [
    FrameNavItem(tabIndex: 0, icon: AppIcons.cart, label: 'Sell'),
    FrameNavItem(tabIndex: 1, icon: AppIcons.vanDelivery, label: 'My Trip'),
  ];

  @override
  Widget build(BuildContext context) {
    final rail = context.isRailLayout;
    final content = Column(
      children: [
        header,
        Expanded(child: body),
        if (bottom != null) bottom!,
        if (!rail && showNav)
          FrameBottomBar(items: _items, currentIndex: tab, onTap: onTab),
      ],
    );
    return Container(
      decoration: AppDecorations.pageBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: rail
            ? Row(
                children: [
                  FrameNavRail(items: _items, currentIndex: tab, onTap: onTab),
                  Expanded(child: content),
                ],
              )
            : content,
      ),
    );
  }
}

/// Title + primary subtitle, an optional back/close button, and the sync chip.
/// The title and subtitle wrap inside their own column, so a long title can
/// never run into the line below it.
class _DriverHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData? leadingIcon;
  final String? leadingLabel;
  final VoidCallback? onLeading;
  final Widget? trailing;
  final Widget? chip;

  const _DriverHeader({
    required this.title,
    required this.subtitle,
    this.leadingIcon,
    this.leadingLabel,
    this.onLeading,
    this.trailing,
    this.chip,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        top + context.getRSize(8),
        context.getRSize(16),
        context.getRSize(10),
      ),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(bottom: BorderSide(color: t.dividerColor)),
      ),
      child: Row(
        children: [
          if (leadingIcon != null) ...[
            IconButton(
              tooltip: leadingLabel,
              onPressed: onLeading,
              icon: Icon(leadingIcon, size: context.getRSize(22)),
            ),
            SizedBox(width: context.getRSize(4)),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: t.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  subtitle,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: context.getRSize(12)),
            trailing!,
          ],
          if (chip != null) ...[
            SizedBox(width: context.getRSize(12)),
            Flexible(child: chip!),
          ],
        ],
      ),
    );
  }
}

/// "Offline · 3 waiting" — read from the real outbox
/// (`pendingQueueCountProvider`) and the sync service's online flag.
class _SyncChip extends ConsumerWidget {
  const _SyncChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingQueueCountProvider).valueOrNull ?? 0;
    final online = ref.watch(driverOnlineListenableProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: online,
      builder: (context, isOnline, _) {
        final label = driverSyncChipLabel(online: isOnline, pending: pending);
        if (label == null) return const SizedBox.shrink();
        final f =
            Theme.of(context).extension<AppFixedColors>() ??
            AppFixedColors.light;
        return Container(
          key: const ValueKey('van-sync-chip'),
          padding: EdgeInsets.symmetric(
            horizontal: context.getRSize(12),
            vertical: context.getRSize(8),
          ),
          decoration: BoxDecoration(
            color: f.warningTint,
            borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isOnline ? AppIcons.cloudSync : AppIcons.cloudOff,
                size: context.getRSize(16),
                color: f.warning,
              ),
              SizedBox(width: context.getRSize(6)),
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ActionBar extends StatelessWidget {
  final Widget child;

  /// True when no navigation bar sits below (it would otherwise own the inset).
  final bool showInset;

  const _ActionBar({required this.child, required this.showInset});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
        context.getRSize(12) + (showInset ? context.deviceBottomPadding : 0),
      ),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: child,
    );
  }
}

class _InfoCard extends StatelessWidget {
  final Widget child;
  const _InfoCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusL,
      ),
      child: child,
    );
  }
}

class _SearchBox extends StatelessWidget {
  final ValueChanged<String> onChanged;
  const _SearchBox({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('van-search'),
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: 'Search products on your van',
        prefixIcon: Icon(AppIcons.search, size: context.getRSize(20)),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        ),
      ),
    );
  }
}

class _OnVanPill extends StatelessWidget {
  final int count;
  const _OnVanPill({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(14),
        vertical: context.getRSize(14),
      ),
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusM,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            AppIcons.vanDelivery,
            size: context.getRSize(20),
            color: Theme.of(context).colorScheme.primary,
          ),
          SizedBox(width: context.getRSize(8)),
          Text(
            '$count on van',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

// ── product card ────────────────────────────────────────────────────────────

class _ProductCard extends StatelessWidget {
  final String productId;
  final String name;
  final String unitLabel;
  final int loadPriceKobo;
  final int onVan;
  final int units;
  final bool wide;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const _ProductCard({
    required this.productId,
    required this.name,
    required this.unitLabel,
    required this.loadPriceKobo,
    required this.onVan,
    required this.units,
    required this.wide,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final soldOut = onVan <= 0;
    final allIn = driverAllInSale(units: units, onVan: onVan);
    final subtext = t.textTheme.bodySmall;
    final muted = soldOut ? t.disabledColor : null;

    final tile = Container(
      width: context.getRSize(44),
      height: context.getRSize(44),
      decoration: BoxDecoration(
        color: soldOut ? f.neutralTile : f.infoTint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Icon(
        AppIcons.box,
        size: context.getRSize(22),
        color: soldOut ? f.neutralIcon : f.info,
      ),
    );

    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: t.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: muted,
          ),
        ),
        Text(
          '$unitLabel · Load ${formatCurrency(loadPriceKobo / 100)}',
          style: subtext,
        ),
        Text(
          soldOut ? 'None on van' : '$onVan on van',
          style: subtext?.copyWith(
            fontWeight: FontWeight.w700,
            color: soldOut ? null : t.colorScheme.onSurface,
          ),
        ),
      ],
    );

    final decoration = BoxDecoration(
      color: soldOut
          ? t.colorScheme.surface.withValues(alpha: 0.5)
          : t.colorScheme.surface,
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      border: Border.all(
        color: units > 0 ? t.colorScheme.primary : t.dividerColor,
        width: units > 0 ? 2 : 1,
      ),
    );

    if (wide) {
      return Container(
        padding: EdgeInsets.all(context.getRSize(14)),
        decoration: decoration,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                tile,
                const Spacer(),
                if (units > 0)
                  CircleAvatar(
                    radius: context.getRSize(13),
                    backgroundColor: t.colorScheme.primary,
                    child: Text(
                      '$units',
                      style: TextStyle(
                        color: t.colorScheme.onPrimary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: context.getRSize(8)),
            texts,
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: soldOut
                  ? _PillLabel(label: 'None left', fill: f.neutralTile)
                  : allIn
                  ? _PillLabel(
                      label: 'All $onVan are in this sale',
                      fill: f.warningTint,
                      icon: AppIcons.block,
                    )
                  : AppButton(
                      key: ValueKey('van-add-$productId'),
                      text: units > 0 ? 'Add One More' : 'Add',
                      icon: AppIcons.add,
                      variant: units > 0
                          ? AppButtonVariant.primary
                          : AppButtonVariant.secondary,
                      onPressed: onAdd,
                    ),
            ),
          ],
        ),
      );
    }

    final Widget trailing;
    if (soldOut) {
      trailing = _PillLabel(label: 'None left', fill: f.neutralTile);
    } else if (units == 0) {
      trailing = AppButton(
        key: ValueKey('van-add-$productId'),
        text: 'Add',
        icon: AppIcons.add,
        variant: AppButtonVariant.secondary,
        isFullWidth: false,
        onPressed: onAdd,
      );
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepButton(
            key: ValueKey('van-remove-$productId'),
            icon: AppIcons.minus,
            onTap: onRemove,
          ),
          SizedBox(
            width: context.getRSize(32),
            child: Text(
              '$units',
              textAlign: TextAlign.center,
              style: t.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          _StepButton(
            key: ValueKey('van-plus-$productId'),
            icon: allIn ? AppIcons.block : AppIcons.add,
            solid: !allIn,
            onTap: allIn ? null : onAdd,
          ),
        ],
      );
    }

    return Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: decoration,
      child: Column(
        children: [
          Row(
            children: [
              tile,
              SizedBox(width: context.getRSize(12)),
              Expanded(child: texts),
              SizedBox(width: context.getRSize(8)),
              trailing,
            ],
          ),
          if (allIn) ...[
            SizedBox(height: context.getRSize(10)),
            Container(
              key: ValueKey('van-all-in-$productId'),
              width: double.infinity,
              padding: EdgeInsets.all(context.getRSize(10)),
              decoration: BoxDecoration(
                color: f.warningTint,
                borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
              ),
              child: Row(
                children: [
                  Icon(
                    AppIcons.infoCircle,
                    size: context.getRSize(18),
                    color: f.warning,
                  ),
                  SizedBox(width: context.getRSize(8)),
                  Expanded(
                    child: Text(
                      'All $onVan on your van are in this sale.',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PillLabel extends StatelessWidget {
  final String label;
  final Color fill;
  final IconData? icon;
  const _PillLabel({required this.label, required this.fill, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(12),
        vertical: context.getRSize(12),
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: context.getRSize(16)),
            SizedBox(width: context.getRSize(6)),
          ],
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool solid;

  const _StepButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.solid = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final size = context.getRSize(44);
    final disabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
      child: Container(
        width: size < 44 ? 44 : size,
        height: size < 44 ? 44 : size,
        decoration: BoxDecoration(
          color: solid ? t.colorScheme.primary : null,
          borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
          border: disabled
              ? Border.all(color: t.dividerColor)
              : solid
              ? null
              : Border.all(color: t.dividerColor),
        ),
        child: Icon(
          icon,
          size: context.getRSize(20),
          color: solid ? t.colorScheme.onPrimary : t.iconTheme.color,
        ),
      ),
    );
  }
}

// ── tablet "This sale" panel ────────────────────────────────────────────────

class _SalePanel extends StatelessWidget {
  final List<_SaleLine> lines;
  final int itemCount;
  final int totalKobo;
  final ({int count, String? names}) empties;
  final void Function(String id, int onVan) onAdd;
  final void Function(String id, int onVan) onRemove;
  final VoidCallback onClear;
  final VoidCallback onCheckout;

  const _SalePanel({
    required this.lines,
    required this.itemCount,
    required this.totalKobo,
    required this.empties,
    required this.onAdd,
    required this.onRemove,
    required this.onClear,
    required this.onCheckout,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: context.getRSize(360),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: Border(left: BorderSide(color: t.dividerColor)),
      ),
      padding: EdgeInsets.all(context.getRSize(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(
                        text: 'This sale',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      TextSpan(
                        text: ' · $itemCount ${itemCount == 1 ? 'item' : 'items'}',
                        style: t.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  style: t.textTheme.titleMedium,
                ),
              ),
              if (lines.isNotEmpty)
                TextButton(onPressed: onClear, child: const Text('Clear')),
            ],
          ),
          const Divider(),
          Expanded(
            child: lines.isEmpty
                ? Center(
                    child: Text(
                      'Add products from your van.',
                      style: t.textTheme.bodySmall,
                    ),
                  )
                : ListView(
                    children: [
                      for (final l in lines)
                        _PanelLine(
                          line: l,
                          onAdd: () => onAdd(
                            l.row.product.id,
                            l.row.totalStock.floor(),
                          ),
                          onRemove: () => onRemove(
                            l.row.product.id,
                            l.row.totalStock.floor(),
                          ),
                        ),
                      if (empties.count > 0) ...[
                        SizedBox(height: context.getRSize(12)),
                        _CratesNote(empties: empties),
                      ],
                    ],
                  ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Total at load price',
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                formatCurrency(totalKobo / 100),
                key: const ValueKey('van-sell-total'),
                style: t.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: t.colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: context.getRSize(12)),
          AppButton(
            key: const ValueKey('van-checkout'),
            text: 'Checkout',
            trailingIcon: AppIcons.chevronRight,
            onPressed: totalKobo <= 0 ? null : onCheckout,
          ),
          SizedBox(height: context.deviceBottomPadding),
        ],
      ),
    );
  }
}

class _PanelLine extends StatelessWidget {
  final _SaleLine line;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const _PanelLine({
    required this.line,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final onVan = line.row.totalStock.floor();
    final allIn = driverAllInSale(units: line.units, onVan: onVan);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(6)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.row.product.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${formatCurrency(line.priceKobo / 100)} each · '
                  '${formatCurrency(line.priceKobo * line.units / 100)}',
                  style: t.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          _StepButton(icon: AppIcons.minus, onTap: onRemove),
          SizedBox(
            width: context.getRSize(30),
            child: Text(
              '${line.units}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          _StepButton(
            icon: allIn ? AppIcons.block : AppIcons.add,
            solid: !allIn,
            onTap: allIn ? null : onAdd,
          ),
        ],
      ),
    );
  }
}

// ── notes + banners ─────────────────────────────────────────────────────────

/// "Collect N empty crates": shown only when the business tracks crates and
/// the sale holds crate-tracked bottles. Built by [driverCrateEmpties].
class _CratesNote extends StatelessWidget {
  final ({int count, String? names}) empties;
  const _CratesNote({required this.empties});

  @override
  Widget build(BuildContext context) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    final n = empties.count;
    return Container(
      key: const ValueKey('van-crates-note'),
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: f.warningTint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.recycle, size: context.getRSize(24)),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Collect $n empty ${n == 1 ? 'crate' : 'crates'}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  '${empties.names}. Take one empty back for each full crate.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PaidBanner extends StatelessWidget {
  final int totalKobo;
  final int changeKobo;
  const _PaidBanner({required this.totalKobo, required this.changeKobo});

  @override
  Widget build(BuildContext context) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    return Container(
      key: const ValueKey('van-paid-banner'),
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: f.greenTint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
      ),
      child: Row(
        children: [
          Icon(AppIcons.checkCircle, color: f.green, size: context.getRSize(36)),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${formatCurrency(totalKobo / 100)} paid in cash',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text(
                  changeKobo > 0
                      ? 'Give change of ${formatCurrency(changeKobo / 100)}'
                      : 'No change to give',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CenterNote extends StatelessWidget {
  final String title;
  final String message;
  const _CenterNote({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(28)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: t.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              message,
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// A loaded van with nothing on the price list — the load landed with no
/// priced lines.
class _EmptyVan extends StatelessWidget {
  const _EmptyVan();

  @override
  Widget build(BuildContext context) => const _CenterNote(
    title: 'Nothing on the van',
    message: 'Ask a manager to restock you, or head back to reconcile.',
  );
}

// ── no open trip ────────────────────────────────────────────────────────────

/// A driver at the yard (spec §9.2 #6). Not an error: the normal state between
/// trips. Says so, with a Check Again button, the van they will load, and what
/// carries over from the last trip.
class _NoOpenTripShell extends ConsumerWidget {
  final int tab;
  final ValueChanged<int> onTab;
  final String driverName;

  const _NoOpenTripShell({
    required this.tab,
    required this.onTab,
    required this.driverName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final userId = ref.watch(currentUserIdProvider);
    final balanceKobo = userId == null
        ? 0
        : ref.watch(driverBalanceProvider(userId)).valueOrNull ?? 0;
    final trips = userId == null
        ? const <VanTripData>[]
        : ref.watch(driverTripsProvider(userId)).valueOrNull ??
              const <VanTripData>[];
    final stores =
        ref.watch(allStoresProvider).valueOrNull ?? const <StoreData>[];
    final last = trips.isEmpty ? null : trips.first;
    final van = _storeById(stores, last?.vanStoreId);
    final source = _storeById(stores, last?.sourceStoreId);
    final closedAt = last?.closedAt;
    final carriedKobo = balanceKobo < 0 ? -balanceKobo : 0;
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;

    Future<void> checkAgain() async {
      ref.invalidate(currentDriverTripProvider);
      try {
        await ref.read(currentDriverTripProvider.future);
      } catch (_) {
        // still no trip: the card stays as it is
      }
    }

    final card = _InfoCard(
      child: Column(
        children: [
          Container(
            width: context.getRSize(64),
            height: context.getRSize(64),
            decoration: BoxDecoration(
              color: f.infoTint,
              borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
            ),
            child: Icon(
              AppIcons.vanDelivery,
              size: context.getRSize(30),
              color: f.info,
            ),
          ),
          SizedBox(height: context.getRSize(12)),
          Text(
            'No open trip',
            textAlign: TextAlign.center,
            style: t.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: context.getRSize(8)),
          Text(
            "You can't sell yet. A manager needs to load your van and open a "
            'trip for you.',
            textAlign: TextAlign.center,
            style: t.textTheme.bodyMedium,
          ),
          SizedBox(height: context.getRSize(14)),
          AppButton(
            key: const ValueKey('van-check-again'),
            text: 'Check Again',
            icon: AppIcons.refresh,
            variant: AppButtonVariant.secondary,
            isFullWidth: false,
            onAsyncPressed: checkAgain,
          ),
        ],
      ),
    );

    final vanCard = _InfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'YOUR VAN',
            style: t.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: context.getRSize(10)),
          Row(
            children: [
              Icon(
                AppIcons.vanDelivery,
                color: t.colorScheme.primary,
                size: context.getRSize(22),
              ),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      van == null ? 'No van assigned yet' : _vanLabel(van),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    if (source != null)
                      Text(
                        'Loads from ${source.name}',
                        style: t.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
          Divider(height: context.getRSize(24)),
          Row(
            children: [
              Icon(AppIcons.cash, size: context.getRSize(22)),
              SizedBox(width: context.getRSize(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Carried from your last trip',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      "Added to your next trip's balance",
                      style: t.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Text(
                formatCurrency(carriedKobo / 100),
                style: t.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    final note = Container(
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: f.infoTint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.infoCircle, color: f.info, size: context.getRSize(20)),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Text(
              closedAt == null
                  ? 'Ask your manager if you think a trip should be open.'
                  : 'Last trip closed ${_when(closedAt)}. Ask your manager if '
                        'you think a trip should be open.',
            ),
          ),
        ],
      ),
    );

    return _DriverShell(
      tab: tab,
      onTab: onTab,
      header: _DriverHeader(
        title: tab == 0 ? 'Sell' : 'My Trip',
        subtitle: '$driverName · Driver',
        chip: const _SyncChip(),
      ),
      body: ListView(
        padding: _pagePadding(context),
        children: [
          card,
          SizedBox(height: context.getRSize(14)),
          vanCard,
          SizedBox(height: context.getRSize(14)),
          note,
        ],
      ),
    );
  }
}
