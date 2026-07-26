import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

import 'package:reebaplus_pos/core/database/app_database.dart';
import 'package:reebaplus_pos/core/permissions/gate_registry.dart';
import 'package:reebaplus_pos/core/permissions/guarded.dart';
import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/providers/stream_providers.dart';
import 'package:reebaplus_pos/core/services/crash_reporter.dart';
import 'package:reebaplus_pos/core/theme/app_decorations.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/theme/semantic_colors.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/number_format.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/features/van_sales/screens/driver_run_screen.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';

/// The **driver terminal** (#142, PRD #139 / ADR 0019, van-sales spec §9.2).
///
/// A driver's whole app. Not a mode of the shop POS — a screen of its own,
/// which is what makes the strip credible: there is no store picker, no
/// customer, no credit, no discount and no crate surface to hide, because none
/// of them was ever built here. A driver also cannot reach Load Van, the
/// reconcile screen or Record Payment, for the same structural reason plus
/// `Gates.vanManage`, which they do not hold (spec §9.5 #21).
///
/// What it does:
///  * scopes itself to the trip the driver is out on (`currentDriverTripProvider`
///    — one open trip per driver, enforced by a cloud partial-unique index), and
///    to the van that trip named;
///  * prices every line at the **load price** the manager and driver agreed at
///    the tailgate (`van_trip_lots.load_price_kobo`), never the catalogue tier
///    (spec §5.1 — the load price is the single valuation the whole
///    reconciliation uses, so selling off any other number would make sold value
///    and loaded value incomparable);
///  * rings the sale as an ordinary cash walk-in order on the van store, which
///    writes **no payment row** and books **no per-sale COGS**
///    (`OrdersDao.createOrder` enforces both from the store, not from this
///    screen — see [VanSaleContext]);
///  * prints/shares a receipt exactly as the shop till does.
///
/// **A sale does not touch the driver's balance.** The balance is
/// `loaded − returned − paid`; a sale moves goods into cash the driver is
/// already accountable for, so booking it would double-count the debt.
///
/// **No open trip ⇒ no selling** (spec §9.2 #6). That is not an error state, it
/// is the normal state of a driver at the yard, and it says so.
class DriverTerminalScreen extends ConsumerStatefulWidget {
  const DriverTerminalScreen({super.key});

  @override
  ConsumerState<DriverTerminalScreen> createState() =>
      _DriverTerminalScreenState();
}

class _DriverTerminalScreenState extends ConsumerState<DriverTerminalScreen> {
  /// productId → units in the current sale. A plain map, deliberately: the shop
  /// `CartService` carries customers, discounts, custom prices, saved carts and
  /// crate lines — every one of which is out of scope on the road, and any of
  /// which could be re-enabled by accident if the terminal shared it.
  final Map<String, int> _units = {};

  final ScreenshotController _shot = ScreenshotController();

  /// Set once a sale is rung — flips this screen to its receipt.
  _RoadSale? _lastSale;

  bool _ringing = false;
  bool _printing = false;

