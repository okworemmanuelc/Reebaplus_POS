import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

import 'package:reebaplus_pos/core/providers/app_providers.dart';
import 'package:reebaplus_pos/core/theme/design_tokens.dart';
import 'package:reebaplus_pos/core/utils/notifications.dart';
import 'package:reebaplus_pos/core/utils/responsive.dart';
import 'package:reebaplus_pos/features/pos/services/receipt_builder.dart';
import 'package:reebaplus_pos/shared/services/printer_service.dart';
import 'package:reebaplus_pos/shared/widgets/printer_picker.dart';
import 'package:reebaplus_pos/shared/widgets/receipt_widget.dart';

/// One road sale's receipt, and the two things anybody can do with it: print it
/// to the driver's thermal printer, or share it as an image (#208 item 1, PRD
/// #139 / ADR 0019, van-sales spec §9.2).
///
/// This is the **only** print/share plumbing on the van surface. It used to sit
/// inline in the driver terminal, which is why the driver profile's Sales tab
/// (#146) could re-open a road receipt but not hand a customer a copy of it —
/// a manager answering "the driver says he never gave me a receipt" had the
/// document on screen and no way to produce it. Lifting it here is what makes
/// the same receipt printable from the till and from the audit surface without
/// two copies of the ESC/POS call drifting apart.
///
/// The van receipt is fixed in three ways, and they are the reason this widget
/// takes so few arguments:
///
///  * **Cash, in full** — the road has no other tender (spec §9.2), so the
///    payment method and the cash-received line are not caller decisions;
///  * **No crate deposit** — the road is swap-only in v1 (spec §11), so
///    printing a deposit line would invent money that never moved;
///  * **"Van Sale" as the rider** — a road sale has no registered customer and
///    no delivery to name (spec §16).
///
/// Renders as a `Column`, not a page: both callers already own their scroll
/// view and their own trailing action ("Next sale" on the terminal, "Done" on
/// the sheet), and only the receipt plus its two buttons is shared.
class VanReceiptView extends ConsumerStatefulWidget {
  /// The human order number (`ORD-…`), printed as the receipt's reference.
  final String orderNumber;

  /// Receipt lines in the shape every receipt surface in the app reads:
  /// `name`, `qty` and `price` **in naira**.
  final List<Map<String, dynamic>> cart;

  /// The sale total. Subtotal and total are the same figure on the road —
  /// there is no discount surface and no deposit.
  final int totalKobo;

  /// What the customer handed over. Equal to [totalKobo] on a fresh sale; read
  /// off the order when an old one is re-opened.
  final int cashReceivedKobo;

  /// The order's status, when it has one worth printing (a cancelled sale
  /// re-opened from the profile). Null on a sale rung a second ago.
  final String? orderStatus;

  /// Print the moment the receipt appears, the way the shop till does at
  /// Confirm Payment. Only the terminal wants this.
  final bool autoPrint;

  /// True when this surface RE-OPENS an already-issued receipt (the driver
  /// profile's Sales tab), so a print or share stamps the copy REPRINTED /
  /// RESHARED — the same rule the orders list and the customer profile follow,
  /// and what stops a second copy passing as the original. A till surface (the
  /// driver terminal) leaves it false: its first copy *is* the original.
  final bool isReopened;

  const VanReceiptView({
    super.key,
    required this.orderNumber,
    required this.cart,
    required this.totalKobo,
    required this.cashReceivedKobo,
    this.orderStatus,
    this.autoPrint = false,
    this.isReopened = false,
  });

  @override
  ConsumerState<VanReceiptView> createState() => _VanReceiptViewState();
}

class _VanReceiptViewState extends ConsumerState<VanReceiptView> {
  final ScreenshotController _shot = ScreenshotController();

  bool _printing = false;

  /// Set on a re-open only — see [VanReceiptView.isReopened]. At most one of
  /// the two is ever non-null: a copy is either a reprint or a reshare.
  DateTime? _reprintAt;
  DateTime? _reshareAt;

  @override
  void initState() {
    super.initState();
    if (widget.autoPrint) {
      // After the first frame: the receipt has to exist on screen before the
      // "Printing receipt…" line above it means anything.
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_print()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_printing)
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
          controller: _shot,
          child: ReceiptWidget(
            orderId: widget.orderNumber,
            cart: widget.cart,
            subtotal: widget.totalKobo / 100.0,
            crateDeposit: 0,
            total: widget.totalKobo / 100.0,
            paymentMethod: 'Cash',
            cashReceived: widget.cashReceivedKobo / 100.0,
            orderStatus: widget.orderStatus,
            reprintDate: _reprintAt,
            reshareDate: _reshareAt,
            riderName: 'Van Sale',
            businessName: ref.watch(currentBusinessNameProvider),
          ),
        ),
        SizedBox(height: context.getRSize(16)),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _printing ? null : () => unawaited(_print()),
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
                onPressed: () => unawaited(_share()),
                icon: Icon(
                  FontAwesomeIcons.shareNodes.data,
                  size: context.getRSize(14),
                ),
                label: const Text('Share'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Builds the ESC/POS bytes and sends them, falling back to the manual
  /// printer picker when auto-connect finds nothing.
  Future<void> _print() async {
    if (!mounted) return;
    setState(() {
      _printing = true;
      if (widget.isReopened) {
        _reprintAt = DateTime.now();
        _reshareAt = null;
      }
    });
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
        orderId: widget.orderNumber,
        cart: widget.cart,
        subtotal: widget.totalKobo / 100.0,
        // No deposit on the road — swap-only (spec §11).
        crateDeposit: 0,
        total: widget.totalKobo / 100.0,
        paymentMethod: 'Cash',
        cashReceived: widget.cashReceivedKobo / 100.0,
        showWalletInfo: false,
        orderStatus: widget.orderStatus,
        reprintDate: _reprintAt,
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
  void _showPrinterPicker(PrinterService printer, List<int> receiptBytes) {
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

  /// Captures the on-screen receipt and hands it to the platform share sheet —
  /// the copy a customer with no printer in sight still walks away with.
  Future<void> _share() async {
    if (widget.isReopened) {
      setState(() {
        _reshareAt = DateTime.now();
        _reprintAt = null;
      });
      // The stamp has to be painted before the capture, or the image says
      // nothing about being a duplicate.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    try {
      final image = await _shot.capture(pixelRatio: 3.0);
      if (image == null) return;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/receipt_${widget.orderNumber}.png');
      await file.writeAsBytes(image);
      await Share.shareXFiles([
        XFile(file.path),
      ], text: 'Reebaplus POS Receipt');
    } catch (e) {
      if (mounted) AppNotification.showError(context, 'Share failed: $e');
    }
  }
}
