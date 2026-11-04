import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/app_icons.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/fixed_colors.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/van_sales/driver_terminal_data.dart';
import 'package:reebaplus_pos/shared/models/order_status.dart';

/// **My Trip** (#142, restyled #729): the driver's **read-only** view of their
/// own trip, shown as the second tab of the driver shell.
///
/// Read-only is the whole design: a driver has no surface here to load a van,
/// record a payment against themselves or reconcile, and `Gates.vanManage`
/// (which they do not hold) backs that up at every write boundary.
///
///  * **You owe** is the driver's cross-trip ledger balance
///    (`loaded − returned − paid`). Selling does not change it; it goes down
///    only when a manager records cash or goods brought back.
///  * **Collected** is `soldValue`: road takings at load price. It is NOT cash
///    the business holds (a road sale writes no payment row, ADR 0019).
///  * **Waiting / Sent** per sale comes from the real outbox
///    ([driverTripSaleStatesProvider]).
class DriverRunScreen extends ConsumerWidget {
  final String tripId;

  const DriverRunScreen({super.key, required this.tripId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Body guard (hard rule #6): a live revocation while this screen is open
    // must empty it, not just hide the way in.
    if (!Gates.vanSell.allows(ref)) {
      return const Material(
        type: MaterialType.transparency,
        child: _Empty(
          icon: AppIcons.lock,
          title: 'No access',
          message: 'You no longer have access to van sales.',
        ),
      );
    }

    final trip = ref.watch(vanTripProvider(tripId)).valueOrNull;
    final driverId = trip?.driverUserId;
    final balanceKobo = driverId == null
        ? 0
        : ref.watch(driverBalanceProvider(driverId)).valueOrNull ?? 0;
    final history = driverId == null
        ? const <DriverLedgerEntryData>[]
        : ref.watch(driverLedgerHistoryProvider(driverId)).valueOrNull ??
              const <DriverLedgerEntryData>[];
    final lots =
        ref.watch(vanTripLotsProvider(tripId)).valueOrNull ??
        const <VanTripLotData>[];
    final soldKobo =
        ref.watch(vanTripSoldValueProvider(tripId)).valueOrNull ?? 0;
    final withItems = driverId == null
        ? const <OrderWithItems>[]
        : ref.watch(driverVanSalesProvider(driverId)).valueOrNull ??
              const <OrderWithItems>[];
    final states =
        ref.watch(driverTripSaleStatesProvider(tripId)).valueOrNull ??
        const <String, SaleEnvelopeState>{};
    final pending =
        ref.watch(vanTripPendingSalesProvider(tripId)).valueOrNull ?? 0;
    final prices =
        ref.watch(vanTripLoadPricesProvider(tripId)).valueOrNull ??
        const <String, int>{};
    final stock = trip == null
        ? const <ProductDataWithStock>[]
        : ref.watch(productsWithStockProvider(trip.vanStoreId)).valueOrNull ??
              const <ProductDataWithStock>[];
    final tracksCrates = businessTracksCrates(
      ref.watch(currentBusinessProvider),
    );

    final sales = [
      for (final o in withItems)
        if (o.order.vanTripId == tripId) o,
    ];
    final recognised = sales
        .where((o) => orderCountsAsSale(o.order.status))
        .length;
    final figures = driverTripFigures(
      tripId: tripId,
      driverHistory: history,
      lots: lots,
    );
    final onVan = [
      for (final s in stock)
        if (prices.containsKey(s.product.id)) s,
    ]..sort(
        (a, b) => a.product.name.toLowerCase().compareTo(
          b.product.name.toLowerCase(),
        ),
      );

    final opened = trip?.openedAt;
    final today = opened != null && _sameDay(opened, DateTime.now());

    final oweCard = _Card(
      child: _OweCard(
        balanceKobo: balanceKobo,
        figures: figures,
        loadedLabel: today ? 'Loaded today' : 'Loaded this trip',
      ),
    );
    final banner = pending > 0 ? _WaitingBanner(count: pending) : null;
    final soldSection = _SoldSection(
      salesCount: recognised,
      collectedKobo: soldKobo,
      sales: sales,
      states: states,
      tripId: tripId,
    );
    final vanSection = _VanSection(rows: onVan, tracksCrates: tracksCrates);

    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 900;
          final pad = EdgeInsets.fromLTRB(
            context.getRSize(16),
            context.getRSize(14),
            context.getRSize(16),
            context.getRSize(16) + context.deviceBottomPadding,
          );
          if (wide) {
            return SingleChildScrollView(
              padding: pad,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        oweCard,
                        if (banner != null) ...[
                          SizedBox(height: context.getRSize(14)),
                          banner,
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: context.getRSize(16)),
                  Expanded(child: soldSection),
                  SizedBox(width: context.getRSize(16)),
                  Expanded(child: vanSection),
                ],
              ),
            );
          }
          return ListView(
            padding: pad,
            children: [
              oweCard,
              if (banner != null) ...[
                SizedBox(height: context.getRSize(14)),
                banner,
              ],
              SizedBox(height: context.getRSize(18)),
              soldSection,
              SizedBox(height: context.getRSize(18)),
              vanSection,
            ],
          );
        },
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _signed(int kobo, String sign) =>
    '$sign${formatCurrency(kobo.abs() / 100)}';

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(context.getRSize(16)),
    decoration: AppDecorations.card(context, radius: AppSpacing.borderRadiusL),
    child: child,
  );
}