  @override
  Widget build(BuildContext context) {
    return Guarded.screen(
      gate: Gates.vanSell,
      builder: (context) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final trip = ref.watch(currentDriverTripProvider).valueOrNull;
    if (trip == null) return const _NoOpenTrip();

    if (_lastSale != null) {
      return _ReceiptView(
        sale: _lastSale!,
        shot: _shot,
        printing: _printing,
        onPrint: () => _print(_lastSale!),
        onShare: () => _share(_lastSale!),
        onDone: () => setState(() => _lastSale = null),
      );
    }

    final prices = ref.watch(vanTripLoadPricesProvider(trip.id)).valueOrNull
        ?? const <String, int>{};
    final stock = ref.watch(productsWithStockProvider(trip.vanStoreId))
        .valueOrNull ?? const <ProductDataWithStock>[];
    // Only what was actually loaded is sellable: a product with van stock but no
    // lot has no agreed road price, and inventing one (from the catalogue) is
    // exactly the mistake spec §5.1 rules out.
    final sellable = [
      for (final s in stock)
        if (prices.containsKey(s.product.id) && s.totalStock > 0) s,
    ]..sort((a, b) => a.product.name.compareTo(b.product.name));

    final totalKobo = _units.entries.fold<int>(
      0,
      (sum, e) => sum + (prices[e.key] ?? 0) * e.value,
    );

    return Container(
      decoration: AppDecorations.glassyBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          automaticallyImplyLeading: false,
          title: const Text(
            'Van Sales',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            IconButton(
              tooltip: 'My run',
              icon: Icon(
                FontAwesomeIcons.receipt.data,
                size: context.getRSize(16),
              ),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => DriverRunScreen(tripId: trip.id),
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              const _SwapOnlyBanner(),
              Expanded(
                child: sellable.isEmpty
                    ? const _EmptyVan()
                    : ListView.separated(
                        padding: EdgeInsets.fromLTRB(
                          context.getRSize(16),
                          context.getRSize(8),
                          context.getRSize(16),
                          context.getRSize(16),
                        ),
                        itemCount: sellable.length,
                        separatorBuilder: (_, _) =>
                            SizedBox(height: context.getRSize(10)),
                        itemBuilder: (_, i) {
                          final row = sellable[i];
                          final id = row.product.id;
                          return _StockLine(
                            name: row.product.name,
                            onVan: row.totalStock,
                            loadPriceKobo: prices[id] ?? 0,
                            units: _units[id] ?? 0,
                            onAdd: () => _bump(id, 1, row.totalStock),
                            onRemove: () => _bump(id, -1, row.totalStock),
                          );
                        },
                      ),
              ),
              _TakePaymentBar(
                totalKobo: totalKobo,
                busy: _ringing,
                onTake: totalKobo <= 0 || _ringing
                    ? null
                    : () => _ring(trip, prices, sellable),
              ),
            ],
          ),
        ),
      ),
    );
  }

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

  Future<void> _ring(
    VanTripData trip,
    Map<String, int> prices,
    List<ProductDataWithStock> sellable,
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
            // The LOAD price, not the catalogue tier. No `catalogPriceKobo` is
            // recorded: a road price is not a concession off a shop price, it is
            // the price the driver signed for (spec §5.1 / §9.2 #9 — anything
            // the driver charges above it is off-book by design in v1).
            'unitPriceKobo': prices[entry.key] ?? 0,
            // #146: the receipt surfaces (`ReceiptWidget` and the thermal
            // builder) both read `price`, in NAIRA. Without it the on-screen
            // receipt printed every line at zero and the thermal builder threw
            // on a null cast — a road sale could not be printed at all.
            'price': (prices[entry.key] ?? 0) / 100.0,
          },
      ];
      final totalKobo = cart.fold<int>(
        0,
        (sum, l) => sum + (l['unitPriceKobo'] as int) * (l['qty'] as int),
      );

      final orderNumber = await ref
          .read(orderServiceProvider)
          .addOrder(
            // Walk-in ONLY on the road: no registered customer, so no wallet,
            // no credit and no crate balance can be accrued (spec §16).
            customerId: null,
            cart: cart,
            totalAmountKobo: totalKobo,
            // Cash in full. A road sale is settled on the spot or it is not a
            // road sale — there is no credit surface here to make it otherwise.
            amountPaidKobo: totalKobo,
            paymentType: 'Cash',
            staffId: ref.read(authProvider).currentUser?.id,
            // The VAN. This is the single fact `createOrder` keys its whole van
            // behaviour on: no payment row, no per-sale COGS, and the trip tag.
            storeId: trip.vanStoreId,
            paymentSubType: 'cash',
          );

      if (!mounted) return;
      final sale = _RoadSale(
        orderNumber: orderNumber,
        cart: cart,
        totalKobo: totalKobo,
      );
      setState(() {
        _units.clear();
        _lastSale = sale;
      });
      // Auto-print, exactly as the shop till does at Confirm Payment.
      unawaited(_print(sale));
    } catch (e, st) {
      CrashReporter.record(e, st, context: 'van.terminal.ring');
      if (mounted) {
        AppNotification.showError(context, 'Sale failed: $e');
      }
    } finally {
      if (mounted) setState(() => _ringing = false);
    }
  }

  Future<void> _print(_RoadSale sale) async {
    if (!mounted) return;
    setState(() => _printing = true);
    try {
      final printer = ref.read(printerServiceProvider);
      final granted = await printer.requestPermissions();
      if (!mounted) return;
      if (!granted) {
        AppNotification.showError(context, 'Bluetooth permissions denied');
        return;
      }
      final paperSize = await printer.getPaperSize();
      final bytes = await ThermalReceiptService.buildReceipt(
        orderId: sale.orderNumber,
        cart: sale.cart,
        subtotal: sale.totalKobo / 100.0,
        // No deposit on the road — swap-only (spec §11).
        crateDeposit: 0,
        total: sale.totalKobo / 100.0,
        paymentMethod: 'Cash',
        cashReceived: sale.totalKobo / 100.0,
        showWalletInfo: false,
        riderName: 'Van Sale',
        businessName: ref.read(currentBusinessNameProvider),
        paperSize: paperSize,
      );
      if (!mounted) return;
      final printed = await printer.printBytes(bytes);
      if (!mounted) return;
      if (printed) {
        AppNotification.showSuccess(context, 'Print successful');
        return;
      }
      _showPrinterPicker(printer, bytes);
    } catch (e) {
      if (mounted) AppNotification.showError(context, 'Print error: $e');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  /// The manual fallback when auto-connect could not find the printer — the
  /// same sheet the shop till falls back to.
  void _showPrinterPicker(dynamic printer, List<int> receiptBytes) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppSpacing.borderRadiusL),
        ),
      ),
      builder: (_) => PrinterPicker(
        onSelected: (device) async {
          if (!mounted) return;
          Navigator.pop(context);
          if (!mounted) return;
          setState(() => _printing = true);
          try {
            final connected = await printer.connect(device.macAdress);
            if (!mounted) return;
            if (connected) {
              await printer.saveLastConnectedMac(device.macAdress);
              await printer.printBytesDirectly(receiptBytes);
              if (!mounted) return;
              AppNotification.showSuccess(context, 'Print successful');
            } else {
              AppNotification.showError(context, 'Could not connect');
            }
          } catch (e) {
            if (mounted) AppNotification.showError(context, 'Print error: $e');
          } finally {
            if (mounted) setState(() => _printing = false);
          }
        },
      ),
    );
  }

  Future<void> _share(_RoadSale sale) async {
    try {
      final image = await _shot.capture(pixelRatio: 3.0);
      if (image == null) return;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/receipt_${sale.orderNumber}.png');
      await file.writeAsBytes(image);
      await Share.shareXFiles([
        XFile(file.path),
      ], text: 'Reebaplus POS Receipt');
    } catch (e) {
      if (mounted) AppNotification.showError(context, 'Share failed: $e');
    }
  }
}

/// One rung road sale, snapshotted so the receipt survives the cart clearing.
class _RoadSale {
  final String orderNumber;
  final List<Map<String, dynamic>> cart;
  final int totalKobo;

  const _RoadSale({
    required this.orderNumber,
    required this.cart,
    required this.totalKobo,
  });
}

/// The operating rule, stated where the driver sells (spec §11).
///
/// v1 tracks empty crates as **memo counts only** — no deposit money moves on
/// the road. Saying so on the terminal is what stops a driver inventing a
/// deposit transaction the books cannot represent.
class _SwapOnlyBanner extends StatelessWidget {
  const _SwapOnlyBanner();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    return Container(
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(
        context.getRSize(16),
        0,
        context.getRSize(16),
        context.getRSize(8),
      ),
      padding: EdgeInsets.all(context.getRSize(12)),
      decoration: BoxDecoration(
        color: semantic.info.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        border: Border.all(color: t.dividerColor),
      ),
      child: Row(
        children: [
          Icon(
            FontAwesomeIcons.rotate.data,
            size: context.getRSize(14),
            color: semantic.info,
          ),
          SizedBox(width: context.getRSize(10)),
          Expanded(
            child: Text(
              'Swap-only — no deposit sales on the road. '
              'Take an empty crate for every full one.',
              style: t.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One sellable line: what is on the van, at the price it was loaded at.
class _StockLine extends StatelessWidget {
  final String name;
  final int onVan;
  final int loadPriceKobo;
  final int units;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const _StockLine({
    required this.name,
    required this.onVan,
    required this.loadPriceKobo,
    required this.units,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Container(
      padding: EdgeInsets.all(context.getRSize(14)),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusM),
        border: Border.all(
          color: units > 0 ? t.colorScheme.primary : t.dividerColor,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: t.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: context.getRSize(2)),
                Text(
                  '${formatCurrency(loadPriceKobo / 100)} • $onVan on the van',
                  style: t.textTheme.bodySmall?.copyWith(color: subtext),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: units > 0 ? onRemove : null,
            icon: Icon(
              FontAwesomeIcons.circleMinus.data,
              size: context.getRSize(18),
            ),
          ),
          SizedBox(
            width: context.getRSize(28),
            child: Text(
              '$units',
              textAlign: TextAlign.center,
              style: t.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          IconButton(
            onPressed: units < onVan ? onAdd : null,
            icon: Icon(
              FontAwesomeIcons.circlePlus.data,
              size: context.getRSize(18),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one action on this screen. Cash, in full, walk-in — no other tender is
/// representable, which is the point.
class _TakePaymentBar extends StatelessWidget {
  final int totalKobo;
  final bool busy;
  final VoidCallback? onTake;

  const _TakePaymentBar({
    required this.totalKobo,
    required this.busy,
    required this.onTake,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.getRSize(16),
        context.getRSize(12),
        context.getRSize(16),
        context.getRSize(12) + context.deviceBottomPadding,
      ),
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.92),
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Total',
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.textTheme.bodySmall?.color,
                  ),
                ),
                Text(
                  formatCurrency(totalKobo / 100),
                  style: t.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: context.getRSize(12)),
          FilledButton.icon(
            onPressed: onTake,
            icon: busy
                ? SizedBox(
                    width: context.getRSize(14),
                    height: context.getRSize(14),
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    FontAwesomeIcons.moneyBill1.data,
                    size: context.getRSize(14),
                  ),
            label: const Text('Take cash'),
          ),
        ],
      ),
    );
  }
}

/// The receipt, and the three things a driver can do with it.
class _ReceiptView extends StatelessWidget {
  final _RoadSale sale;
  final ScreenshotController shot;
  final bool printing;
  final VoidCallback onPrint;
  final VoidCallback onShare;
  final VoidCallback onDone;

  const _ReceiptView({
    required this.sale,
    required this.shot,
    required this.printing,
    required this.onPrint,
    required this.onShare,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      decoration: AppDecorations.glassyBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          automaticallyImplyLeading: false,
          title: const Text(
            'Sale complete',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            context.getRSize(16),
            context.getRSize(8),
            context.getRSize(16),
            context.getRSize(16) + context.deviceBottomPadding,
          ),
          children: [
            if (printing)
              Padding(
                padding: EdgeInsets.only(bottom: context.getRSize(12)),
                child: Text(
                  'Printing receipt…',
                  style: t.textTheme.bodySmall?.copyWith(
                    color: t.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            Screenshot(
              controller: shot,
              child: ReceiptWidget(
                orderId: sale.orderNumber,
                cart: sale.cart,
                subtotal: sale.totalKobo / 100.0,
                crateDeposit: 0,
                total: sale.totalKobo / 100.0,
                paymentMethod: 'Cash',
                cashReceived: sale.totalKobo / 100.0,
                riderName: 'Van Sale',
              ),
            ),
            SizedBox(height: context.getRSize(16)),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onPrint,
                    icon: Icon(
                      FontAwesomeIcons.print.data,
                      size: context.getRSize(14),
                    ),
                    label: const Text('Print'),
                  ),
                ),
                SizedBox(width: context.getRSize(12)),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onShare,
                    icon: Icon(
                      FontAwesomeIcons.shareNodes.data,
                      size: context.getRSize(14),
                    ),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
            SizedBox(height: context.getRSize(12)),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onDone,
                child: const Text('Next sale'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A driver at the yard (spec §9.2 #6). Not an error — the normal state between
/// runs — but selling is impossible until a manager loads the van, because
/// there is no trip to attribute the sale to and no agreed price to sell at.
class _NoOpenTrip extends ConsumerWidget {
  const _NoOpenTrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    final userId = ref.watch(currentUserIdProvider);
    final balanceKobo = userId == null
        ? 0
        : ref.watch(driverBalanceProvider(userId)).valueOrNull ?? 0;

    return Container(
      decoration: AppDecorations.glassyBackground(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          automaticallyImplyLeading: false,
          title: const Text(
            'Van Sales',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(context.getRSize(28)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  FontAwesomeIcons.truck.data,
                  size: context.getRSize(44),
                  color: subtext,
                ),
                SizedBox(height: context.getRSize(16)),
                Text(
                  'No open trip',
                  style: t.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: context.getRSize(8)),
                Text(
                  'Your van has not been loaded yet. Ask a manager to load it, '
                  'then pull down or reopen the app to start selling.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall?.copyWith(color: subtext),
                ),
                SizedBox(height: context.getRSize(20)),
                _BalancePill(balanceKobo: balanceKobo),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A loaded van with nothing sellable on it — every lot sold out, or the load
/// landed with zero quantities.
class _EmptyVan extends StatelessWidget {
  const _EmptyVan();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final subtext = t.textTheme.bodySmall?.color ?? t.iconTheme.color!;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.getRSize(28)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FontAwesomeIcons.boxOpen.data,
              size: context.getRSize(40),
              color: subtext,
            ),
            SizedBox(height: context.getRSize(12)),
            Text(
              'Nothing left on the van',
              style: t.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.getRSize(6)),
            Text(
              'Ask a manager to restock you, or head back to reconcile.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall?.copyWith(color: subtext),
            ),
          ],
        ),
      ),
    );
  }
}

/// The driver's cross-trip balance, in shop-owner words. Negative = they owe.
class BalancePill extends StatelessWidget {
  final int balanceKobo;

  const BalancePill({super.key, required this.balanceKobo});

  @override
  Widget build(BuildContext context) => _BalancePill(balanceKobo: balanceKobo);
}

class _BalancePill extends StatelessWidget {
  final int balanceKobo;

  const _BalancePill({required this.balanceKobo});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final semantic = t.extension<AppSemanticColors>()!;
    final owes = balanceKobo < 0;
    final color = owes
        ? t.colorScheme.error
        : balanceKobo == 0
        ? semantic.success
        : semantic.info;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.getRSize(16),
        vertical: context.getRSize(10),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.borderRadiusL),
        border: Border.all(color: t.dividerColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            owes
                ? 'You owe'
                : balanceKobo == 0
                ? 'Settled'
                : 'In credit',
            style: t.textTheme.bodySmall?.copyWith(
              color: t.textTheme.bodySmall?.color,
            ),
          ),
          SizedBox(height: context.getRSize(4)),
          Text(
            formatCurrency((owes ? -balanceKobo : balanceKobo) / 100),
            style: t.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