class _OweCard extends StatelessWidget {
  final int balanceKobo;
  final DriverTripFigures figures;
  final String loadedLabel;

  const _OweCard({
    required this.balanceKobo,
    required this.figures,
    required this.loadedLabel,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final credit = balanceKobo > 0;
    final loads = figures.loadCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(credit ? 'In credit' : 'You owe', style: t.textTheme.bodyMedium),
        Text(
          formatCurrency((credit ? balanceKobo : -balanceKobo) / 100),
          key: const ValueKey('van-owe-amount'),
          style: t.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: t.colorScheme.primary,
          ),
        ),
        SizedBox(height: context.getRSize(8)),
        _FigureRow(
          label: loadedLabel,
          hint: loads > 0 ? '($loads ${loads == 1 ? 'load' : 'loads'})' : null,
          value: formatCurrency(figures.loadedKobo / 100),
        ),
        _FigureRow(
          label: 'Carried from last trip',
          value: figures.carriedKobo >= 0
              ? _signed(figures.carriedKobo, '+')
              : _signed(figures.carriedKobo, '-'),
        ),
        _FigureRow(
          label: 'Goods returned',
          value: _signed(figures.returnedKobo, '-'),
        ),
        _FigureRow(
          label: "Cash you've handed in",
          value: _signed(figures.handedInKobo, '-'),
        ),
        SizedBox(height: context.getRSize(10)),
        Text(
          "Selling doesn't change this figure. It goes down when a manager "
          'records cash you hand in or goods you bring back.',
          style: t.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _FigureRow extends StatelessWidget {
  final String label;
  final String? hint;
  final String value;
  const _FigureRow({required this.label, this.hint, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(10)),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: label),
                  if (hint != null)
                    TextSpan(text: ' $hint', style: t.textTheme.bodySmall),
                ],
              ),
            ),
          ),
          SizedBox(width: context.getRSize(8)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _WaitingBanner extends StatelessWidget {
  final int count;
  const _WaitingBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    final f =
        Theme.of(context).extension<AppFixedColors>() ?? AppFixedColors.light;
    return Container(
      key: const ValueKey('van-waiting-banner'),
      width: double.infinity,
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: f.warningTint,
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusXL),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.cloudOff, size: context.getRSize(26)),
          SizedBox(width: context.getRSize(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count ${count == 1 ? 'sale' : 'sales'} waiting to send',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const Text(
                  "They're saved safely on this device and will send by "
                  'themselves when you have signal.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SoldSection extends StatelessWidget {
  final int salesCount;
  final int collectedKobo;
  final List<OrderWithItems> sales;
  final Map<String, SaleEnvelopeState> states;
  final String tripId;

  const _SoldSection({
    required this.salesCount,
    required this.collectedKobo,
    required this.sales,
    required this.states,
    required this.tripId,
  });

  static const _shown = 4;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final head = Text(
      'Sold this trip',
      style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        head,
        SizedBox(height: context.getRSize(10)),
        Row(
          children: [
            Expanded(
              child: _StatBox(label: 'Sales', value: '$salesCount'),
            ),
            SizedBox(width: context.getRSize(10)),
            Expanded(
              flex: 2,
              child: _StatBox(
                label: 'Collected',
                value: formatCurrency(collectedKobo / 100),
              ),
            ),
          ],
        ),
        SizedBox(height: context.getRSize(12)),
        if (sales.isEmpty)
          const _Empty(
            icon: AppIcons.receipt,
            title: 'No sales yet',
            message: 'Every sale you ring on this trip will show here.',
          )
        else
          _Card(
            child: Column(
              children: [
                for (final s in sales.take(_shown))
                  _SaleRow(sale: s, state: states[s.order.id]),
                if (sales.length > _shown)
                  TextButton(
                    key: const ValueKey('van-see-all'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _AllSalesScreen(
                          sales: sales,
                          states: states,
                        ),
                      ),
                    ),
                    child: Text('See all ${sales.length} sales  ›'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  const _StatBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: AppDecorations.card(
        context,
        radius: AppSpacing.borderRadiusL,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.textTheme.bodySmall),
          Text(
            value,
            style: t.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SaleRow extends StatelessWidget {
  final OrderWithItems sale;
  final SaleEnvelopeState? state;

  const _SaleRow({required this.sale, required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    final order = sale.order;
    final reversed = !orderCountsAsSale(order.status);
    final items = sale.items.fold<int>(
      0,
      (a, i) => a + i.item.quantity.round(),
    );
    final waiting = state == SaleEnvelopeState.pending;
    return Container(
      padding: EdgeInsets.symmetric(vertical: context.getRSize(10)),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${order.orderNumber} · $items ${items == 1 ? 'item' : 'items'}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    decoration: reversed ? TextDecoration.lineThrough : null,
                  ),
                ),
                Text(
                  reversed
                      ? '${_time(order.createdAt)} · cancelled'
                      : _time(order.createdAt),
                  style: t.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatCurrency(order.netAmountKobo / 100),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: reversed ? t.disabledColor : null,
                ),
              ),
              if (!reversed && state != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      waiting ? AppIcons.lockClock : AppIcons.cloudSync,
                      size: context.getRSize(14),
                      color: waiting ? null : f.green,
                    ),
                    SizedBox(width: context.getRSize(4)),
                    Text(
                      waiting ? 'Waiting' : 'Sent',
                      key: ValueKey(
                        'van-sale-${waiting ? 'waiting' : 'sent'}-'
                        '${order.orderNumber}',
                      ),
                      style: t.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: waiting ? null : f.green,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _time(DateTime d) => DateFormat('h:mm a').format(d).toLowerCase();
}

class _AllSalesScreen extends StatelessWidget {
  final List<OrderWithItems> sales;
  final Map<String, SaleEnvelopeState> states;
  const _AllSalesScreen({required this.sales, required this.states});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sales this trip')),
      body: ListView(
        padding: EdgeInsets.all(context.getRSize(16)),
        children: [
          for (final s in sales) _SaleRow(sale: s, state: states[s.order.id]),
        ],
      ),
    );
  }
}

class _VanSection extends StatelessWidget {
  final List<ProductDataWithStock> rows;
  final bool tracksCrates;
  const _VanSection({required this.rows, required this.tracksCrates});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = t.extension<AppFixedColors>() ?? AppFixedColors.light;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Left on your van',
          style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        SizedBox(height: context.getRSize(10)),
        _Card(
          child: rows.isEmpty
              ? Text('Nothing on the van.', style: t.textTheme.bodySmall)
              : Column(
                  children: [
                    for (final r in rows)
                      Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: context.getRSize(8),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                r.product.name,
                                style: TextStyle(
                                  color: r.totalStock.floor() <= 0
                                      ? t.disabledColor
                                      : null,
                                ),
                              ),
                            ),
                            Text(
                              r.totalStock.floor() <= 0
                                  ? 'None'
                                  : '${r.totalStock.floor()}',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: r.totalStock.floor() <= 0
                                    ? t.disabledColor
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        if (tracksCrates) ...[
          SizedBox(height: context.getRSize(12)),
          Container(
            key: const ValueKey('van-bring-back-note'),
            width: double.infinity,
            padding: EdgeInsets.all(context.getRSize(14)),
            decoration: BoxDecoration(
              color: f.infoTint,
              borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(AppIcons.recycle, color: f.info),
                SizedBox(width: context.getRSize(10)),
                const Expanded(
                  child: Text(
                    'Bring back an empty crate for every full crate you sold. '
                    'Your manager counts them when you return.',
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String message;

  const _Empty({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Padding(
      padding: EdgeInsets.all(context.getRSize(28)),
      child: Column(
        children: [
          Icon(icon, size: context.getRSize(36), color: subtext),
          SizedBox(height: context.getRSize(12)),
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
            style: t.textTheme.bodySmall?.copyWith(color: subtext),
          ),
        ],
      ),
    );
  }
}
